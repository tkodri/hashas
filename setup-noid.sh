#!/usr/bin/env bash
# Parano1d node + wallet bootstrap script
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/tkodri/hashas/main/setup-noid.sh)
#
# Share one wallet across machines (same payout address) :
#   NOID_IMPORT_SECRET=<64 hex>  bash <(curl -fsSL .../setup-noid.sh)
#   NOID_SECRET_FILE=/root/.noid-secret bash <(curl -fsSL .../setup-noid.sh)
#
# Env overrides:
#   NOID_VERSION        release tag                 (default: v2.0.4)
#   NOID_MODE           node|miner|extminer         (default: node)
#   NOID_THREADS        cpu threads for miner mode  (default: all cores)
#   NOID_PREFIX         install dir                 (default: $HOME/noid)
#   NOID_DATADIR        chain + wallet dir          (default: $HOME/.parano1d/data)
#   NOID_IMPORT_SECRET  64-char hex master secret   (optional)
#   NOID_SECRET_FILE    file holding the secret     (optional)
#   NOID_EXPECT_ADDRESS assert derived address      (optional, safety)
#   NOID_SYSTEMD        1 = install+enable service  (default: 0)
#   NOID_FORCE          1 = replace existing wallet  (default: 0)
#   NOID_RPC_WAIT       seconds to wait for RPC      (default: 300)

set -euo pipefail

VERSION="${NOID_VERSION:-v2.0.4}"
MODE="${NOID_MODE:-node}"
THREADS="${NOID_THREADS:-}"
PREFIX="${NOID_PREFIX:-$HOME/noid}"
DATADIR="${NOID_DATADIR:-$HOME/.parano1d/data}"
IMPORT_SECRET="${NOID_IMPORT_SECRET:-}"
SECRET_FILE="${NOID_SECRET_FILE:-}"
EXPECT_ADDR="${NOID_EXPECT_ADDRESS:-}"
USE_SYSTEMD="${NOID_SYSTEMD:-0}"
FORCE="${NOID_FORCE:-0}"

log()  { printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

KEYFILE="$DATADIR/wallet.key"
MAGIC='noid_plain_key_1'

# ---- helpers --------------------------------------------------------------
hexval() {  # read bytes 16..48 of wallet.key as lowercase hex, single line
  local f="$1"
  if command -v xxd >/dev/null 2>&1; then
    xxd -p -c 256 -s 16 -l 32 "$f" | tr -d '\n'
  else
    python3 -c "import sys;print(open(sys.argv[1],'rb').read()[16:48].hex())" "$f"
  fi
}

mkwallet() {  # write 48-byte wallet.key with 0600
  local secret="$1" out="$2"
  printf '%s' "$MAGIC" > "$out"
  if command -v xxd >/dev/null 2>&1; then
    printf '%s' "$secret" | xxd -r -p >> "$out"
  else
    python3 -c "import sys,binascii;sys.stdout.buffer.write(binascii.unhexlify(sys.argv[1]))" "$secret" >> "$out"
  fi
  chmod 600 "$out"
}

# ---- platform -------------------------------------------------------------
OS="$(uname -s)"; ARCH="$(uname -m)"
case "$OS-$ARCH" in
  Linux-x86_64)              PLAT=linux-x86_64 ;;
  Linux-aarch64|Linux-arm64) PLAT=linux-aarch64 ;;
  Darwin-arm64)              PLAT=macos-aarch64 ;;
  Darwin-x86_64)             PLAT=macos-x86_64 ;;
  *) die "unsupported platform: $OS-$ARCH" ;;
esac

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar  >/dev/null 2>&1 || die "tar is required"

if command -v sha256sum >/dev/null 2>&1; then SHA() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum  >/dev/null 2>&1; then SHA() { shasum -a 256 "$1" | awk '{print $1}'; }
else die "no sha256sum / shasum available"; fi

# ---- resolve requested secret ---------------------------------------------
if [ -n "$SECRET_FILE" ]; then
  [ -r "$SECRET_FILE" ] || die "secret file not readable: $SECRET_FILE"
  IMPORT_SECRET="$(tr -d ' \t\n\r' < "$SECRET_FILE")"
fi

if [ -n "$IMPORT_SECRET" ]; then
  IMPORT_SECRET="$(printf '%s' "$IMPORT_SECRET" | tr 'A-F' 'a-f')"
  case "$IMPORT_SECRET" in
    *[!0-9a-f]*|'') die "master secret must be 64 hex chars" ;;
  esac
  [ "${#IMPORT_SECRET}" -eq 64 ] || die "master secret length is ${#IMPORT_SECRET}, expected 64 hex"
  log "import mode: one shared wallet across machines"
