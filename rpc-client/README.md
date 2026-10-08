# Sophon RPC client

Shared JSON-RPC client with browser HTTP, Node stdio, and Neutralino stdio transports. No runtime dependencies.

```sh
npm ci
npm run build
npm test
```

Import `sophon-rpc-client/react` (or the package root) in React/browser code, `sophon-rpc-client/node` in Node, and `sophon-rpc-client/neutralino` in Yaagl. When importing built files directly, use `dist/index.js`, `dist/node.js`, or `dist/neutralino.js` respectively. Browser entry points contain no Node imports.

## Session settings

Set manifest caching and logging when starting the RPC process. Node and Neutralino use the existing second argument to `stdio()`:

```ts
const client = await SophonRpcClient.stdio("/path/to/SophonCLI", [
  "--manifest-cache-dir", "/app-cache/sophon/manifests",
  "--log-file", "/app-data/sophon.log",
  "--log-level", "debug",
]);
```

| Option | Default |
| --- | --- |
| `--manifest-cache-dir PATH` | System cache directory under `SophonClientv3/manifests` |
| `--log-file PATH` | Omitted: logging disabled |
| `--log-level LEVEL` | `info`; accepts `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical` |

These settings apply to every operation/query in that RPC process and remain fixed until it restarts. Logs append to existing contents; concurrent operations share one file writer. stdout stays reserved for JSON-RPC. A file-open error rejects startup; a later write failure is reported to stderr once and disables file logging while operations continue.

For HTTP, add the same flags to `SophonCLI rpc --transport http ...` when starting the server. All browser clients use that server's settings. Working cache, predownload storage, resume state, budgets, and workers remain per-operation parameters under `transfer`, `downloads`, and `writes`.

## Yaagl / Neutralino

