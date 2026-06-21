# World Creator 2026.4 on Linux (Wine)

Launchers and an `LD_PRELOAD` memory shim that run BiteTheBytes' World Creator 2026.4 — a Windows .NET 10 desktop application with a Veldrid/Vulkan renderer — under Wine on Linux. World Creator itself is not included; install it from your own licensed copy. The shim exists because the application sizes a startup allocation to the host's reported memory, which under Wine includes swap and exhausts RAM; the shim caps what the application reads.

Verified on Wine 11.11, a GeForce RTX 5080 (NVIDIA 610 driver, Vulkan 1.4), and .NET 10.0.8.

## What's here

- `memcap.c` — the `LD_PRELOAD` memory shim, the load-bearing fix.
- `world-creator`, `world-creator-debug` — launchers (the debug one logs to a file with OIDN and module-load diagnostics on).
- `vkheapcap.c` — a Vulkan layer that caps reported memory-heap sizes. Not needed for the base fix; kept as scaffolding for the GPU-denoise work below.
- `build.sh` — builds the shim, the layer, and the optional `nvcuda` bridge.

## Why the shim is needed

World Creator sizes a native startup buffer to the system's memory. Wine derives `GlobalMemoryStatusEx` from `sysinfo()` and `/proc/meminfo`, so on a host with large swap the reported total is RAM+swap (a 165 GB commit limit on the test machine), and the application tries to commit most of it and dies thrashing. `memcap.so` intercepts `sysinfo()` and caps `totalram`/`freeram` while zeroing swap, so the reported figure is sane and the application sizes a buffer that fits. `MEMCAP_GB` (default 24) sets the cap.

## Setup

1. Create a 64-bit prefix:
   ```
   export WINEPREFIX=/path/to/WORLD_CREATOR/wineprefix
   WINEDLLOVERRIDES="mscoree=d;mshtml=d" wineboot --init
   ```
   The `mscoree`/`mshtml` overrides only skip the Mono/Gecko prompt during init; they must not persist at run time (see Gotchas).

2. Install the prefix dependencies:
   - **.NET 10 Desktop Runtime (x64).** The application's `runtimeconfig.json` requires `Microsoft.NETCore.App` and `Microsoft.WindowsDesktop.App` 10.0. Run the Windows desktop-runtime installer under `wine` with `/install /quiet /norestart`.
   - **Visual C++ 2015-2022 redistributable:** `winetricks -q vcrun2022`.
   - **DXVK:** `winetricks -q dxvk`.

3. Install World Creator into the prefix from your MSI:
   ```
   wine msiexec /i 'Z:/path/to/WorldCreator_2026_4.msi' /qn
   ```
   A silent MSI install skips the bundled VC++/.NET prerequisites, so install those as in step 2. Note the bundled prerequisite is .NET 9, but the application needs .NET 10.

4. Build the shim:
   ```
   ./build.sh
   ```

5. Run:
   ```
   ./world-creator
   ```

The launchers resolve their own directory, so place them next to `wineprefix/` and `memcap.so`.

## Gotchas

- **`DOTNET_ROOT` leaks into Wine.** If the host sets `DOTNET_ROOT` for a Linux dotnet install, the Windows apphost follows it to `Z:\usr\share\dotnet` and fails with a missing `hostfxr.dll`. The launchers `unset DOTNET_ROOT`.
- **`mscoree` must stay builtin at run time.** Disabling it to skip the Mono prompt during init is fine, but a `mscoree=d` override while running makes the CoreCLR managed assemblies fail to load with a misleading "Module not found" — the managed PE files carry a legacy `mscoree` import stub the loader resolves.
- **Do not fake `/proc/meminfo` with a constant.** `memcap.c` can also rewrite `/proc/meminfo`, gated behind `MEMCAP_MEMINFO`; leave it off. The application allocates in a loop until reported free memory drops, so a constant `MemAvailable` makes that loop never terminate and re-introduces the runaway. Capping `sysinfo()` alone is correct.
- **EGL warning spam.** The NVIDIA EGL driver prints `failed to create dri2 screen` repeatedly. It is harmless, but piping it to a terminal that cannot drain it fast enough blocks the application's stdout and hangs it at the splash. The launchers log to a file and set `EGL_LOG_LEVEL=fatal`.

## GPU denoise — status and roadmap

The denoiser is Intel Open Image Denoise 2.3.3, shipped with only GPU device backends (CUDA, HIP, SYCL) and no CPU backend module. On NVIDIA the path is CUDA, which needs `nvcuda.dll` (the CUDA Driver API), which Wine does not provide. Adding the official `OpenImageDenoise_device_cpu.dll` for OIDN 2.3.3 gives OIDN a CPU device to fall back to.

Denoise does not yet work under Wine, by two separate failures:

- **CUDA path.** An `nvcuda` bridge built from [nvidia-libs](https://github.com/SveSop/nvidia-libs) forwards the CUDA Driver API to the host `libcuda.so`. With the bridge loadable, the application's CUDA-detection path enters an allocation loop at startup that exhausts memory — before any denoise runs, and before the bridge forwards a single CUDA call. The loop is triggered by detection itself.
- **CPU path.** With no bridge, OIDN selects its CPU device, but enabling denoise then crashes in `Veldrid.ResourceFactory.CreateBuffer` with an access violation. The denoise render pass's buffer setup faults under winevulkan.

Next diagnostics:

- Instrument the `nvcuda` bridge to log the exact Driver-API calls the application makes before the loop. A candidate trigger is a driver-version branch: the host reports CUDA 13 / driver 610, and the application may behave badly on a version it was not built against.
- Isolate the CPU-path `CreateBuffer` crash as a separate winevulkan/Veldrid buffer issue.

`vkheapcap.c` caps the reported Vulkan memory-heap sizes (host-visible and device-local). It was tried against the runaway and ruled out: the loop is not sized to the Vulkan heaps. It remains only as scaffolding for the bridge work.

## License

The shims, layer, and launchers here are MIT. World Creator, the .NET runtime, DXVK, and nvidia-libs are separate works under their own licenses.
