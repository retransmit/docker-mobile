// Package pairing implements how a phone and the agent first come to trust
// each other: a one-time code shown on the server, and a proof exchange that
// binds that code to the agent's certificate without ever sending it.
package pairing

import (
	"crypto/hmac"
	"crypto/pbkdf2"
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

// Normalize turns what a person typed into the canonical code: the letters a
// to z made upper case, hyphens and spaces dropped, O read as 0, I and L as
// 1. The bool is false when the result is not a valid code.
//
// Only ASCII is accepted. Anything above 127 is refused as it is, before any
// change of case, so that no letter of another script can turn into one of
// the alphabet on the way.
func Normalize(input string) (string, bool) {
	var b strings.Builder
	for _, r := range input {
		if r > 127 {
			return "", false
		}
		if r >= 'a' && r <= 'z' {
			r -= 'a' - 'A'
		}
		switch r {
		case '-', ' ':
			continue
		case 'O':
			r = '0'
		case 'I', 'L':
			r = '1'
		}
		if !strings.ContainsRune(alphabet, r) {
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

// proofContext names the exchange and its version. It is the first part of
// the salt of the key and the first part of what both proofs authenticate.
const proofContext = "docker-mobile pair v1"

// stretchRounds is how many rounds of PBKDF2 turn a code into the key of the
// proofs. A code holds only 60 bits, so whoever has seen one proof can try
// every code against it; the rounds make each of those tries cost this many
// times more, and the salt (see proofKey) keeps them from being prepared
// before the proof is seen.
const stretchRounds = 100000

// NonceLen is the length of the random value each side contributes.
const NonceLen = 32

// PhoneProof is what the phone sends: an HMAC keyed with the stretched code
// over the fingerprint the phone sees on its connection and its own nonce.
// The nonce also salts the stretch (see proofKey), so the key is good for
// this one attempt and no other. That is why the phone must draw a fresh,
// random nonce for every attempt.
//
// code is a canonical code of CodeLen characters. fingerprint is 32 bytes,
// or empty when the agent has no certificate of its own (it runs behind a
// proxy that terminates TLS). phoneNonce is NonceLen bytes. None of this is
// checked here: the length of the fingerprint is written as a single byte
// and the nonce is written without one, so the caller must check the length
// of anything that came from the network before calling.
func PhoneProof(code string, fingerprint, phoneNonce []byte) []byte {
	return proof(code, "phone", fingerprint, phoneNonce)
}

// AgentProof is the answer: the same construction with the other label and
// both nonces, so the phone knows the agent holds the code too. Its key is
// the key of the phone's proof: the stretch is salted with the phone's
// nonce, and both proofs of one attempt carry that nonce.
//
// It expects what PhoneProof expects, and agentNonce is NonceLen bytes too.
// The two nonces are written one after the other with nothing between them,
// so here as well the caller must check the lengths of anything that came
// from the network before calling.
func AgentProof(code string, fingerprint, phoneNonce, agentNonce []byte) []byte {
	return proof(code, "agent", fingerprint, phoneNonce, agentNonce)
}

// proofKey stretches a code into the 32-byte key of both proofs of one
// attempt. The salt is proofContext, a zero byte and the phone's nonce.
//
// The nonce is in the salt so that a key computed for one attempt is useless
// for any other: nothing can be stretched ahead of time and kept for a
// pairing that is still to come. This holds only while the phone's nonce is
// fresh and random for every attempt, so that nobody knows it beforehand.
func proofKey(code string, phoneNonce []byte) []byte {
	salt := make([]byte, 0, len(proofContext)+1+len(phoneNonce))
	salt = append(salt, proofContext...)
	salt = append(salt, 0)
	salt = append(salt, phoneNonce...)
	key, err := pbkdf2.Key(sha256.New, code, salt, stretchRounds, sha256.Size)
	if err != nil {
		// Only parameters the library refuses lead here, and nothing a
		// caller passes is one of them: the hash, the rounds and the length
		// are constants, and the salt is never shorter than proofContext.
		panic("pairing: stretching the code: " + err.Error())
	}
	return key
}

func proof(code, who string, fingerprint []byte, nonces ...[]byte) []byte {
	// The first nonce is the phone's; both callers pass it.
	mac := hmac.New(sha256.New, proofKey(code, nonces[0]))
	mac.Write([]byte(proofContext))
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
