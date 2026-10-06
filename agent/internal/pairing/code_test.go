package pairing

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type vectors struct {
	Proofs []struct {
		Name           string `json:"name"`
		Code           string `json:"code"`
		FingerprintHex string `json:"fingerprintHex"`
		PhoneNonceHex  string `json:"phoneNonceHex"`
		AgentNonceHex  string `json:"agentNonceHex"`
		PhoneProofHex  string `json:"phoneProofHex"`
		AgentProofHex  string `json:"agentProofHex"`
	} `json:"proofs"`
	Normalization []struct {
		Input string  `json:"input"`
		Code  *string `json:"code"`
	} `json:"normalization"`
}

func loadVectors(t *testing.T) vectors {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v vectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	if len(v.Proofs) == 0 || len(v.Normalization) == 0 {
		t.Fatal("the vectors file is empty")
	}
	return v
}

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestProofsMatchTheSharedVectors(t *testing.T) {
	for _, p := range loadVectors(t).Proofs {
		fp, np, na := unhex(t, p.FingerprintHex), unhex(t, p.PhoneNonceHex), unhex(t, p.AgentNonceHex)
		if got := hex.EncodeToString(PhoneProof(p.Code, fp, np)); got != p.PhoneProofHex {
			t.Errorf("%s: phone proof = %s, want %s", p.Name, got, p.PhoneProofHex)
		}
		if got := hex.EncodeToString(AgentProof(p.Code, fp, np, na)); got != p.AgentProofHex {
			t.Errorf("%s: agent proof = %s, want %s", p.Name, got, p.AgentProofHex)
		}
	}
}

func TestNormalizeMatchesTheSharedVectors(t *testing.T) {
	for _, n := range loadVectors(t).Normalization {
		got, ok := Normalize(n.Input)
		switch {
		case n.Code == nil && ok:
			t.Errorf("Normalize(%q) = %q, want rejected", n.Input, got)
		case n.Code != nil && (!ok || got != *n.Code):
			t.Errorf("Normalize(%q) = %q, %v, want %q", n.Input, got, ok, *n.Code)
		}
	}
}

func TestAProofDependsOnEveryInput(t *testing.T) {
	fp := bytes.Repeat([]byte{1}, 32)
	np := bytes.Repeat([]byte{2}, 32)
	na := bytes.Repeat([]byte{3}, 32)
	base := hex.EncodeToString(PhoneProof("K7QM2XPA9TRC", fp, np))
	other := bytes.Repeat([]byte{9}, 32)
	for name, got := range map[string][]byte{
		"another code":        PhoneProof("K7QM2XPA9TRD", fp, np),
		"another fingerprint": PhoneProof("K7QM2XPA9TRC", other, np),
		"no fingerprint":      PhoneProof("K7QM2XPA9TRC", nil, np),
		"another nonce":       PhoneProof("K7QM2XPA9TRC", fp, other),
		"the agent's label":   AgentProof("K7QM2XPA9TRC", fp, np, nil),
	} {
		if hex.EncodeToString(got) == base {
			t.Errorf("%s gives the same proof", name)
		}
	}
	if bytes.Equal(AgentProof("K7QM2XPA9TRC", fp, np, na), AgentProof("K7QM2XPA9TRC", fp, np, other)) {
		t.Error("the agent proof ignores the agent nonce")
	}
}

func TestNewCodeIsCanonicalAndVaries(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		code, err := NewCode(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		if got, ok := Normalize(code); !ok || got != code {
			t.Fatalf("NewCode gave %q, which is not canonical", code)
		}
		seen[code] = true
	}
	if len(seen) != 200 {
		t.Fatalf("only %d distinct codes in 200 draws", len(seen))
	}
	if _, err := NewCode(bytes.NewReader([]byte{1, 2, 3})); err == nil {
		t.Fatal("a short random source was accepted")
	}
}

func TestNewCodeUsesTheWholeAlphabet(t *testing.T) {
	raw := make([]byte, 0, 36)
	for i := 0; i < 36; i++ {
		raw = append(raw, byte(i))
	}
	var all strings.Builder
	r := bytes.NewReader(raw)
	for i := 0; i < 3; i++ {
		code, err := NewCode(r)
		if err != nil {
			t.Fatal(err)
		}
		all.WriteString(code)
	}
	if got := all.String(); got != "0123456789ABCDEFGHJKMNPQRSTVWXYZ0123" {
		t.Fatalf("codes = %s", got)
	}
}

func TestFormat(t *testing.T) {
	if got := Format("K7QM2XPA9TRC"); got != "K7QM-2XPA-9TRC" {
		t.Fatalf("Format = %s", got)
	}
	if got := Format("short"); got != "short" {
		t.Fatalf("Format(short) = %s", got)
	}
}

func TestLink(t *testing.T) {
	got := Link(LinkParams{Host: "my-server.lan", Port: "8443", Fingerprint: "OfCPv7Bu5FeqspEEZcUtbwd9RqmtauCT2Hr78uU9WwI", Code: "K7QM2XPA9TRC", Name: "home lab"})
	want := "dockermobile://pair?c=K7QM2XPA9TRC&f=OfCPv7Bu5FeqspEEZcUtbwd9RqmtauCT2Hr78uU9WwI&h=my-server.lan&n=home+lab&p=8443&v=1"
	if got != want {
		t.Fatalf("Link =\n %s\nwant\n %s", got, want)
	}
	bare := Link(LinkParams{Scheme: "https", Host: "docker.example.com", Code: "K7QM2XPA9TRC"})
	if bare != "dockermobile://pair?c=K7QM2XPA9TRC&h=docker.example.com&s=https&v=1" {
		t.Fatalf("Link without a pin = %s", bare)
	}
	if only := Link(LinkParams{Fingerprint: "abc", Code: "K7QM2XPA9TRC"}); only != "dockermobile://pair?c=K7QM2XPA9TRC&f=abc&v=1" {
		t.Fatalf("Link without an address = %s", only)
	}
}
