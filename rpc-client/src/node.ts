import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { SophonRpcClient as SharedClient, type RpcClientOptions, type RpcTransport } from "./index.js";

export * from "./index.js";

class NodeTransport implements RpcTransport {
  readonly exited: Promise<void>;
  private receive?: (chunk: string) => void;
  private fail?: (error: Error) => void;

  constructor(private readonly child: ChildProcessWithoutNullStreams) {
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", this.onData);
    child.stdout.on("error", this.onError);
    child.stdin.on("error", this.onError);
    child.stderr.on("error", this.onError);
    child.on("error", this.onError);
    child.stderr.resume();
    this.exited = new Promise(resolve => child.once("close", (code, signal) => {
      this.fail?.(new Error("RPC process closed: " + (signal ?? String(code))));
      resolve();
    }));
  }

  connect(receive: (chunk: string) => void, fail: (error: Error) => void): void {
    this.receive = receive;
    this.fail = fail;
  }

  private onData = (chunk: string): void => { this.receive?.(chunk); };
  private onError = (error: Error): void => { this.fail?.(error); };

  write(frame: string, signal: AbortSignal): Promise<void> {
    if (signal.aborted) return Promise.reject(signal.reason);
    return new Promise((resolve, reject) => this.child.stdin.write(frame, error => {
      if (error) reject(error); else resolve();
    }));
  }

  async endInput(): Promise<void> { this.child.stdin.end(); }

  async terminate(force: boolean): Promise<void> {
    if (this.child.exitCode === null && this.child.signalCode === null) {
      this.child.kill(force ? "SIGKILL" : "SIGTERM");
    }
  }

  dispose(): void {
    this.child.stdout.off("data", this.onData);
    // Keep error handlers through late stream callbacks, while dropping client references.
    this.receive = undefined;
    this.fail = undefined;
    this.child.stdin.destroy();
    this.child.stdout.destroy();
    this.child.stderr.destroy();
  }
}

export class SophonRpcClient extends SharedClient {
  static stdio(
    executable: string, arguments_: string[] = [], options: RpcClientOptions = {},
  ): SophonRpcClient {
    const transport = new NodeTransport(spawn(executable, ["rpc", ...arguments_], { stdio: "pipe" }));
    try {
      return new SophonRpcClient(transport, options);
    } catch (error) {
      void transport.terminate(true);
      transport.dispose();
      throw error;
    }
  }
}
