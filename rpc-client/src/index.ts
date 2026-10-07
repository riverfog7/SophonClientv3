// Browser-safe shared client. Process transports live in ./node and ./neutralino.
export interface TransferSettings {
  cacheDirectory?: string;
  predownloadDirectory?: string;
  stateDirectory?: string;
  memoryLimit?: number;
  diskLimit?: number;
  diskCacheEnabled?: boolean;
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

export interface OperationProgress {
  phase: string;
  totalDownloadBytes?: number | null;
  totalWriteBytes?: number | null;
  downloadedBytes: number;
  writtenBytes: number;
  [field: string]: unknown;
}

export interface InstallationProgress extends OperationProgress {
  phase: "metadata" | "scanning" | "trimming" | "running";
  totalChunk?: number | null;
  totalFile?: number | null;
  scannedFiles: number;
  completedFiles: number;
  completedChunks: number;
  outcome?: unknown;
}

export interface OperationStatus {
  operationID: string;
  status: "starting" | "running" | "completed" | "failed" | "cancelled";
  progress?: OperationProgress;
  error?: string;
}

export interface Notification {
  method: string;
  params?: unknown;
}

export interface RpcClientOptions {
  shutdownTimeoutMs?: number;
  terminationTimeoutMs?: number;
  onNotificationError?: (error: unknown, notification: Notification) => void | Promise<void>;
}

export interface RpcCallOptions {
  timeoutMs?: number;
  signal?: AbortSignal;
}

// An adapter delivers newline-framed stdout (or HTTP responses) and reports process failure.
export interface RpcTransport {
  connect(receive: (chunk: string) => void, fail: (error: Error) => void): void;
  write(frame: string, signal: AbortSignal): Promise<void>;
  readonly exited?: Promise<void>;
  endInput?(): Promise<void>;
  terminate?(force: boolean): Promise<void>;
  dispose(): void | Promise<void>;
}

interface Response {
  jsonrpc: "2.0";
  id?: string;
  result?: unknown;
  error?: { code: number; message: string };
  method?: string;
  params?: unknown;
}

interface Pending {
  resolve(value: unknown): void;
  reject(error: Error): void;
  abort: AbortController;
  cleanup(): void;
}

export class RpcError extends Error {
  constructor(public readonly code: number, message: string) {
    super(message);
    this.name = "RpcError";
  }
}

function errorOf(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

function positiveTimeout(value: number): number {
  if (!Number.isFinite(value) || value <= 0 || value > 2_147_483_647) {
    throw new RangeError("RPC timeouts must be positive and fit a timer");
  }
  return value;
}

async function within<T>(operation: Promise<T>, timeout: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      operation,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error("RPC shutdown timed out")), timeout);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

export class SophonRpcClient {
  private sequence = 0;
  private pending = new Map<string, Pending>();
  private listeners = new Set<(notification: Notification) => void | Promise<void>>();
  private buffer = "";
  private closed = false;
  private closing = false;
  private closePromise?: Promise<void>;
  private readonly shutdownTimeout: number;
  private readonly terminationTimeout: number;

  protected constructor(
    private readonly transport: RpcTransport,
    private readonly options: RpcClientOptions = {},
  ) {
    this.shutdownTimeout = positiveTimeout(options.shutdownTimeoutMs ?? 5_000);
    this.terminationTimeout = positiveTimeout(options.terminationTimeoutMs ?? 1_000);
    transport.connect(chunk => this.read(chunk), error => this.fail(error));
  }

  static fromTransport(transport: RpcTransport, options: RpcClientOptions = {}): SophonRpcClient {
    return new SophonRpcClient(transport, options);
  }

  static http(
    url: string, token?: string,
    options: RpcClientOptions & { fetch?: typeof globalThis.fetch } = {},
  ): SophonRpcClient {
    const fetcher = options.fetch ?? globalThis.fetch;
    let receive: (chunk: string) => void = () => {};
    return new SophonRpcClient({
      connect(handler) { receive = handler; },
      async write(frame, signal) {
        const headers: Record<string, string> = { "Content-Type": "application/json" };
        if (token) headers.Authorization = "Bearer " + token;
        const response = await fetcher(url, {
          method: "POST", headers, body: frame, signal, credentials: "omit",
        });
        if (!response.ok) throw new Error("RPC HTTP status " + response.status);
        const value: unknown = await response.json();
        const id = (JSON.parse(frame) as Response).id;
        if (!value || typeof value !== "object" || (value as Response).id !== id) {
          throw new Error("Invalid RPC response ID");
        }
        receive(JSON.stringify(value) + "\n");
      },
      dispose() { receive = () => {}; },
    }, options);
  }

