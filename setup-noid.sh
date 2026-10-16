#!/usr/bin/env bash
# Parano1d node + wallet bootstrap script
# Usage:  bash <(curl -fsSL https://raw.githubusercontent.com/tkodri/hashas/main/setup-noid.sh)
#
# Env overrides:
#   NOID_VERSION   release tag        (default: v2.0.4)
#   NOID_MODE      node|miner|extminer (default: node)
#   NOID_THREADS   cpu threads for internal mode (default: all)
#   NOID_PREFIX    install dir        (default: $HOME/noid)
#   NOID_DATADIR   chain + wallet dir (default: $HOME/.parano1d/data)

set -euo pipefail

VERSION="${NOID_VERSION:-v2.0.4}"
MODE="${NOID_MODE:-node}"
THREADS="${NOID_THREADS:-}"
PREFIX="${NOID_PREFIX:-$HOME/noid}"
DATADIR="${NOID_DATADIR:-$HOME/.parano1d/data}"

log() { printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- platform -------------------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS-$ARCH" in
  Linux-x86_64)              PLAT=linux-x86_64 ;;
  Linux-aarch64|Linux-arm64) PLAT=linux-aarch64 ;;
  Darwin-arm64)              PLAT=macos-aarch64 ;;
  Darwin-x86_64)             PLAT=macos-x86_64 ;;
  *) die "unsupported platform: $OS-$ARCH" ;;
esac

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar  >/dev/null 2>&1 || die "tar is required"

# sha256 helper (GNU coreutils or BSD shasum)
if command -v sha256sum >/dev/null 2>&1; then
  SHA() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  SHA() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  die "no sha256sum / shasum available"
fi

ASSET="parano1d-core-${VERSION}-${PLAT}.tar.gz"
BASE="https://github.com/ignotusnemo/parano1d/releases/download/${VERSION}"

# ---- download + verify ----------------------------------------------------
mkdir -p "$PREFIX"
cd "$PREFIX"

log "downloading ${ASSET}"
curl -fSL --retry 3 --retry-delay 2 -o "$ASSET" "$BASE/$ASSET"
curl -fSL --retry 3 --retry-delay 2 -o SHA256SUMS "$BASE/SHA256SUMS"

EXPECTED="$(grep " ${ASSET}\$" SHA256SUMS | awk '{print $1}' || true)"
ACTUAL="$(SHA "$ASSET")"
if [ -z "$EXPECTED" ]; then
  die "no checksum entry for ${ASSET} in SHA256SUMS"
fi
[ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch
  expected $EXPECTED
  actual   $ACTUAL"
log "checksum ok  ($ACTUAL)"

log "extracting"
tar xzf "$ASSET"
chmod +x parano1d parano1d-cli parano1d-miner 2>/dev/null || true

# ---- hardware -------------------------------------------------------------
log "hardware check"
./parano1d --check-hardware || die "this host cannot run production Parano1d"

# ---- stop previous instance ----------------------------------------------
./parano1d-cli stop >/dev/null 2>&1 || true
sleep 1

mkdir -p "$DATADIR"

# ---- start ----------------------------------------------------------------
case "$MODE" in
  miner)
    log "starting node with internal proof pipeline (mode=miner)"
    if [ -n "$THREADS" ]; then
      nohup ./parano1d --mode miner --cpu-threads "$THREADS" --data-dir "$DATADIR" >/dev/null 2>&1 &
    else
      nohup ./parano1d --mode miner --data-dir "$DATADIR" >/dev/null 2>&1 &
    fi
    ;;
  extminer)
    KEYFILE="$HOME/.parano1d/mining.key"
    if [ ! -s "$KEYFILE" ]; then
      head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$KEYFILE"
      chmod 600 "$KEYFILE"
    fi
    log "starting node with external worker pipeline (mode=extminer)"
    nohup ./parano1d --mode extminer --mining-key-file "$KEYFILE" --data-dir "$DATADIR" >/dev/null 2>&1 &
    ;;
  *)
    log "starting ordinary node (mode=node)"
    nohup ./parano1d --data-dir "$DATADIR" >/dev/null 2>&1 &
    ;;
esac

# ---- wait for RPC ---------------------------------------------------------
log "waiting for RPC on 127.0.0.1:9601"
ok=0
for _ in $(seq 1 90); do
  if ./parano1d-cli status >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
[ "$ok" = 1 ] || die "node did not come up; check it manually"

# ---- report ---------------------------------------------------------------
echo
echo "================= NODE ================="
./parano1d-cli status || true
echo
echo "================ WALLET ================"
./parano1d-cli address || true
echo

# master secret = wallet.key bytes 16..48
KEYFILE="$DATADIR/wallet.key"
if [ -s "$KEYFILE" ]; then
  SECRET="$(od -An -tx1 -j16 -N32 "$KEYFILE" 2>/dev/null | tr -d ' \n')"
  echo "master secret (64 hex) : ${SECRET}"
  echo "back it up offline. it controls every derived address."
fi

echo "wallet key file        : $KEYFILE"
echo "node dir               : $PREFIX"
echo
echo "manage:  $PREFIX/parano1d-cli status | address | balance | stop"
