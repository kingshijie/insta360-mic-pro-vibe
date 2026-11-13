#!/bin/zsh
set -euo pipefail

if (( $# > 1 )) || [[ ${1-} != "" && $1 != --build-only ]]; then
    print -u2 "Usage: $0 [--build-only]"
    exit 2
fi

project=${0:A:h}
stage=${MC110_BUILD_CACHE:-"$HOME/Library/Application Support/MC110 Doubao"}
decoder="$stage/liblc3"
revision=96a3af0beb5487aca3b98a4b992a539a1f6d80d1
if ! xcrun --find clang >/dev/null; then
    print -u2 "Install the Xcode Command Line Tools with: xcode-select --install"
    exit 1
fi
mkdir -p "$stage"

if [[ ! -d "$decoder/.git" ]]; then
    git init -q "$decoder"
fi
if [[ "$(git -C "$decoder" rev-parse --verify HEAD 2>/dev/null || true)" != "$revision" ]]; then
    git -C "$decoder" fetch --depth 1 https://github.com/google/liblc3 "$revision"
    git -C "$decoder" checkout --detach "$revision"
fi

export MACOSX_DEPLOYMENT_TARGET=13.0

if [[ ${1-} == --build-only ]]; then
    destination="$project/build"
else
    destination="$HOME/Applications"
fi
app="$destination/Mic Pro 听写.app"
mkdir -p "$destination"
bundle=$(mktemp -d "$destination/.mc110.XXXXXX")
trap 'rm -rf "$bundle"' EXIT
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$project/Info.plist" "$bundle/Contents/Info.plist"
cp "$project/assets/MicPro.icns" "$project/assets/MicProStatus.png" "$bundle/Contents/Resources/"
cp -R "$project/localizations/zh-Hans.lproj" "$bundle/Contents/Resources/"
cp "$project/LICENSE" "$bundle/Contents/Resources/LICENSE-MicPro.txt"
cp "$decoder/LICENSE" "$bundle/Contents/Resources/LICENSE-liblc3.txt"
for cpu in arm64 x86_64; do
    object_dir="build-macos13-$cpu"
    make -C "$decoder" -j "$(sysctl -n hw.logicalcpu)" CC="clang -arch $cpu" \
        BUILD_DIR="$object_dir" BIN_DIR="bin-macos13-$cpu" liblc3 >&2
    objects=("$decoder/$object_dir/src/"*.o)
    xcrun clang -arch "$cpu" -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
        -I "$decoder/include" -framework AppKit -framework Foundation -framework ApplicationServices \
        -framework IOBluetooth -framework CoreAudio -framework AudioToolbox \
        "$project/panel.m" "$project/bridge.m" "$project/serial-audio.m" \
        "${objects[@]}" -o "$bundle/MC110Dictation-$cpu"
done
xcrun lipo -create "$bundle/MC110Dictation-arm64" "$bundle/MC110Dictation-x86_64" \
    -output "$bundle/Contents/MacOS/MC110Dictation"
unlink "$bundle/MC110Dictation-arm64"
unlink "$bundle/MC110Dictation-x86_64"
/usr/bin/codesign --force --sign - --identifier local.mc110.dictation "$bundle"
/usr/bin/codesign --verify --strict "$bundle"

# Replace the old bundle so removed files from earlier builds do not linger.
if [[ -e "$app" ]]; then
    previous="$bundle.previous"
    mv "$app" "$previous"
    if ! mv "$bundle" "$app"; then
        mv "$previous" "$app"
        exit 1
    fi
    rm -rf "$previous"
else
    mv "$bundle" "$app"
fi
touch "$app"
printf '%s\n' "$app"
