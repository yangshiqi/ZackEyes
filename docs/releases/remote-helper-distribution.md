# Remote helper distribution

The `Remote helpers` workflow builds Linux x86_64/arm64 and macOS x86_64/arm64 packages on native runners. Linux uses the checksum-pinned Swift 6.0.3 Static Linux SDK (musl); packages must have no ELF interpreter or dynamic dependencies. macOS targets 14+ and permits only system dynamic libraries. Each native runner executes `--help`, reads a protocol-v1 snapshot and verifies clean termination before packaging.

Every `zackeyes-remote-X.Y.Z-PLATFORM.tar.gz` contains only `zackeyes` and `build-info.json` (version, architecture and full helper source SHA). The aggregate `remote-helpers` artifact adds `SHA256SUMS` and `install-remote.sh`. Verification rejects missing platforms, incorrect source/version/architecture and hash mismatches. The workflow has read-only repository permissions and never publishes from a pull request.

## Release integration

After pushing the release branch, `make release` invokes:

```sh
Scripts/fetch-remote-assets.sh X.Y.Z FULL_SOURCE_SHA .build/remote-assets-X.Y.Z
```

This dispatches the workflow on the pushed current branch, waits for its exact run, downloads the aggregate artifact and verifies it again. All four platforms must pass before the DMG or helper assets can be uploaded. The existing release upload now includes the verified helper directory. A failed build leaves the public release untouched. Delete or move an incomplete local helper output directory before retrying; stale files are never silently reused.

For a backfill of an existing release, dispatch `remote-helpers.yml` with the existing version and source commit (use the original tag when it builds on every platform; v0.10.0 needs the musl import compatibility fix in this distribution change), download the `remote-helpers` artifact, verify it against the resolved helper source SHA and upload the six new assets to the existing distribution release. Do not replace its DMG, tags or existing checksums. Record the workflow run and helper source SHA in the release notes. Never publish partial platform sets.

## User installation

Run on the remote host, using the same account that runs Claude/Codex:

```sh
curl -fsSL https://github.com/yangshiqi/ZackEyes-release/releases/download/vX.Y.Z/install-remote.sh | sh -s -- X.Y.Z
```

The installer selects Linux/macOS and x86_64/arm64, verifies the release checksum, smoke-tests the binary and atomically installs it at `~/.local/bin/zackeyes`. No sudo, Git, Swift installation, daemon, hook changes or SSH configuration changes are needed. An optional `--prefix DIRECTORY` supports isolated testing. Failure preserves the old helper. SHA256 checks detect corrupted or mismatched downloads; they are not a separate signing identity from the HTTPS release host.

Tests: `python3 -m unittest discover -s Tests/Distribution -v`.