The adapter targets [Yaagl main](https://github.com/yaagl/yet-another-anime-game-launcher/blob/784dda385c536286ef75f92e990514ac81509784/neutralino.config.json): Neutralino runtime **4.11.0**, JavaScript client **3.8.0**. It uses the application's existing global `Neutralino`; it does not install another SDK or call `Neutralino.init()`. Yaagl's native allowlist already includes `os.*`.

```ts
import { SophonRpcClient } from "sophon-rpc-client/neutralino";

const client = await SophonRpcClient.stdio("/path/to/SophonCLI", [], {
  onStderr: chunk => console.debug(chunk),
  onNotificationError: error => console.error(error),
});
const parameters = { game: "hk4e_global", directory: "/games/Genshin" };
const action = await client.nextAction(parameters); // Does not execute the action.

const unsubscribe = client.onNotification(({ method, params }) => {
  if (method === "operation.progress" || method === "operation.finished") {
    console.log(params);
  }
});

const { operationID } = await client.update(parameters);
const result = await client.wait(operationID);
if (result.status !== "completed") {
  console.error(result.status, result.error);
}
unsubscribe();
await client.close();
```

Call this after Neutralino is initialized/ready. The adapter registers its event handler before spawning, handles fragmented stdout and unrelated process events, and unregisters the handler on close. Arguments are shell-quoted for Linux/macOS. The `exec` prefix keeps the process PID attached to the CLI. Windows CLI patching remains unsupported.

To predownload, use `cacheOnly: true` and `transfer.predownloadDirectory`. Add `predownload: true` to select the future branch. The CLI owns game version detection and next-action decisions.

## React / browser HTTP

Start the CLI with the exact frontend origin:

```sh
SophonCLI rpc --transport http --port 9876 --token YOUR_TOKEN \
  --allow-origin http://localhost:5173
```

Repeat `--allow-origin` to permit additional origins. Wildcards are rejected. HTTP handles JSON/bearer preflights and returns CORS headers for allowed origins; no browser origins are enabled by default. Neutralino stdio requires no CORS configuration.

```tsx
import { useEffect, useState } from "react";
import { SophonRpcClient, type OperationStatus } from "sophon-rpc-client/react";

const client = SophonRpcClient.http("http://127.0.0.1:9876/rpc", "YOUR_TOKEN");

function Progress({ operationID }: { operationID: string }) {
  const [status, setStatus] = useState<OperationStatus>();
  useEffect(() => {
    let stopped = false;
    const refresh = async () => {
      const value = await client.status(operationID);
      if (!stopped) setStatus(value);
    };
    void refresh().catch(console.error);
    const timer = setInterval(() => { void refresh().catch(console.error); }, 250);
    return () => { stopped = true; clearInterval(timer); };
  }, [operationID]);
  const files = status?.progress?.metrics.common.files;
  return <span>{files?.completed ?? 0} / {files?.total ?? "?"} files</span>;
}
```

React running inside Neutralino can use the Neutralino client instead of HTTP and subscribe to notifications inside `useEffect`; return the unsubscribe function from the effect. The shared client itself is framework-independent, so it also works with Yaagl's Solid frontend. HTTP does not emit push notifications: poll `status()` or await `wait()`.

## Node stdio

```ts
import { SophonRpcClient } from "sophon-rpc-client/node";
const client = SophonRpcClient.stdio("../.build/debug/SophonCLI");
console.log(await client.call("rpc.discover"));
await client.close();
```

## Progress and lifecycle

Progress has `phase`, optional `outcome`, and `metrics`. Updates also include `sourceVersion` and `targetVersion` when known. The exported `InstallationMetrics` and `UpdateMetrics` types share `metrics.common`; there are no legacy flat counters.

| Section | Contents |
| --- | --- |
| `common.timing` | Operation/stage elapsed seconds, completed phase durations, overall ETA |
| `common.metadata` | All, installation, and diff manifest counts; planning completion |
| `common.network` | New network bytes in this run, including retries |
| `common.read` | Application read bytes, including installation verification |
| `common.write` | Installation placements or verified update output; excludes already updated files |
| `common.files` | Completed/total files, including skipped or cached update targets |
| `common.resources` | RAM/cache limits and usage, per-volume read/write metrics, per-bundle received/retained/new bytes |
| Install `verification` | Assessed bytes, chunks, files, missing and broken file counts |
| Install `trimming`, `download`, `processing` | Trimmed files, received payload bytes, processed chunks/bytes |
| Install `downloadedChunks`, `retries` | Completed unique payload downloads and retry attempts |
| Update `patch` | Required/received/remaining patch bytes, new patch network bytes, retained/verified bytes, ready bundles |
| Update `repair`, `deletion` | Repair download/write metrics and file count; delete entry and byte progress |
| Update `skippedFiles`, `cachedFiles` | Already updated targets and cache-only targets |

Each `SophonMetric` has `completed`, optional `total`, `remaining`, `percentage`, `rate`, `averageRate`, `etaSeconds`, plus `elapsedSeconds` and `isFinished`. Byte rates use bytes/s; count rates use items/s. Unknown totals or estimates are omitted. Recent rates use a roughly five-second window and decay to zero while idle; averages cover the active stage. Finished metrics freeze. A finished cancelled/failed stage can still have remaining work and no ETA.

Installation chunk traffic is aggregated in constant time; resource snapshots include individual patch bundles rather than every installation chunk. Raw chunk events remain available.

Reporters update counters on work events and read live I/O telemetry when a snapshot is requested. They own the clock and metric calculations, with no periodic publishing task. CLI rendering and stdio RPC sampling run outside the reporters at 250 ms by default; HTTP clients choose their polling interval. Applications format the supplied metrics without reconstructing totals, speeds, percentages, or ETAs from raw events.

Received bytes include retained data; `common.network` and `patch.network` count new traffic. Update output is counted after hash verification; per-volume writes include live output/cache I/O before a file finishes. Installation verification distinguishes assessed bytes from actual reads, so missing files advance assessment without claiming a read. These counters are application I/O, not physical device traffic or free-storage estimates.

**A resolved `wait()` is not a success signal.** Failed and cancelled operations also return a final status. Check `result.status === "completed"`. `wait()` and `cancel()` can run concurrently. Aborting a client request only stops waiting for that request; use `cancel(operationID)` to cancel the CLI operation.

Stdio sends `operation.progress` notifications with `kind: "install" | "update"`, an `events` array of 0–128 raw reporter events, and the latest `progress` snapshot. Raw events are sent as soon as the writer is available, without waiting for a timer or a full batch. An external 250 ms sampler also requests snapshots while no events arrive; these frames have `events: []`. Sampler wakeups coalesce behind a slow writer. Events remain ordered within an operation and none are sampled out. The snapshot may reflect events not yet delivered, so use it for authoritative totals rather than as an event-log checkpoint.

```ts
const unsubscribe = client.onProgressBatch(batch => {
  updateProgressDisplay(batch.progress);
  if (batch.kind === "install") {
    for (const event of batch.events) {
      if ("chunkDownloaded" in event) {
        recordChunk(event.chunkDownloaded.chunkID, event.chunkDownloaded.bytes);
      }
    }
  }
});
```

Events use Swift's tagged-enum encoding, for example `{ "chunkDownloaded": { "chunkID": "id", "bytes": 1024 } }`. Unlabelled associated values use `_0`, such as `{ "phaseChanged": { "_0": "scanning" } }`. `onNotification()` still receives the same batch notification; `onProgressBatch()` adds typed filtering. Synchronous and asynchronous listener failures are isolated from transport errors. `onNotificationError` can report UI exceptions without closing the client. The Node and Neutralino adapters share this behavior; HTTP remains status polling without raw event delivery.

The collector and reporter never wait for transport delivery. A slow client can grow the intentionally unbounded RAM event backlog; the file-cache memory limit does not cap that queue. There is no disk event spool or overflow dropping. Encoding and writes run in the sender, with RPC replies prioritized before its next notification write.

If the writer fails, its event subscription ends and releases the undeliverable backlog. The reporter remains usable; existing process-exit/cancellation behavior still applies when the host closes stdin.

`status()` and `wait()` report actual operation state independently of notification delivery. They may report completion while events are still queued. `operation.finished` follows that operation's event batches, and normal `rpc.shutdown` drains them before acknowledging shutdown.

`close()` is idempotent and bounded. For owned stdio processes it requests `rpc.shutdown`, closes stdin, then tries termination and force termination if necessary. Configure `shutdownTimeoutMs` (default 5,000) and `terminationTimeoutMs` (default 1,000) for slow target storage. Force termination can interrupt an active write; the CLI's saved operation state handles subsequent recovery. Neutralino 4.11 lacks a force-kill argument, so the adapter checks the active virtual ID/PID and uses `os.execCommand("kill -KILL <pid>")` as its final Linux/macOS fallback.

Closing an HTTP client aborts its outstanding fetches and leaves the remote CLI server running. `call()` and `wait()` accept optional `{ timeoutMs, signal }`; ordinary operations have no default request timeout. Request IDs are strings.
