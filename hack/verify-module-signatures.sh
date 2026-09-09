#!/usr/bin/env bash
# Verify that every kernel module under $1 carries a module signature that
# validates against the X.509 certificate $2 (PEM). Fails on the first module
# that is unsigned, malformed, or signed by a different key.
#
# Layout of a signed module (kernel/scripts/sign-file.c, include/linux/module_signature.h):
#   [ELF module][CMS/PKCS#7 DER, sig_len bytes][struct module_signature, 12 bytes][magic, 28 bytes]
#   struct module_signature: u8 algo, hash, id_type, signer_len, key_id_len, __pad[3]; __be32 sig_len
#
# Usage: verify-module-signatures.sh <modules-dir> <cert.pem>
set -euo pipefail

modules_dir="$1"
cert="$2"
magic='~Module signature appended~'
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

count=0
while IFS= read -r ko; do
  count=$((count + 1))
  size="$(wc -c < "$ko" | tr -d ' ')"
  if ! tail -c 28 "$ko" | grep -qF "$magic"; then
    echo "FAIL: $ko: no module signature appended" >&2
    exit 1
  fi
  # sig_len: big-endian u32 at bytes [size-32, size-28); od prints 4 numbers on one line
  sig_len="$(tail -c 32 "$ko" | head -c 4 | od -An -tu1 | tr -s ' \n' ' ' | awk '{ print ($1 * 16777216) + ($2 * 65536) + ($3 * 256) + $4 }')"
  case "$sig_len" in
    ''|*[!0-9]*) echo "FAIL: $ko: cannot parse sig_len" >&2; exit 1 ;;
  esac
  body_len=$((size - 28 - 12 - sig_len))
  if [ "$body_len" -le 0 ]; then
    echo "FAIL: $ko: implausible sig_len=$sig_len" >&2
    exit 1
  fi
  head -c "$body_len" "$ko" > "$tmp/body"
  tail -c $((28 + 12 + sig_len)) "$ko" | head -c "$sig_len" > "$tmp/sig.der"
  if ! openssl cms -verify -binary -inform DER -in "$tmp/sig.der" -content "$tmp/body" \
        -nointern -noverify -certfile "$cert" -out /dev/null 2> "$tmp/err"; then
    echo "FAIL: $ko: signature does not verify against $cert" >&2
    cat "$tmp/err" >&2
    exit 1
  fi
done < <(find "$modules_dir" -type f -name '*.ko')

if [ "$count" -eq 0 ]; then
  echo "FAIL: no .ko files found under $modules_dir" >&2
  exit 1
fi
echo "OK: $count module(s) under $modules_dir verified against $cert"
