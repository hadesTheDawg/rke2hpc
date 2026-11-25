#!/usr/bin/env bash
# issue.sh <pki-dir> <name> <org> <san,san,...> [<required,names,...>]
# Puts <name>.crt/.key into <pki-dir>, one of two ways (docs/certificates.md):
#   own certificate  <pki-dir>/own/<name>.crt + <name>.key exist: checked (key
#                    matches, not expired, chains to ca.crt or own/ca.crt, covers
#                    every required name; default: the SAN list) and installed
#                    as they are. Never re-issued; replace the files to renew.
#   issued           otherwise, from <pki-dir>/ca.crt + ca.key. Re-issued when the
#                    SAN list or the CA changed, or fewer than 30 days remain.
# Prints "issued" or "installed" when it changed something, else "current";
# lines starting with "warning:" are shown by ansible.
set -euo pipefail
PKI="$1" name="$2" org="$3" sans="$4" need="${5:-$4}"
OWN="$PKI/own"
die() { echo "$name certificate: $*" >&2; exit 1; }
sha() { cat "$@" | openssl sha256 | awk '{print $NF}'; }

if [ -e "$OWN/$name.crt" ] || [ -e "$OWN/$name.key" ]; then
  crt="$OWN/$name.crt" key="$OWN/$name.key"
  [ -s "$crt" ] && [ -s "$key" ] || die "an own certificate needs both $crt and $key"
  openssl x509 -in "$crt" -noout 2>/dev/null || die "$crt is not a PEM certificate"
  openssl pkey -in "$key" -passin pass: -noout 2>/dev/null \
    || die "$key is not an unencrypted PEM private key (decrypt it: openssl pkey -in encrypted.key -out $key)"
  [ "$(openssl x509 -in "$crt" -noout -pubkey | openssl sha256)" = "$(openssl pkey -in "$key" -pubout | openssl sha256)" ] \
    || die "$key is not the private key of $crt"
  openssl x509 -in "$crt" -noout -checkend 0 >/dev/null \
    || die "$crt has expired ($(openssl x509 -in "$crt" -noout -enddate))"
  # Trust anchors: the internal CA plus the issuer chain given in own/ca.crt.
  # Intermediates may be in the certificate file after the leaf, or in own/ca.crt.
  chain=$(mktemp); trap 'rm -f "$chain"' EXIT
  cat "$PKI/ca.crt" >"$chain"
  [ ! -s "$OWN/ca.crt" ] || cat "$OWN/ca.crt" >>"$chain"
  if ! out=$(openssl verify -CAfile "$chain" -untrusted "$crt" "$crt" 2>&1); then
    die "$crt does not chain to $PKI/ca.crt or $OWN/ca.crt (put the issuing CA chain, root included, into $OWN/ca.crt): $(echo "$out" | tail -2 | tr '\n' ' ')"
  fi
  missing=""
  for s in $(echo "$need" | tr ',' ' '); do
    case "$s" in
      *[!0-9.]*) h="$s"; case "$h" in '*.'*) h="hpc-san-check.${h#\*.}" ;; esac
                 r=$(openssl x509 -in "$crt" -noout -checkhost "$h" 2>&1 || true) ;;
      *)         r=$(openssl x509 -in "$crt" -noout -checkip "$s" 2>&1 || true) ;;
    esac
    case "$r" in *"does match"*) ;; *) missing="$missing $s" ;; esac
  done
  [ -z "$missing" ] || die "$crt does not cover:$missing (needed:$(echo "$need" | tr ',' ' '))"
  stamp="own:$(sha "$crt" "$key")"
  if [ "$(cat "$PKI/$name.sans" 2>/dev/null)" = "$stamp" ] && cmp -s "$crt" "$PKI/$name.crt" && cmp -s "$key" "$PKI/$name.key"; then
    echo current
  else
    umask 077
    cp "$crt" "$PKI/$name.crt.new" && mv -f "$PKI/$name.crt.new" "$PKI/$name.crt"
    cp "$key" "$PKI/$name.key.new" && mv -f "$PKI/$name.key.new" "$PKI/$name.key"
    echo "$stamp" >"$PKI/$name.sans"
    echo installed
  fi
  openssl x509 -in "$crt" -noout -checkend $((30*86400)) >/dev/null \
    || echo "warning: own $name certificate expires $(openssl x509 -in "$crt" -noout -enddate | cut -d= -f2); replace $crt and $key"
  exit 0
fi

# ---- issued from the internal (or site) CA ------------------------------------------
if [ -s "$PKI/$name.crt" ] && [ "$(cat "$PKI/$name.sans" 2>/dev/null)" = "$sans" ] \
   && openssl verify -CAfile "$PKI/ca.crt" "$PKI/$name.crt" >/dev/null 2>&1 \
   && openssl x509 -in "$PKI/$name.crt" -noout -checkend $((30*86400)) >/dev/null; then
  echo current; exit 0
fi
umask 077
# Back from an own certificate: do not keep using its key.
case "$(cat "$PKI/$name.sans" 2>/dev/null)" in own:*) rm -f "$PKI/$name.key" ;; esac
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
