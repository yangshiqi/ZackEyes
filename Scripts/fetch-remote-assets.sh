#!/bin/bash
# Build the exact release source on all native CI runners, then retrieve one verified bundle.
set -euo pipefail
version=${1:?Usage: fetch-remote-assets.sh X.Y.Z SOURCE_SHA OUTPUT_DIRECTORY}
source_sha=${2:?Source SHA required}
output=${3:?Output directory required}
branch=$(git branch --show-current)
tools=$(cd "$(dirname "$0")" && pwd)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$source_sha" =~ ^[a-f0-9]{40}$ ]] || exit 1
[ -n "$branch" ] || { echo 'Run from a pushed branch.' >&2; exit 1; }
[ ! -e "$output" ] || { echo 'Output already exists; refusing to reuse stale helper assets.' >&2; exit 1; }
# Save the existing runs so concurrent/older builds cannot be mistaken for this request.
previous=$(mktemp)
trap 'rm -f "$previous"' EXIT
gh run list --repo yangshiqi/ZackEyes --workflow remote-helpers.yml --branch "$branch" --event workflow_dispatch --limit 100 --json databaseId > "$previous"
gh workflow run remote-helpers.yml --repo yangshiqi/ZackEyes --ref "$branch" -f version="$version" -f source_ref="$source_sha"
run_id=
for attempt in {1..30}; do
    runs=$(gh run list --repo yangshiqi/ZackEyes --workflow remote-helpers.yml --branch "$branch" --event workflow_dispatch --limit 100 --json databaseId,displayTitle)
    run_id=$(python3 -c 'import json,sys; old={r["databaseId"] for r in json.load(open(sys.argv[1]))}; matches=[str(r["databaseId"]) for r in json.loads(sys.argv[2]) if r["databaseId"] not in old and r["displayTitle"]==sys.argv[3]]; assert len(matches)<=1,"Ambiguous workflow runs"; print(matches[0] if matches else "")' "$previous" "$runs" "Remote helpers $version from $source_sha")
    [ -z "$run_id" ] || break
    sleep 2
done
[ -n "$run_id" ] || { echo 'Cannot identify helper build run.' >&2; exit 1; }
printf 'Waiting for native helper build: https://github.com/yangshiqi/ZackEyes/actions/runs/%s\n' "$run_id"
gh run watch "$run_id" --repo yangshiqi/ZackEyes --exit-status --interval 15
mkdir -p "$output"
gh run download "$run_id" --repo yangshiqi/ZackEyes --name remote-helpers --dir "$output"
python3 "$tools/verify-remote-assets.py" "$version" "$source_sha" "$output"
