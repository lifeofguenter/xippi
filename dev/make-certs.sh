#!/usr/bin/env bash
# Creates the test CA and one server certificate for the local test servers.
#
#   dev/certs/test-ca.pem   CA certificate, the trust anchor for tests
#   dev/certs/test-ca.key   CA key
#   dev/certs/server.pem    server certificate, used by Prosody and ejabberd
#   dev/certs/server.key    server key
#
# Every run replaces all four files. The keys are world-readable on purpose:
# the containers read them through a bind mount under their own user, and
# they protect nothing outside a local test run.
set -euo pipefail

cd "$(dirname "$0")"
out=certs
mkdir -p "$out"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Apple platforms refuse TLS server certificates valid for more than 825
# days, even under a custom anchor.
ca_days=3650
server_days=825

cat >"$work/ca.cnf" <<'CNF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext

[dn]
CN = Xippi Test CA
O = Xippi tests

[ext]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
CNF

cat >"$work/server.cnf" <<'CNF'
[req]
distinguished_name = dn
prompt = no

[dn]
CN = localhost
O = Xippi tests

[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
subjectAltName = @san

[san]
DNS.1 = localhost
DNS.2 = prosody.test
DNS.3 = conference.prosody.test
DNS.4 = upload.prosody.test
DNS.5 = ejabberd.test
DNS.6 = conference.ejabberd.test
DNS.7 = mix.ejabberd.test
DNS.8 = pubsub.ejabberd.test
DNS.9 = upload.ejabberd.test
IP.1 = 127.0.0.1
IP.2 = ::1
CNF

openssl ecparam -name prime256v1 -genkey -noout -out "$work/test-ca.key"
openssl req -new -x509 -sha256 -days "$ca_days" \
    -config "$work/ca.cnf" -key "$work/test-ca.key" -out "$work/test-ca.pem"

openssl ecparam -name prime256v1 -genkey -noout -out "$work/server.key"
openssl req -new -sha256 -config "$work/server.cnf" \
    -key "$work/server.key" -out "$work/server.csr"
openssl x509 -req -sha256 -days "$server_days" \
    -in "$work/server.csr" -CA "$work/test-ca.pem" -CAkey "$work/test-ca.key" \
    -set_serial "0x$(openssl rand -hex 16)" \
    -extfile "$work/server.cnf" -extensions ext -out "$work/server.pem"

openssl verify -CAfile "$work/test-ca.pem" "$work/server.pem" >/dev/null

chmod 644 "$work/test-ca.key" "$work/server.key" "$work/test-ca.pem" "$work/server.pem"
mv "$work/test-ca.key" "$work/test-ca.pem" "$work/server.key" "$work/server.pem" "$out/"

echo "Certificates written to dev/$out"
