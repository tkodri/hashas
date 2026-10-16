#!/usr/bin/env bash
# noid.sh — one-paste ParanO(1)d deployer (PUBLIC repo: tkodri/hashas)
#
# No GitHub token needed. The wallet secret is read from the environment, so it
# never sits in this file and never has to be typed into a URL.
#
#   NOID_IMPORT_SECRET=<64-hex> bash <(curl -fsSL https://raw.githubusercontent.com/tkodri/hashas/main/noid.sh)
#
# Everything is overridable:
#   NOID_MODE=miner|node|extminer   (default: miner)
#   NOID_THREADS=<n>                (default: let the node choose)
#   NOID_SYSTEMD=1                  (default: 1; auto-skips on hosts without systemd)
#   NOID_RPC_WAIT=<seconds>         (default: 300)
#   NOID_PREFIX / NOID_DATADIR      (default: ~/noid and ~/.parano1d/data)
#
#   NOID_SECRET_FILE=/path          read the secret from a file instead
#
set -euo pipefail

: "${NOID_MODE:=miner}"
: "${NOID_SYSTEMD:=1}"
export NOID_MODE NOID_SYSTEMD

# secret from env, or from a file if NOID_SECRET_FILE is set
if [ -z "${NOID_IMPORT_SECRET:-}" ] && [ -n "${NOID_SECRET_FILE:-}" ] && [ -s "${NOID_SECRET_FILE}" ]; then
  NOID_IMPORT_SECRET="$(tr -d ' \t\r\n' < "$NOID_SECRET_FILE")"
fi

if [ -z "${NOID_IMPORT_SECRET:-}" ]; then
  cat >&2 <<'USAGE'
[!] NOID_IMPORT_SECRET is not set.

    paste the secret inline:
      NOID_IMPORT_SECRET=<64-hex> bash <(curl -fsSL https://raw.githubusercontent.com/tkodri/hashas/main/noid.sh)

    or keep it in a file and point at it:
      NOID_SECRET_FILE=~/.noid-secret bash <(curl -fsSL https://raw.githubusercontent.com/tkodri/hashas/main/noid.sh)
USAGE
  exit 1
fi

# sanity: must be 64 hex chars
case "$NOID_IMPORT_SECRET" in
  *[!0-9a-fA-F]*)
    echo "[!] NOID_IMPORT_SECRET must be hex only (0-9, a-f) — got: ${#NOID_IMPORT_SECRET} chars" >&2
    exit 1 ;;
esac
if [ "${#NOID_IMPORT_SECRET}" -ne 64 ]; then
  echo "[!] NOID_IMPORT_SECRET must be 64 hex chars, got ${#NOID_IMPORT_SECRET}" >&2
  echo "    (a classic slip: letter O instead of digit 0 inside the secret)" >&2
  exit 1
fi
export NOID_IMPORT_SECRET

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
curl -fsSL --retry 3 -o "$TMP" https://raw.githubusercontent.com/tkodri/hashas/main/setup-noid.sh
bash "$TMP"
