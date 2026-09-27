#!/system/bin/sh
# ===========================================================================
# Multi-level ZRAM with page-type-aware idle compression (Magisk/KSU module)
#
# zram has no per-page type field, so "type" is handled per *tier*: each zram
# device is dedicated to a data profile, and each profile gets an algorithm
# plus an idle threshold that matches that data's lifetime.
#
# Profile table:
#
#   profile       data                          algorithm   idle
#   hot_small     small, frequently touched     lz4hc       120s
#   hot_large     large, frequently touched     lz4         300s
#   cold_large    large, rarely touched         zstd        360s
#   cold_small    small, rarely touched         zstdp       240s
#   kernel_text   kernel/slab, cold             lz4hc       600s
#
# Idle compression: pages untouched longer than the threshold become
# reclaimable. The kernel performs the actual page movement; this script only
# arms the mechanism and reports ratios.
#
# Limits (stated so they are not mistaken for features):
#   - stored pages are NOT re-encoded; changing comp_algorithm only affects
#     pages written afterwards
#   - there is no writeback "mode" sysfs node (writeback is a 0/1 bool)
#   - no per-page tagging; classification is per-tier
# ===========================================================================
CONFDIR=/data/adb/multizram
CONF=$CONFDIR/zram.conf
LOG=$CONFDIR/service.log
[ -d "$CONFDIR" ] || mkdir -p "$CONFDIR"
[ -f "$CONF" ] || cp "$0/../zram.conf" "$CONF" 2>/dev/null

log() { echo "[multizram $(date '+%F %T')] $*" >> "$LOG"; }

# config reader: strips inline comments; returns $2 when the key is absent
cfg() {
  awk -v k="$1" -v d="$2" -F= '
    /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=/ {
      line=$0; sub(/#.*/, "", line);
      n=index(line,"="); key=substr(line,1,n-1); gsub(/[ \t]/,"",key);
      if (key==k) val=substr(line,n+1);
    }
    END { gsub(/[ \t]/,"",val); if (val=="") val=d; print val }' "$CONF" 2>/dev/null
}

profile() {  # profile <name> <algo|idle> <default>
  case "$1-$2" in
    hot_small-algo) echo lz4hc;;   hot_small-idle)   echo 120;;
    hot_large-algo) echo lz4;;     hot_large-idle)   echo 300;;
    cold_large-algo) echo zstd;;   cold_large-idle)  echo 360;;
    cold_small-algo) echo zstdp;;  cold_small-idle)  echo 240;;
    kernel_text-algo) echo lz4hc;; kernel_text-idle) echo 600;;
    *) echo "$3";;
  esac
}

# ---------- sysfs writers --------------------------------------------------
wfile() {  # wfile <path> <value> <label>
  [ -w "$1" ] || { log "skip $3 (not writable)"; return 1; }
  printf '%s' "$2" > "$1" 2>/dev/null && return 0
  log "fail $3 <- $2"; return 1
}

# zram publishes no algorithm list, so the write itself validates the name.
set_algo() {  # set_algo <dev> <name>
  local cur
  cur=$(tr -d ' ' < "$1/comp_algorithm" 2>/dev/null)
  printf '%s' "$2" > "$1/comp_algorithm" 2>/dev/null && return 0
  printf '%s' "$cur" > "$1/comp_algorithm" 2>/dev/null
  log "kernel rejected algo '$2'"; return 1
}

# ---------- idle-time sweep (invoked via --idle) --------------------------
# Runs a few minutes after boot once the system has warmed up. Reports each
# tier's compression ratio and re-arms idle reclamation. It does NOT re-encode
# stored pages — zram has no such node.
if [ "${1:-}" = "--idle" ]; then
  STATE=$CONFDIR/idle_state
  now=$(date +%s)
  interval=$(cfg IDLE_INTERVAL 21600)
  last=$(awk -F= '/^idle_at=/{print $2}' "$STATE" 2>/dev/null)
  if [ "${last:-0}" -gt 0 ] && [ $((now - last)) -lt "$interval" ]; then
    exit 0
  fi
  for z in /sys/block/zram*; do
    [ -e "$z" ] || continue
    name=$(basename "$z")
    if [ -r "$z/mm_stat" ]; then
      stats=$(awk '/^orig_data/{o=$2} /^mem_used_total/{u=$2} END{print o, u}' "$z/mm_stat")
      if [ -n "$stats" ]; then
        orig=${stats%% *}
        used=${stats##* }
      else
        orig=0
        used=0
      fi
      if [ "${orig:-0}" -gt 0 ] && [ "${used:-0}" -gt 0 ]; then
        r=$(awk -v o="$orig" -v u="$used" 'BEGIN{printf "%.2f", o/u}')
        log "idle: $name ratio=${r}x"
      else
        log "idle: $name pool empty"
      fi
    fi
    # re-arm reclamation: pages past their idle threshold become reclaimable
    [ -w "$z/mark_idle" ] && printf '1' > "$z/mark_idle" 2>/dev/null
  done
  printf 'idle_at=%s\n' "$now" > "$STATE"
  log "idle sweep done"
  exit 0
fi

# ---------- safety: never reconfigure a live device ------------------------
for z in /sys/block/zram*; do
  [ -e "$z/disksize" ] && [ -s "$z/disksize" ] && {
    log "zram already active; aborting"; exit 0
  }
done

# ---------- boot ----------
MEM=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo)
[ "${MEM:-0}" -gt 0 ] || MEM=8192

TIER_DEFAULTS="hot_small:6:100 hot_large:12:95 cold_large:10:90"
i=0
for spec in $TIER_DEFAULTS; do
  dev="/sys/block/zram$i"
  [ -e "$dev" ] || { log "zram$i missing; stopping"; break; }

  # spec is "profile:sizepct:prio" — defaults unless zram.conf overrides
  prof=${spec%%:*}; rest=${spec#*:}
  sizepct=${rest%%:*}; prio=${rest##*:}

  prof=$(cfg "t${i}_PROFILE" "$prof")
  default_algo=$(profile "$prof" algo "")
  default_idle=$(profile "$prof" idle "")
  algo=$(cfg "t${i}_ALGO" "$default_algo")
  idlev=$(cfg "t${i}_IDLE" "$default_idle")
  sz=$(cfg "t${i}_SIZE_PCT" "$sizepct")

  devsize=$(( MEM * sz / 100 * 1024 * 1024 ))
  bdev="/dev/block/${dev##*/}"

  wfile "$dev/reset" 1 "reset $i" || true
  wfile "$dev/disksize" "$devsize" "disksize $i" || continue

  set_algo "$dev" "$algo" || for a in lz4 lz4hc zstd lzo; do
    set_algo "$dev" "$a" && { algo=$a; break; }
  done

  [ -w "$dev/idle" ] && wfile "$dev/idle" "$idlev" "idle $i"
  [ -w "$dev/writeback" ] && wfile "$dev/writeback" 1 "writeback $i"

  if mkswap "$bdev" 2>/dev/null && swapon -p "$prio" "$bdev" 2>/dev/null; then
    log "zram$i up: profile=$prof algo=$algo ${sz}% prio=$prio idle=${idlev}s"
  else
    log "zram$i swapon failed"
  fi
  i=$((i+1))
done

# arm the idle pass
for z in /sys/block/zram*; do
  [ -w "$z/mark_idle" ] && printf '1' > "$z/mark_idle" 2>/dev/null
done

# defer the idle sweep so the system warms up first
( sleep 300 && sh "$0" --idle ) >/dev/null 2>&1 &

log "configured $i tiers"
