# SophonClientv3

Swift 6.3 library and CLI for Sophon installation, incremental updates, and predownloads. Linux and macOS 13+ are supported. Windows patching is deferred until HDiffSwift supports it.

```sh
swift build
.build/debug/SophonCLI --help
.build/debug/SophonCLI update GAME /games/GAME
.build/debug/SophonCLI update GAME /games/GAME --predownload --cache-only
.build/debug/SophonCLI next-action GAME /games/GAME
.build/debug/SophonCLI state /games/GAME
.build/debug/SophonCLI state /games/GAME --operation install
```

`GAME` accepts an API game ID or biz. `--cn` selects CN endpoints; `--mode base` selects the base installation scenario. `update --predownload` selects the future branch; `--cache-only` runs source checks and caches bundles/repair chunks while skipping target writes and deletions. The default source version is detected from the configured executable MD5 and API version records; `--from` overrides it. `update --plan` prints the static manifest plan without modifying game files.

## Cache and recovery

Install and update downloads share a persistent cache. Occupied bytes and eviction order are tracked in memory; a revision marker refreshes accounting after another process changes payloads. Received prefixes of 4 MiB HTTP ranges are journaled after writing their bytes, and resumed requests start at those prefixes. Servers that ignore Range requests fall back to a full request. Payload size and MD5 are checked before use; cached predownloads are rechecked when read. Idle completed payloads can be evicted when space is needed; unfinished downloads are retained.

