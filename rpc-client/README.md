# Sophon RPC client

Node client for the CLI's stdio and HTTP transports. No runtime dependencies.

```sh
npm ci
npm run build
```

```ts
import { SophonRpcClient } from "./dist/index.js";

const client = SophonRpcClient.stdio("../.build/debug/SophonCLI");
const parameters = { game: "hk4e_global", directory: "/games/Genshin" };
const action = await client.nextAction(parameters);
console.log(action); // This query does not execute an operation.

client.onNotification(({ method, params }) => console.log(method, params));
// When the caller decides to proceed:
const { operationID } = await client.update({
  ...parameters, cacheOnly: true, predownload: true,
  transfer: { predownloadDirectory: "/downloads/Genshin" },
});
console.log(await client.wait(operationID));
await client.close();
```

`SophonRpcClient.http("http://127.0.0.1:PORT/rpc", "TOKEN")` uses the same methods.
HTTP callers poll `status()`; stdio callers can subscribe to progress notifications.
Closing a stdio client shuts down its owned CLI process. Closing an HTTP client leaves the server running.
`wait()` and `cancel()` can run concurrently. Request IDs are strings to avoid JavaScript integer precision loss.
