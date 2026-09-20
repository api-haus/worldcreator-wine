# World Creator on Linux (Wine)

Launch BiteTheBytes' World Creator on Linux with its Vulkan renderer and NVIDIA
GPU denoiser. World Creator is proprietary; supply your own licensed installer.

## Requirements

- **Wine 11.17 or newer**, or Wine with [the TTC header fix] backported. Use the
  complete Wine installation, including its Unix font backend. An app-local
  `dwrite.dll` with a native override can leave all UI text missing.
- NVIDIA driver with Vulkan and CUDA support for GPU denoise.
- `winetricks`, `meson`, `ninja`, a working MinGW-w64 cross compiler, Wine
  development tools, .NET SDK 10, and Mono's `ikdasm`.
- Windows .NET Desktop Runtime installers: net8 for World Creator 2024/2025;
  net10 for 2026. Set `WC_DOTNET_DIR` to their directory.

Wine through 11.16 could read a bogus font count from a short TTC header,
allocating until host memory was exhausted during startup. The upstream fix
corrects that read; memory-report shims and startup retry loops are unnecessary.

## Install and launch

Keep this checkout next to its generated `wineprefix/` and `nvlibs-build/`.
Versions coexist in the prefix; installation is repeatable.

```sh
export WC_DOTNET_DIR=/path/to/runtime-installers
./install-wc.sh --msi /path/to/WorldCreator_2026_4.msi
wc-2026.4
```

The installer creates a **World Creator 2026.4** app-menu entry and a
`~/.local/bin/wc-2026.4` command. Both use the same launcher and prefix.
It installs `vcrun2022`, fonts, the required .NET runtime, and the denoise patches.

```sh
./wc "World Creator 2026.4"                 # GPU denoise enabled
./wc "World Creator 2026.4" --no-denoise    # Vulkan renderer without CUDA
./wc "World Creator 2025.6"
./wc "World Creator 2025.1"
```

Patch an existing installation or portable directory:

```sh
./install-wc.sh --portable "/path/to/World Creator 2026.4"
```

Repair app-menu and CLI entries without reinstalling:

```sh
./install-wc.sh --portable "$PWD/wineprefix/drive_c/Program Files/World Creator 2026.4" --launcher-only
```

`--prefix DIR` selects another prefix. `world-creator` and
`world-creator-denoise` remain shortcuts for 2026.4; `build.sh` repairs that
version's existing installation.

## NVIDIA denoise

World Creator uses Veldrid/Vulkan directly; DXVK is unnecessary. Its GPU-only
Open Image Denoise backend needs these pieces:

- **Veldrid patch:** resolve `vkGetMemoryWin32HandleKHR` through the device
  proc address. The instance lookup returns NULL under Wine.
- **nvcuda bridge:** [nvidia-libs] forwards the Windows CUDA driver API to host
  `libcuda.so.1`. Our patch imports Vulkan shared memory through D3DKMT instead
  of Proton's unavailable shared-resource ioctl.
- **Prefix DLL:** `wineprefix/drive_c/windows/system32/nvcuda.dll` must point to
  `nvlibs-build/lib/wine/x86_64-windows/nvcuda.dll`.
- **Driver lookup:** `wc` adds `/run/opengl-driver/lib` to `LD_LIBRARY_PATH`
  on NixOS so the bridge can load CUDA.

Rebuild the bridge after changing Wine's internal ABI: remove its generated
`nvlibs-build/build.64` directory and rerun the installer. The installer also
renames the separate, unused Octane path tracer to `octane.dll.OFF`.

## Troubleshooting

- Logs are written beside `wc` as `wc-World_Creator_<version>_.log`.
  Set `WINEDEBUG=+nvcuda` when checking CUDA initialization.
- `wc` sets `DOTNET_ROOT` to `C:\Program Files\dotnet`; a Linux runtime path
  inherited by Wine causes misleading missing-runtime dialogs. Keep both
  Windows Desktop Runtime generations installed; do not edit their registry
  registrations by hand.
- Keep `mscoree` builtin. Disabling it at runtime prevents managed assemblies
  from loading.
- Do not install an OIDN CPU backend as a substitute for the GPU bridge.
- Avoid native `dwrite` overrides or copied DLLs when applying the font fix:
  update Wine itself, so text rendering retains its Unix backend.

## Verify the Wine font fix

`tools/check-dwrite.c` checks a synthetic one-font collection without launching
World Creator or allocating a font set. Build it with a working MinGW toolchain
and run it with Wine; success reports `faces=1 expected=1` and exits zero.
On NixOS, compile inside `nix-shell -p pkgsCross.mingwW64.stdenv.cc`.

```sh
x86_64-w64-mingw32-gcc tools/check-dwrite.c -o tools/check-dwrite.exe -luuid
wine tools/check-dwrite.exe
```


## License

These launchers and patches are MIT. World Creator, .NET, Wine, and nvidia-libs
retain their respective licenses.

[the TTC header fix]: https://github.com/wine-mirror/wine/commit/a6fc12e4a94bf4dae2d5c3a297794107627dad0a
[nvidia-libs]: https://github.com/SveSop/nvidia-libs
