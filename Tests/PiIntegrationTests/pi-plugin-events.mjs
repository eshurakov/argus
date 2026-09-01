import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
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

// Exercise the public Pi lifecycle and pi-subagents RPC boundary without a
// model, installed extensions, or the production Argus socket.
function fixture(extraEnvironment = {}, transport) {
  const emitter = new EventEmitter();
  const events = {
    emit: (name, data) => emitter.emit(name, data),
    on(name, handler) {
      emitter.on(name, handler);
      return () => emitter.off(name, handler);
    },
  };
  const handlers = new Map();
  const deliveries = [];
  let session = "main-session";
  const context = { sessionManager: { getSessionId: () => session }, isIdle: () => true };
  createPlugin({
    environment: { ...environment, ...extraEnvironment },
    instanceID: "regression",
    transport: async (_, payload) => {
      deliveries.push(payload);
      await transport?.(payload);
    },
  })({ events, on: (name, handler) => handlers.set(name, handler) });
  return {
    events, emitter, handlers, deliveries, context,
    setSession: (id) => { session = id; },
    fire: async (name, event = {}) => handlers.get(name)?.(event, context),
    completions: () => deliveries.filter((payload) => payload.method === "agent.turnCompleted"),
    states: () => deliveries.filter((payload) => payload.method === "agent.statusChanged").map((payload) => payload.params.state),
    replyListeners: () => emitter.eventNames().filter((name) => name.startsWith("subagents:rpc:v1:reply:")),
    advertise(capabilities = { fleetStatus: { version: 1 } }) {
      events.emit("subagents:rpc:v1:ready", { version: 1, capabilities, session: { sessionId: session } });
    },
    respond(request, data = { fleet: { version: 1, totalActive: 0, entries: [] } }) {
      events.emit(`subagents:rpc:v1:reply:${request.requestId}`, {
        version: 1, requestId: request.requestId, method: "status", success: true, data,
      });
    },
  };
}

async function finishTurn(f, stopReason = "stop") {
  await f.fire("agent_end", { messages: [{ role: "assistant", stopReason }] });
  await f.fire("agent_settled");
}

// Every child lifecycle is silent, even when it inherits valid Argus IDs.
for (const depth of ["1", "3"]) {
  const child = fixture({ PI_SUBAGENT_CHILD: "1", PI_SUBAGENT_DEPTH: depth });
  for (const name of ["session_start", "agent_start", "agent_end", "agent_settled", "session_shutdown"]) {
    await child.fire(name);
  }
  assert.equal(child.deliveries.length, 0);
  assert.equal(child.handlers.size, 0);
  assert.equal(child.emitter.eventNames().length, 0);
}

// Root sessions also have PI_SUBAGENT_PARENT_SESSION. It is not a child marker.
{
  const f = fixture({ PI_SUBAGENT_PARENT_SESSION: "main-session", PI_SUBAGENT_CHILD: "0" });
  await f.fire("session_start");
  await f.fire("agent_settled");
  assert.equal(f.completions().length, 0, "startup idle is not a completed turn");
  await f.fire("agent_start");
  await finishTurn(f);
  await f.fire("agent_settled");
  assert.equal(f.completions().length, 1, "plain Pi completes once without an RPC provider");
  await f.fire("session_shutdown");
  assert.equal(f.emitter.eventNames().length, 0);
}

// Ready may precede or follow Argus's session_start depending on extension order.
for (const readyFirst of [true, false]) {
  const f = fixture();
  let active = 2;
  f.events.on("subagents:rpc:v1:request", (request) => {
    assert.equal(request.version, 1);
    assert.equal(request.method, "status");
    f.respond(request, { fleet: { version: 1, totalActive: active, entries: [], omitted: active } });
  });
  if (readyFirst) f.advertise();
  await f.fire("session_start");
  if (!readyFirst) f.advertise();
  await f.fire("agent_start");
  await finishTurn(f);
  assert.equal(f.completions().length, 0);
  assert.equal(f.states().at(-1), "running", "main yielding with active children stays running");
  active = 0;
  await f.fire("agent_settled");
  assert.equal(f.completions().length, 0, "duplicate settlement cannot announce child completion");
  await f.fire("agent_start"); // Main agent wakes and consumes the child results.
  await finishTurn(f);
  assert.equal(f.completions().length, 1);
  assert.equal(f.states().at(-1), "idle");
  assert.equal(f.replyListeners().length, 0);
  await f.fire("session_shutdown");
  assert.equal(f.emitter.listenerCount("subagents:rpc:v1:ready"), 0);
}

