import assert from "node:assert/strict";
import { mkdtemp, writeFile, rm, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, exec } from "node:child_process";
import { promisify } from "node:util";
import { test } from "node:test";
import { SophonRpcClient, RpcError } from "../dist/index.js";
import { SophonRpcClient as NodeClient } from "../dist/node.js";
import { SophonRpcClient as NeutralinoClient } from "../dist/neutralino.js";

const tick = () => new Promise(resolve => setImmediate(resolve));
const metric = (completed = 0) => ({ completed, elapsedSeconds: 0, isFinished: false });
const installProgress = (downloaded = 0) => ({
  phase: "running",
  metrics: {
    common: {
      timing: { elapsedSeconds: 0, stageElapsedSeconds: 0, phaseDurations: {} },
      metadata: { manifests: metric(), installationManifests: metric(), diffManifests: metric(), planning: metric() },
      network: metric(downloaded), read: metric(), write: metric(), files: metric(),
    },
    verification: { bytes: metric(), chunks: metric(), files: metric(), missingFiles: 0, brokenFiles: 0 },
    trimming: metric(), download: metric(downloaded), downloadedChunks: downloaded,
    processing: { chunks: metric(), bytes: 0 }, retries: 0,
  },
});

class FakeTransport {
  frames = [];
  connect(receive, fail) { this.receive = receive; this.fail = fail; }
  async write(frame) { this.frames.push(JSON.parse(frame)); }
  dispose() { this.disposed = true; }
  reply(id, result) { this.receive(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n"); }
}

test("fragmented notifications and throwing UI callbacks do not break pending requests", async () => {
  const transport = new FakeTransport();
  const errors = [];
  const client = SophonRpcClient.fromTransport(transport, {
    onNotificationError: async error => {
      errors.push(error.message);
      throw new Error("UI error reporter failure");
    },
  });
  const received = [];
  client.onNotification(() => { throw new Error("sync UI failure"); });
  client.onNotification(async () => { throw new Error("async UI failure"); });
  client.onNotification(value => { received.push(value); });
  const first = client.call("first");
  const second = client.call("second");
  await tick();
  const notification = JSON.stringify({ jsonrpc: "2.0", method: "operation.progress", params: { value: 5 } });
  transport.receive(notification.slice(0, 15));
  transport.receive(notification.slice(15) + "\r\n");
  transport.reply(transport.frames[1].id, "second result");
  transport.reply(transport.frames[0].id, "first result");
  assert.deepEqual(await Promise.all([first, second]), ["first result", "second result"]);
  await tick();
  assert.equal(received.length, 1);
  assert.deepEqual(errors.sort(), ["async UI failure", "sync UI failure"]);
  await client.close();
});

test("progress batches preserve 10,000 events, framing and listener isolation", async () => {
  const transport = new FakeTransport();
  const errors = [];
  const client = SophonRpcClient.fromTransport(transport, {
    onNotificationError: error => { errors.push(error.message); },
  });
  const seen = [];
  const sizes = [];
  client.onProgressBatch(async () => { throw new Error("batch UI failure"); });
  const unsubscribe = client.onProgressBatch(batch => {
    sizes.push(batch.events.length);
    assert.ok(batch.progress.metrics.download.completed >= seen.length);
    for (const event of batch.events) seen.push(Number(event.chunkDownloaded.chunkID));
  });
  const pending = client.call("while-events-arrive");
  await tick();
  for (let offset = 0; offset < 10_000; offset += 128) {
    const events = Array.from({ length: Math.min(128, 10_000 - offset) }, (_, index) => ({
      chunkDownloaded: { chunkID: String(offset + index), bytes: 1 },
    }));
    const frame = JSON.stringify({ jsonrpc: "2.0", method: "operation.progress", params: {
      operationID: "job", status: "running", kind: "install", events,
      progress: installProgress(offset + events.length),
    } }) + "\n";
    transport.receive(frame.slice(0, 23));
    transport.receive(frame.slice(23));
  }
  transport.reply(transport.frames[0].id, true);
  assert.equal(await pending, true);
  await tick();
  assert.deepEqual(seen, Array.from({ length: 10_000 }, (_, index) => index));
  assert.equal(sizes.length, 79);
  assert.equal(sizes.at(-1), 16);
  assert.equal(errors.length, 79);
  // Aggregate sampling during a quiet transfer has no synthetic raw events.
  transport.receive(JSON.stringify({ jsonrpc: "2.0", method: "operation.progress", params: {
    operationID: "job", status: "running", kind: "install", events: [], progress: installProgress(10_000),
  } }) + "\n");
  assert.equal(sizes.at(-1), 0);
  assert.deepEqual(seen, Array.from({ length: 10_000 }, (_, index) => index));
  unsubscribe();
  transport.receive(JSON.stringify({ jsonrpc: "2.0", method: "operation.progress", params: {
    operationID: "job", status: "running", progress: { phase: "metadata" },
  } }) + "\n");
  assert.equal(sizes.length, 80);
  await client.close();
});

test("snapshot progress exposes phase and metrics without event arrays", async () => {
  const transport = new FakeTransport();
  const errors = [];
  const client = SophonRpcClient.fromTransport(transport, {
    onNotificationError: error => { errors.push(error.message); },
  });
  const snapshots = [];
  let batches = 0;
  client.onProgress(() => { throw new Error("snapshot UI failure"); });
  const unsubscribe = client.onProgress(value => { snapshots.push(value); });
  client.onProgressBatch(() => { batches++; });
  const progress = installProgress(1024);
  progress.phase = "scanning";
  progress.metrics.common.resources = {
    memoryBytes: 0, memoryLimit: 1024, diskLimit: 1024, diskReservedBytes: 0, devices: [], downloads: [],
    memoryCache: { read: { ...metric(64), rate: 32 }, write: metric(128) },
    diskCache: { read: metric(16), write: { ...metric(32), rate: 16 } },
    target: { read: metric(256), write: metric(512) },
  };
  transport.receive(JSON.stringify({ jsonrpc: "2.0", method: "operation.progress", params: {
    operationID: "snapshot", status: "running", kind: "install", progress,
  } }) + "\n");
  await tick();
  assert.equal(snapshots.length, 1);
  assert.equal(snapshots[0].progress.phase, "scanning");
  assert.equal(snapshots[0].progress.metrics.common.network.completed, 1024);
  assert.equal(batches, 0);
  assert.equal(snapshots[0].progress.metrics.common.resources.memoryCache.read.rate, 32);
  assert.equal(snapshots[0].progress.metrics.common.resources.diskCache.write.rate, 16);
  assert.deepEqual(errors, ["snapshot UI failure"]);
  unsubscribe();
  await client.close();
});

test("timeout, abort, RPC failure and process failure reject the appropriate requests", async () => {
  const transport = new FakeTransport();
  const client = SophonRpcClient.fromTransport(transport);
  await assert.rejects(client.call("slow", {}, { timeoutMs: 10 }), /timed out/);
  const controller = new AbortController();
  const aborted = client.call("aborted", {}, { signal: controller.signal });
  controller.abort(new Error("user abort"));
  await assert.rejects(aborted, /user abort/);
  const request = client.call("failure");
  await tick();
  const id = transport.frames.at(-1).id;
  transport.receive(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32001, message: "unknown" } }) + "\n");
  await assert.rejects(request, error => error instanceof RpcError && error.code === -32001);
  const waiting = client.call("pending");
  transport.fail(new Error("process crashed"));
  await assert.rejects(waiting, /process crashed/);
  await client.close();
});

