# iPadOS / iOS build (experimental)

This folder builds Skate 3 Recomp as an iPad app. The game code is the same
ahead-of-time recompiled ARM64 code as the macOS build: no JIT, no emulator,
so it runs under normal iOS rules. Rendering is Vulkan through MoltenVK on
Metal, input and audio are SDL3.

Requirements: an Apple Silicon iPad (M1 or newer), a **paid** Apple developer
team (the app needs the *Extended Virtual Addressing* entitlement for its
4.5 GiB guest address space), Xcode, and
`brew install llvm cmake ninja xcodegen`.

## One-time setup

1. MoltenVK: download `MoltenVK-all.tar` from the
   [MoltenVK releases](https://github.com/KhronosGroup/MoltenVK/releases) and
   extract it to `../deps/moltenvk` next to this repository (the presets
   expect `../deps/moltenvk/MoltenVK/MoltenVK/static/MoltenVK.xcframework`).
2. Signing: create `ios/local.env` (git-ignored):

   ```sh
   SKATE3_IOS_TEAM=ABCDE12345            # your team ID (developer.apple.com > Membership)
   SKATE3_IOS_BUNDLE_ID=com.you.skate3
   ```

3. On the iPad: Settings > Privacy & Security > Developer Mode, on. Connect it
   to the Mac and trust the computer.

## Generate the game code (needs your own copy of the game)

The recompiled game is generated on the Mac from your legally obtained Xbox 360
dump, exactly as for the macOS build (see the main README). Codegen only needs
the two executables, so there is no need to extract the whole disc on the Mac:

```sh
python3 ios/tools/extract_from_iso.py /path/to/Skate3.iso game default.xex data/webkit/EAWebkit.xex
```

Put the TU3 package (`TU_12K2276_000000C000000.00000000000O3`) in the repo root,
then

```sh
cmake --preset macos-release
cmake --build --preset macos-release --target generate-all --parallel
```

This writes `generated/`, which the iOS build compiles for the iPad.

## Build and run

```sh
ios/build.sh device --run     # build, install and launch on the connected iPad
ios/build.sh sim --run        # iPad simulator (UI and platform testing)
```

`--shell` builds against a stub instead of `generated/`: the app runs up to its
install wizard, which is useful for testing the platform layer before you have
the game code.

`ios/build.sh` runs CMake (Homebrew LLVM) to build `libskate3_ios.a`, generates
`ios/Skate3.xcodeproj` with XcodeGen and builds it with your team. After the
first build you can also open `ios/Skate3.xcodeproj` in Xcode and run or debug
from there.

## Getting the game onto the iPad

Everything the app stores lives in its Documents folder, which the Files app
shows as **On My iPad > Skate 3**: `game/` (the installed game), `skate3/`
(settings and saves), `logs/` and `dlc/`.

Either:

- copy your ISO into the Skate 3 folder (Files app, AirDrop or Finder), open the
  app and choose **Select ISO**. The installer extracts it into `game/`, so
  you need room for the ISO plus the extracted game (about twice the ISO
  size); delete the ISO afterwards. Or
- extract on the Mac (for example with the macOS app's installer) and copy the
  folder over USB: `ios/build.sh game /path/to/extracted/game`.

The title update is downloaded by the app on first launch, as on desktop.

Big single files (the ISO) are most reliable copied with Finder: select the
iPad in the sidebar, open **Files** and drag the ISO onto **Skate 3**
(`devicectl device copy` drops multi-GB files).

## Controls

Use a Bluetooth controller (Xbox, PlayStation or MFi). Touch works for the
setup and settings screens; there are no on-screen game controls yet. RB +
Start opens the settings menu.

## Display

The iPad screen is 4:3 and the game renders 16:9, so the picture is shown
whole and undistorted with bars above and below (`present_letterbox`). The
native renderer's true-ultrawide mode only widens past 16:9.

## Saves

Saves live in `Documents/skate3/<profile>/454108E6/` and appear in the Files
app. They are included in iCloud/Finder backups; the installed `game/` folder
and `skate3/cache` are excluded. When the app is backgrounded it asks iOS for
time to finish any save being written, so switching apps mid-save is safe.
Deleting the app deletes its saves (copy the `skate3` folder out first).

## Performance

- iOS builds target `-mcpu=apple-m1` (LSE atomics, Apple scheduling).
- Runtime threads run at the user-interactive QoS class so iOS keeps them on
  the performance cores.
- Double-buffered swapchain (iOS only offers FIFO) and a two-period camera
  smoothing window (`skate3_native_render_scene_smooth_camera_filter_ms`
  33.3 ms instead of 50) for lower input latency.
- On first launch the app applies iPad graphics defaults once (MSAA 2x, no
  PCSS, 2048 static shadows, 1.5x draw distance and LOD); change them in the
  settings menu (RB + Start) and they stick. Delete
  `Documents/skate3/ios_defaults_v1` to apply them again.
- Performance logging can be enabled without rebuilding by putting a
  `skate3.toml` in the app's Documents with, for example,
  `skate3_native_render_scene_perf_log = true`.

## iOS-specific behaviour

- **Apply & Restart** quits the app (iOS apps cannot relaunch themselves);
  reopen it to apply the change.
- GPU work is paused, and in-flight work drained, while the app is in the
  background.
- Guest memory uses Mach memory entries instead of POSIX shared memory
  (`REX_MEMORY_MACH_ENTRIES`, `third_party/rexglue-sdk/src/core/memory_posix.cpp`).
