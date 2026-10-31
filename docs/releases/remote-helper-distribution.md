# Remote helper distribution

The `Remote helpers` workflow builds Linux x86_64/arm64 and macOS x86_64/arm64 packages on native runners. Linux uses the checksum-pinned Swift 6.0.3 Static Linux SDK (musl); packages must have no ELF interpreter or dynamic dependencies. Linux release links use `--strip-all` to omit debug and link-time symbol tables while retaining the static Swift/Foundation runtime and runtime reflection metadata. The native build rejects remaining debug/symbol sections, then smoke-tests the final stripped executable before packaging. macOS targets 14+ and permits only system dynamic libraries. Each native runner executes `--help`, reads a protocol-v1 snapshot and verifies clean termination before packaging.

Every `zackeyes-remote-X.Y.Z-PLATFORM.tar.gz` contains only `zackeyes` and `build-info.json`. Metadata records the package version, architecture and requested release `source_sha`. New packages also record `compiled_source_sha` (the commit that actually produced the binary) and `helper_inputs_sha256` (the helper sources and build recipes). A reused binary retains its original compilation commit even across several app releases. The aggregate `remote-helpers` artifact adds `SHA256SUMS` and `install-remote.sh`. Verification rejects missing platforms, incorrect source/version/architecture and hash mismatches. The workflow has read-only repository permissions and never publishes from a pull request.

## Release integration

After pushing the release branch, `make release` invokes:

```sh
Scripts/fetch-remote-assets.sh X.Y.Z FULL_SOURCE_SHA .build/remote-assets-X.Y.Z
```

By default this first attempts to reuse the latest stable published distribution release. It downloads and verifies the entire four-platform bundle, then compares a helper-input fingerprint: `RemoteCore`, `RemoteStream`, the app's SSH adapter, remote-core tests, Package manifests/lockfile, build/package/smoke scripts, fingerprint policy and the native workflow (including toolchain/SDK pins). UI, website, version and unrelated app changes do not invalidate it.

When inputs match, it copies the verified binary bytes into new version-specific packages, preserves `compiled_source_sha`, records the new release `source_sha`, copies the current installer, regenerates checksums and verifies the complete result before atomically installing the local output directory. It does not dispatch CI, download the Swift SDK or compile either architecture. Reuse relies on the published binaries' prior native smoke checks; cross-platform binaries are not executed on the release machine. Published assets are durable, so the workflow's 14-day artifact retention does not limit reuse.

When inputs change, the previous release/assets are missing or invalid, or provenance is unavailable, it dispatches the workflow on the pushed current branch, waits for its exact run, downloads the aggregate artifact and verifies it again. The workflow, checked-out scripts and helper sources are pinned to the same commit; a branch advancing during dispatch fails before compilation. All four platforms must pass before the DMG or helper assets can be uploaded. The existing release upload now includes the verified helper directory. A failed build leaves the public release untouched. Delete or move an incomplete local helper output directory before retrying; stale files are never silently reused.

The first release after enabling this feature builds fresh helpers once: older packages lack the fingerprint needed to prove equivalence. Later unchanged-helper releases reuse that published set. Reuse remains all-or-nothing; a single platform mismatch requires a fresh native build.

Force fresh native compilation when desired:

```sh
REMOTE_HELPERS_FORCE_REBUILD=1 make release VERSION=X.Y.Z NOTES='Fixed: ...'
```

The same environment variable works when calling `fetch-remote-assets.sh` directly. It accepts only `0` or `1`. Native workflow dispatch verifies the authenticated GitHub account is `yangshiqi` before writing; an overriding token for another account stops the dispatch.

For a backfill of an existing release, dispatch `remote-helpers.yml` on a matching branch/tag with the existing version and source commit (use the original tag when it builds on every platform; v0.10.0 needs the musl import compatibility fix in this distribution change), download the `remote-helpers` artifact, verify it against the resolved helper source SHA (and the helper fingerprint for new bundles) and upload the six new assets to the existing distribution release. Do not replace its DMG, tags or existing checksums. Record the workflow run and helper source SHA in the release notes. Never publish partial platform sets.

## User installation

Run on the remote host, using the same account that runs Claude/Codex:

```sh
curl -fsSL https://github.com/yangshiqi/ZackEyes-release/releases/download/vX.Y.Z/install-remote.sh | sh -s -- X.Y.Z
```

The installer selects Linux/macOS and x86_64/arm64, verifies the release checksum, smoke-tests the binary and atomically installs it at `~/.local/bin/zackeyes`. No sudo, Git, Swift installation, daemon, hook changes or SSH configuration changes are needed. An optional `--prefix DIRECTORY` supports isolated testing. Failure preserves the old helper. SHA256 checks detect corrupted or mismatched downloads; they are not a separate signing identity from the HTTPS release host.

Tests: `python3 -m unittest discover -s Tests/Distribution -v`.
