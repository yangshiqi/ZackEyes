#!/bin/sh
# Install a version-matched, prebuilt SSH helper. No sudo, Git or Swift required.
set -eu
umask 077
fail() { printf '%s\n' "ERROR: $*" >&2; exit 1; }
version=${1:-}
[ "$#" -gt 0 ] || fail 'Usage: sh install-remote.sh X.Y.Z [--prefix DIRECTORY]'
shift
printf '%s\n' "$version" | LC_ALL=C grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail 'Version must be X.Y.Z.'
prefix=${HOME:?}/.local/bin
if [ "$#" -gt 0 ]; then
    [ "$#" -eq 2 ] && [ "$1" = --prefix ] && [ -n "$2" ] || fail 'Expected --prefix DIRECTORY.'
    prefix=$2
fi
case "$(uname -s)" in
    Linux) platform=linux ;;
    Darwin) platform=macos ;;
    *) fail 'Supported remote systems: Linux and macOS.' ;;
esac
case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) fail 'Supported architectures: x86_64 and arm64.' ;;
esac
if [ "$platform" = macos ]; then
    major=$(sw_vers -productVersion | cut -d. -f1)
    [ "$major" -ge 14 ] || fail 'The macOS helper requires macOS 14 or later.'
fi
for tool in curl tar mktemp; do command -v "$tool" >/dev/null 2>&1 || fail "Required command: $tool"; done
if command -v sha256sum >/dev/null 2>&1; then
    checksum() { sha256sum "$1" | cut -d ' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
    checksum() { shasum -a 256 "$1" | cut -d ' ' -f1; }
else
    fail 'Install sha256sum or shasum to verify downloads.'
fi
[ ! -L "$prefix" ] || fail 'Installation directory must not be a symlink.'
[ ! -L "$prefix/zackeyes" ] || fail 'Existing helper must not be a symlink.'
work=$(mktemp -d "${TMPDIR:-/tmp}/zackeyes-install.XXXXXXXX")
staged=
cleanup() { rm -rf "$work"; [ -z "$staged" ] || rm -f "$staged"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
asset="zackeyes-remote-$version-$platform-$arch.tar.gz"
base="https://github.com/yangshiqi/ZackEyes-release/releases/download/v$version"
fetch() { curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 --output "$2" "$base/$1"; }
fetch SHA256SUMS "$work/SHA256SUMS" || fail 'Cannot download release checksums; helper unchanged.'
expected=$(awk -v name="$asset" '$2 == name {print $1}' "$work/SHA256SUMS")
printf '%s\n' "$expected" | LC_ALL=C grep -Eq '^[a-f0-9]{64}$' || fail 'Missing or invalid release checksum; helper unchanged.'
fetch "$asset" "$work/helper.tar.gz" || fail 'Cannot download this platform package; helper unchanged.'
[ "$(checksum "$work/helper.tar.gz")" = "$expected" ] || fail 'Package checksum mismatch; helper unchanged.'
tar -xzf "$work/helper.tar.gz" -C "$work" zackeyes || fail 'Invalid helper package.'
[ -f "$work/zackeyes" ] && [ ! -L "$work/zackeyes" ] || fail 'Package does not contain a regular helper.'
chmod 755 "$work/zackeyes"
"$work/zackeyes" --help >/dev/null || fail 'Helper cannot run on this host; existing installation unchanged.'
mkdir -p "$prefix"
staged=$(mktemp "$prefix/.zackeyes-install.XXXXXXXX")
cat "$work/zackeyes" > "$staged"
chmod 755 "$staged"
mv -f "$staged" "$prefix/zackeyes"
staged=
printf 'Installed ZackEyes remote helper %s (%s/%s) at %s/zackeyes\n' "$version" "$platform" "$arch" "$prefix"