fi

# ---- download + verify ----------------------------------------------------
mkdir -p "$PREFIX"; cd "$PREFIX"
ASSET="parano1d-core-${VERSION}-${PLAT}.tar.gz"
BASE="https://github.com/ignotusnemo/parano1d/releases/download/${VERSION}"

log "downloading ${ASSET}"
curl -fSL --retry 3 --retry-delay 2 -o "$ASSET" "$BASE/$ASSET"
curl -fSL --retry 3 --retry-delay 2 -o SHA256SUMS "$BASE/SHA256SUMS"

EXPECTED="$(grep " ${ASSET}\$" SHA256SUMS | awk '{print $1}' || true)"
ACTUAL="$(SHA "$ASSET")"
[ -n "$EXPECTED" ] || die "no checksum entry for ${ASSET}"
[ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch
  expected $EXPECTED
  actual   $ACTUAL"
log "checksum ok  ($ACTUAL)"

log "extracting"
tar xzf "$ASSET"
chmod +x parano1d parano1d-cli parano1d-miner 2>/dev/null || true

log "hardware check"
./parano1d --check-hardware || die "host cannot run production Parano1d"

# ---- stop running instance ------------------------------------------------
./parano1d-cli stop >/dev/null 2>&1 || true
sleep 2

mkdir -p "$DATADIR"

# ---- install shared secret (before node starts) ---------------------------
INSTALLED_SECRET=""
if [ -n "$IMPORT_SECRET" ]; then
  if [ -s "$KEYFILE" ]; then
    CUR="$(hexval "$KEYFILE" 2>/dev/null || echo '')"
    if [ "$CUR" = "$IMPORT_SECRET" ]; then
      log "wallet.key already holds the requested secret, keeping it"
      INSTALLED_SECRET="$CUR"
    elif [ "$FORCE" = "1" ]; then
      STAMP="$(date +%s)"
      cp -p "$KEYFILE" "$KEYFILE.bak.$STAMP"
      warn "replacing wallet.key (backup: $KEYFILE.bak.$STAMP)"
      for extra in wallet.receipts wallet.history wallet.labels; do
        [ -e "$DATADIR/$extra" ] && cp -p "$DATADIR/$extra" "$DATADIR/$extra.bak.$STAMP" || true
      done
      mkwallet "$IMPORT_SECRET" "$KEYFILE"
      INSTALLED_SECRET="$IMPORT_SECRET"
    else
      die "wallet.key exists with a DIFFERENT secret.
  current : $CUR
  wanted  : $IMPORT_SECRET
  Re-run with NOID_FORCE=1 to replace it (a backup is kept)."
    fi
  else
    mkwallet "$IMPORT_SECRET" "$KEYFILE"
    INSTALLED_SECRET="$IMPORT_SECRET"
    log "wallet.key written (shared secret, 0600)"
  fi
fi

# ---- start ----------------------------------------------------------------
NODELOG="$PREFIX/parano1d.log"

launch() {   # launch <args...>  — data-dir appended, output to log, stdin detached
  nohup "$@" --data-dir "$DATADIR" >"$NODELOG" 2>&1 </dev/null &
  NODEPID=$!
}

case "$MODE" in
  miner)
    log "starting node, internal proof pipeline (mode=miner)"
    if [ -n "$THREADS" ]; then
      launch ./parano1d --mode miner --cpu-threads "$THREADS"
    else
      launch ./parano1d --mode miner
    fi ;;
  extminer)
    MK="$HOME/.parano1d/mining.key"
    if [ ! -s "$MK" ]; then
      head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$MK"; chmod 600 "$MK"
    fi
    log "starting node, external worker pipeline (mode=extminer)"
    launch ./parano1d --mode extminer --mining-key-file "$MK" ;;
  *)
    log "starting ordinary node (mode=node)"
    launch ./parano1d ;;
esac

log "node pid $NODEPID — log: $NODELOG"