test("close is idempotent and bounded even when every shutdown API stalls", async () => {
  const transport = new FakeTransport();
  transport.exited = new Promise(() => {});
  transport.endInput = () => new Promise(() => {});
  transport.terminate = () => new Promise(() => {});
  transport.dispose = () => new Promise(() => {});
  const client = SophonRpcClient.fromTransport(transport, {
    shutdownTimeoutMs: 15, terminationTimeoutMs: 10,
  });
  const waiting = client.call("operation.wait");
  const rejection = assert.rejects(waiting, /closed/);
  const start = Date.now();
  const close = client.close();
  assert.equal(close, client.close());
  await close;
  await rejection;
  assert.ok(Date.now() - start < 500);
});

test("HTTP correlation and close work without closing the remote server", async () => {
  const requests = [];
  const client = SophonRpcClient.http("http://localhost/rpc", "secret", {
    fetch: async (_url, options) => {
      const request = JSON.parse(options.body);
      requests.push({ request, options });
      return new Response(JSON.stringify({
        jsonrpc: "2.0", id: request.id,
        result: { operationID: "job", status: "failed", error: "test failure" },
      }));
    },
  });
  const result = await client.wait("job");
  assert.equal(result.status, "failed"); // wait resolving does not mean success.
  assert.equal(requests[0].options.headers.Authorization, "Bearer secret");
  await client.close();
  assert.equal(requests.length, 1);
});

