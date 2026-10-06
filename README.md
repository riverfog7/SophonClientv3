# SophonClientv3

Swift 6.3 library and CLI for Sophon installation, incremental updates, and predownloads. Linux and macOS 13+ are supported. Windows patching is deferred until HDiffSwift supports it.

```sh
swift build
.build/debug/SophonCLI --help
.build/debug/SophonCLI update GAME /games/GAME --from SOURCE_VERSION
.build/debug/SophonCLI predownload GAME /games/GAME --from SOURCE_VERSION
.build/debug/SophonCLI state /games/GAME
.build/debug/SophonCLI state /games/GAME --operation install
```

`GAME` accepts an API game ID or biz. `--cn` selects CN endpoints; `--mode base` selects the base installation scenario. Predownload selects the future branch; add `--live` to cache a live update. `update --plan` prints the static manifest plan without modifying game files.

## Cache and recovery

Install and update downloads share a persistent cache. Received prefixes of 4 MiB HTTP ranges are journaled after writing their bytes, and resumed requests start at those prefixes. Servers that ignore Range requests fall back to a full request. Payload size and MD5 are checked before use; cached predownloads are rechecked when read. Idle completed payloads can be evicted when space is needed; unfinished downloads are retained.

An update only checks and modifies its selected patch targets. It skips targets already matching the new hash, caches and checks old inputs, applies HDIFF through [HDiffSwift](https://github.com/ohaiibuzzle/hdiffswift), and streams the output to disk while calculating its MD5. Raw bundle payloads are copied with the same output checks. Broken sources and failed patches fall back to their installation chunks without scanning the rest of the installation. Obsolete files are deleted last.

Checkpointed resume is enabled by default. Installation scans once to create its initial plan, then records each completed chunk placement and trim. Restart loads that saved plan and downloads/writes only the remaining placements, without scanning the installation again. An update records each completed target after output verification and replacement. Restart trusts those completed-file receipts and works only on unfinished targets. Initial scanning that stopped before a plan was saved must be repeated.

Completion receipts assume game files have not changed outside the operation. Use `--stateless` for a fresh verification: installation scans its files again, while updating checks its selected patch targets. This discards that operation's saved checkpoints but keeps downloaded payloads. Resume an unfinished operation before starting a different operation type in the same game directory.

The default `--write-mode temporary` keeps the existing target until output verification succeeds. Replacement uses a recoverable rename and backup. `--write-mode in-place` preserves the original on the cache drive before overwriting the target. An interrupted active patch restarts from that original; completed files and received download bytes are retained. This is process-exit recovery, not a guarantee against power loss. Keep the cache and state directories until an unfinished update has completed, and resume with the same `--from` version and directories.

Useful options on `install`, `update`, and `predownload`:

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

`install.start`, `update.start`, and `update.predownload` return an operation ID immediately. Stdio emits `operation.progress` and `operation.finished` notifications. `operation.wait` waits for the final status; cancellation remains available while it waits. Status for the most recent 128 completed operations is kept in the process. `state.inspect` needs only `directory`, optional `transfer`, and optional `operation` (`update` by default or `install`); it reads persisted state without contacting the API.

Operation parameters: `game`, `directory`, optional `cn`, `mode` (`full`/`base`), `voicePacks` and `predownload` (installation), `downloads` (8), `writes` (4), and `transfer`. Updates also need `sourceVersion`. `update.predownload` uses `futureBranch: true` by default; `update.plan` uses the live branch unless `futureBranch: true` is supplied. Transfer fields use bytes for `memoryLimit` and `diskLimit`, an `entryLimit` of 500 by default, and `writeMode: "temporary"` or `"in-place"`. Set `transfer.preserveState: false` for a fresh verification.

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

Linux/macOS CI runs this focused suite. Existing live-manifest tests can be run separately.
