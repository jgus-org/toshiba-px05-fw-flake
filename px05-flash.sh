# Flash Toshiba PX05 SAS SSDs to AS10 via SCSI WRITE BUFFER, selected by serial.
# PATH, FW_DEFAULT, TARGET_MODEL, TARGET_FW are injected by the nix wrapper.
set -uo pipefail

FW_BIN="${PX05_FW:-$FW_DEFAULT}"
WB_MODE=7 # WRITE BUFFER: download microcode with offsets, save, activate
BPW=65536 # per-command chunk: <128 SG_IO segments (the mpt3sas request limit), aligned to any sane download boundary
ASSUME_YES=0
FORCE_INUSE=0
DRYRUN=0

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<EOF
Usage: sudo px05-flash [options] SERIAL [SERIAL ...]
       px05-flash --dry-run SERIAL ...     # inventory only (no root needed)

Options:
  --dry-run         Show target drives, current FW, in-use status. No writes.
  --yes             Skip the per-drive confirmation prompt.
  --force-in-use    Allow flashing a drive that is mounted / an md or zfs member.
  --bin PATH        Override the firmware image (default: bundled $TARGET_FW).
  --bpw N           WRITE BUFFER chunk size in bytes (default 65536).

Target model: $TARGET_MODEL   Target firmware: $TARGET_FW
EOF
  exit 2
}

SERIALS=()
while [ $# -gt 0 ]; do
  case "$1" in
  --dry-run) DRYRUN=1 ;;
  --yes) ASSUME_YES=1 ;;
  --force-in-use) FORCE_INUSE=1 ;;
  --bin)
    shift
    FW_BIN="${1:-}"
    ;;
  --bpw)
    shift
    BPW="${1:-}"
    ;;
  -h | --help) usage ;;
  -*) die "unknown option: $1" ;;
  *) SERIALS+=("$1") ;;
  esac
  shift
done
[ ${#SERIALS[@]} -gt 0 ] || usage
[ -f "$FW_BIN" ] || die "firmware image not found: $FW_BIN"

declare -A SER2DEV
build_map() {
  SER2DEV=()
  local dev base ser
  for dev in /sys/block/sd*; do
    [ -e "$dev" ] || continue
    base="${dev##*/}"
    ser="$(lsblk -dno SERIAL "/dev/$base" 2>/dev/null)"
    [ -n "$ser" ] && SER2DEV["$ser"]="/dev/$base"
  done
}
field() { lsblk -dno "$2" "$1" 2>/dev/null | head -1; }

inuse_reason() {
  local out
  out="$(lsblk -no MOUNTPOINT,FSTYPE "$1" 2>/dev/null)"
  grep -qE '[^[:space:]]' <<<"$out" || {
    echo ""
    return
  }
  grep -qE '/' <<<"$out" && {
    echo "mounted"
    return
  }
  grep -qE 'linux_raid_member' <<<"$out" && {
    echo "md-member"
    return
  }
  grep -qE 'zfs_member' <<<"$out" && {
    echo "zfs-member"
    return
  }
  grep -qE 'LVM2_member' <<<"$out" && {
    echo "lvm-member"
    return
  }
  grep -qE 'crypto_LUKS' <<<"$out" && {
    echo "luks"
    return
  }
  echo ""
}

build_map
echo "Firmware: $FW_BIN ($(stat -c%s "$FW_BIN") bytes) -> $TARGET_FW"
echo
echo "Target drives:"
printf '  %-14s %-9s %-12s %-6s %s\n' SERIAL DEV MODEL FW STATUS
for ser in "${SERIALS[@]}"; do
  dev="${SER2DEV[$ser]:-}"
  if [ -z "$dev" ]; then
    printf '  %-14s %-9s %-12s %-6s %s\n' "$ser" "-" "-" "-" "NOT FOUND on this host"
    continue
  fi
  model="$(field "$dev" MODEL)"
  vendor="$(field "$dev" VENDOR)"
  fw="$(field "$dev" REV)"
  reason="$(inuse_reason "$dev")"
  status="ready"
  [ "$model" = "$TARGET_MODEL" ] || status="WRONG MODEL ($vendor $model)"
  [ "$fw" = "$TARGET_FW" ] && status="already $TARGET_FW (skip)"
  [ -n "$reason" ] && status="$status; IN USE: $reason"
  printf '  %-14s %-9s %-12s %-6s %s\n' "$ser" "$dev" "$model" "$fw" "$status"
done
echo

[ "$DRYRUN" = 1 ] && {
  echo "Dry run; nothing written."
  exit 0
}
[ "$(id -u)" = 0 ] || die "must run as root to flash (WRITE BUFFER needs raw SCSI access)"

for ser in "${SERIALS[@]}"; do
  dev="${SER2DEV[$ser]:-}"
  echo "=================================================================="
  [ -n "$dev" ] || {
    echo "Drive $ser: NOT FOUND; skipping."
    continue
  }
  model="$(field "$dev" MODEL)"
  fw="$(field "$dev" REV)"
  echo "Drive $ser ($dev)  model=$model  current FW=$fw"
  [ "$model" = "$TARGET_MODEL" ] || {
    echo "  SKIP: not $TARGET_MODEL"
    continue
  }
  [ "$fw" = "$TARGET_FW" ] && {
    echo "  SKIP: already $TARGET_FW"
    continue
  }
  reason="$(inuse_reason "$dev")"
  if [ -n "$reason" ]; then
    if [ "$FORCE_INUSE" != 1 ]; then
      echo "  SKIP: in use ($reason). Quiesce it, then re-run with --force-in-use."
      continue
    fi
    echo "  WARNING: $dev is in use ($reason); proceeding because --force-in-use is set."
  fi
  if [ "$ASSUME_YES" != 1 ]; then
    read -r -p "  Flash $dev ($ser) ${fw} -> ${TARGET_FW}? type 'yes': " ans
    [ "$ans" = "yes" ] || {
      echo "  skipped by user"
      continue
    }
  fi

  echo "  Flashing (sg_write_buffer --mode=$WB_MODE --bpw=$BPW)..."
  if sg_write_buffer --verbose --mode="$WB_MODE" --bpw="$BPW" --in="$FW_BIN" "$dev"; then
    echo "  WRITE BUFFER OK; rescanning..."
    echo 1 >"/sys/block/$(basename "$dev")/device/rescan" 2>/dev/null || true
    sleep 3
    build_map
    newfw="$(field "${SER2DEV[$ser]:-$dev}" REV)"
    if [ "$newfw" = "$TARGET_FW" ]; then
      echo "  VERIFIED: $ser now reports FW $newfw"
    else
      echo "  NOTE: $ser reports FW '$newfw' (expected $TARGET_FW); some units update the INQUIRY string only after a power cycle."
    fi
  else
    rc=$?
    echo "  FLASH FAILED on $dev (rc=$rc)."
    echo "  If a chunk was rejected ('invalid field in cdb'), try a smaller/aligned chunk:"
    echo "    px05-flash --bpw 32768 $ser"
    die "stopping after failure on $dev"
  fi
  echo
done
echo "All requested drives processed."
