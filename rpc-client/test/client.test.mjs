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
      + "let waiting;\n"
      + "function reply(id,result){process.stdout.write(JSON.stringify({jsonrpc:'2.0',id,result})+'\\n');}\n"
      + "rl.on('line',line=>{const r=JSON.parse(line);\n"
      + "if(r.method==='rpc.shutdown'){reply(r.id,true);rl.close();process.exit(0);}\n"
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
    const client = NodeClient.stdio(normal.file);
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
    const client = await NeutralinoClient.stdio(normal.file, ["literal$()"], {
      neutralino: bridge.api,
      onStderr: async () => { throw new Error("UI log failure"); },
    });
    assert.ok(bridge.command.includes("'\\''"));
    assert.ok(bridge.command.includes("'literal$()'"));
    bridge.emit({ id: 900, action: "stdOut", data: "not our process\n" });
    bridge.emit({ id: 1, action: "stdErr", data: "fixture stderr" });
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
