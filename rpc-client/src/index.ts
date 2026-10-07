import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createInterface } from "node:readline";

export interface TransferSettings {
  cacheDirectory?: string;
  predownloadDirectory?: string;
  stateDirectory?: string;
  memoryLimit?: number;
  diskLimit?: number;
  entryLimit?: number;
  ioPolicy?: "parallel" | "serialized";
  writeMode?: "temporary" | "in-place";
  preserveState?: boolean;
}

export interface OperationParameters {
  game: string;
  directory: string;
  sourceVersion?: string;
  cn?: boolean;
  mode?: "full" | "base";
  predownload?: boolean;
  cacheOnly?: boolean;
  voicePacks?: string[];
  downloads?: number;
  writes?: number;
  transfer?: TransferSettings;
}

export interface GameAction {
  action: "resumeInstall" | "resumeUpdate" | "install" | "update" | "cacheUpdate" | "none";
  sourceVersion?: string | null;
  targetVersion: string;
  predownload: boolean;
  cacheOnly: boolean;
  mode: "CATEGORY_SCENARIO_FULL" | "CATEGORY_SCENARIO_BASE";
  voicePacks: string[];
  reason: string;
}

export interface OperationStatus {
  operationID: string;
  status: "starting" | "running" | "completed" | "failed" | "cancelled";
  progress?: Record<string, unknown>;
  error?: string;
}

export interface Notification {
  method: string;
  params?: unknown;
}

interface Response {
  jsonrpc: "2.0";
  id?: string;
  result?: unknown;
  error?: { code: number; message: string };
  method?: string;
  params?: unknown;
}

export class RpcError extends Error {
  constructor(public readonly code: number, message: string) {
    super(message);
    this.name = "RpcError";
  }
}

export class SophonRpcClient {
  private sequence = 0;
  private pending = new Map<string, { resolve(value: unknown): void; reject(error: Error): void }>();
  private listeners = new Set<(notification: Notification) => void>();
  private closed = false;
  private exit?: Promise<void>;

  private constructor(
    private readonly child?: ChildProcessWithoutNullStreams,
    private readonly http?: { url: string; token?: string },
  ) {
    if (!child) return;
    const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
    lines.on("line", line => {
      try { this.receive(JSON.parse(line) as Response); }
      catch (error) { this.fail(error instanceof Error ? error : new Error(String(error))); }
    });
    // Drain stderr so the CLI cannot block; callers can inspect the process when needed.
    child.stderr.resume();
    child.stdin.on("error", error => this.fail(error));
    child.on("error", error => this.fail(error));
    this.exit = new Promise(resolve => child.once("close", () => {
      lines.close();
      this.fail(new Error("RPC process closed"));
      resolve();
    }));
  }

  static stdio(executable: string, arguments_: string[] = []): SophonRpcClient {
    return new SophonRpcClient(spawn(executable, ["rpc", ...arguments_], { stdio: "pipe" }));
  }

  static http(url: string, token?: string): SophonRpcClient {
    return new SophonRpcClient(undefined, { url, token });
  }

  onNotification(listener: (notification: Notification) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  async call<T = unknown>(method: string, params: object = {}): Promise<T> {
    if (this.closed) throw new Error("RPC client is closed");
    const id = String(++this.sequence);
    const request = JSON.stringify({ jsonrpc: "2.0", id, method, params });
    if (this.http) {
      const headers: Record<string, string> = { "Content-Type": "application/json" };
      if (this.http.token) headers.Authorization = `Bearer ${this.http.token}`;
      const response = await fetch(this.http.url, { method: "POST", headers, body: request });
      if (!response.ok) throw new Error(`RPC HTTP status ${response.status}`);
      const value = await response.json() as Response;
      if (value.jsonrpc !== "2.0" || value.id !== id) throw new Error("Invalid RPC response ID");
      if (value.error) throw new RpcError(value.error.code, value.error.message);
      return value.result as T;
    }
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: value => resolve(value as T), reject });
      this.child!.stdin.write(request + "\n", error => {
        if (error) { this.pending.delete(id); reject(error); }
      });
    });
  }

  nextAction(params: OperationParameters): Promise<GameAction> {
    return this.call("game.nextAction", params);
  }

  update(params: OperationParameters): Promise<{ operationID: string }> {
    return this.call("update.start", params);
  }

  install(params: OperationParameters): Promise<{ operationID: string }> {
    return this.call("install.start", params);
  }

  status(operationID: string): Promise<OperationStatus> {
    return this.call("operation.status", { operationID });
  }

  wait(operationID: string): Promise<OperationStatus> {
    return this.call("operation.wait", { operationID });
  }

  cancel(operationID: string): Promise<boolean> {
    return this.call("operation.cancel", { operationID });
  }

  async close(): Promise<void> {
    if (this.closed) {
      if (this.child) { this.child.stdin.end(); await this.exit; }
      return;
    }
    if (this.child) {
      try { await this.call("rpc.shutdown"); }
      finally { this.child.stdin.end(); await this.exit; }
    }
    this.fail(new Error("RPC client closed"));
  }

  private receive(value: Response): void {
    if (value.jsonrpc !== "2.0") throw new Error("Invalid JSON-RPC message");
    if (value.id === undefined && value.method) {
      for (const listener of this.listeners) listener({ method: value.method, params: value.params });
      return;
    }
    const pending = value.id === undefined ? undefined : this.pending.get(value.id);
    if (!pending) return;
    this.pending.delete(value.id!);
    if (value.error) pending.reject(new RpcError(value.error.code, value.error.message));
    else pending.resolve(value.result);
  }

  private fail(error: Error): void {
    this.closed = true;
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
    this.listeners.clear();
  }
}