  onNotification(listener: (notification: Notification) => void | Promise<void>): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  async call<T = unknown>(
    method: string, params: object = {}, options: RpcCallOptions = {},
  ): Promise<T> {
    if (this.closed || (this.closing && method !== "rpc.shutdown")) {
      throw new Error("RPC client is closed");
    }
    if (options.signal?.aborted) throw errorOf(options.signal.reason ?? "RPC request aborted");
    if (options.timeoutMs !== undefined) positiveTimeout(options.timeoutMs);
    const id = String(++this.sequence);
    const frame = JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";
    return new Promise<T>((resolve, reject) => {
      const abort = new AbortController();
      let timer: ReturnType<typeof setTimeout> | undefined;
      const cancelled = () => this.reject(id, errorOf(options.signal?.reason ?? "RPC request aborted"));
      const cleanup = () => {
        clearTimeout(timer);
        options.signal?.removeEventListener("abort", cancelled);
      };
      this.pending.set(id, { resolve: value => resolve(value as T), reject, abort, cleanup });
      options.signal?.addEventListener("abort", cancelled, { once: true });
      if (options.timeoutMs !== undefined) {
        timer = setTimeout(() => this.reject(id, new Error("RPC request timed out: " + method)), options.timeoutMs);
      }
      if (options.signal?.aborted) { cancelled(); return; }
      Promise.resolve().then(() => this.transport.write(frame, abort.signal))
        .catch(error => this.reject(id, errorOf(error)));
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

  wait(operationID: string, options: RpcCallOptions = {}): Promise<OperationStatus> {
    return this.call("operation.wait", { operationID }, options);
  }

  cancel(operationID: string): Promise<boolean> {
    return this.call("operation.cancel", { operationID });
  }

  close(): Promise<void> {
    if (!this.closePromise) {
      this.closing = true;
      this.closePromise = this.closeTransport();
    }
    return this.closePromise;
  }

  private async closeTransport(): Promise<void> {
    try {
      if (this.transport.exited) {
        try {
          await within((async () => {
            if (!this.closed) await this.call("rpc.shutdown", {}, { timeoutMs: this.shutdownTimeout });
            await this.transport.endInput?.();
            await this.transport.exited;
          })(), this.shutdownTimeout);
        } catch {
          try { await within(Promise.resolve(this.transport.endInput?.()), this.terminationTimeout); } catch {}
          for (const force of [false, true]) {
            try {
              await within((async () => {
                await this.transport.terminate?.(force);
                await this.transport.exited;
              })(), this.terminationTimeout);
              break;
            } catch {}
          }
        }
      }
    } finally {
      this.fail(new Error("RPC client closed"));
      try { await within(Promise.resolve(this.transport.dispose()), this.terminationTimeout); } catch {}
    }
  }

  private read(chunk: string): void {
    if (this.closed) return;
    this.buffer += chunk;
    let newline: number;
    while ((newline = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, newline).replace(/\r$/, "");
      this.buffer = this.buffer.slice(newline + 1);
      try { this.receive(JSON.parse(line) as Response); }
      catch (error) { this.fail(errorOf(error)); return; }
    }
  }

  private receive(value: Response): void {
    if (!value || value.jsonrpc !== "2.0") throw new Error("Invalid JSON-RPC message");
    if (value.id === undefined && typeof value.method === "string") {
      const notification = { method: value.method, params: value.params };
      for (const listener of Array.from(this.listeners)) {
        try {
          Promise.resolve(listener(notification)).catch(error => this.listenerError(error, notification));
        } catch (error) {
          this.listenerError(error, notification);
        }
      }
      return;
    }
    if (typeof value.id !== "string") throw new Error("Invalid JSON-RPC response ID");
    const pending = this.pending.get(value.id);
    if (!pending) return;
    this.pending.delete(value.id);
    pending.cleanup();
    if (value.error) pending.reject(new RpcError(value.error.code, value.error.message));
    else if ("result" in value) pending.resolve(value.result);
    else {
      pending.reject(new Error("Invalid JSON-RPC response"));
      throw new Error("Invalid JSON-RPC response");
    }
  }

  private listenerError(error: unknown, notification: Notification): void {
    try {
      if (this.options.onNotificationError) {
        Promise.resolve(this.options.onNotificationError(error, notification)).catch(() => {});
      }
      else console.error("RPC notification listener failed", error);
    } catch {}
  }

  private reject(id: string, error: Error): void {
    const pending = this.pending.get(id);
    if (!pending) return;
    this.pending.delete(id);
    pending.cleanup();
    pending.abort.abort(error);
    pending.reject(error);
  }

  private fail(error: Error): void {
    this.closed = true;
    for (const id of Array.from(this.pending.keys())) this.reject(id, error);
    this.listeners.clear();
    this.buffer = "";
  }
}
