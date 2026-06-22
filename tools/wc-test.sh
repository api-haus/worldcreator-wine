#!/bin/bash
# Reusable World Creator boot tester — one script for every version/config probe.
#
# Usage:
#   wc-test.sh --dir "World Creator 2026.4" [opts]
#   wc-test.sh --portable /mnt/archive4/wc-2025/WorldCreator_2025_1_BETA [opts]
#
#   --dir NAME       install dir under the wineprefix's "Program Files"
#   --portable PATH  absolute path to a portable WC dir (overrides --dir)
#   --bridge         load the nvcuda CUDA bridge (the GPU-denoise path)
#   --heapcap        enable the vkheapcap Vulkan layer
#   --mode MODE      loop (default): classify N boots; persist: one boot, hold open for login
#   -n N             boots in loop mode (default 8)
#   --kill MB        RSS kill ceiling (default 14000 loop / 28000 persist)
#   --floor MB       MemAvailable floor MB (default 12000 loop / 10000 persist)
#   --window S       clean-classify window, loop mode (default 22)
#   --label TXT      label in output
#
# Always: WINEPREFIX = the repo prefix; DOTNET_ROLL_FORWARD=LatestMajor; no memcap;
# each boot is reaped with wineserver -k (never -k9); reaps on exit.
set -u
HERE=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
PREFIX="$HERE/wineprefix"

DIR=""; PORTABLE=""; BRIDGE=0; HEAPCAP=0; MODE=loop; N=8; KILL=""; FLOOR=""; WINDOW=22; LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2;;
    --portable) PORTABLE="$2"; shift 2;;
    --bridge) BRIDGE=1; shift;;
    --heapcap) HEAPCAP=1; shift;;
    --mode) MODE="$2"; shift 2;;
    -n) N="$2"; shift 2;;
    --kill) KILL="$2"; shift 2;;
    --floor) FLOOR="$2"; shift 2;;
    --window) WINDOW="$2"; shift 2;;
    --label) LABEL="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

APP="${PORTABLE:-$PREFIX/drive_c/Program Files/$DIR}"
[ -x "$APP/WorldCreator.exe" ] || { echo "error: WorldCreator.exe not found at: $APP" >&2; exit 2; }
[ "$MODE" = persist ] && { KILL="${KILL:-28000}"; FLOOR="${FLOOR:-10000}"; } || { KILL="${KILL:-14000}"; FLOOR="${FLOOR:-12000}"; }
[ -n "$LABEL" ] || LABEL="$(basename "$APP")$([ $BRIDGE = 1 ] && echo +bridge)$([ $HEAPCAP = 1 ] && echo +heapcap)"

# Each World Creator generation ships against its own .NET (2025.x = net8,
# 2026.x = net10); install those runtimes into the prefix rather than forcing
# roll-forward, which breaks net10 apphost resolution.
# Point DOTNET_ROOT at the in-prefix runtime explicitly. The apphost otherwise
# probes the registry InstallLocation key, else %ProgramFiles%\dotnet, and an
# inherited host DOTNET_ROOT mis-resolves to Z:\usr\share\dotnet — set the Windows
# path directly so resolution is deterministic.
export WINEPREFIX WINEDEBUG=-all EGL_LOG_LEVEL=fatal DOTNET_EnableWriteXorExecute=0
export DOTNET_ROOT='C:\Program Files\dotnet'
unset LD_PRELOAD WINEDLLOVERRIDES WINEDLLPATH WC_HEAPCAP_ENABLE VKHEAPCAP_GB VKHEAPCAP_VRAM_GB DOTNET_ROLL_FORWARD
[ $BRIDGE = 1 ] && { export WINEDLLOVERRIDES="nvcuda=b" WINEDLLPATH="$HERE/nvlibs-build/lib/wine"; }
[ $HEAPCAP = 1 ] && { export WC_HEAPCAP_ENABLE=1 VKHEAPCAP_GB=4 VKHEAPCAP_VRAM_GB=8; }

reap() { local p; for p in $(pgrep -f 'WorldCreator.exe'); do kill -9 "$p" 2>/dev/null; done; wineserver -k 2>/dev/null; wineserver -w 2>/dev/null; }
trap reap EXIT INT TERM

