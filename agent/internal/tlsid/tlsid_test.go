package tlsid

import (
	"crypto/ecdsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/state"
)

var t0 = time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)

func openTemp(t *testing.T) *state.Dir {
	t.Helper()
	d, err := state.Open(filepath.Join(t.TempDir(), "data"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	return d
}

func TestFirstUseCreatesAP256IdentityValidForTenYears(t *testing.T) {
	d := openTemp(t)
	cert, err := LoadOrCreate(d, t0)
	if err != nil {
		t.Fatalf("LoadOrCreate: %v", err)
	}
	key, ok := cert.PrivateKey.(*ecdsa.PrivateKey)
	if !ok || key.Curve.Params().Name != "P-256" {
		t.Fatalf("key = %T, want ECDSA P-256", cert.PrivateKey)
	}
	if cert.Leaf == nil {
		t.Fatal("Leaf is not set")
	}
	if got := cert.Leaf.NotAfter.Sub(t0); got != validity {
		t.Fatalf("validity = %v, want %v", got, validity)
	}
	for _, name := range []string{"tls.key", "tls.crt"} {
		if _, err := os.Stat(d.Path(name)); err != nil {
			t.Fatalf("%s was not written: %v", name, err)
		}
	}
}

func TestASecondLoadReturnsTheSameIdentity(t *testing.T) {
	d := openTemp(t)
	first, _ := LoadOrCreate(d, t0)
	second, err := LoadOrCreate(d, t0.Add(24*time.Hour))
	if err != nil {
		t.Fatalf("LoadOrCreate: %v", err)
	}
	if string(first.Certificate[0]) != string(second.Certificate[0]) {
		t.Fatal("the certificate changed between two loads")
	}
}

func TestACertificateCloseToExpiryIsReissuedAroundTheSameKey(t *testing.T) {
	d := openTemp(t)
	first, _ := LoadOrCreate(d, t0)
	fpBefore, _ := FingerprintOf(first)

	late := t0.Add(validity - 29*24*time.Hour)
	second, err := LoadOrCreate(d, late)
	if err != nil {
		t.Fatalf("LoadOrCreate: %v", err)
	}
	if string(first.Certificate[0]) == string(second.Certificate[0]) {
		t.Fatal("the certificate was not reissued")
	}
	if got := second.Leaf.NotAfter.Sub(late); got != validity {
		t.Fatalf("new validity = %v, want %v", got, validity)
	}
	fpAfter, _ := FingerprintOf(second)
	if fpBefore != fpAfter {
		t.Fatal("the fingerprint changed with the renewal")
	}
}

func TestACertificateWithMoreThanThirtyDaysLeftIsKept(t *testing.T) {
	d := openTemp(t)
	first, _ := LoadOrCreate(d, t0)
	second, err := LoadOrCreate(d, t0.Add(validity-31*24*time.Hour))
	if err != nil {
		t.Fatalf("LoadOrCreate: %v", err)
	}
	if string(first.Certificate[0]) != string(second.Certificate[0]) {
		t.Fatal("the certificate was reissued too early")
	}
}

func TestAMissingCertificateIsReissuedForAnExistingKey(t *testing.T) {
	d := openTemp(t)
	first, _ := LoadOrCreate(d, t0)
	fpBefore, _ := FingerprintOf(first)
	if err := os.Remove(d.Path("tls.crt")); err != nil {
		t.Fatal(err)
	}
	second, err := LoadOrCreate(d, t0)
	if err != nil {
		t.Fatalf("LoadOrCreate: %v", err)
	}
	fpAfter, _ := FingerprintOf(second)
	if fpBefore != fpAfter {
		t.Fatal("a new key was made although the old one was there")
	}
}

func TestDamagedFilesAreErrors(t *testing.T) {
	d := openTemp(t)
	LoadOrCreate(d, t0)
	if err := d.WriteFile("tls.key", []byte("not a key")); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadOrCreate(d, t0); err == nil {
		t.Fatal("a damaged key was accepted")
	}

	d2 := openTemp(t)
	LoadOrCreate(d2, t0)
	other := openTemp(t)
	LoadOrCreate(other, t0)
	foreign, _ := other.ReadFile("tls.crt")
	if err := d2.WriteFile("tls.crt", foreign); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadOrCreate(d2, t0); err == nil {
		t.Fatal("a certificate for another key was accepted")
	}

	d3 := openTemp(t)
	LoadOrCreate(d3, t0)
	if err := os.Remove(d3.Path("tls.key")); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadOrCreate(d3, t0); err == nil {
		t.Fatal("a certificate without its key was accepted")
	}
}

func TestFingerprintMatchesTheSharedVector(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "fingerprint.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		CertificateDerBase64 string `json:"certificateDerBase64"`
		Fingerprint          string `json:"fingerprint"`
	}
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	der, err := base64.StdEncoding.DecodeString(v.CertificateDerBase64)
	if err != nil {
		t.Fatal(err)
	}
	fp, err := FingerprintOfDER(der)
	if err != nil {
		t.Fatalf("FingerprintOfDER: %v", err)
	}
	if fp.String() != v.Fingerprint {
		t.Fatalf("fingerprint = %s, want %s", fp, v.Fingerprint)
	}
	if fp.Display() != "SHA256:"+v.Fingerprint {
		t.Fatalf("Display = %s", fp.Display())
	}
	if _, err := FingerprintOfDER([]byte("junk")); err == nil {
		t.Fatal("junk accepted as a certificate")
	}
}

func TestServerConfigSpeaksTLS13OnlyAndPresentsTheIdentity(t *testing.T) {
	cert, _ := LoadOrCreate(openTemp(t), time.Now())
	want, _ := FingerprintOf(cert)
	ln, err := tls.Listen("tcp", "127.0.0.1:0", ServerConfig(cert))
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				c.(*tls.Conn).Handshake()
				c.Close()
			}()
		}
	}()

	var seen Fingerprint
	client := &tls.Config{
		InsecureSkipVerify: true,
		VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
			fp, err := FingerprintOfDER(raw[0])
			seen = fp
			return err
		},
	}
	conn, err := tls.DialWithDialer(&net.Dialer{Timeout: 3 * time.Second}, "tcp", ln.Addr().String(), client)
	if err != nil {
		t.Fatalf("TLS 1.3 handshake: %v", err)
	}
	if conn.ConnectionState().Version != tls.VersionTLS13 {
		t.Fatalf("version = %x", conn.ConnectionState().Version)
	}
	conn.Close()
	if seen != want {
		t.Fatal("the client saw a different fingerprint")
	}

	old := &tls.Config{InsecureSkipVerify: true, MaxVersion: tls.VersionTLS12}
	if c, err := tls.DialWithDialer(&net.Dialer{Timeout: 3 * time.Second}, "tcp", ln.Addr().String(), old); err == nil {
		c.Close()
		t.Fatal("a TLS 1.2 client was accepted")
	}
}

