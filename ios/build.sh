#!/usr/bin/env bash
# Builds the iOS/iPadOS app and optionally installs and launches it.
#
#   ios/build.sh sim    [--shell] [--run]      iPad simulator
#   ios/build.sh device [--shell] [--run]      connected iPad (signed with your team)
#   ios/build.sh game <dir> [device]           copy an extracted game folder to the iPad
#
# --shell builds against a stub instead of the generated game code (see
# ios/tools/make_shell_stub.py): the app runs up to its install wizard. Without
# it, generated/ must exist (cmake --build --preset macos-release --target generate-all).
#
# Signing settings come from the environment or ios/local.env (git-ignored):
#   SKATE3_IOS_TEAM=ABCDE12345            Apple development team ID
#   SKATE3_IOS_BUNDLE_ID=com.you.skate3   bundle identifier
#   SKATE3_IOS_DEVICE=<name|udid>         which iPad, when several are connected
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
[ -f ios/local.env ] && . ios/local.env
: "${SKATE3_IOS_BUNDLE_ID:=io.github.skate3recomp.ios}"
: "${SKATE3_IOS_DEVICE_PRESET:=ios-release}"
: "${SKATE3_IOS_SIMULATOR:=iPad Pro 13-inch (M5)}"
export SKATE3_IOS_TEAM="${SKATE3_IOS_TEAM:-}" SKATE3_IOS_BUNDLE_ID SKATE3_IOS_DEVICE_PRESET

die() { echo "error: $*" >&2; exit 1; }

target=${1:-}; shift || true
shell=OFF; run=0
case $target in
game)
    src=${1:?usage: ios/build.sh game <extracted game dir> [device]}
    device=${2:-${SKATE3_IOS_DEVICE:-}}
    [ -f "$src/default.xex" ] || die "$src has no default.xex"
    args=(); [ -n "$device" ] && args=(--device "$device")
    echo "Copying $src to Documents/game on the iPad (unchanged files are skipped)"
    exec xcrun devicectl device copy to "${args[@]}" --domain-type appDataContainer \
        --domain-identifier "$SKATE3_IOS_BUNDLE_ID" --source "$src" --destination Documents/game
    ;;
sim) preset=iossim-release; sdk=iphonesimulator ;;
device) preset=$SKATE3_IOS_DEVICE_PRESET; sdk=iphoneos ;;
*) sed -n '2,17p' "$0"; exit 1 ;;
esac
for arg in "$@"; do
    case $arg in
    --shell) shell=ON ;;
    --run) run=1 ;;
    *) die "unknown option $arg" ;;
    esac
done
if [ "$shell" = OFF ] && [ ! -f generated/sources.cmake ]; then
    die "generated/ is missing: run the macOS generate-all target with your game dump first, or pass --shell"
fi
if [ "$sdk" = iphoneos ] && [ -z "$SKATE3_IOS_TEAM" ]; then
    die "set SKATE3_IOS_TEAM (in ios/local.env) to sign for a device"
fi

cmake --preset "$preset" -DSKATE3_SHELL_BUILD=$shell > /dev/null
cmake --build --preset "$preset" --target skate3_ios

command -v xcodegen > /dev/null || die "xcodegen is not installed (brew install xcodegen)"
xcodegen generate --quiet --spec ios/project.yml

derived="$root/out/ios-derived"
xcode_args=(-project ios/Skate3.xcodeproj -scheme Skate3 -configuration Release
            -sdk "$sdk" -derivedDataPath "$derived" -quiet)
if [ "$sdk" = iphonesimulator ]; then
    xcodebuild "${xcode_args[@]}" -destination "platform=iOS Simulator,name=$SKATE3_IOS_SIMULATOR" build
    app="$derived/Build/Products/Release-iphonesimulator/Skate 3.app"
else
    xcodebuild "${xcode_args[@]}" -destination generic/platform=iOS -allowProvisioningUpdates build
    app="$derived/Build/Products/Release-iphoneos/Skate 3.app"
fi
echo "Built $app"
[ "$run" = 1 ] || exit 0

if [ "$sdk" = iphonesimulator ]; then
    xcrun simctl boot "$SKATE3_IOS_SIMULATOR" 2> /dev/null || true
    open -a Simulator
    xcrun simctl install "$SKATE3_IOS_SIMULATOR" "$app"
    exec xcrun simctl launch --console-pty --terminate-running-process "$SKATE3_IOS_SIMULATOR" "$SKATE3_IOS_BUNDLE_ID"
else
    args=(); [ -n "${SKATE3_IOS_DEVICE:-}" ] && args=(--device "$SKATE3_IOS_DEVICE")
    xcrun devicectl device install app "${args[@]}" "$app"
    exec xcrun devicectl device process launch --console --terminate-existing "${args[@]}" "$SKATE3_IOS_BUNDLE_ID"
fi