async function fixture(hung = false) {
  const directory = await mkdtemp(join(tmpdir(), "sophon rpc-"));
  const file = join(directory, "mock cli's executable");
  const source = hung
    ? "#!/usr/bin/env node\nprocess.on('SIGTERM',()=>{}); process.stdin.resume(); setInterval(()=>{},1000);\n"
    : "#!/usr/bin/env node\n"
      + "const rl=require('node:readline').createInterface({input:process.stdin});\n"
      + "const metric=" + metric.toString() + "; const installProgress=" + installProgress.toString() + ";\n"
      + "let waiting;\n"
      + "function reply(id,result){process.stdout.write(JSON.stringify({jsonrpc:'2.0',id,result})+'\\n');}\n"
      + "rl.on('line',line=>{const r=JSON.parse(line);\n"
      + "if(r.method==='rpc.shutdown'){reply(r.id,true);rl.close();process.exit(0);}\n"
      + "else if(r.method==='events'){for(let i=0;i<1024;i+=128){process.stdout.write(JSON.stringify({jsonrpc:'2.0',method:'operation.progress',params:{operationID:'job',status:'running',kind:'install',events:Array.from({length:128},(_,j)=>({chunkDownloaded:{chunkID:String(i+j),bytes:1}})),progress:installProgress(i+128)}})+'\\n');}reply(r.id,1024);}\n"
      + "else if(r.method==='argv'){reply(r.id,process.argv.slice(2));}\n"
      + "else if(r.method==='operation.wait'){waiting=r.id;}\n"
      + "else if(r.method==='operation.cancel'){reply(r.id,true);reply(waiting,{operationID:'job',status:'cancelled'});}\n"
      + "else reply(r.id,{operationID:'job'});});\n";
  await writeFile(file, source, { mode: 0o755 });
  return { directory, file };
}

test("Node stdio supports concurrent wait/cancel, process errors and forced shutdown", async () => {
  const normal = await fixture();
  const hung = await fixture(true);
  try {
    const arguments_ = ["--manifest-cache-dir", join(normal.directory, "manifest cache"),
      "--log-file", join(normal.directory, "session log.txt"), "--log-level", "debug", "--progress-snapshots-only"];
    const client = NodeClient.stdio(normal.file, arguments_);
    assert.deepEqual(await client.call("argv"), ["rpc", ...arguments_]);
    const seen = [];
    client.onProgressBatch(batch => { for (const event of batch.events) seen.push(Number(event.chunkDownloaded.chunkID)); });
    assert.equal(await client.call("events"), 1024);
    assert.deepEqual(seen, Array.from({ length: 1024 }, (_, index) => index));
    const waiting = client.wait("job");
    assert.equal(await client.cancel("job"), true);
    assert.equal((await waiting).status, "cancelled");
    await client.close();
    const stalled = NodeClient.stdio(hung.file, [], { shutdownTimeoutMs: 30, terminationTimeoutMs: 30 });
    const pending = stalled.call("never");
    const rejection = assert.rejects(pending, /closed/);
    await stalled.close();
    await rejection;
    const missing = NodeClient.stdio(join(normal.directory, "missing"));
    await assert.rejects(missing.call("anything"), /ENOENT|closed/);
    await missing.close();
  } finally {
    await rm(normal.directory, { recursive: true, force: true });
    await rm(hung.directory, { recursive: true, force: true });
  }
});

function neutralinoBridge() {
  const handlers = new Set();
  const children = new Map();
  let sequence = 0;
  let command;
  const emit = detail => { for (const handler of handlers) handler({ detail }); };
  const api = {
    events: {
      async on(_name, handler) { handlers.add(handler); },
      async off(_name, handler) { handlers.delete(handler); },
    },
    os: {
      async spawnProcess(value) {
        command = value;
        const child = spawn("/bin/sh", ["-c", value], { stdio: "pipe" });
        const id = ++sequence;
        children.set(id, child);
        child.stdout.setEncoding("utf8");
        child.stdout.on("data", data => {
          // Exercise arbitrary chunk boundaries, as Neutralino events do.
          emit({ id, action: "stdOut", data: data.slice(0, 9) });
          emit({ id, action: "stdOut", data: data.slice(9) });
        });
        child.stderr.on("data", data => emit({ id, action: "stdErr", data: String(data) }));
        child.on("close", code => {
          children.delete(id);
          emit({ id, action: "exit", data: code });
        });
        return { id, pid: child.pid };
      },
      async updateSpawnedProcess(id, action, data) {
        const child = children.get(id);
        if (!child) throw new Error("missing process");
        if (action === "stdIn") child.stdin.write(data);
        if (action === "stdInEnd") child.stdin.end();
        if (action === "exit") child.kill("SIGTERM");
      },
      async getSpawnedProcesses() {
        return Array.from(children, ([id, child]) => ({ id, pid: child.pid }));
      },
      async execCommand(value) {
        await promisify(exec)(value);
        return { exitCode: 0 };
      },
    },
  };
  return { api, handlers, children, emit, get command() { return command; } };
}