func TestReadFingerprintReadsWithoutCreating(t *testing.T) {
	d := openTemp(t)
	if _, err := ReadFingerprint(d.Path("")); !os.IsNotExist(err) {
		t.Fatalf("err = %v, want not-exist", err)
	}
	if _, err := os.Stat(d.Path("tls.key")); !os.IsNotExist(err) {
		t.Fatal("reading the fingerprint created a key")
	}
	cert, _ := LoadOrCreate(d, t0)
	want, _ := FingerprintOf(cert)
	got, err := ReadFingerprint(d.Path(""))
	if err != nil || got != want {
		t.Fatalf("ReadFingerprint = %v, %v", got, err)
	}
	if err := d.WriteFile("tls.crt", []byte("junk")); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadFingerprint(d.Path("")); err == nil {
		t.Fatal("junk was accepted as a certificate")
	}
}

// serve answers TLS handshakes with cert until the test ends and returns the
// address it listens on.
func serve(t *testing.T, cert tls.Certificate) string {
	t.Helper()
	ln, err := tls.Listen("tcp", "127.0.0.1:0", ServerConfig(cert))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				c.(*tls.Conn).Handshake()
				c.Close()
			}()
		}
	}()
	return ln.Addr().String()
}

func TestLocalClientConfigTrustsOnlyTheStoredCertificate(t *testing.T) {
	mine := openTemp(t)
	myCert, _ := LoadOrCreate(mine, time.Now())
	otherCert, _ := LoadOrCreate(openTemp(t), time.Now())

	cfg, err := LocalClientConfig(mine.Path(""))
	if err != nil {
		t.Fatalf("LocalClientConfig: %v", err)
	}
	dialer := &net.Dialer{Timeout: 3 * time.Second}
	conn, err := tls.DialWithDialer(dialer, "tcp", serve(t, myCert), cfg)
	if err != nil {
		t.Fatalf("the agent's own certificate was refused: %v", err)
	}
	conn.Close()
	if c, err := tls.DialWithDialer(dialer, "tcp", serve(t, otherCert), cfg); err == nil {
		c.Close()
		t.Fatal("another agent's certificate was accepted")
	}
	if _, err := LocalClientConfig(openTemp(t).Path("")); err == nil {
		t.Fatal("a folder without a certificate was accepted")
	}
}

func TestLocalClientConfigDoesNotMindTheDatesOfTheCertificate(t *testing.T) {
	dialer := &net.Dialer{Timeout: 3 * time.Second}
	for name, issued := range map[string]time.Time{
		// The clock was four years ahead when the agent first ran.
		"a certificate that is not valid yet": time.Now().AddDate(4, 0, 0),
		// The agent has run without a restart for longer than its
		// certificate lasts.
		"a certificate that has run out": time.Now().Add(-validity - 24*time.Hour),
	} {
		mine := openTemp(t)
		myCert, err := LoadOrCreate(mine, issued)
		if err != nil {
			t.Fatalf("%s: LoadOrCreate: %v", name, err)
		}
		cfg, err := LocalClientConfig(mine.Path(""))
		if err != nil {
			t.Fatalf("%s: LocalClientConfig: %v", name, err)
		}
		conn, err := tls.DialWithDialer(dialer, "tcp", serve(t, myCert), cfg)
		if err != nil {
			t.Errorf("%s was refused although it is the stored one: %v", name, err)
			continue
		}
		conn.Close()
		// A certificate with another key and the same dates is still refused.
		otherCert, err := LoadOrCreate(openTemp(t), issued)
		if err != nil {
			t.Fatalf("%s: LoadOrCreate: %v", name, err)
		}
		if c, err := tls.DialWithDialer(dialer, "tcp", serve(t, otherCert), cfg); err == nil {
			c.Close()
			t.Errorf("%s: a certificate with another key was accepted", name)
		}
	}
}
