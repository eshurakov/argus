/* Argus-owned Kilo TUI plugin. It uses only the public TUI API. */
const requiredEnvironment = ["ARGUS_SOCKET_PATH", "ARGUS_WORKSPACE_ID", "ARGUS_SURFACE_ID"];

export function environmentIsValid(environment) {
  return requiredEnvironment.every((key) => typeof environment[key] === "string" && environment[key].length > 0);
}

export function eventProperties(event) {
  return event?.properties ?? {};
}

export function turnEventID(sessionID, candidateID, sequence) {
  return `kilo:${sessionID}:${candidateID ?? "unknown"}:${sequence}`;
}

export function closeIsEligible(properties, state, isRoot) {
  return isRoot && properties.reason === "completed" && state.candidateID && state.activity && !state.synthetic && !state.compaction && !state.closed;
}

function stateFor(states, sessionID) {
  if (!states.has(sessionID)) states.set(sessionID, { candidateID: null, activity: false, synthetic: false, compaction: false, closed: false, sequence: 0 });
  return states.get(sessionID);
}

async function rootSession(api, sessionID) {
  try {
    const response = await api.client?.session?.get?.({ sessionID });
    const session = response?.data ?? response;
    return Boolean(session) && !session.parentID;
  } catch { return false; }
}

async function send(socketPath, payload) {
  const { connect } = await import("node:net");
  await new Promise((resolve, reject) => {
    const socket = connect(socketPath);
    socket.once("error", reject);
    socket.end(`${JSON.stringify(payload)}\n`, resolve);
  });
}

export function createPlugin({ environment: suppliedEnvironment, transport = send } = {}) {
  return {
    id: "argus-turn-completed",
    tui(api) {
      const environment = suppliedEnvironment ?? (typeof process === "undefined" ? {} : process.env);
      if (!environmentIsValid(environment)) return;
      const states = new Map();
      const subscriptions = [];
      const subscribe = (name, handler) => {
        const unsubscribe = api.event.on(name, handler);
        if (typeof unsubscribe === "function") subscriptions.push(unsubscribe);
      };

      subscribe("session.turn.open", (event) => {
      const { sessionID } = eventProperties(event);
      if (sessionID) states.set(sessionID, { candidateID: null, activity: false, synthetic: false, compaction: false, closed: false, sequence: (states.get(sessionID)?.sequence ?? 0) + 1 });
      });
      subscribe("message.updated", (event) => {
      const message = eventProperties(event).info;
      if (!message || message.role !== "user") return;
      const state = stateFor(states, message.sessionID);
      state.candidateID = message.id;
      state.synthetic ||= message.synthetic === true;
      });
      subscribe("message.part.updated", (event) => {
      const part = eventProperties(event).part;
      if (!part) return;
      const state = stateFor(states, part.sessionID);
      state.synthetic ||= part.type === "text" && part.synthetic === true;
      state.compaction ||= part.type === "compaction";
      });
      subscribe("session.status", (event) => {
      const { sessionID, status } = eventProperties(event);
      if (sessionID && (status?.type === "busy" || status?.type === "retry")) stateFor(states, sessionID).activity = true;
      });
      subscribe("session.turn.close", async (event) => {
      const { sessionID, reason } = eventProperties(event);
      if (!sessionID) return;
      const state = stateFor(states, sessionID);
      if (!closeIsEligible({ reason }, state, await rootSession(api, sessionID))) return;
      state.closed = true;
      const eventId = turnEventID(sessionID, state.candidateID, state.sequence);
      try {
        await transport(environment.ARGUS_SOCKET_PATH, {
          version: 1,
          id: eventId,
          method: "agent.turnCompleted",
          params: {
            agentKey: "kilo",
            workspaceId: environment.ARGUS_WORKSPACE_ID,
            surfaceId: environment.ARGUS_SURFACE_ID,
            eventId,
          },
        });
      } catch {
        // Delivery failures must not alter Kilo's completed turn behavior.
      }
      });
      api.lifecycle?.onDispose?.(() => {
        subscriptions.forEach((unsubscribe) => { unsubscribe(); });
        states.clear();
      });
    },
  };
}

export default createPlugin();
