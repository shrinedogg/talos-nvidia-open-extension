#!/usr/bin/env bash
# Manage the kernel module signing key (RSA-4096, self-signed, 100 years; the
# same shape as the kernel's own certs/x509.genkey key, so the kernel build
# can use the PEM directly as CONFIG_MODULE_SIG_KEY).
#
#   generate <key.pem> <cert.crt>  write a new key (PEM: private key + cert) and its cert
#   ensure <key.pem>               generate a throwaway key at <key.pem> if it is missing
#   matches <key.pem> <cert.crt>   exit 0 if <cert.crt> is the certificate of <key.pem>
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
genkey="${here}/../certs/module-signing.genkey"

cmd="${1:-}"
shift || true

case "$cmd" in
  generate)
    key="${1:?key.pem}"
    crt="${2:?cert.crt}"
    umask 077
    openssl req -new -nodes -utf8 -sha512 -days 36500 -batch -x509 \
      -config "$genkey" -outform PEM -out "$key" -keyout "$key" 2>/dev/null
    openssl x509 -in "$key" -out "$crt"
    echo "==> wrote $key (PRIVATE KEY, never commit) and $crt"
    ;;
  ensure)
    key="${1:?key.pem}"
    if [ ! -s "$key" ]; then
      mkdir -p "$(dirname "$key")"
      echo "==> no signing key at $key, generating a throwaway key" >&2
      "$0" generate "$key" "${key%.pem}.crt" >&2
    fi
    ;;
  matches)
    key="${1:?key.pem}"
    crt="${2:?cert.crt}"
    [ -s "$key" ] && [ -s "$crt" ] || exit 1
    cmp -s <(openssl x509 -in "$crt" -pubkey -noout) <(openssl pkey -in "$key" -pubout)
    ;;
  *)
    echo "usage: $0 generate <key.pem> <cert.crt> | ensure <key.pem> | matches <key.pem> <cert.crt>" >&2
    exit 2
    ;;
esac
