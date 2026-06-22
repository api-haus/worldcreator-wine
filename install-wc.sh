#!/usr/bin/env bash
# Reusable World Creator installer for Wine. Installs and patches ANY version into a
# shared prefix; multiple versions coexist (each in its own "Program Files" dir, with
# the .NET runtime it needs). Idempotent — re-run to repair or re-patch.
#
#   ./install-wc.sh --msi /path/WorldCreator_2026_4.msi
#   ./install-wc.sh --portable /path/WorldCreator_2025_1_BETA
#
#   --msi PATH        install from an MSI, then patch
#   --portable DIR    patch an existing dir in place (portable build, or one already
#                     installed by hand) — no MSI step
#   --net 8|10        .NET runtime to ensure (default: auto — 2024/2025.x=8, else 10)
#   --prefix DIR      WINEPREFIX (default: ./wineprefix)
#
# .NET runtimes are found in $WC_DOTNET_DIR (default: this repo dir) as
# windowsdesktop-runtime-<major>-x64.exe; override the dir or pre-install them.
# Launch an installed version with ./wc "World Creator <ver>".
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

MSI=""; PORTABLE=""; NET=""; PREFIX="$HERE/wineprefix"
while [ $# -gt 0 ]; do case "$1" in
  --msi) MSI="$2"; shift 2;;
  --portable) PORTABLE="$2"; shift 2;;
  --net) NET="$2"; shift 2;;
  --prefix) PREFIX="$2"; shift 2;;
  -h|--help) sed -n '2,18p' "$0"; exit 0;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
[ -n "$MSI$PORTABLE" ] || { echo "usage: install-wc.sh (--msi PATH | --portable DIR) [--net 8|10] [--prefix DIR]" >&2; exit 2; }

export WINEPREFIX="$PREFIX" WINEDEBUG=-all
unset DOTNET_ROOT DOTNET_ROOT_X64 2>/dev/null || true   # host leak would mis-resolve under wine

SRC="${MSI:-$PORTABLE}"
VER=$(basename "$SRC" | grep -oiE '20[0-9]{2}[._][0-9]+' | head -1 | tr '_' '.' || true)
[ -n "$VER" ] || VER="?"
if [ -z "$NET" ]; then case "$VER" in 2024.*|2025.*) NET=8;; *) NET=10;; esac; fi
echo "== World Creator install: version=${VER} net=${NET} prefix=${PREFIX} =="

ensure_dotnet() {       # $1 = major (8|10); install the Desktop Runtime if absent
  local maj="$1" shared="$PREFIX/drive_c/Program Files/dotnet/shared/Microsoft.WindowsDesktop.App"
  if ls "$shared" 2>/dev/null | grep -q "^${maj}\."; then echo "[dotnet] net${maj} present"; return; fi
  local dir="${WC_DOTNET_DIR:-$HERE}" exe
  exe=$(ls "$dir"/windowsdesktop-runtime-"${maj}"[.-]*x64.exe 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$exe" ] || { echo "error: .NET ${maj} Desktop Runtime missing and no installer in ${dir}" >&2
    echo "       put windowsdesktop-runtime-${maj}-x64.exe there or set WC_DOTNET_DIR" >&2; exit 1; }
  echo "[dotnet] installing net${maj} from $(basename "$exe")"
  wine "$exe" /install /quiet /norestart || true
  wineserver -w 2>/dev/null || true
}

setup_prefix_wide() {   # everything shared by all versions; all steps idempotent
  if command -v winetricks >/dev/null; then
    echo "[deps] vcrun2022 + dxvk + corefonts + fontsmooth"
    winetricks -q vcrun2022 dxvk corefonts fontsmooth=rgb
  else echo "  WARNING: winetricks not found — denoise needs vcrun2022 + dxvk"; fi

  if [ -f /usr/include/vulkan/vk_layer.h ]; then
    gcc -O2 -fPIC -shared -o "$HERE/vkheapcap.so" "$HERE/vkheapcap.c"
    mkdir -p "$HOME/.local/share/vulkan/implicit_layer.d"
    sed "s#@LIB@#$HERE/vkheapcap.so#" "$HERE/wc_heapcap.json.in" \
      > "$HOME/.local/share/vulkan/implicit_layer.d/wc_heapcap.json"
  fi

  if command -v x86_64-w64-mingw32-gcc >/dev/null && command -v meson >/dev/null; then
    if [ ! -d "$HERE/nvidia-libs" ]; then
      git clone --depth 1 https://github.com/SveSop/nvidia-libs.git "$HERE/nvidia-libs"
      git -C "$HERE/nvidia-libs" submodule update --init --recursive
    fi
    if [ ! -d "$HERE/nvlibs-build/build.64" ]; then
      meson setup --cross-file "$HERE/nvidia-libs/nvcuda/build-wine64.txt" \
        --buildtype release --prefix "$HERE/nvlibs-build" \
        "$HERE/nvlibs-build/build.64" "$HERE/nvidia-libs/nvcuda"
      ninja -C "$HERE/nvlibs-build/build.64" install
    fi
    WC_ROOT="$HERE" "$HERE/tools/patch-nvcuda/patch-nvcuda.sh"
  else echo "  WARNING: need mingw-w64-gcc + meson + ninja for the nvcuda bridge (GPU denoise)"; fi

  # OIDN's CUDA backend does LoadLibrary("nvcuda.dll"); WINEDLLOVERRIDES/WINEDLLPATH are
  # not enough on their own — the PE half must be visible in the prefix's system32 or
  # the denoiser enables but silently does nothing.
  local pe="$HERE/nvlibs-build/lib/wine/x86_64-windows/nvcuda.dll"
  if [ -f "$pe" ] && [ -d "$PREFIX/drive_c/windows/system32" ]; then
    ln -sf "$pe" "$PREFIX/drive_c/windows/system32/nvcuda.dll"
  fi
}

# 1. prefix
if [ ! -f "$PREFIX/system.reg" ]; then
  echo "[prefix] creating $PREFIX"
  WINEARCH=win64 WINEDLLOVERRIDES="mscoree=d;mshtml=d" wineboot --init
  wineserver -w 2>/dev/null || true
fi
# 2. runtime + shared deps
ensure_dotnet "$NET"
setup_prefix_wide
# 3. install / locate the version
if [ -n "$MSI" ]; then
  echo "[install] $MSI"
  wine msiexec /i "$(winepath -w "$MSI")" /qn
  wineserver -w 2>/dev/null || true
  WC_DIR="$PREFIX/drive_c/Program Files/World Creator ${VER}"
else
  WC_DIR="$PORTABLE"
fi
[ -f "$WC_DIR/WorldCreator.exe" ] || { echo "error: WorldCreator.exe not found at: $WC_DIR" >&2; exit 1; }
# 4. patch this install
echo "[patch] Veldrid + octane @ $WC_DIR"
WC_INSTALL_DIR="$WC_DIR" "$HERE/tools/patch-veldrid/patch-veldrid.sh"
if [ -f "$WC_DIR/octane.dll" ]; then
  # Octane is a separate bundled CUDA path tracer with its own RAM-sized host pool;
  # the Vulkan renderer + OIDN do not need it.
  mv "$WC_DIR/octane.dll" "$WC_DIR/octane.dll.OFF"; echo "  disabled octane.dll"
fi
echo "done. launch: ./wc \"$(basename "$WC_DIR")\"   (add --no-denoise to skip the GPU denoiser)"
