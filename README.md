# World Creator on Linux (Wine)

Launchers and patches that run BiteTheBytes' World Creator — a Windows .NET desktop application with a Veldrid/Vulkan renderer — under Wine on Linux, including the GPU (CUDA/OIDN) viewport denoiser on NVIDIA. World Creator itself is not included; install it from your own licensed copy.

Verified on Wine 11.11, a GeForce RTX 5080 (NVIDIA 610 driver, Vulkan 1.4), and .NET 10.0.8.

## What's here

- `install-wc.sh` — installs and patches **any** World Creator version into a shared prefix (prefix deps, .NET runtime, nvcuda bridge, Veldrid/octane patches). Idempotent; versions coexist.
- `wc` — generic launcher: GPU denoise env + the startup-runaway guard, for any installed version.
- `world-creator` / `world-creator-denoise` — back-compat 2026.4 shortcuts over `wc` (baseline / GPU denoise).
- `build.sh` — back-compat shim: prefix setup + patch an already-installed 2026.4.
- `tools/patch-nvcuda/`, `tools/patch-veldrid/` — the two source patches the GPU denoiser needs (below).
- `vkheapcap.c` + `wc_heapcap.json.in` — a Vulkan layer that caps the reported host-visible heap size.

## Setup

`install-wc.sh` does everything — creates the prefix, installs the prefix deps (`vcrun2022` + fonts), builds and patches the `nvcuda` bridge, ensures the right .NET runtime, installs the version, and patches it. Idempotent; install versions side by side:

```
./install-wc.sh --msi /path/to/WorldCreator_2026_4.msi          # from an MSI
./install-wc.sh --portable /path/to/WorldCreator_2025_1_BETA    # existing/portable dir, patched in place
```

.NET is auto-selected (2024/2025.x → net8, else net10) and installed from `$WC_DOTNET_DIR` (default: the repo dir; drop `windowsdesktop-runtime-<major>-x64.exe` there); override with `--net` or the dir. Then:

```
./wc "World Creator 2026.4"               # GPU denoiser + runaway guard
./wc "World Creator 2026.4" --no-denoise  # baseline
./wc "World Creator 2025.1"               # any other installed version (2025.1 needs no guard)
```

`world-creator-denoise` / `world-creator` stay as 2026.4 shortcuts. The scripts resolve their own directory; keep them next to `wineprefix/` and `nvlibs-build/`.

**Side-by-side .NET caveat:** 2025.x (net8) + 2026.x (net10) in one prefix means both runtimes are installed. Fine on clean installs — the explicit `DOTNET_ROOT` the launcher sets resolves the right framework per `runtimeconfig` — but never hand-edit the `HKLM\SOFTWARE\dotnet` registry tree; a corrupted one is what produces the ".NET Desktop Runtime" dialog (see Gotchas).

## Gotchas

- **The apphost must be pointed at the in-prefix runtime.** `WorldCreator.exe` has no embedded search path; it resolves the runtime from `DOTNET_ROOT[_X64]`, else the registry key `HKLM\SOFTWARE\dotnet\Setup\InstalledVersions\x64\InstallLocation`, else the `%ProgramFiles%\dotnet` known-folder. A host `DOTNET_ROOT=/usr/share/dotnet` leaks into Wine and mis-resolves to `Z:\usr\share\dotnet`; merely clearing it then leaves resolution on the registry/known-folder probe, which yields "must install .NET Desktop Runtime" whenever that registry key is missing (the desktop-runtime installer writes it; deleting `HKLM\SOFTWARE\dotnet` drops it). The launchers set `DOTNET_ROOT='C:\Program Files\dotnet'` — an explicit Windows path that overrides the leak and skips the probe entirely.
- **`mscoree` must stay builtin at run time.** Disabling it to skip the Mono prompt during init is fine, but an `mscoree=d` override while running makes the CoreCLR managed assemblies fail to load with a misleading "Module not found".
- **EGL warning spam.** The NVIDIA EGL driver prints `failed to create dri2 screen` repeatedly. It is harmless, but piping it to a terminal that cannot drain it fast enough blocks the application's stdout and hangs it at the splash. The launchers log to a file and set `EGL_LOG_LEVEL=fatal`.

## GPU denoise

The viewport denoiser is Intel Open Image Denoise 2.3.3, GPU backends only; on NVIDIA it needs `nvcuda.dll` (the CUDA Driver API). `install-wc.sh` assembles the pieces it requires, and `wc` (incl. `world-creator-denoise`) enables them.

