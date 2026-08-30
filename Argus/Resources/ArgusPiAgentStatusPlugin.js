/* Argus-owned Pi extension for live Agent Status and turn completion. */
const requiredEnvironment = ["ARGUS_SOCKET_PATH", "ARGUS_WORKSPACE_ID", "ARGUS_SURFACE_ID"];
const deliveryTimeoutMilliseconds = 1500;

export function environmentIsValid(environment) {
  return requiredEnvironment.every(
    (key) => typeof environment[key] === "string" && environment[key].length > 0,
  );
}

export function hasFinalAgentError(messages) {
  return Array.isArray(messages) && messages.some(
    (message) => message?.role === "assistant" && message.stopReason === "error",
  );
}

export function statusEventID(sessionID, sequence, operation = "changed") {
  return `pi:${operation}:${sessionID}:${sequence}`;
}

export function turnEventID(sessionID, sequence) {
  return `pi:turnCompleted:${sessionID}:${sequence}`;
}

async function send(socketPath, payload) {
  const { connect } = await import("node:net");
  await new Promise((resolve, reject) => {
    const socket = connect(socketPath);
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("Argus delivery timed out"));
    }, deliveryTimeoutMilliseconds);
    const finish = (operation) => (value) => {
      clearTimeout(timeout);
      operation(value);
    };
    socket.once("error", finish(reject));
    socket.end(`${JSON.stringify(payload)}\n`, finish(resolve));
  });
}

async function deliverWithDeadline(transport, socketPath, payload) {
  let timeout;
  try {
    await Promise.race([
      transport(socketPath, payload),
      new Promise((_, reject) => {
        timeout = setTimeout(
          () => reject(new Error("Argus delivery timed out")),
          deliveryTimeoutMilliseconds,
        );
      }),
    ]);
  } finally {
    clearTimeout(timeout);
  }
}

function defaultInstanceID() {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}

function sessionIDFor(context, instanceID) {
  const sessionID = context?.sessionManager?.getSessionId?.();
  const base = typeof sessionID === "string" && sessionID.length > 0 ? sessionID : "unknown";
  return `${base}:${instanceID}`;
}

export function createPlugin({ environment: suppliedEnvironment, transport = send, instanceID = defaultInstanceID() } = {}) {
  return function install(pi) {
    const environment = suppliedEnvironment ?? (typeof process === "undefined" ? {} : process.env);
    if (!environmentIsValid(environment)) return;

    let sessionID;
    let sequence = 0;
    let finalAgentError = false;
    let deliveryQueue = Promise.resolve();

    function ensureSession(context) {
      const nextSessionID = sessionIDFor(context, instanceID);
      if (sessionID !== nextSessionID) {
        sessionID = nextSessionID;
        sequence = 0;
        finalAgentError = false;
      }
      return sessionID;
    }

    function enqueue(context, state) {
      const currentSessionID = ensureSession(context);
      const currentSequence = ++sequence;
      const payload = {
        version: 1,
        id: statusEventID(currentSessionID, currentSequence),
        method: "agent.statusChanged",
        params: {
          agentKey: "pi",
          workspaceId: environment.ARGUS_WORKSPACE_ID,
          surfaceId: environment.ARGUS_SURFACE_ID,
          state,
          sessionId: currentSessionID,
          sequence: currentSequence,
        },
      };
      deliveryQueue = deliveryQueue
        .then(() => deliverWithDeadline(transport, environment.ARGUS_SOCKET_PATH, payload))
        .catch(() => {
          // Delivery failures must not alter Pi's lifecycle behavior.
        });
      return deliveryQueue;
    }

    function enqueueTurnCompletion(context) {
      const currentSessionID = ensureSession(context);
      const currentSequence = ++sequence;
      const eventId = turnEventID(currentSessionID, currentSequence);
      const payload = {
        version: 1,
        id: eventId,
        method: "agent.turnCompleted",
        params: {
          agentKey: "pi",
          workspaceId: environment.ARGUS_WORKSPACE_ID,
          surfaceId: environment.ARGUS_SURFACE_ID,
          eventId,
        },
      };
      deliveryQueue = deliveryQueue
        .then(() => deliverWithDeadline(transport, environment.ARGUS_SOCKET_PATH, payload))
        .catch(() => {
          // Delivery failures must not alter Pi's lifecycle behavior.
        });
      return deliveryQueue;
    }

    function enqueueClear(context) {
      const currentSessionID = ensureSession(context);
      const currentSequence = ++sequence;
      const payload = {
        version: 1,
        id: statusEventID(currentSessionID, currentSequence, "cleared"),
        method: "agent.statusCleared",
        params: {
          agentKey: "pi",
          workspaceId: environment.ARGUS_WORKSPACE_ID,
          surfaceId: environment.ARGUS_SURFACE_ID,
          sessionId: currentSessionID,
          sequence: currentSequence,
        },
      };
      deliveryQueue = deliveryQueue
        .then(() => deliverWithDeadline(transport, environment.ARGUS_SOCKET_PATH, payload))
        .catch(() => {
          // Delivery failures must not alter Pi's shutdown behavior.
        });
      return deliveryQueue;
    }

    pi.on("session_start", (_event, context) => enqueue(context, "idle"));

    pi.on("agent_start", (_event, context) => {
      finalAgentError = false;
      return enqueue(context, "running");
    });

    pi.on("agent_end", (event) => {
      finalAgentError = hasFinalAgentError(event?.messages);
    });

    pi.on("agent_settled", (_event, context) => {
      const state = finalAgentError ? "error" : "idle";
      return enqueue(context, state)
        .then(() => state === "idle" ? enqueueTurnCompletion(context) : undefined)
        .then(() => {
          finalAgentError = false;
        });
    });

    pi.on("session_shutdown", (_event, context) => enqueueClear(context));
  };
}

export default function (pi) {
  return createPlugin()(pi);
}
