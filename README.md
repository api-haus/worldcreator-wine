# World Creator 2026.4 on Linux (Wine)

Launchers and patches that run BiteTheBytes' World Creator — a Windows .NET desktop application with a Veldrid/Vulkan renderer — under Wine on Linux, including the GPU (CUDA/OIDN) viewport denoiser on NVIDIA. World Creator itself is not included; install it from your own licensed copy.

Verified on Wine 11.11, a GeForce RTX 5080 (NVIDIA 610 driver, Vulkan 1.4), and .NET 10.0.8.

## What's here

- `tools/patch-nvcuda/`, `tools/patch-veldrid/` — the two source patches the GPU denoiser needs (below).
- `vkheapcap.c` + `wc_heapcap.json.in` — a Vulkan layer that caps the reported host-visible heap size.
- `build.sh` — builds the layer, builds and patches the `nvcuda` bridge, and applies the install patches.
- `world-creator` — baseline launcher (no CUDA bridge, no GPU denoiser).
- `world-creator-denoise` — GPU-denoise launcher with the boot guard (below).

## Setup

1. Create a 64-bit prefix:
   ```
   export WINEPREFIX=/path/to/WORLD_CREATOR/wineprefix
   WINEDLLOVERRIDES="mscoree=d;mshtml=d" wineboot --init
   ```
   The overrides only skip the Mono/Gecko prompt during init; they must not persist at run time (see Gotchas).

2. Install the prefix dependencies:
   - **.NET 10 Desktop Runtime (x64)** — the application needs `Microsoft.NETCore.App` and `Microsoft.WindowsDesktop.App` 10.0. Run the Windows desktop-runtime installer under `wine` with `/install /quiet /norestart`.
   - **Visual C++ 2015-2022:** `winetricks -q vcrun2022`.
   - **DXVK:** `winetricks -q dxvk`.

3. Install World Creator into the prefix from your MSI:
   ```
   wine msiexec /i 'Z:/path/to/WorldCreator_2026_4.msi' /qn
   ```
   The silent MSI skips its bundled prerequisites, and the bundled .NET is 9 where the application needs 10, so install the dependencies in step 2 regardless.

4. Build the layer, bridge, and patches:
   ```
   ./build.sh
   ```

5. Run:
   ```
   ./world-creator-denoise   # GPU denoiser
   ./world-creator           # no denoiser
   ```

The launchers resolve their own directory; keep them next to `wineprefix/` and `nvlibs-build/`.

## Gotchas

- **`DOTNET_ROOT` leaks into Wine.** If the host sets `DOTNET_ROOT` for a Linux dotnet install, the Windows apphost follows it to `Z:\usr\share\dotnet` and fails with a missing `hostfxr.dll`. The launchers `unset DOTNET_ROOT`.
- **`mscoree` must stay builtin at run time.** Disabling it to skip the Mono prompt during init is fine, but an `mscoree=d` override while running makes the CoreCLR managed assemblies fail to load with a misleading "Module not found".
- **EGL warning spam.** The NVIDIA EGL driver prints `failed to create dri2 screen` repeatedly. It is harmless, but piping it to a terminal that cannot drain it fast enough blocks the application's stdout and hangs it at the splash. The launchers log to a file and set `EGL_LOG_LEVEL=fatal`.

## GPU denoise

The viewport denoiser is Intel Open Image Denoise 2.3.3, GPU backends only; on NVIDIA it needs `nvcuda.dll` (the CUDA Driver API). `build.sh` assembles the three pieces it requires, and `world-creator-denoise` enables them.

- **nvcuda bridge** — built from [nvidia-libs](https://github.com/SveSop/nvidia-libs), forwarding the CUDA Driver API to host `libcuda.so`. It loads as a builtin split DLL via `WINEDLLOVERRIDES=nvcuda=b` + `WINEDLLPATH`.
- **Bridge patch (`tools/patch-nvcuda/`)** — OIDN imports the Vulkan buffers via `cuImportExternalMemory` (`OPAQUE_WIN32`). The stock bridge resolves the handle through Proton's `IOCTL_SHARED_GPU_RESOURCE` device, absent in Wine 11.11, so the import fails and denoise renders black. The patch opens the handle's D3DKMT shared resource instead, the way win32u does.
- **Veldrid patch (`tools/patch-veldrid/`)** — `vkGetMemoryWin32HandleKHR` is resolved via the device proc-addr; the instance proc-addr returns NULL under winevulkan, and the unguarded NULL otherwise faults at address 0 on the first external buffer.
- **Octane disabled** — `octane.dll` is renamed to `octane.dll.OFF`. It is a separate bundled CUDA path tracer that builds its own RAM-sized host pool; the Vulkan renderer and OIDN do not need it.

## The startup memory runaway (World Creator 2025.2 and later)

Some World Creator versions enter a memory runaway during startup: a few seconds in, the process begins committing host memory at ~2.5 GB/s and climbs toward tens of GB without settling, until it is killed. It does not recover on its own; left alone it exhausts host RAM and starves the desktop.

It is **bimodal and non-deterministic**. The same build, same machine, same inputs boots clean on some attempts (RSS settles ~1.5 GB and the session is stable for its whole life, large terrains and high resolution included) and runs away on others. Roughly 40–70% of boots are clean, with no relation to anything the user does.

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
- **On 2025.2 and later (including 2026.x)** the runaway is unavoidable in World Creator's code, so `world-creator-denoise` works around it rather than preventing it: it guards the startup window with a hard RSS kill-switch (kill at 5 GB RSS or below 12 GB `MemAvailable`), kills a filling boot before it can starve the host, and relaunches until one lands clean — usually one or two tries. That is the "it works sometimes" behaviour made automatic. Once a boot is clean the guard disarms, and on exit (quit, Ctrl-C, or close) it reaps its whole wine session so nothing lingers. Tunable via `WC_KILL_RSS_MB`, `WC_GUARD_WINDOW_S`, `WC_MAX_TRIES`.

## License

The shims, layer, patches, and launchers here are MIT. World Creator, the .NET runtime, DXVK, and nvidia-libs are separate works under their own licenses.
