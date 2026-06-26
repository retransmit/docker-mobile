#!/usr/bin/env bash
# Generates a CA + server cert + client cert for smoke-testing docker-mobile's
# TCP+TLS (mTLS) transport against a real dockerd.
#
# Usage:   ./scripts/gen-tls-certs.sh [HOST] [OUT_DIR]
#   HOST     IP/hostname the daemon will be reached at (default 127.0.0.1).
#            For an Android emulator reaching the host machine, the daemon must
#            be bound on the host's LAN IP and HOST should be that IP (the app
#            then connects to that IP, not 10.0.2.2, since the cert pins the IP).
#   OUT_DIR  where to write the certs (default ./certs).
#
# Git Bash on Windows: prefix the whole command with MSYS_NO_PATHCONV=1 so the
# `-subj "/CN=..."` arguments are not mangled into Windows paths, e.g.
#   MSYS_NO_PATHCONV=1 ./scripts/gen-tls-certs.sh 192.168.1.50
set -euo pipefail

HOST="${1:-127.0.0.1}"
OUT="${2:-./certs}"

mkdir -p "$OUT"
cd "$OUT"

echo "==> CA"
openssl genrsa -out ca-key.pem 4096
openssl req -new -x509 -days 365 -key ca-key.pem -sha256 -subj "/CN=docker-mobile-test-ca" -out ca.pem

echo "==> Server cert (CN=$HOST, SAN includes $HOST + 127.0.0.1 + localhost)"
openssl genrsa -out server-key.pem 4096
openssl req -subj "/CN=$HOST" -new -key server-key.pem -out server.csr
printf 'subjectAltName = DNS:localhost,IP:%s,IP:127.0.0.1\nextendedKeyUsage = serverAuth\n' "$HOST" > extfile.cnf
openssl x509 -req -days 365 -sha256 -in server.csr -CA ca.pem -CAkey ca-key.pem \
  -CAcreateserial -out server-cert.pem -extfile extfile.cnf

echo "==> Client cert (mTLS, what the app presents)"
openssl genrsa -out client-key.pem 4096
openssl req -subj "/CN=docker-mobile-client" -new -key client-key.pem -out client.csr
printf 'extendedKeyUsage = clientAuth\n' > extfile-client.cnf
openssl x509 -req -days 365 -sha256 -in client.csr -CA ca.pem -CAkey ca-key.pem \
  -CAcreateserial -out client-cert.pem -extfile extfile-client.cnf

rm -f server.csr client.csr extfile.cnf extfile-client.cnf ca.srl

echo
echo "Done. Files in: $OUT"
echo
echo "Run dockerd with mTLS:"
echo "  dockerd --tlsverify \\"
echo "    --tlscacert=$OUT/ca.pem --tlscert=$OUT/server-cert.pem --tlskey=$OUT/server-key.pem \\"
echo "    -H=0.0.0.0:2376"
echo
echo "In the app (Connect -> + -> TCP+TLS, port 2376):"
echo "  Client certificate (PEM)  <- contents of $OUT/client-cert.pem"
echo "  Client key (PEM)          <- contents of $OUT/client-key.pem"
echo "  CA certificate (PEM)      <- contents of $OUT/ca.pem"
echo "  Allow insecure: OFF"
