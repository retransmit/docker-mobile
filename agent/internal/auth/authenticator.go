// Package auth decides who sent a request: a paired device, the shared
// token from the environment, or nobody.
package auth

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"math"
	"net/http"
	"strconv"
	"strings"

	"github.com/retransmit/docker-mobile/agent/internal/conns"
	"github.com/retransmit/docker-mobile/agent/internal/state"
	"github.com/retransmit/docker-mobile/agent/internal/throttle"
)

// LegacyDeviceID is the id requests carry when they authenticate with the
// shared token from the environment.
const LegacyDeviceID = "env"

type callerKey struct{}

// WithCaller returns a context that knows which device sent the request.
func WithCaller(ctx context.Context, dev state.Device) context.Context {
	return context.WithValue(ctx, callerKey{}, dev)
}

// Caller returns the device that sent the request, if it was authenticated.
func Caller(ctx context.Context) (state.Device, bool) {
	dev, ok := ctx.Value(callerKey{}).(state.Device)
	return dev, ok
}

// Authenticator guards handlers. Devices is required; the rest is optional.
type Authenticator struct {
	Devices *state.Devices
	// Legacy is the shared token from the environment; empty disables it.
	Legacy  string
	Limiter *throttle.Limiter
	Conns   *conns.Registry
	// OnFailure is told the source address of every failed attempt.
	OnFailure func(remoteAddr string)
	// OnCaller is told who a request belongs to, once that is known. The
	// device comes without the hash of its token, as does the one in the
	// request's context.
	OnCaller func(r *http.Request, dev state.Device)
}

// Require lets a request through only with valid credentials. A token with
// the shape of a device token is always looked up, and a paired device passes
// whatever its address has done before: the failures of others behind the
// same address must not lock it out. Any other request from an address that
// has failed too often is answered with 429; the shared token is not compared
// then, so it cannot be guessed at speed. A request that fails is counted
// against its address, except while that address is blocked.
func (a *Authenticator) Require(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		bearer, hasBearer := bearerToken(r)
		if hasBearer && state.IsDeviceToken(bearer) {
			if dev, ok := a.Devices.Authenticate(bearer); ok {
				if a.serve(w, r, dev, bearer, next) {
					return
				}
			}
		}
		key := throttle.Key(r.RemoteAddr)
		if a.Limiter != nil {
			if left, blocked := a.Limiter.Blocked(key); blocked {
				w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(left.Seconds()))))
				WriteError(w, http.StatusTooManyRequests, "Too many failed attempts from this address")
				return
			}
		}
		if hasBearer && a.Legacy != "" && !state.IsDeviceToken(bearer) && sameToken(bearer, a.Legacy) {
			a.serve(w, r, state.Device{ID: LegacyDeviceID, Name: "env-token", Role: state.RoleFull}, "", next)
			return
		}
		if a.Limiter != nil {
			a.Limiter.Fail(key)
		}
		if a.OnFailure != nil {
			a.OnFailure(r.RemoteAddr)
		}
		WriteError(w, http.StatusUnauthorized, "unauthorized")
	})
}

// serve hands a request with valid credentials to next. deviceToken is the
// token of the paired device it came from, or empty when it came with the
// shared token. It reports false, having answered nothing, when the device is
// no longer paired.
func (a *Authenticator) serve(w http.ResponseWriter, r *http.Request, dev state.Device, deviceToken string, next http.Handler) bool {
	parent := r.Context()
	ctx := parent
	endedByRegistry := false
	if a.Conns != nil {
		tracked, release := a.Conns.Track(parent, dev.ID)
		defer release()
		ctx = tracked
		// Over before it began although the client is still there: the
		// registry ended the request. A client that went away ends parent as
		// well, and that is not the registry's doing. Asking parent after
		// tracked is what makes this sure: a parent that is alive now was
		// alive when tracked was found ended.
		endedByRegistry = tracked.Err() != nil && parent.Err() == nil
	}
	// The token was accepted before the request was tracked. A device removed
	// in between had its requests closed while this one was not tracked yet,
	// so nothing would end it. Hence the second lookup, now that the request
	// is tracked: if the device is still paired, any removal comes later and
	// its close ends this request too; if it is not, the request is refused.
	if deviceToken != "" {
		paired, ok := a.Devices.Authenticate(deviceToken)
		if !ok {
			return false
		}
		dev = paired
	}
	// Nothing further in needs the hash of the token, and whatever prints or
	// encodes the caller must not find it there.
	dev.TokenHash = ""
	if a.OnCaller != nil {
		a.OnCaller(r, dev)
	}
	// The registry had ended the request before its device was looked up
	// again and found. A removal would have unpaired the device by then, so
	// this is the registry refusing everything. That is why the look at the
	// context comes before the lookup: taken after it, a device removed just
	// after the lookup would be told that the agent stops.
	if endedByRegistry {
		WriteError(w, http.StatusServiceUnavailable, "The agent is shutting down")
		return true
	}
	next.ServeHTTP(w, r.WithContext(WithCaller(ctx, dev)))
	return true
}

func bearerToken(r *http.Request) (string, bool) {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || token == "" {
		return "", false
	}
	return token, true
}

// sameToken compares two tokens in constant time. It compares their SHA-256
// digests, which always have the same length: comparing the tokens themselves
// would answer sooner for a guess of another length, and so give the length
// of the shared token away.
func sameToken(got, want string) bool {
	gotSum, wantSum := sha256.Sum256([]byte(got)), sha256.Sum256([]byte(want))
	return subtle.ConstantTimeCompare(gotSum[:], wantSum[:]) == 1
}

// WriteError answers with a JSON body shaped like the Docker API's errors, so
// clients read agent errors and daemon errors the same way.
func WriteError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"message": message})
}
