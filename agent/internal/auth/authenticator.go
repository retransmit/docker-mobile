// Package auth decides who sent a request: a paired device, the shared
// token from the environment, or nobody.
package auth

import (
	"context"
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
	// OnCaller is told who a request belongs to, once that is known.
	OnCaller func(r *http.Request, dev state.Device)
}

// Require lets a request through only with valid credentials. A paired
// device always passes. Anything else from an address that has failed too
// often is refused without a look at its token, so the shared token cannot
// be guessed at speed.
func (a *Authenticator) Require(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		bearer, hasBearer := bearerToken(r)
		if hasBearer && state.IsDeviceToken(bearer) {
			if dev, ok := a.Devices.Authenticate(bearer); ok {
				a.serve(w, r, dev, next)
				return
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
		if hasBearer && a.Legacy != "" && !state.IsDeviceToken(bearer) &&
			subtle.ConstantTimeCompare([]byte(bearer), []byte(a.Legacy)) == 1 {
			a.serve(w, r, state.Device{ID: LegacyDeviceID, Name: "env-token", Role: state.RoleFull}, next)
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

func (a *Authenticator) serve(w http.ResponseWriter, r *http.Request, dev state.Device, next http.Handler) {
	if a.OnCaller != nil {
		a.OnCaller(r, dev)
	}
	ctx := r.Context()
	if a.Conns != nil {
		tracked, release := a.Conns.Track(ctx, dev.ID)
		defer release()
		ctx = tracked
	}
	next.ServeHTTP(w, r.WithContext(WithCaller(ctx, dev)))
}

func bearerToken(r *http.Request) (string, bool) {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || token == "" {
		return "", false
	}
	return token, true
}

// WriteError answers with a JSON body shaped like the Docker API's errors, so
// clients read agent errors and daemon errors the same way.
func WriteError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"message": message})
}
