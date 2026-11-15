# Certificate issuing against the site CA in secrets/pki (deployer-side).
PKI="$SECRETS_DIR/pki"

issue() { # issue <name> <san,san,...>  (re-issued when the SAN list changes or <30d left)
  local name="$1" sans="$2" san_ext="" s
  if [ -s "$PKI/$name.crt" ] && [ "$(cat "$PKI/$name.sans" 2>/dev/null)" = "$sans" ] \
     && openssl x509 -in "$PKI/$name.crt" -noout -checkend $((30*86400)) >/dev/null; then
    info "$name certificate is current"; return
  fi
  for s in $(echo "$sans" | tr ',' ' '); do
    case "$s" in
      *[!0-9.]*) san_ext="$san_ext,DNS:$s" ;;
      *)         san_ext="$san_ext,IP:$s" ;;
    esac
  done
  [ -s "$PKI/$name.key" ] || openssl genrsa -out "$PKI/$name.key" 2048 2>/dev/null
  openssl req -new -key "$PKI/$name.key" -subj "/O=$CLUSTER_NAME/CN=${sans%%,*}" -out "$PKI/$name.csr"
  printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' \
    "${san_ext#,}" >"$PKI/$name.ext"
  openssl x509 -req -in "$PKI/$name.csr" -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" -CAcreateserial \
    -sha256 -days 825 -extfile "$PKI/$name.ext" -out "$PKI/$name.crt" 2>/dev/null
  rm -f "$PKI/$name.csr" "$PKI/$name.ext"
  echo "$sans" >"$PKI/$name.sans"
  ok "issued $name certificate ($sans)"
}
