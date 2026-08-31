import assert from "node:assert/strict";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import plugin, {
  createPlugin,
  environmentIsValid,
  hasFinalAgentError,
  send,
  statusEventID,
  turnEventID,
} from "../../Argus/Resources/ArgusPiAgentStatusPlugin.js";

const environment = {
  ARGUS_SOCKET_PATH: "/tmp/argus.sock",
  ARGUS_WORKSPACE_ID: "workspace-id",
  ARGUS_SURFACE_ID: "surface-id",
};

assert.equal(environmentIsValid({}), false);
assert.equal(environmentIsValid(environment), true);
assert.equal(hasFinalAgentError([{ role: "assistant", stopReason: "error" }]), true);
assert.equal(hasFinalAgentError([{ role: "assistant", stopReason: "aborted" }]), false);
assert.equal(statusEventID("session", 2), "pi:changed:session:2");
assert.equal(turnEventID("session", 3), "pi:turnCompleted:session:3");

const handlers = new Map();
const deliveries = [];
const api = {
  on(name, handler) {
    handlers.set(name, handler);
  },
};
const context = {
  sessionManager: {
    getSessionId() {
      return "pi-session";
    },
  },
};

createPlugin({
  environment,
  instanceID: "instance",
  transport: async (socketPath, payload) => {
    deliveries.push({ socketPath, payload });
  },
})(api);

for (const name of ["session_start", "agent_start", "agent_end", "agent_settled", "session_shutdown"]) {
  assert(handlers.has(name), `missing ${name} handler`);
}

await handlers.get("session_start")({}, context);
await handlers.get("agent_start")({}, context);
await handlers.get("agent_end")({ messages: [{ role: "assistant", stopReason: "error" }] }, context);
await handlers.get("agent_settled")({}, context);
await handlers.get("agent_start")({}, context);
await handlers.get("agent_end")({ messages: [{ role: "assistant", stopReason: "end_turn" }] }, context);
await handlers.get("agent_settled")({}, context);
await handlers.get("session_shutdown")({}, context);

assert.deepEqual(
  deliveries.map(({ socketPath, payload }) => ({ socketPath, payload })),
  [
    {
      socketPath: environment.ARGUS_SOCKET_PATH,
      payload: {
        version: 1,
        id: "pi:changed:pi-session:instance:1",
        method: "agent.statusChanged",
        params: {
          agentKey: "pi",
          workspaceId: environment.ARGUS_WORKSPACE_ID,
          surfaceId: environment.ARGUS_SURFACE_ID,
          state: "idle",
          sessionId: "pi-session:instance",
          sequence: 1,
        },
      },
    },
    {
      socketPath: environment.ARGUS_SOCKET_PATH,
      payload: {
        version: 1,
        id: "pi:changed:pi-session:instance:2",
        method: "agent.statusChanged",
        params: {
          agentKey: "pi",
          workspaceId: environment.ARGUS_WORKSPACE_ID,
          surfaceId: environment.ARGUS_SURFACE_ID,
          state: "running",
          sessionId: "pi-session:instance",
          sequence: 2,
        },
      },
    },
    {
      socketPath: environment.ARGUS_SOCKET_PATH,
      payload: {
        version: 1,
        id: "pi:changed:pi-session:instance:3",
        method: "agent.statusChanged",
        params: {
          agentKey: "pi",
          workspaceId: environment.ARGUS_WORKSPACE_ID,
          surfaceId: environment.ARGUS_SURFACE_ID,
          state: "error",
          sessionId: "pi-session:instance",
          sequence: 3,
        },
      },
    },
    {
      socketPath: environment.ARGUS_SOCKET_PATH,
      payload: {
        version: 1,
        id: "pi:changed:pi-session:instance:4",
        method: "agent.statusChanged",
        params: {
          agentKey: "pi",
          workspaceId: environment.ARGUS_WORKSPACE_ID,
          surfaceId: environment.ARGUS_SURFACE_ID,
          state: "running",
          sessionId: "pi-session:instance",
          sequence: 4,
        },
      },
    },
    {
      socketPath: environment.ARGUS_SOCKET_PATH,
      payload: {
        version: 1,
        id: "pi:changed:pi-session:instance:5",
        method: "agent.statusChanged",
        params: {
          agentKey: "pi",
          workspaceId: environment.ARGUS_WORKSPACE_ID,
          surfaceId: environment.ARGUS_SURFACE_ID,
          state: "idle",
          sessionId: "pi-session:instance",
          sequence: 5,
        },
      },
    },
    {
      socketPath: environment.ARGUS_SOCKET_PATH,
      payload: {
        version: 1,
        id: "pi:turnCompleted:pi-session:instance:6",
        method: "agent.turnCompleted",
        params: {
          agentKey: "pi",
          workspaceId: environment.ARGUS_WORKSPACE_ID,
          surfaceId: environment.ARGUS_SURFACE_ID,
          eventId: "pi:turnCompleted:pi-session:instance:6",
        },
      },
    },
    {
      socketPath: environment.ARGUS_SOCKET_PATH,
      payload: {
        version: 1,
        id: "pi:cleared:pi-session:instance:7",
        method: "agent.statusCleared",
        params: {
          agentKey: "pi",
          workspaceId: environment.ARGUS_WORKSPACE_ID,
          surfaceId: environment.ARGUS_SURFACE_ID,
          sessionId: "pi-session:instance",
          sequence: 7,
        },
      },
    },
  ],
);

const invalidHandlers = new Map();
createPlugin({ environment: {}, transport: async () => { throw new Error("must not send"); } })({
  on(name, handler) {
    invalidHandlers.set(name, handler);
  },
});
assert.equal(invalidHandlers.size, 0);
assert.equal(typeof plugin, "function");

const socketPath = join(tmpdir(), `argus-pi-transport-${process.pid}-${Date.now()}.sock`);
let serverReleasedConnection = false;
const server = createServer({ allowHalfOpen: true }, (socket) => {
  socket.on("data", () => {});
  setTimeout(() => {
    serverReleasedConnection = true;
    socket.end();
  }, 30);
});
await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(socketPath, resolve);
});
await send(socketPath, { version: 1 });
assert.equal(serverReleasedConnection, true, "delivery waits for the connection to close");
await new Promise((resolve) => server.close(resolve));
