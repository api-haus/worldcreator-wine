#!/usr/bin/env bash
# Apply the winevulkan vkGetMemoryWin32HandleKHR resolution fix to the installed
# World Creator Veldrid.dll, reproducibly and idempotently.
#
# Stock Veldrid resolves vkGetMemoryWin32HandleKHR through the Vulkan instance
# proc-addr, which winevulkan returns NULL for (it is a device-level command),
# and stores the NULL unguarded -> the first External buffer creation calls
# address 0 (c0000005, execute @ 0x0) and the denoiser crashes. This swaps the
# resolution to the device proc-addr, which winevulkan exposes correctly. See
# tools/patch-veldrid/Program.cs for the exact IL edit.
#
# The patcher reads the stock DLL and writes the patched DLL; the stock copy is
# preserved as Veldrid.dll.orig. Running this again after a World Creator
# reinstall re-applies the fix from the fresh stock DLL.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

INSTALL_DIR="${WC_INSTALL_DIR:-$REPO/wineprefix/drive_c/Program Files/World Creator 2026.4}"
DLL="$INSTALL_DIR/Veldrid.dll"
ORIG="$INSTALL_DIR/Veldrid.dll.orig"

if [ ! -f "$DLL" ]; then
  echo "error: Veldrid.dll not found at: $DLL" >&2
  echo "       set WC_INSTALL_DIR to the install directory if it lives elsewhere." >&2
  exit 1
fi

# Distinguish a stock from an already-patched DLL by checking which resolver the
# guarded call site targets. ikdasm disassembles managed IL without a runtime;
# monodis segfaults on Cecil-rewritten metadata, so it is not used here. The
# guarded call is rendered on the line after the ldstr, hence -A2.
is_patched() {
  ikdasm "$1" 2>/dev/null \
    | grep -A2 -F 'ldstr      "vkGetMemoryWin32HandleKHR"' \
    | grep -qF 'GetDeviceProcAddr(string)'
}

# Back up the stock DLL once. Never overwrite an existing .orig: if the current
# Veldrid.dll is already patched and no .orig exists, the stock copy is gone and
# we must not clobber the backup with a patched file.
if [ ! -f "$ORIG" ]; then
  if is_patched "$DLL"; then
    echo "error: $DLL is already patched but no $ORIG backup exists." >&2
    echo "       cannot recover the stock DLL; reinstall World Creator to restore it." >&2
    exit 1
  fi
  cp -p "$DLL" "$ORIG"
  echo "backed up stock Veldrid.dll -> $ORIG"
else
  echo "stock backup already present: $ORIG (left untouched)"
fi

# Always patch from the stock backup so re-runs are deterministic and never
# double-apply or patch an already-patched DLL.
TMP_OUT="$(mktemp --suffix=.dll)"
trap 'rm -f "$TMP_OUT"' EXIT

echo "building patcher (dotnet)…"
dotnet build "$HERE/PatchVeldrid.csproj" -c Release -v quiet --nologo >/dev/null

PATCHER="$HERE/bin/Release/net10.0/patch-veldrid.dll"
echo "patching $ORIG -> $TMP_OUT"
dotnet "$PATCHER" "$ORIG" "$TMP_OUT"

if ! is_patched "$TMP_OUT"; then
  echo "error: post-patch verification failed; patched DLL still resolves via instance proc-addr." >&2
  exit 1
fi

cp "$TMP_OUT" "$DLL"
echo "installed patched Veldrid.dll -> $DLL"
echo "done."
