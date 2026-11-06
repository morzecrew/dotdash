#!/usr/bin/env bash
# Makes the certificates for Cloudflare zone-level Authenticated Origin Pulls.
#
#   scripts/cf-aop-cert.sh <out-dir>
#
# Writes, into <out-dir> (created mode 0700):
#   aop-ca.crt       -> morzer secret cf_aop_ca: Caddy trusts only clients it signed
#   aop-client.crt   -> upload to Cloudflare (SSL/TLS > Origin Server >
#   aop-client.key      Authenticated Origin Pulls > Zone-level), then delete
#   aop-ca.key       -> keep offline or delete; needed only to sign a new client cert
#
# Cloudflare refuses a CA as the uploaded certificate, hence a CA plus a leaf.
set -euo pipefail

out=${1:?usage: $0 <out-dir>}
days=${AOP_DAYS:-3650}
umask 077
mkdir -p "$out"
cd "$out"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days "$days" \
  -subj "/CN=dotdash AOP CA" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout aop-ca.key -out aop-ca.crt 2>/dev/null

openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -subj "/CN=dotdash AOP client" -keyout aop-client.key -out aop-client.csr 2>/dev/null
openssl x509 -req -in aop-client.csr -CA aop-ca.crt -CAkey aop-ca.key -CAcreateserial -days "$days" \
  -extfile <(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n') \
  -out aop-client.crt 2>/dev/null
rm -f aop-client.csr aop-ca.srl

openssl verify -CAfile aop-ca.crt aop-client.crt
