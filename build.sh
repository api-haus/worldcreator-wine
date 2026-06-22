#!/usr/bin/env bash
# Build and install everything needed to run World Creator 2026.4 with the GPU
# (CUDA/OIDN) denoiser under Wine on NVIDIA. Run once after World Creator is
# installed into ./wineprefix. Safe to re-run (idempotent).
#
#   1. vkheapcap.so   — Vulkan layer capping the host-visible heap size
#                       (optional; needs Vulkan headers).
#   2. nvcuda bridge  — SveSop's nvcuda plus the D3DKMT external-memory patch OIDN
#                       needs to import the denoise buffers (optional; needs
#                       mingw-w64-gcc + meson + ninja).
#   3. install patches — Veldrid.dll vkGetMemoryWin32HandleKHR fix, octane disable.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
WC_DIR="${WC_INSTALL_DIR:-$HERE/wineprefix/drive_c/Program Files/World Creator 2026.4}"
WINEPREFIX="${WINEPREFIX:-$HERE/wineprefix}"; export WINEPREFIX

echo "[1/4] prefix deps: vcrun2022 + dxvk + fonts"
# GPU denoise needs the MSVC runtime (vcrun2022) for the native OIDN DLLs and DXVK for
# the D3D->Vulkan path; without them the denoiser enables but produces no output.
# corefonts + fontsmooth=rgb give the UI crisp antialiased text — wine defaults font
# smoothing off, which leaves the (small) UI labels aliased. winetricks is idempotent.
if command -v winetricks >/dev/null; then
  winetricks -q vcrun2022 dxvk corefonts fontsmooth=rgb
else
  echo "  WARNING: winetricks not found — install vcrun2022 + dxvk manually or GPU denoise will not work"
fi

echo "[2/4] vkheapcap.so (Vulkan layer)"
if [ -f /usr/include/vulkan/vk_layer.h ]; then
  gcc -O2 -fPIC -shared -o "$HERE/vkheapcap.so" "$HERE/vkheapcap.c"
  mkdir -p "$HOME/.local/share/vulkan/implicit_layer.d"
  sed "s#@LIB@#$HERE/vkheapcap.so#" "$HERE/wc_heapcap.json.in" \
    > "$HOME/.local/share/vulkan/implicit_layer.d/wc_heapcap.json"
else
  echo "  skipped: Vulkan headers not found"
fi

echo "[3/4] nvcuda bridge (GPU denoise)"
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
  WC_ROOT="$HERE" "$HERE/tools/patch-nvcuda/patch-nvcuda.sh"   # D3DKMT import fix + rebuild
else
  echo "  skipped: need mingw-w64-gcc + meson + ninja"
fi
# OIDN's CUDA backend does LoadLibrary("nvcuda.dll"); the WINEDLLOVERRIDES/WINEDLLPATH
# the launcher sets are not enough on their own — the PE half must be visible in the
# prefix's system32 or the denoiser enables but silently does nothing.
PE_NVCUDA="$HERE/nvlibs-build/lib/wine/x86_64-windows/nvcuda.dll"
if [ -f "$PE_NVCUDA" ] && [ -d "$WINEPREFIX/drive_c/windows/system32" ]; then
  ln -sf "$PE_NVCUDA" "$WINEPREFIX/drive_c/windows/system32/nvcuda.dll"
  echo "  linked nvcuda.dll into prefix system32"
fi

echo "[4/4] World Creator install patches"
if [ -d "$WC_DIR" ]; then
  WC_INSTALL_DIR="$WC_DIR" "$HERE/tools/patch-veldrid/patch-veldrid.sh"
  if [ -f "$WC_DIR/octane.dll" ]; then
    # OctaneRender builds its own RAM-sized host pool on a CUDA device; World
    # Creator's Vulkan renderer + OIDN do not need it, so disable it.
    mv "$WC_DIR/octane.dll" "$WC_DIR/octane.dll.OFF"
    echo "  disabled octane.dll -> octane.dll.OFF"
  fi
else
  echo "  skipped: World Creator not found at $WC_DIR — install it into ./wineprefix and re-run."
fi

echo "done. Launch: ./world-creator-denoise (GPU denoise) or ./world-creator (no denoise)."