- **`nvcuda.dll` in the prefix `system32`** — OIDN's CUDA backend does `LoadLibrary("nvcuda.dll")`, and the `WINEDLLOVERRIDES=nvcuda=b` + `WINEDLLPATH` the launcher sets are **not** enough on their own: the bridge's PE half must be visible in the prefix's `system32`, or the denoiser toggles on and silently does nothing. `install-wc.sh` symlinks it (`…/nvlibs-build/lib/wine/x86_64-windows/nvcuda.dll`).
- **`vcrun2022` (MSVC runtime) — required to launch.** `WorldCreator.exe`'s native libraries link the Microsoft Visual C++ runtime; without it the .NET app won't start at all (coreclr/`libicuuc` load failure). `install-wc.sh` installs it. (An OIDN `_device_cpu.dll` is a dead end — it never denoises, only renders **black** — so don't add one.)

**DXVK is not needed** — World Creator is Vulkan-native (Veldrid → winevulkan), so nothing translates D3D. Leave-one-out on 2025.1 (deterministic) confirms the **minimal denoise set**: the Veldrid patch, the D3DKMT bridge patch, the nvcuda bridge + `system32` symlink, and `vcrun2022` — removing any one breaks denoise (crash / black / black / no-launch); DXVK, fonts, and vkheapcap do not.

- **nvcuda bridge** — built from [nvidia-libs](https://github.com/SveSop/nvidia-libs), forwarding the CUDA Driver API to host `libcuda.so`. It loads as a builtin split DLL via `WINEDLLOVERRIDES=nvcuda=b` + `WINEDLLPATH`.
- **Bridge patch (`tools/patch-nvcuda/`)** — OIDN imports the Vulkan buffers via `cuImportExternalMemory` (`OPAQUE_WIN32`). The stock bridge resolves the handle through Proton's `IOCTL_SHARED_GPU_RESOURCE` device, absent in Wine 11.11, so the import fails and denoise renders black. The patch opens the handle's D3DKMT shared resource instead, the way win32u does.
- **Veldrid patch (`tools/patch-veldrid/`)** — `vkGetMemoryWin32HandleKHR` is resolved via the device proc-addr; the instance proc-addr returns NULL under winevulkan, and the unguarded NULL otherwise faults at address 0 on the first external buffer.
- **Octane disabled** — `octane.dll` is renamed to `octane.dll.OFF`. It is a separate bundled CUDA path tracer that builds its own RAM-sized host pool; the Vulkan renderer and OIDN do not need it.

## The startup memory runaway (World Creator 2025.2 and later)

Some World Creator versions enter a memory runaway during startup: a few seconds in, the process begins committing host memory at ~2.5 GB/s and climbs toward tens of GB without settling, until it is killed. It does not recover on its own; left alone it exhausts host RAM and starves the desktop.

It is **bimodal and non-deterministic**. The same build, same machine, same inputs boots clean on some attempts (RSS settles ~1.5 GB and the session is stable for its whole life, large terrains and high resolution included) and runs away on others, with no relation to anything the user does. The clean rate is **machine-dependent and can be low** — on an RTX 5080 it has been ~1 in 10 (seven-plus runaways before a clean boot), so the relaunch loop may need many tries.

### What it is — and is not

A version bisect places the regression precisely: **2025.1 never runs away; 2025.2 is the first version that does, and every version since (2025.3, 2025.6, 2026.1 … 2026.4) inherits it.** So it is a change in World Creator's own startup code, confirmed by ruling out every external factor:

- **Not the wine version** — 11.8, 11.9, 11.10 and 11.11 all run away at the same rate.
- **Not swap or the reported pagefile** — disabling swap does not help; the runaway still claims host memory.
- **Not the GPU-denoise / CUDA path** — the baseline renderer with no `nvcuda` bridge loaded runs away too; the bridge is not required to trigger it.
- **Not the .NET runtime** — 2025.1 and 2025.6 are both `net8` and both run on the same installed runtime via roll-forward, yet one is clean and the other is not.
- **Not boundable by faking the reported memory** — capping the `sysinfo` figure has no effect (World Creator does not size its allocation to it), and capping `/proc/meminfo` instead makes its allocate-until-free-memory-drops loop never terminate. No in-process cap bounds it without corrupting the process, and no external lever (CPU affinity, in-process GPU pre-warm, memory caps) makes a boot deterministically clean. (An earlier `memcap` `LD_PRELOAD` shim that capped `sysinfo` was removed once testing showed it changed nothing.)

The diverging factor between a clean and a runaway boot is internal timing in World Creator's (obfuscated) startup, not any value the environment can set — which is why it presents as random and cannot be fixed from outside the application.

### Living with it

- **For reliable GPU denoise, use World Creator 2025.1** with the Veldrid patch (`build.sh` applies it to whatever version is installed). 2025.1 boots clean every time and denoises on the RTX 5080.
- **On 2025.2 and later (including 2026.x)** the runaway is unavoidable in World Creator's code, so `world-creator-denoise` works around it rather than preventing it: it guards the startup window with a hard RSS kill-switch (kill at 5 GB RSS or below 12 GB `MemAvailable`), kills a filling boot before it can starve the host, and relaunches until one lands clean. At a ~1-in-10 clean rate that can take many tries, so the default ceiling is 30 (`WC_MAX_TRIES`). That is the "it works sometimes" behaviour made automatic. Once a boot is clean the guard disarms, and on exit (quit, Ctrl-C, or close) it reaps its whole wine session so nothing lingers. Tunable via `WC_KILL_RSS_MB`, `WC_GUARD_WINDOW_S`, `WC_MAX_TRIES`.

## License

The shims, layer, patches, and launchers here are MIT. World Creator, the .NET runtime, and nvidia-libs are separate works under their own licenses.
