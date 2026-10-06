// Package pairing implements how a phone and the agent first come to trust
// each other: a one-time code shown on the server, and a proof exchange that
// binds that code to the agent's certificate without ever sending it.
package pairing

import (
	"crypto/hmac"
	"crypto/sha256"
	"fmt"
	"io"
	"net/url"
	"strings"
)

// CodeLen is the number of characters in a pairing code: 12 symbols of
// 5 bits each, 60 bits in all.
const CodeLen = 12

// alphabet is Crockford base32: digits and letters without I, L, O and U.
const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// NewCode draws a random code from rand.
func NewCode(rand io.Reader) (string, error) {
	raw := make([]byte, CodeLen)
	if _, err := io.ReadFull(rand, raw); err != nil {
		return "", fmt.Errorf("random code: %w", err)
	}
	out := make([]byte, CodeLen)
	for i, b := range raw {
		out[i] = alphabet[b&31]
	}
	return string(out), nil
}

// Normalize turns what a person typed into the canonical code: upper case,
// hyphens and spaces dropped, O read as 0, I and L as 1. The bool is false
// when the result is not a valid code.
func Normalize(input string) (string, bool) {
	var b strings.Builder
	for _, r := range strings.ToUpper(input) {
		switch r {
		case '-', ' ':
			continue
		case 'O':
			r = '0'
		case 'I', 'L':
			r = '1'
		}
		if r > 127 || !strings.ContainsRune(alphabet, r) {
			return "", false
		}
		b.WriteRune(r)
	}
	if b.Len() != CodeLen {
		return "", false
	}
	return b.String(), true
}

// Format shows a canonical code in three groups: XXXX-XXXX-XXXX.
func Format(code string) string {
	if len(code) != CodeLen {
		return code
	}
	return code[0:4] + "-" + code[4:8] + "-" + code[8:12]
}

const context = "docker-mobile pair v1"

// NonceLen is the length of the random value each side contributes.
const NonceLen = 32

// PhoneProof is what the phone sends: an HMAC keyed with the code over the
// fingerprint the phone sees on its connection and its own nonce.
// fingerprint is 32 bytes, or empty when the agent has no certificate of its
// own (it runs behind a proxy that terminates TLS).
func PhoneProof(code string, fingerprint, phoneNonce []byte) []byte {
	return proof(code, "phone", fingerprint, phoneNonce)
}

// AgentProof is the answer: the same construction with the other label and
// both nonces, so the phone knows the agent holds the code too.
func AgentProof(code string, fingerprint, phoneNonce, agentNonce []byte) []byte {
	return proof(code, "agent", fingerprint, phoneNonce, agentNonce)
}

func proof(code, who string, fingerprint []byte, nonces ...[]byte) []byte {
	mac := hmac.New(sha256.New, []byte(code))
	mac.Write([]byte(context))
	mac.Write([]byte{0})
	mac.Write([]byte(who))
	mac.Write([]byte{0})
	mac.Write([]byte{byte(len(fingerprint))})
	mac.Write(fingerprint)
	for _, n := range nonces {
		mac.Write(n)
	}
	return mac.Sum(nil)
}

// LinkParams is what a pairing link carries.
type LinkParams struct {
	// Host and Port say where the agent is reachable; both may be empty,
	// and the app then asks for the address.
	Host string
	Port string
	// Fingerprint is the pinned form (base64url); empty without a pin.
	Fingerprint string
	// Scheme is "https" or "http" when there is no pin; empty otherwise.
	Scheme string
	Code   string
	// Name is how the agent calls itself, shown on the confirm step.
	Name string
}

// Link builds the dockermobile://pair link, which is also the QR content.
func Link(p LinkParams) string {
	q := url.Values{}
	q.Set("v", "1")
	if p.Host != "" {
		q.Set("h", p.Host)
	}
	if p.Port != "" {
		q.Set("p", p.Port)
	}
	if p.Fingerprint != "" {
		q.Set("f", p.Fingerprint)
	}
	if p.Scheme != "" {
		q.Set("s", p.Scheme)
	}
	q.Set("c", p.Code)
	if p.Name != "" {
		q.Set("n", p.Name)
	}
	return "dockermobile://pair?" + q.Encode()
}
