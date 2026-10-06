package policy

import "testing"

const id = "3f2a9c1b7d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4f5061728394a5b6c7d8e"

// reads holds at least one path for every rule of the allow list, without an
// API version in front.
var reads = []string{
	"/_ping",
	"/version",
	"/info",
	"/system/df",
	"/events",
	"/containers/json",
	"/containers/" + id + "/json",
	"/containers/" + id + "/logs",
	"/containers/" + id + "/stats",
	"/containers/my_web-1.2/json",
	"/images/json",
	"/images/sha256:" + id + "/json",
	"/images/sha256:" + id + "/history",
	"/images/nginx:1.27/json",
	"/images/ghcr.io/owner/app:latest/json",
	"/images/registry.example.com:5000/team/app@sha256:" + id + "/history",
	"/networks",
	"/networks/" + id,
	"/networks/bridge",
	"/volumes",
	"/volumes/pg_data",
	"/agent/v1/whoami",
}

func TestEveryReadTheAppMakesIsAllowed(t *testing.T) {
	for _, p := range reads {
		for _, prefix := range []string{"", "/v1.45", "/v1.41"} {
			for _, method := range []string{"GET", "HEAD"} {
				if !AllowedReadOnly(method, prefix+p) {
					t.Errorf("%s %s%s was refused", method, prefix, p)
				}
			}
		}
	}
}

func TestEverythingThatChangesSomethingIsRefused(t *testing.T) {
	writes := []struct{ method, path string }{
		{"POST", "/containers/create"},
		{"POST", "/containers/" + id + "/start"},
		{"POST", "/containers/" + id + "/stop"},
		{"POST", "/containers/" + id + "/restart"},
		{"POST", "/containers/" + id + "/kill"},
		{"POST", "/containers/" + id + "/pause"},
		{"POST", "/containers/" + id + "/unpause"},
		{"POST", "/containers/" + id + "/rename"},
		{"POST", "/containers/" + id + "/exec"},
		{"POST", "/containers/prune"},
		{"DELETE", "/containers/" + id},
		{"POST", "/exec/" + id + "/resize"},
		{"POST", "/exec/" + id + "/start"},
		{"POST", "/images/create"},
		{"POST", "/images/" + id + "/tag"},
		{"POST", "/images/prune"},
		{"DELETE", "/images/" + id},
		{"POST", "/networks/create"},
		{"POST", "/networks/prune"},
		{"DELETE", "/networks/" + id},
		{"POST", "/volumes/create"},
		{"POST", "/volumes/prune"},
		{"DELETE", "/volumes/pg_data"},
		{"POST", "/build/prune"},
		{"POST", "/build"},
		{"PUT", "/containers/" + id + "/archive"},
		// A read path with a method that is not a read.
		{"POST", "/containers/json"},
		{"DELETE", "/containers/" + id + "/json"},
		{"PUT", "/info"},
		{"PATCH", "/version"},
		{"OPTIONS", "/events"},
		{"CONNECT", "/_ping"},
	}
	for _, w := range writes {
		for _, prefix := range []string{"", "/v1.45"} {
			if AllowedReadOnly(w.method, prefix+w.path) {
				t.Errorf("%s %s%s was allowed", w.method, prefix, w.path)
			}
		}
	}
}

func TestReadsThatLeakOrAreNotUsedAreRefused(t *testing.T) {
	paths := []string{
		"/",
		"",
		"/containers/" + id + "/archive",
		"/containers/" + id + "/export",
		"/containers/" + id + "/changes",
		"/containers/" + id + "/top",
		"/containers/" + id + "/attach/ws",
		"/containers/" + id,
		"/exec/" + id + "/json",
		"/exec/" + id + "/ws",
		"/images/get",
		"/images/" + id + "/get",
		"/images/search",
		"/secrets",
		"/configs",
		"/swarm",
		"/swarm/unlockkey",
		"/nodes",
		"/services",
		"/plugins",
		"/session",
		"/agent/v1/pair",
		"/agent/v1/devices",
		"/healthz/extra",
	}
	for _, p := range paths {
		if AllowedReadOnly("GET", p) {
			t.Errorf("GET %s was allowed", p)
		}
	}
}

