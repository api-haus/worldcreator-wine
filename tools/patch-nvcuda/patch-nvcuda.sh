#!/bin/sh
# Apply the D3DKMT external-memory fix to the nvcuda bridge, rebuild, install.
#
# OIDN imports the Vulkan denoise buffers via cuImportExternalMemory
# (OPAQUE_WIN32). The stock bridge resolves the Win32 handle to a host fd via
# Proton's IOCTL_SHARED_GPU_RESOURCE device, absent in upstream Wine 11.11, so
# the import fails (CUDA_ERROR_UNKNOWN) and denoise renders black. The patch
# opens the handle's D3DKMT shared resource instead (see d3dkmt-import.patch).
#
# Idempotent; re-run after re-cloning nvidia-libs. Needs meson/ninja + the
# configured build dir.
set -e
ROOT=${WC_ROOT:-/mnt/archive4/WORLD_CREATOR}
NVCUDA="$ROOT/nvidia-libs/nvcuda"
BUILD="$ROOT/nvlibs-build/build.64"
INSTALL="$ROOT/nvlibs-build/lib/wine/x86_64-unix/nvcuda.dll.so"
PATCH="$(dirname "$(readlink -f "$0")")/d3dkmt-import.patch"

cd "$NVCUDA"
if grep -q 'd3dkmt_object_open' dlls/nvcuda/internal.c; then
    echo "patch already present in internal.c; rebuilding only"
else
    git apply --check "$PATCH" || { echo "patch does not apply cleanly against $(git rev-parse HEAD)"; exit 1; }
    git apply "$PATCH"
    echo "patch applied"
fi

ninja -C "$BUILD"
cp -n "$INSTALL" "$INSTALL.preD3DKMT" 2>/dev/null || true
cp "$BUILD/dlls/nvcuda/nvcuda.dll.so" "$INSTALL"
echo "installed rebuilt bridge -> $INSTALL"
grep -c 'd3dkmt' "$INSTALL" >/dev/null 2>&1 || true
strings "$INSTALL" | grep -q 'd3dkmt resource fd conversion failed' && echo "verified: D3DKMT path present in installed .so"
