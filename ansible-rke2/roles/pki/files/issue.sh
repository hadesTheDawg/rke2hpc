#!/usr/bin/env bash
# issue.sh <pki-dir> <name> <org> <san,san,...>
# Issues <name>.crt/.key from the CA in <pki-dir>. Re-issued only when the SAN
# list changed or fewer than 30 days remain. Prints "issued" when it did work.
set -euo pipefail
PKI="$1" name="$2" org="$3" sans="$4"
if [ -s "$PKI/$name.crt" ] && [ "$(cat "$PKI/$name.sans" 2>/dev/null)" = "$sans" ] \
   && openssl x509 -in "$PKI/$name.crt" -noout -checkend $((30*86400)) >/dev/null; then
  echo current; exit 0
fi
umask 077
san_ext=""
for s in $(echo "$sans" | tr ',' ' '); do
  case "$s" in *[!0-9.]*) san_ext="$san_ext,DNS:$s" ;; *) san_ext="$san_ext,IP:$s" ;; esac
done
[ -s "$PKI/$name.key" ] || openssl genrsa -out "$PKI/$name.key" 2048 2>/dev/null
openssl req -new -key "$PKI/$name.key" -subj "/O=$org/CN=${sans%%,*}" -out "$PKI/$name.csr"
printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' \
  "${san_ext#,}" >"$PKI/$name.ext"
openssl x509 -req -in "$PKI/$name.csr" -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" -CAcreateserial \
  -sha256 -days 825 -extfile "$PKI/$name.ext" -out "$PKI/$name.crt" 2>/dev/null
rm -f "$PKI/$name.csr" "$PKI/$name.ext"
echo "$sans" >"$PKI/$name.sans"
echo issued
