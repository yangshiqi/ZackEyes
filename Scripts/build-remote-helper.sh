#!/bin/bash
set -euo pipefail
version=${1:?Usage: build-remote-helper.sh X.Y.Z OUTPUT_DIRECTORY}
output=${2:?Output directory required}
tools=$(cd "$(dirname "$0")" && pwd)
source_dir=${REMOTE_SOURCE_DIR:-$(cd "$tools/.." && pwd)}
source_sha=$(git -C "$source_dir" rev-parse HEAD)
case "$(uname -m)" in x86_64) arch=x86_64;; arm64|aarch64) arch=arm64;; *) exit 1;; esac
case "$(uname -s)" in
    Darwin)
        platform=macos
        swift_args=(--arch "$arch")
        export MACOSX_DEPLOYMENT_TARGET=14.0
        ;;
    Linux)
        platform=linux
        triple=x86_64-swift-linux-musl
        if [ "$arch" = arm64 ]; then triple=aarch64-swift-linux-musl; fi
        swift_args=(--swift-sdk "$triple")
        ;;
    *) exit 1 ;;
esac
scratch="$source_dir/.build/remote-$platform-$arch"
swift build --package-path "$source_dir" --scratch-path "$scratch" -c release --product zackeyes-stream "${swift_args[@]}"
bin_dir=$(swift build --package-path "$source_dir" --scratch-path "$scratch" -c release --show-bin-path "${swift_args[@]}")
binary="$bin_dir/zackeyes-stream"
if [ "$platform" = linux ]; then
    # A glibc or Swift dynamic dependency would make the package unusable on a clean host.
    if readelf -l "$binary" | grep -q INTERP; then echo 'ERROR: helper is not fully static' >&2; exit 1; fi
    if readelf -d "$binary" | grep -q NEEDED; then echo 'ERROR: helper has shared-library dependencies' >&2; exit 1; fi
else
    codesign --force --sign - "$binary"
    codesign --verify --strict "$binary"
    if otool -L "$binary" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/)'; then
        echo 'ERROR: helper depends on non-system libraries' >&2; exit 1
    fi
fi
python3 "$tools/smoke-remote-helper.py" "$binary"
python3 "$tools/package-remote-helper.py" "$version" "$platform-$arch" "$binary" "$source_sha" "$output"
