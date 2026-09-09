#!/usr/bin/env bash
# Tests for hack/verify-module-signatures.sh using synthetic modules: random
# bytes plus a CMS signature in the kernel's appended-signature layout.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
verify="${here}/../verify-module-signatures.sh"
keys="${here}/../module-signing-key.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

"$keys" generate "$tmp/good.pem" "$tmp/good.crt" > /dev/null
"$keys" generate "$tmp/bad.pem" "$tmp/bad.crt" > /dev/null

# sign_module <body> <key.pem> <cert.crt> <out.ko>
sign_module() {
  openssl cms -sign -binary -nocerts -noattr -nosmimecap -md sha512 -outform DER \
    -signer "$3" -inkey "$2" -in "$1" -out "$tmp/sig.der"
  sig_len="$(wc -c < "$tmp/sig.der" | tr -d ' ')"
  {
    cat "$1" "$tmp/sig.der"
    # struct module_signature: algo=0 hash=0 id_type=2 (PKEY_ID_PKCS7) signer_len=0 key_id_len=0 pad[3], be32 sig_len
    printf '\000\000\002\000\000\000\000\000'
    printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $(( (sig_len >> 24) & 255 )) $(( (sig_len >> 16) & 255 )) $(( (sig_len >> 8) & 255 )) $(( sig_len & 255 )))"
    printf '~Module signature appended~\n'
  } > "$4"
}

head -c 4096 /dev/urandom > "$tmp/body"
mkdir -p "$tmp/signed/kernel/drivers" "$tmp/unsigned" "$tmp/empty"
sign_module "$tmp/body" "$tmp/good.pem" "$tmp/good.crt" "$tmp/signed/kernel/drivers/a.ko"
sign_module "$tmp/body" "$tmp/good.pem" "$tmp/good.crt" "$tmp/signed/b.ko"
cp "$tmp/body" "$tmp/unsigned/c.ko"

out="$("$verify" "$tmp/signed" "$tmp/good.crt")" || fail "good cert should verify"
[ "$out" = "OK: 2 module(s) under $tmp/signed verified against $tmp/good.crt" ] || fail "unexpected output: $out"
! "$verify" "$tmp/signed" "$tmp/bad.crt" 2> /dev/null || fail "wrong cert must fail"
! "$verify" "$tmp/unsigned" "$tmp/good.crt" 2> /dev/null || fail "unsigned module must fail"
! "$verify" "$tmp/empty" "$tmp/good.crt" 2> /dev/null || fail "empty dir must fail"
cp "$tmp/unsigned/c.ko" "$tmp/signed/c.ko"
! "$verify" "$tmp/signed" "$tmp/good.crt" 2> /dev/null || fail "one unsigned module among signed ones must fail"

echo "PASS: verify-module-signatures"
