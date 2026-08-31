import assert from "node:assert/strict";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import plugin, {
  closeIsEligible,
  createPlugin,
  environmentIsValid,
  send,
  turnEventID,
} from "../../Argus/Resources/ArgusKiloTurnCompletionPlugin.js";

assert.equal(environmentIsValid({}), false);
assert.equal(environmentIsValid({ ARGUS_SOCKET_PATH: "socket", ARGUS_WORKSPACE_ID: "workspace", ARGUS_SURFACE_ID: "surface" }), true);
const eligibleState = { candidateID: "user", activity: true, synthetic: false, compaction: false, closed: false };
assert.equal(closeIsEligible({ reason: "completed" }, eligibleState, true), true);
assert.equal(closeIsEligible({ reason: "completed" }, eligibleState, false), false);
assert.equal(closeIsEligible({ reason: "error" }, eligibleState, true), false);
assert.equal(closeIsEligible({ reason: "interrupted" }, eligibleState, true), false);
assert.equal(closeIsEligible({ reason: "completed" }, { ...eligibleState, activity: false }, true), false);
assert.equal(closeIsEligible({ reason: "completed" }, { ...eligibleState, synthetic: true }, true), false);
assert.equal(closeIsEligible({ reason: "completed" }, { ...eligibleState, compaction: true }, true), false);
assert.notEqual(turnEventID("session", "user", 1), turnEventID("session", "user", 2));

const deliveries = [];
const handlers = new Map();
const roots = new Set(["root", "synthetic", "failed", "interrupted", "idle"]);
const environment = {
  ARGUS_SOCKET_PATH: "/tmp/argus.sock",
  ARGUS_WORKSPACE_ID: "workspace-id",
  ARGUS_SURFACE_ID: "surface-id",
};
const api = {
  event: { on(name, handler) { handlers.set(name, handler); return () => {}; } },
  lifecycle: { onDispose() {} },
  client: { session: { async get({ sessionID }) { return roots.has(sessionID) ? { data: { id: sessionID } } : { data: { id: sessionID, parentID: "root" } }; } } },
};
createPlugin({ environment, transport: async (socketPath, payload) => { deliveries.push({ socketPath, payload }); } }).tui(api);
assert(handlers.has("message.updated"));
assert(handlers.has("message.part.updated"));
assert(handlers.has("session.status"));
assert(handlers.has("session.turn.open"));
assert(handlers.has("session.turn.close"));
async function closeTurn(sessionID, { reason = "completed", synthetic = false, compaction = false, active = true } = {}) {
  handlers.get("session.turn.open")({ properties: { sessionID } });
  handlers.get("message.updated")({ properties: { info: { id: `user-${sessionID}`, sessionID, role: "user", synthetic } } });
  if (compaction) handlers.get("message.part.updated")({ properties: { part: { sessionID, type: "compaction" } } });
  if (active) handlers.get("session.status")({ properties: { sessionID, status: { type: "busy" } } });
  await handlers.get("session.turn.close")({ properties: { sessionID, reason } });
}

await closeTurn("root");
await closeTurn("child");
await closeTurn("synthetic", { synthetic: true });
await closeTurn("failed", { reason: "error" });
await closeTurn("interrupted", { reason: "interrupted" });
await closeTurn("idle", { active: false });
await closeTurn("compaction", { compaction: true });

assert.equal(deliveries.length, 1);
assert.deepEqual(deliveries[0], {
  socketPath: environment.ARGUS_SOCKET_PATH,
  payload: {
    version: 1,
    id: "kilo:root:user-root:1",
    method: "agent.turnCompleted",
    params: {
      agentKey: "kilo",
      workspaceId: environment.ARGUS_WORKSPACE_ID,
      surfaceId: environment.ARGUS_SURFACE_ID,
      eventId: "kilo:root:user-root:1",
    },
  },
});

assert.equal(plugin.id, "argus-turn-completed");

const socketPath = join(tmpdir(), `argus-kilo-transport-${process.pid}-${Date.now()}.sock`);
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
