#!/usr/bin/env bash
# Build the memory shim (required), the Vulkan heap-cap layer (optional), and
# the nvcuda bridge (optional, for the GPU-denoise work). The nvcuda step needs
# mingw-w64-gcc, meson, ninja, winegcc and Vulkan headers; it is skipped if the
# tools are missing.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)

echo "[1/3] memcap.so (required)"
gcc -O2 -fPIC -shared -o "$HERE/memcap.so" "$HERE/memcap.c" -ldl

echo "[2/3] vkheapcap.so (Vulkan layer, optional)"
if [ -f /usr/include/vulkan/vk_layer.h ]; then
  gcc -O2 -fPIC -shared -o "$HERE/vkheapcap.so" "$HERE/vkheapcap.c"
  # install the implicit-layer manifest pointing at the built .so
  mkdir -p "$HOME/.local/share/vulkan/implicit_layer.d"
  sed "s#@LIB@#$HERE/vkheapcap.so#" "$HERE/wc_heapcap.json.in" \
    > "$HOME/.local/share/vulkan/implicit_layer.d/wc_heapcap.json"
else
  echo "  skipped: vulkan headers not found"
fi

echo "[3/3] nvcuda bridge (optional)"
if ! command -v x86_64-w64-mingw32-gcc >/dev/null || ! command -v meson >/dev/null; then
  echo "  skipped: need mingw-w64-gcc + meson + ninja"
  exit 0
fi
if [ ! -d "$HERE/nvidia-libs" ]; then
  git clone --depth 1 https://github.com/SveSop/nvidia-libs.git "$HERE/nvidia-libs"
  git -C "$HERE/nvidia-libs" submodule update --init --recursive
fi
rm -rf "$HERE/nvlibs-build"
meson setup --cross-file "$HERE/nvidia-libs/nvcuda/build-wine64.txt" \
  --buildtype release --prefix "$HERE/nvlibs-build" "$HERE/nvlibs-build/build.64" \
  "$HERE/nvidia-libs/nvcuda"
ninja -C "$HERE/nvlibs-build/build.64" install
echo "  nvcuda bridge: $HERE/nvlibs-build/lib/nvcuda.dll.so"