// Unknown delegated state must not become a false success or leak a listener.
for (const data of [undefined, { fleet: { version: 2, totalActive: 0 } },
  ...[-1, 0.5, "0", Infinity].map((totalActive) => ({ fleet: { version: 1, totalActive } }))]) {
  const f = fixture();
  f.events.on("subagents:rpc:v1:request", (request) => {
    f.events.emit(`subagents:rpc:v1:reply:${request.requestId}`, {
      version: 1, requestId: request.requestId, success: data !== undefined, data,
    });
  });
  f.advertise();
  await f.fire("session_start");
  await f.fire("agent_start");
  await finishTurn(f);
  assert.equal(f.completions().length, 0);
  assert.equal(f.states().at(-1), "running");
  assert.equal(f.replyListeners().length, 0);
  await f.fire("session_shutdown");
}

for (const malformed of [false, true]) {
  const f = fixture();
  if (malformed) f.events.emit("subagents:rpc:v1:ready", undefined);
  else f.advertise({}); // Older advertised API cannot prove that delegated work is idle.
  await f.fire("session_start");
  await f.fire("agent_start");
  await finishTurn(f);
  assert.equal(f.completions().length, 0);
  await f.fire("session_shutdown");
}

{
  const f = fixture();
  f.advertise(); // Advertised provider stops replying.
  await f.fire("session_start");
  await f.fire("agent_start");
  await finishTurn(f); // Bounded by the integration deadline, not an indefinite wait.
  assert.equal(f.completions().length, 0);
  assert.equal(f.replyListeners().length, 0);
  await f.fire("session_shutdown");
}

for (const stopReason of ["error", "aborted"]) {
  const f = fixture();
  await f.fire("session_start");
  await f.fire("agent_start");
  await finishTurn(f, stopReason);
  assert.equal(f.completions().length, 0);
  assert.equal(f.states().at(-1), stopReason === "error" ? "error" : "idle");
  await f.fire("agent_start");
  await finishTurn(f);
  assert.equal(f.completions().length, 1, "a later successful turn can complete");
  await f.fire("session_shutdown");
}

// A reply to an old query cannot complete a new turn or a closed/replaced session.
for (const interruption of ["agent_start", "session_shutdown", "session_switch"]) {
  const f = fixture();
  let request;
  const requested = new Promise((resolve) => f.events.on("subagents:rpc:v1:request", (value) => {
    request = value;
    resolve();
  }));
  f.advertise();
  await f.fire("session_start");
  await f.fire("agent_start");
  const settlement = finishTurn(f);
  await requested;
  if (interruption === "session_switch") f.setSession("replacement-session");
  else await f.fire(interruption);
  f.respond(request);
  await settlement;
  assert.equal(f.completions().length, 0);
  assert.equal(f.replyListeners().length, 0);
  if (interruption === "session_shutdown") {
    assert.equal(f.deliveries.at(-1).method, "agent.statusCleared");
  } else {
    await f.fire("session_shutdown");
  }
}

// A mismatched response cannot satisfy a request; only the correlated reply can.
{
  const f = fixture();
  f.events.on("subagents:rpc:v1:request", (request) => {
    f.events.emit(`subagents:rpc:v1:reply:${request.requestId}`, {
      version: 1, requestId: "wrong-request", success: true,
      data: { fleet: { version: 1, totalActive: 0 } },
    });
    f.respond(request, { fleet: { version: 1, totalActive: 1 } });
  });
  f.advertise();
  await f.fire("session_start");
  await f.fire("agent_start");
  await finishTurn(f);
  assert.equal(f.completions().length, 0);
  assert.equal(f.replyListeners().length, 0);
  await f.fire("session_shutdown");
}

// A new agent run during slow socket delivery invalidates the pending completion.
{
  let releaseIdle;
  let idleStarted;
  const deliveringIdle = new Promise((resolve) => { idleStarted = resolve; });
  const idleBlocked = new Promise((resolve) => { releaseIdle = resolve; });
  let holdIdle = false;
  const f = fixture({}, async (payload) => {
    if (holdIdle && payload.params.state === "idle") {
      idleStarted();
      await idleBlocked;
    }
  });
  await f.fire("session_start");
  await f.fire("agent_start");
  holdIdle = true;
  const settlement = finishTurn(f);
  await deliveringIdle;
  const restart = f.fire("agent_start");
  releaseIdle();
  await Promise.all([settlement, restart]);
  assert.equal(f.completions().length, 0);
  assert.equal(f.states().at(-1), "running");
  await f.fire("session_shutdown");
}

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
