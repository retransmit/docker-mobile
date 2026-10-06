// Package policy decides which Docker requests a read-only device may send.
// It denies by default: only requests on a short list of reads pass.
package policy

import (
	"net/http"
	"regexp"
	"strings"
)

// Segment shapes. An id or name starts with a letter or digit; an image
// reference may also contain "/", ":" and "@".
const (
	idSeg    = `[A-Za-z0-9][A-Za-z0-9_.-]*`
	imageSeg = `[A-Za-z0-9][A-Za-z0-9_.:@/-]*`
)

var apiVersion = regexp.MustCompile(`^/v[0-9]+\.[0-9]+(/|$)`)

// readOnly is every read the app performs.
var readOnly = []*regexp.Regexp{
	regexp.MustCompile(`^/_ping$`),
	regexp.MustCompile(`^/version$`),
	regexp.MustCompile(`^/info$`),
	regexp.MustCompile(`^/system/df$`),
	regexp.MustCompile(`^/events$`),
	regexp.MustCompile(`^/containers/json$`),
	regexp.MustCompile(`^/containers/` + idSeg + `/(json|logs|stats)$`),
	regexp.MustCompile(`^/images/json$`),
	regexp.MustCompile(`^/images/` + imageSeg + `/(json|history)$`),
	regexp.MustCompile(`^/networks$`),
	regexp.MustCompile(`^/networks/` + idSeg + `$`),
	regexp.MustCompile(`^/volumes$`),
	regexp.MustCompile(`^/volumes/` + idSeg + `$`),
	regexp.MustCompile(`^/agent/v1/whoami$`),
}

// AllowedReadOnly reports whether a read-only device may send a request with
// this method and path. escapedPath is the path exactly as it will be
// forwarded (r.URL.EscapedPath()).
func AllowedReadOnly(method, escapedPath string) bool {
	if method != http.MethodGet && method != http.MethodHead {
		return false
	}
	// Refuse anything a server further down might read differently than we
	// do: percent-encoding, dot segments, empty segments, backslashes.
	if strings.ContainsAny(escapedPath, `%\`) || strings.Contains(escapedPath, "//") {
		return false
	}
	for _, seg := range strings.Split(escapedPath, "/") {
		if seg == "." || seg == ".." {
			return false
		}
	}
	path := escapedPath
	if loc := apiVersion.FindStringIndex(path); loc != nil {
		path = path[loc[1]-1:]
		if !strings.HasPrefix(path, "/") {
			return false
		}
	}
	for _, re := range readOnly {
		if re.MatchString(path) {
			return true
		}
	}
	return false
}