# sample one boot; echo "verdict peak_mb avail0_mb tpeak_s". A .NET apphost dialog
# (early exit + dialog text in the log) is classified "dotnet", not clean/runaway,
# so it never pollutes the runaway rate. avail0 = MemAvailable at launch (for the
# "is the rate a system-condition?" question).
sample_boot() {
  local winms="$1"; ( cd "$APP" && exec wine WorldCreator.exe ) >/tmp/wc-test-boot.log 2>&1 &
  local peak=0 tpeak=0 t0 now el rss verdict="" pids p v avail avail0
  t0=$(date +%s%3N); avail0=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
  while :; do
    sleep 0.4; now=$(date +%s%3N); el=$(( now - t0 )); rss=0
    pids=$(pgrep -f 'WorldCreator.exe'); [ -z "$pids" ] && { verdict="exited"; break; }
    for p in $pids; do v=$(awk '/^VmRSS:/{print $2}' "/proc/$p/status" 2>/dev/null); [ -n "$v" ] && rss=$(( rss + v/1024 )); done
    [ "$rss" -gt "$peak" ] && { peak=$rss; tpeak=$el; }
    avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
    if [ "$rss" -gt "$KILL" ] || [ "$avail" -lt "$FLOOR" ]; then verdict="RUNAWAY"; for p in $pids; do kill -9 "$p" 2>/dev/null; done; break; fi
    [ "$el" -ge "$winms" ] && { verdict="clean"; break; }
  done
  if [ "$verdict" = exited ] && grep -qiE 'install .NET|Desktop Runtime|app-launch-failed' /tmp/wc-test-boot.log 2>/dev/null; then verdict="dotnet"; fi
  echo "$verdict $peak $avail0 $((tpeak/1000))"
}

reap
echo "### $LABEL  (mode=$MODE bridge=$BRIDGE heapcap=$HEAPCAP kill=${KILL}MB)"

if [ "$MODE" = persist ]; then
  echo "launching for interactive login; safety kill at ${KILL}MB / avail<${FLOOR}MB. Ctrl-C to stop."
  ( cd "$APP" && exec wine WorldCreator.exe ) >/tmp/wc-test-boot.log 2>&1 &
  t0=$(date +%s%3N)
  while :; do
    sleep 1; now=$(date +%s%3N); el=$(( (now-t0)/1000 )); rss=0
    pids=$(pgrep -f 'WorldCreator.exe'); [ -z "$pids" ] && { echo "t=${el}s EXITED"; break; }
    for p in $pids; do v=$(awk '/^VmRSS:/{print $2}' "/proc/$p/status" 2>/dev/null); [ -n "$v" ] && rss=$(( rss + v/1024 )); done
    avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
    printf 't=%ds rss=%sMB avail=%sMB\n' "$el" "$rss" "$avail"
    if [ "$rss" -gt "$KILL" ] || [ "$avail" -lt "$FLOOR" ]; then echo "t=${el}s SAFETY KILL rss=${rss}"; reap; break; fi
    [ "$el" -ge 900 ] && break
  done
  exit 0
fi

clean=0; runaway=0; dotnet=0; exited=0
for i in $(seq 1 "$N"); do
  # A "dotnet" verdict means the apphost dialog fired — a real, deterministic
  # resolution bug, not a flaky data point. Count and surface it; never retry past it.
  read -r verdict peak avail0 tpeak < <(sample_boot $(( WINDOW * 1000 )))
  case "$verdict" in clean) clean=$((clean+1));; RUNAWAY) runaway=$((runaway+1));; dotnet) dotnet=$((dotnet+1));; *) exited=$((exited+1));; esac
  printf '  boot %2d: %-8s peak=%5sMB tpeak=%ss avail0=%sMB\n' "$i" "$verdict" "$peak" "$tpeak" "$avail0"
  reap; sleep 2
done
valid=$((clean+runaway))
rate=$([ $valid -gt 0 ] && echo "$((clean*100/valid))%" || echo n/a)
echo "=> $LABEL: clean=$clean runaway=$runaway dotnet=$dotnet exited=$exited (of $N); clean-rate=$rate of $valid valid boots"