An update only checks and modifies its selected patch targets. It skips targets already matching the new hash, caches and checks old inputs, applies HDIFF through [HDiffSwift](https://github.com/ohaiibuzzle/hdiffswift), and streams the output to disk while calculating its MD5. Raw bundle payloads are copied with the same output checks. Broken sources and failed patches fall back to their installation chunks without scanning the rest of the installation. Obsolete files are deleted last.

Checkpointed resume is enabled by default. Installation scans once to create its initial plan, then records each completed chunk placement and trim. Restart loads that saved plan and downloads/writes only the remaining placements, without scanning the installation again. An update records each completed target after output verification and replacement. Restart trusts those completed-file receipts and works only on unfinished targets. Initial scanning that stopped before a plan was saved must be repeated.

Completion receipts assume game files have not changed outside the operation. Use `--stateless` for a fresh verification: installation scans its files again, while updating checks its selected patch targets. This discards that operation's saved checkpoints but keeps downloaded payloads. Resume an unfinished operation before starting a different operation type in the same game directory.

The default `--write-mode temporary` keeps the existing target until output verification succeeds. Replacement uses a recoverable rename and backup. `--write-mode in-place` preserves the original on the cache drive before overwriting the target. An interrupted active patch restarts from that original; completed files and received download bytes are retained. This is process-exit recovery, not a guarantee against power loss. Keep the cache and state directories until an unfinished update has completed, and resume with the same `--from` version and directories.

Useful options on `install` and `update`:

| Option | Default | Purpose |
| --- | --- | --- |
| `--cache-directory PATH` | User cache directory | Download and original-file storage; choose a fast local drive |
| `--state-directory PATH` | Within cache | Saved plan and per-file checkpoints |
| `--memory-cache-mib N` | 500 | RAM budget in MiB for original snapshots |
| `--disk-cache-gib N` | 10 | Limit in GiB for each download/snapshot/original disk pool |
| `--cache-entry-limit N` | 500 | Maximum entries admitted to a cache queue |
| `--io-policy parallel` | parallel | Concurrent file work for SSDs |
| `--io-policy serialized` | | One target reader/writer at a time for slow drives |
| `--stateless` | Off | Rebuild work from files instead of trusting saved checkpoints |

Originals exceeding the RAM budget spill to disk. In-place originals and originals needed by another update target remain on disk until their consumers finish. Download-cache pins and byte limits provide backpressure while patch workers consume bundles. Insufficient capacity for one payload, required originals, or a complete predownload fails with an error. Unfinished partial downloads are retained rather than evicted; unrelated stale partials may require a larger cache or manual removal when no operation is using it.

These are cache-storage limits, not a process memory cap or a total filesystem quota. The RAM limit covers updater original snapshots; manifests, native patch buffers, installer chunks, and HTTP buffers use additional memory. Disk limits count logical payload bytes separately for downloads, transient snapshots, and durable originals. Filesystem allocation, journals/state, and target temporary files add disk use. Lowering a disk limit trims idle completed downloads on first cache access; retained partial downloads or active pins can prevent fitting the new limit.

Serialized mode keeps target reads and writes separate, flushing verified output before the next read, while HTTP transfers and cache I/O continue on the fast drive. Installer scanning already precedes target writes. Parallel mode uses the configured download/write counts. These policies do not measure the hardware or promise a particular throughput.

SIGINT/SIGTERM cancel queued work and drain an active native patch write before exiting. A forced kill retains the last recorded state. Separate processes cannot modify the same game directory concurrently.

## App-facing JSON-RPC

Start `.build/debug/SophonCLI rpc` for newline-delimited JSON-RPC 2.0 on stdin/stdout. Stdout carries protocol messages only. Requests may complete out of order; match responses by `id`. Notifications have no response. Closing stdin or calling `rpc.shutdown` cancels and drains active operations.

```json
{"jsonrpc":"2.0","id":1,"method":"rpc.discover"}
{"jsonrpc":"2.0","id":2,"method":"update.start","params":{"game":"GAME","directory":"/games/GAME","sourceVersion":"SOURCE_VERSION","transfer":{"cacheDirectory":"/fast/cache","ioPolicy":"serialized"}}}
{"jsonrpc":"2.0","id":3,"method":"operation.status","params":{"operationID":"ID_FROM_START"}}
{"jsonrpc":"2.0","id":4,"method":"operation.cancel","params":{"operationID":"ID_FROM_START"}}
```

`install.start` and `update.start` return an operation ID immediately. Stdio emits `operation.progress` and `operation.finished` notifications. `operation.wait` waits for the final status; cancellation remains available while it waits. Status for the most recent 128 completed operations is kept in the process. `state.inspect` needs only `directory`, optional `transfer`, and optional `operation` (`update` by default or `install`); it reads persisted state without contacting the API.

Operation parameters: `game`, `directory`, optional `cn`, `mode` (`full`/`base`), `voicePacks` and `predownload` (installation), `downloads` (8), `writes` (4), and `transfer`. `sourceVersion` is optional for updates. `predownload: true` selects the future branch, and `cacheOnly: true` caches update/repair data without applying it. `game.version` reports executable-based detection, and `game.nextAction` returns a decision without executing it. Transfer fields use bytes for `memoryLimit` and `diskLimit`, an `entryLimit` of 500 by default, and `writeMode: "temporary"` or `"in-place"`. Set `transfer.preserveState: false` for a fresh verification.

For HTTP, run:

```sh
.build/debug/SophonCLI rpc --transport http --port 0 --token YOUR_TOKEN
```

The CLI emits an `rpc.listening` message containing its localhost URL. POST JSON requests to that URL with `Content-Type: application/json` and, when configured, `Authorization: Bearer YOUR_TOKEN`. HTTP notifications return 204; poll `operation.status` for progress. Both transports limit requests to 1 MiB and batches to 128 entries. Stdio remains the default transport.

Metadata methods include `api.games`, `api.configs`, `api.branches`, `api.scanInfo`, `api.wpfPackages`, `api.resolveGame`, `api.gameInfo`, `api.lookupVersion`, `api.compareBranches`, `api.checkUpdatePath`, `api.sophonBuild`, and `api.sophonPatchBuild`. All accept named parameters and optional `cn`. Game-specific methods accept `game`; `resolveGame` accepts `query`, `lookupVersion` accepts `md5`, and `checkUpdatePath` accepts `sourceVersion`. Language/search/version/predownload filters correspond to the CLI metadata commands.

## Validation

Local transfer, native patch, and RPC tests stay in the existing test file and do not download a game:

```sh
swift test --filter 'testStreamedPatchWithCachedInputs|testTransfer'
```

Linux/macOS CI runs this focused suite. Existing live-manifest tests can be run separately. Real ZZZ repair, cache-budget measurements, and throttled-storage results are recorded in [resource validation](docs/resource-validation.md).

## Selecting the next action

`next-action GAME DIR` and `game.nextAction` inspect saved operations before executable version detection. Matching unfinished installations/updates resume using their saved plans; a partial applied operation targeting an obsolete version is reconciled using the live installation manifest. Known older versions update to live when incremental patches are supported and a diff is advertised; otherwise, the decision selects installation. An up-to-date installation caches an available future update, unless its payloads are already present. Cache-only receipts never establish an installed version. The decision contains action, source/target versions, branch, cache-only flag, scenario, voice packs and reason.

Version detection uses `exe_file_name` from the launch configuration and version/MD5 records from the API. Multiple versions sharing one executable hash require matching completed installation history or an explicit source override. Source-file integrity is checked by the update pipeline; it does not require a full installation scan before choosing an action.

The [TypeScript client](rpc-client/README.md) exposes both transports with no runtime dependencies.