test("Neutralino 3.8/4.11 process APIs preserve quoting, framing and shutdown", async () => {
  const normal = await fixture();
  const hung = await fixture(true);
  const bridge = neutralinoBridge();
  try {
    const arguments_ = ["literal$()", "--manifest-cache-dir", join(normal.directory, "manifest cache"),
      "--log-file", join(normal.directory, "session log.txt"), "--log-level", "debug", "--progress-snapshots-only"];
    const client = await NeutralinoClient.stdio(normal.file, arguments_, {
      neutralino: bridge.api,
      onStderr: async () => { throw new Error("UI log failure"); },
    });
    assert.ok(bridge.command.includes("'\\''"));
    assert.ok(bridge.command.includes("'literal$()'"));
    assert.deepEqual(await client.call("argv"), ["rpc", ...arguments_]);
    bridge.emit({ id: 900, action: "stdOut", data: "not our process\n" });
    bridge.emit({ id: 1, action: "stdErr", data: "fixture stderr" });
    const seen = [];
    client.onProgressBatch(batch => { for (const event of batch.events) seen.push(Number(event.chunkDownloaded.chunkID)); });
    assert.equal(await client.call("events"), 1024);
    assert.deepEqual(seen, Array.from({ length: 1024 }, (_, index) => index));
    const waiting = client.wait("job");
    assert.equal(await client.cancel("job"), true);
    assert.equal((await waiting).status, "cancelled");
    await client.close();
    assert.equal(bridge.handlers.size, 0);
    const stalled = await NeutralinoClient.stdio(hung.file, [], {
      neutralino: bridge.api, shutdownTimeoutMs: 30, terminationTimeoutMs: 30,
    });
    await stalled.close();
    assert.equal(bridge.handlers.size, 0);
    assert.equal(bridge.children.size, 0);
  } finally {
    for (const child of bridge.children.values()) child.kill("SIGKILL");
    await rm(normal.directory, { recursive: true, force: true });
    await rm(hung.directory, { recursive: true, force: true });
  }
});

test("Neutralino startup buffers early events and cleans a failed spawn subscription", async () => {
  let handler;
  let removed = false;
  let fail = false;
  let earlyExit = false;
  const api = {
    events: {
      async on(_name, value) { handler = value; },
      async off() { removed = true; },
    },
    os: {
      async spawnProcess() {
        if (fail) throw new Error("spawn failed");
        if (earlyExit) {
          handler({ detail: { id: 7, action: "exit", data: 1 } });
          return { id: 7, pid: 123 };
        }
        handler({ detail: { id: 7, action: "stdOut", data: '{"jsonrpc":"2.0",' } });
        return { id: 7, pid: 123 };
      },
      async updateSpawnedProcess(id, action, data) {
        if (action === "stdIn") {
          const request = JSON.parse(data);
          if (request.method === "rpc.shutdown") {
            handler({ detail: { id, action: "stdOut", data: JSON.stringify({ jsonrpc: "2.0", id: request.id, result: true }) + "\n" } });
            handler({ detail: { id, action: "exit", data: 0 } });
          } else {
            handler({ detail: { id, action: "stdOut", data: '"method":"ready"}\n' + JSON.stringify({ jsonrpc: "2.0", id: request.id, result: 5 }) + "\n" } });
          }
        }
      },
      async getSpawnedProcesses() { return []; },
      async execCommand() { return { exitCode: 0 }; },
    },
  };
  const client = await NeutralinoClient.stdio("cli", [], { neutralino: api });
  assert.equal(await client.call("first"), 5);
  await client.close();
  assert.equal(removed, true);
  fail = true;
  removed = false;
  await assert.rejects(NeutralinoClient.stdio("cli", [], { neutralino: api }), /spawn failed/);
  assert.equal(removed, true);
  fail = false;
  earlyExit = true;
  removed = false;
  await assert.rejects(NeutralinoClient.stdio("cli", [], { neutralino: api }), /exited during startup/);
  assert.equal(removed, true);
});

test("browser and Neutralino entry points have no Node transport imports", async () => {
  for (const file of ["index.js", "neutralino.js"]) {
    const contents = await readFile(new URL("../dist/" + file, import.meta.url), "utf8");
    assert.doesNotMatch(contents, /from\s+["']node:|import\s*\(\s*["']node:/);
  }
});
