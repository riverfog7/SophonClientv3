import { SophonRpcClient as SharedClient, type RpcClientOptions, type RpcTransport } from "./index.js";

export * from "./index.js";

// Yaagl main: Neutralino 4.11.0, client 3.8.0, using the global Neutralino object.
export interface NeutralinoProcessEvent {
  detail: { id: number; action: "stdOut" | "stdErr" | "exit"; data: string | number };
}

export interface NeutralinoAPI {
  os: {
    spawnProcess(command: string): Promise<{ id: number; pid: number }>;
    // The 3.8 SDK accepts any stdin data; Yaagl's declarations narrow it to object.
    updateSpawnedProcess(id: number, action: "stdIn" | "stdInEnd" | "exit", data?: any): Promise<unknown>;
    getSpawnedProcesses(): Promise<Array<{ id: number; pid: number }>>;
    execCommand(command: string): Promise<{ exitCode: number }>;
  };
  events: {
    on(name: "spawnedProcess", handler: (event?: NeutralinoProcessEvent) => void): Promise<unknown>;
    off(name: "spawnedProcess", handler: (event?: NeutralinoProcessEvent) => void): Promise<unknown>;
  };
}

export interface NeutralinoClientOptions extends RpcClientOptions {
  neutralino?: NeutralinoAPI;
  onStderr?: (chunk: string) => void | Promise<void>;
}

function quote(argument: string): string {
  if (argument.includes("\0")) throw new Error("Process arguments cannot contain NUL");
  return "'" + argument.replaceAll("'", "'\\''") + "'";
}

class NeutralinoTransport implements RpcTransport {
  readonly exited: Promise<void>;
  private exit!: () => void;
  private process?: { id: number; pid: number };
  private ended = false;
  private receive?: (chunk: string) => void;
  private fail?: (error: Error) => void;
  private queued: NeutralinoProcessEvent[] = [];

  constructor(private readonly api: NeutralinoAPI, private readonly options: NeutralinoClientOptions) {
    this.exited = new Promise(resolve => { this.exit = resolve; });
  }

  async spawn(executable: string, arguments_: string[]): Promise<void> {
    const command = "exec " + [executable, "rpc", ...arguments_].map(quote).join(" ");
    await this.api.events.on("spawnedProcess", this.onEvent);
    try {
      this.process = await this.api.os.spawnProcess(command);
      for (const event of this.queued) this.deliver(event);
      this.queued = [];
      if (this.ended) throw new Error("RPC process exited during startup");
    } catch (error) {
      await this.dispose();
      throw error;
    }
  }

  connect(receive: (chunk: string) => void, fail: (error: Error) => void): void {
    this.receive = receive;
    this.fail = fail;
  }

  private onEvent = (event?: NeutralinoProcessEvent): void => {
    if (!event) return;
    if (!this.process) this.queued.push(event);
    else this.deliver(event);
  };

  private deliver(event: NeutralinoProcessEvent): void {
    if (event.detail.id !== this.process?.id || this.ended) return;
    switch (event.detail.action) {
      case "stdOut":
        this.receive?.(String(event.detail.data));
        break;
      case "stdErr":
        try { Promise.resolve(this.options.onStderr?.(String(event.detail.data))).catch(() => {}); } catch {}
        break;
      case "exit":
        this.ended = true;
        this.exit();
        this.fail?.(new Error("RPC process closed: " + event.detail.data));
        break;
    }
  }

  async write(frame: string, signal: AbortSignal): Promise<void> {
    if (signal.aborted) throw signal.reason;
    if (!this.process || this.ended) throw new Error("RPC process is closed");
    await this.api.os.updateSpawnedProcess(this.process.id, "stdIn", frame);
  }

  async endInput(): Promise<void> {
    if (this.process && !this.ended) {
      await this.api.os.updateSpawnedProcess(this.process.id, "stdInEnd");
    }
  }

  async terminate(force: boolean): Promise<void> {
    if (!this.process || this.ended) return;
    if (!force) {
      await this.api.os.updateSpawnedProcess(this.process.id, "exit");
    } else {
      // The old runtime has no force option. Verify both IDs before using Linux/macOS kill.
      const processes = await this.api.os.getSpawnedProcesses();
      if (!processes.some(p => p.id === this.process!.id && p.pid === this.process!.pid)) return;
      const result = await this.api.os.execCommand("kill -KILL " + this.process.pid);
      if (result.exitCode !== 0) throw new Error("Could not terminate the RPC process");
    }
  }

  async dispose(): Promise<void> {
    this.receive = undefined;
    this.fail = undefined;
    this.queued = [];
    await this.api.events.off("spawnedProcess", this.onEvent);
  }
}

export class SophonRpcClient extends SharedClient {
  static async stdio(
    executable: string, arguments_: string[] = [], options: NeutralinoClientOptions = {},
  ): Promise<SophonRpcClient> {
    const globals = globalThis as typeof globalThis & { Neutralino?: NeutralinoAPI; NL_OS?: string };
    const api = options.neutralino ?? globals.Neutralino;
    if (!api) throw new Error("Initialize Neutralino before starting the RPC client");
    if (globals.NL_OS === "Windows") throw new Error("SophonCLI stdio currently supports Linux and macOS");
    const transport = new NeutralinoTransport(api, options);
    const client = new SophonRpcClient(transport, options);
    await transport.spawn(executable, arguments_);
    return client;
  }
}