func TestPathTricksAreRefused(t *testing.T) {
	paths := []string{
		"/containers/../containers/json",
		"/containers/json/..",
		"/containers/./json",
		"/./containers/json",
		"//containers/json",
		"/containers//json",
		"/containers/json/",
		"/containers/" + id + "/json/",
		"/containers/%2e%2e/json",
		"/containers/abc%2Fjson",
		"/containers/abc%2fstart/json",
		"/containers/abc%5cjson",
		`/containers/abc\json`,
		"/containers/abc/json%00",
		"/containers/abc/json;x",
		"/containers/abc/json?x",
		"/containers/-abc/json",
		"/containers/.hidden/json",
		"/volumes/..",
		"/networks/a/b",
		"/v1.45",
		"/v1.45/",
		"/v1.45/v1.45/containers/json",
		"/v1.45x/containers/json",
		"/v1/containers/json",
		"/vv1.45/containers/json",
		"/images/../containers/x/json",
		"/images/a/../../info/json",
		"/CONTAINERS/json",
		" /containers/json",
	}
	for _, p := range paths {
		if AllowedReadOnly("GET", p) {
			t.Errorf("GET %q was allowed", p)
		}
	}
}

func TestImageNamesMayContainSlashesButNotReachOtherRoutes(t *testing.T) {
	// An image reference may hold "/", so the suffix decides: only json and
	// history are reads.
	for _, p := range []string{
		"/images/library/nginx/json",
		"/images/a/b/c/history",
	} {
		if !AllowedReadOnly("GET", p) {
			t.Errorf("GET %s was refused", p)
		}
	}
	for _, p := range []string{
		"/images/library/nginx/get",
		"/images/library/nginx/push",
		"/images/a/json/tag",
	} {
		if AllowedReadOnly("GET", p) {
			t.Errorf("GET %s was allowed", p)
		}
	}
}

func TestNothingMayBeAddedToEitherEndOfARead(t *testing.T) {
	// Adding "/x" to these two gives a read of its own, because the rule
	// named beside each takes "x" as the name to inspect.
	inspectsX := map[string]bool{
		"/networks": true, // `^/networks/` + idSeg + `$`
		"/volumes":  true, // `^/volumes/` + idSeg + `$`
	}
	for _, p := range reads {
		for _, q := range []string{"/x" + p, p + "/"} {
			if AllowedReadOnly("GET", q) {
				t.Errorf("GET %s was allowed", q)
			}
		}
		if got, want := AllowedReadOnly("GET", p+"/x"), inspectsX[p]; got != want {
			t.Errorf("GET %s/x: allowed is %v, want %v", p, got, want)
		}
	}
}

func TestNearMissesOfARuleAreRefused(t *testing.T) {
	paths := []string{
		// An empty or "." segment inside an image name.
		"/images/a//json",
		"/images/a/./json",
		// Only an image name may hold "/".
		"/containers/a/b/json",
		"/volumes/a/b",
		// An image name starts with a letter or digit.
		"/images/-x/json",
		// The image list is the whole path, not the start of a longer one.
		"/images/json/get",
		"/images/json-server/get",
		// The network and volume rules start at the root.
		"/containers/networks/archive",
		"/containers/volumes/export",
		// An API version is "/v", digits, a dot, digits, at the very start.
		"/v1x45/info",
		"/x/v1.45/info",
	}
	for _, p := range paths {
		if AllowedReadOnly("GET", p) {
			t.Errorf("GET %s was allowed", p)
		}
	}
}

func TestTheMethodIsMatchedExactly(t *testing.T) {
	for _, method := range []string{"get", "Get", "head", ""} {
		for _, p := range reads {
			if AllowedReadOnly(method, p) {
				t.Errorf("%q %s was allowed", method, p)
			}
		}
	}
}
