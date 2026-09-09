#!/usr/bin/env bash
# Tests for hack/module-signing-key.sh.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
keys="${here}/../module-signing-key.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

"$keys" generate "$tmp/a.pem" "$tmp/a.crt" > /dev/null
[ "$(grep -c 'BEGIN' "$tmp/a.pem")" = 2 ] || fail "key.pem must hold private key and certificate"
[ "$(stat -c %a "$tmp/a.pem" 2>/dev/null || stat -f %Lp "$tmp/a.pem")" = 600 ] || fail "key.pem must be mode 0600"
openssl x509 -in "$tmp/a.crt" -noout -subject | grep -q 'talos-nvidia-open-extension' || fail "cert subject"
"$keys" matches "$tmp/a.pem" "$tmp/a.crt" || fail "generated key must match its cert"

"$keys" generate "$tmp/b.pem" "$tmp/b.crt" > /dev/null
! "$keys" matches "$tmp/a.pem" "$tmp/b.crt" || fail "different key must not match"
! "$keys" matches "$tmp/missing.pem" "$tmp/a.crt" 2> /dev/null || fail "missing key must not match"

"$keys" ensure "$tmp/sub/dir/t.pem" 2> /dev/null
[ -s "$tmp/sub/dir/t.pem" ] && [ -s "$tmp/sub/dir/t.crt" ] || fail "ensure must create key and cert"
before="$(cat "$tmp/sub/dir/t.pem")"
"$keys" ensure "$tmp/sub/dir/t.pem" 2> /dev/null
[ "$before" = "$(cat "$tmp/sub/dir/t.pem")" ] || fail "ensure must not overwrite an existing key"

echo "PASS: module-signing-key"
