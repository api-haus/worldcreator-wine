#!/usr/bin/env bash
# Back-compat shim. If World Creator 2026.4 was installed separately (old README flow),
# this sets up the prefix (vcrun2022/dxvk/fonts, vkheapcap, nvcuda bridge + system32
# symlink) and patches that install. New or multi-version installs should use
# ./install-wc.sh directly (it does the same setup plus the MSI/.NET steps).
HERE=$(cd "$(dirname "$0")" && pwd)
exec "$HERE/install-wc.sh" --portable "${WC_INSTALL_DIR:-$HERE/wineprefix/drive_c/Program Files/World Creator 2026.4}"
