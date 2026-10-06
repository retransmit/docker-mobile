// Package tlsid owns the agent's TLS identity: one long-lived key, a
// self-signed certificate around it, and the fingerprint phones pin.
package tlsid

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/state"
)

const (
	keyFile  = "tls.key"
	certFile = "tls.crt"
	// validity is how long a certificate lasts. Phones pin the key, not the
	// certificate, so a renewal changes nothing for them.
	validity = 10 * 365 * 24 * time.Hour
	// renewBefore is how close to expiry a certificate is reissued.
	renewBefore = 30 * 24 * time.Hour
)

// ServerName is the name the certificate is issued for. Phones do not check
// it (they pin the key); the agent's own health check does.
const ServerName = "docker-mobile-agent"

// Fingerprint identifies the agent: SHA-256 over the DER encoding of the
// certificate's SubjectPublicKeyInfo.
type Fingerprint [sha256.Size]byte

// String is the form used in pairing links: base64url without padding.
func (f Fingerprint) String() string { return base64.RawURLEncoding.EncodeToString(f[:]) }

// Display is the form shown to people, in the style of an SSH key fingerprint.
func (f Fingerprint) Display() string { return "SHA256:" + f.String() }

// LoadOrCreate returns the identity stored in dir. On first use it creates a
// P-256 key and a self-signed certificate. A certificate close to expiry is
// reissued around the same key.
func LoadOrCreate(dir *state.Dir, now time.Time) (tls.Certificate, error) {
	keyPEM, keyErr := dir.ReadFile(keyFile)
	certPEM, certErr := dir.ReadFile(certFile)
	switch {
	case errors.Is(keyErr, os.ErrNotExist) && errors.Is(certErr, os.ErrNotExist):
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return tls.Certificate{}, fmt.Errorf("generate key: %w", err)
		}
		der, err := x509.MarshalECPrivateKey(key)
		if err != nil {
			return tls.Certificate{}, fmt.Errorf("encode key: %w", err)
		}
		if err := dir.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der})); err != nil {
			return tls.Certificate{}, err
		}
		return issue(dir, key, now)
	case keyErr != nil:
		return tls.Certificate{}, fmt.Errorf("read %s: %w", keyFile, keyErr)
	}

	key, err := parseKey(keyPEM)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("%s: %w", keyFile, err)
	}
	if errors.Is(certErr, os.ErrNotExist) {
		return issue(dir, key, now)
	}
	if certErr != nil {
		return tls.Certificate{}, fmt.Errorf("read %s: %w", certFile, certErr)
	}
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("%s does not belong to %s: %w", certFile, keyFile, err)
	}
	leaf, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("%s: %w", certFile, err)
	}
	if now.After(leaf.NotAfter.Add(-renewBefore)) {
		return issue(dir, key, now)
	}
	cert.Leaf = leaf
	return cert, nil
}

func parseKey(keyPEM []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(keyPEM)
	if block == nil || block.Type != "EC PRIVATE KEY" {
		return nil, errors.New("not an EC private key in PEM form")
	}
	return x509.ParseECPrivateKey(block.Bytes)
}

// issue writes a fresh self-signed certificate for key and returns the pair.
func issue(dir *state.Dir, key *ecdsa.PrivateKey, now time.Time) (tls.Certificate, error) {
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("serial: %w", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: ServerName},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(validity),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{ServerName},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("create certificate: %w", err)
	}
	if err := dir.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})); err != nil {
		return tls.Certificate{}, err
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		return tls.Certificate{}, fmt.Errorf("parse new certificate: %w", err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}, nil
}

// FingerprintOf returns the fingerprint of a loaded identity.
func FingerprintOf(cert tls.Certificate) (Fingerprint, error) {
	if len(cert.Certificate) == 0 {
		return Fingerprint{}, errors.New("no certificate")
	}
	return FingerprintOfDER(cert.Certificate[0])
}

// FingerprintOfDER returns the fingerprint of a DER-encoded certificate.
func FingerprintOfDER(der []byte) (Fingerprint, error) {
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		return Fingerprint{}, fmt.Errorf("parse certificate: %w", err)
	}
	return sha256.Sum256(leaf.RawSubjectPublicKeyInfo), nil
}

// ReadFingerprint returns the fingerprint of the certificate stored in the
// state folder dataDir, without creating anything.
func ReadFingerprint(dataDir string) (Fingerprint, error) {
	certPEM, err := os.ReadFile(filepath.Join(dataDir, certFile))
	if err != nil {
		return Fingerprint{}, err
	}
	block, _ := pem.Decode(certPEM)
	if block == nil || block.Type != "CERTIFICATE" {
		return Fingerprint{}, fmt.Errorf("%s is not a certificate in PEM form", certFile)
	}
	return FingerprintOfDER(block.Bytes)
}

// LocalClientConfig is for a client on the same machine, such as the health
// check: it trusts exactly the certificate stored in the state folder
// dataDir, and nothing else.
func LocalClientConfig(dataDir string) (*tls.Config, error) {
	certPEM, err := os.ReadFile(filepath.Join(dataDir, certFile))
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(certPEM) {
		return nil, fmt.Errorf("%s is not a certificate in PEM form", certFile)
	}
	return &tls.Config{RootCAs: pool, ServerName: ServerName, MinVersion: tls.VersionTLS13}, nil
}

// ServerConfig is the TLS configuration the agent listens with: its single
// certificate, TLS 1.3 only.
func ServerConfig(cert tls.Certificate) *tls.Config {
	return &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS13}
}
