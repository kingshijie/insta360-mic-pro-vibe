#!/bin/zsh
set -euo pipefail

if (( $# > 1 )) || [[ ${1-} != "" && $1 != --build-only ]]; then
    print -u2 "Usage: $0 [--build-only]"
    exit 2
fi

project=${0:A:h}
stage=${MC110_BUILD_CACHE:-"$HOME/Library/Application Support/MC110 Doubao"}
decoder="$stage/lc3plus"
revision=d558e9b2aa9fa406444a25d0786e0b77898d93c1
if ! xcrun --find clang >/dev/null; then
    print -u2 "Install the Xcode Command Line Tools with: xcode-select --install"
    exit 1
fi
mkdir -p "$stage"

if [[ ! -d "$decoder/.git" ]]; then
    git init -q "$decoder"
fi
if [[ "$(git -C "$decoder" rev-parse --verify HEAD 2>/dev/null || true)" != "$revision" ]]; then
    git -C "$decoder" fetch --depth 1 https://github.com/arkq/LC3plus "$revision"
    git -C "$decoder" checkout --detach "$revision"
fi

src="$decoder/src/floating_point"
export MACOSX_DEPLOYMENT_TARGET=13.0
object_dir="build-macos13-$(uname -m)"
make -C "$src" -j "$(sysctl -n hw.logicalcpu)" CC=clang BUILD="$object_dir" >&2
objects=("$src/$object_dir"/*.o)
objects=(${objects:#*/codec_exe.o})

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
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -I "$src" -framework AppKit -framework Foundation -framework ApplicationServices \
    -framework IOBluetooth -framework CoreAudio -framework AudioToolbox \
    "$project/panel.m" "$project/bridge.m" "$project/serial-audio.m" \
    "${objects[@]}" -o "$bundle/Contents/MacOS/MC110Dictation"
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