# ---- wait for RPC ---------------------------------------------------------
# miner mode calibrates proof capacity before accepting RPC; on shared or
# throttled CPUs that can take minutes. node mode is usually up in ~20-30s.
WAIT="${NOID_RPC_WAIT:-300}"
log "waiting for RPC on 127.0.0.1:9601 (max ${WAIT}s)"
ok=0; waited=0
for i in $(seq 1 "$WAIT"); do
  waited=$i
  ./parano1d-cli status >/dev/null 2>&1 && { ok=1; break; }
  if ! kill -0 "$NODEPID" 2>/dev/null; then
    echo
    warn "node exited during startup. last log lines:"
    tail -n 25 "$NODELOG" 2>/dev/null | sed 's/^/    /'
    die "node died before RPC came up (full log: $NODELOG)"
  fi
  if [ $((i % 15)) -eq 0 ]; then
    printf '    ... %ss  %s\n' "$i" "$(tail -n1 "$NODELOG" 2>/dev/null | cut -c1-88)"
  fi
  sleep 1
done
if [ "$ok" != 1 ]; then
  echo
  warn "RPC still down after ${WAIT}s — node is alive but slow. last log lines:"
  tail -n 25 "$NODELOG" 2>/dev/null | sed 's/^/    /'
  die "retry with a higher NOID_RPC_WAIT (full log: $NODELOG)"
fi
log "RPC up after ${waited}s"

# ---- report ---------------------------------------------------------------
echo
echo "================= NODE ================="
./parano1d-cli status || true
echo
echo "================ WALLET ================"
ADDR_LINE="$(./parano1d-cli address 2>/dev/null || true)"
printf '%s\n' "$ADDR_LINE"
ACTIVE_ADDR="$(printf '%s' "$ADDR_LINE" | tr -d ' ' | grep -o 'o1[0-9a-z]*' | head -1 || true)"
echo

if [ -n "$INSTALLED_SECRET" ]; then
  echo "master secret (shared) : $INSTALLED_SECRET"
else
  if [ -s "$KEYFILE" ]; then
    echo "master secret (local)  : $(hexval "$KEYFILE")"
  fi
fi
echo "payout address         : ${ACTIVE_ADDR:-unknown}"
echo "wallet key file        : $KEYFILE"

if [ -n "$EXPECT_ADDR" ]; then
  if [ "$ACTIVE_ADDR" = "$EXPECT_ADDR" ]; then
    log "address assertion OK"
  else
    die "address mismatch
  expected $EXPECT_ADDR
  got      $ACTIVE_ADDR"
  fi
fi

# ---- optional systemd -----------------------------------------------------
# Auto-detects hosts with no usable systemd (containers, Codespaces, chroot,
# WSL without init) and skips cleanly instead of dying at the very end.
if [ "$USE_SYSTEMD" = "1" ]; then
  sd_ok=1; sd_reason=""
  if [ "$(id -u)" -ne 0 ]; then
    sd_ok=0; sd_reason="needs root"
  elif ! command -v systemctl >/dev/null 2>&1; then
    sd_ok=0; sd_reason="systemctl not installed"
  elif [ ! -d /run/systemd/system ]; then
    sd_ok=0; sd_reason="systemd is not the active init (container / Codespace / chroot)"
  fi

  if [ "$sd_ok" != 1 ]; then
    warn "NOID_SYSTEMD=1 skipped: $sd_reason"
    warn "the node is already running under the launcher. to restart it after reboot:"
    warn "    $PREFIX/parano1d --mode $MODE --data-dir $DATADIR"
  else
    ARGS="--data-dir $DATADIR"
    case "$MODE" in
      miner)    ARGS="--mode miner ${THREADS:+--cpu-threads $THREADS} $ARGS" ;;
      extminer) ARGS="--mode extminer --mining-key-file $HOME/.parano1d/mining.key $ARGS" ;;
    esac

    # hand the RPC port over: the launcher-owned node must release it first,
    # otherwise the unit starts a second node and the bind fails
    log "stopping launcher-owned node (pid $NODEPID) so systemd can own the service"
    ./parano1d-cli stop >/dev/null 2>&1 || true
    kill "$NODEPID" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$NODEPID" 2>/dev/null || break
      sleep 0.5
    done

    cat > /etc/systemd/system/parano1d.service <<EOF
[Unit]
Description=Parano1d node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
WorkingDirectory=$PREFIX
ExecStart=$PREFIX/parano1d $ARGS
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload || warn "systemctl daemon-reload failed"
    if systemctl enable --now parano1d; then
      log "systemd unit installed and started (parano1d.service)"
      sleep 3
      if systemctl is-active --quiet parano1d; then
        log "service is active"
      else
        warn "service not active yet — check: journalctl -u parano1d -n 50"
      fi
    else
      warn "systemctl enable --now failed — restarting under the launcher instead"
      launch ./parano1d --mode "$MODE"
    fi
  fi
fi

echo
echo "manage: $PREFIX/parano1d-cli status | address | balance | stop"
