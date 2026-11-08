import { spawnSync } from "node:child_process";
import { createOpencode } from "@opencode-ai/sdk";
import {
  emit,
  emitComplete,
  emitStatus,
  emitText,
  emitThinking,
  emitToolCall,
} from "./protocol.mjs";

const SERVER_START_TIMEOUT_MS = 20000;
const EVENT_DRAIN_TIMEOUT_MS = 1000;

/**
 * @param {string} model
 * @returns {{ providerID: string, modelID: string }}
 */
export function splitModel(model) {
  const slash = model.indexOf("/");
  if (slash === -1) {
    return { providerID: "opencode", modelID: model };
  }
  return {
    providerID: model.slice(0, slash),
    modelID: model.slice(slash + 1),
  };
}

/**
 * Parse `opencode --version` output ("1.19.3", "opencode v2.2.6", ...).
 *
 * @param {string} output
 * @returns {number|null} major version
 */
export function parseMajorVersion(output) {
  const match = /(\d+)\.(\d+)\.(\d+)/.exec(output ?? "");
  return match ? Number(match[1]) : null;
}

/**
 * `@opencode-ai/sdk` speaks the opencode 1.x server API. opencode 2.x serves a
 * different (/api/...) HTTP surface with password auth, so fail fast with a
 * useful message instead of timing out on server startup.
 *
 * @returns {string|null} error message, or null when the CLI looks usable
 */
function checkOpencodeVersion() {
  const res = spawnSync("opencode", ["--version"], {
    encoding: "utf8",
    timeout: 10000,
  });
  if (res.error) {
    return `failed to run opencode: ${res.error.message}`;
  }
  const major = parseMajorVersion(`${res.stdout ?? ""}${res.stderr ?? ""}`);
  if (major !== null && major >= 2) {
    const version = (res.stdout ?? "").trim();
    return (
      `OpenCodeSdkProvider needs opencode 1.x (found ${version}); ` +
      "@opencode-ai/sdk does not support the opencode 2.x server. " +
      'Use backend = "opencode" (OpenCodeProvider, the opencode CLI) instead.'
    );
  }
  return null;
}

/**
 * @param {{ name?: string, data?: unknown } | undefined} error
 * @returns {string}
 */
export function describeMessageError(error) {
  if (!error) {
    return "opencode prompt failed";
  }
  const data = /** @type {{ message?: unknown }} */ (error.data ?? {});
  const message = typeof data.message === "string" ? data.message : "";
  const name = error.name ?? "opencode error";
  return message ? `${name}: ${message}` : name;
}

/**
 * @param {import("@opencode-ai/sdk").Part} part
 * @param {Map<string, string>} textByPart
 * @param {Map<string, string>} toolStatusByPart
 */
function handlePartUpdate(part, textByPart, toolStatusByPart) {
  if (part.type === "text") {
    if (part.synthetic || part.ignored) {
      return;
    }
    const prev = textByPart.get(part.id) ?? "";
    const next = part.text ?? "";
    if (next.length > prev.length) {
      emitText(next.slice(prev.length));
      textByPart.set(part.id, next);
    }
    return;
  }

  if (part.type === "reasoning") {
    const prev = textByPart.get(part.id) ?? "";
    const next = part.text ?? "";
    if (next.length > prev.length) {
      emitThinking(next.slice(prev.length));
      textByPart.set(part.id, next);
    }
    return;
  }

  if (part.type === "tool") {
    const state = part.state?.status;
    const prev = toolStatusByPart.get(part.id);
    if (state === "pending" || state === "running") {
      if (prev !== "started") {
        toolStatusByPart.set(part.id, "started");
        emitToolCall(part.tool, "started");
      }
      return;
    }
    if (state === "completed" || state === "error") {
      if (prev !== "completed") {
        toolStatusByPart.set(part.id, "completed");
        emitToolCall(part.tool, "completed");
      }
    }
  }
}

/**
 * @param {Array<import("@opencode-ai/sdk").Part>} parts
 * @returns {string}
 */
function extractAssistantText(parts) {
  return parts
    .filter((part) => part.type === "text" && !part.synthetic)
    .map((part) => part.text)
    .join("\n");
}

/**
 * @param {Promise<unknown>} task
 * @param {number} ms
 */
function settleWithin(task, ms) {
  return Promise.race([
    task.catch(() => undefined),
    new Promise((resolve) => {
      setTimeout(resolve, ms).unref();
    }),
  ]);
}

/**
 * @param {{ model: string, cwd: string, prompt: string }} request
 * @param {AbortSignal} signal
 */
export async function runOpencode(request, signal) {
  emit({ type: "start" });

  const versionError = checkOpencodeVersion();
  if (versionError) {
    emitComplete("failed", versionError);
    return { status: "failed", result: versionError };
  }

  emitStatus("starting opencode server");

  /** @type {{ close(): void } | null} */
  let server = null;
  let completed = false;
  /** @type {Promise<void> | null} */
  let eventTask = null;
  // the SSE stream does not end when the server is closed; abort it explicitly
  const eventAbort = new AbortController();
  const onAbort = () => eventAbort.abort();
  signal.addEventListener("abort", onAbort);

  const textByPart = new Map();
  const toolStatusByPart = new Map();
  /** @type {Map<string, string>} */
  const partTypes = new Map();
  /** @type {Set<string>} */
  const userMessageIDs = new Set();

  try {
    const opencode = await createOpencode({
      hostname: "127.0.0.1",
      port: 0,
      timeout: SERVER_START_TIMEOUT_MS,
      signal,
    });
    server = opencode.server;

    const sessionResult = await opencode.client.session.create({
      query: { directory: request.cwd },
    });
    if (sessionResult.error || !sessionResult.data) {
      throw new Error(
        sessionResult.error?.message ?? "failed to create opencode session",
      );
    }
    const sessionID = sessionResult.data.id;
    emitStatus("session started");

    const events = await opencode.client.event.subscribe({
      query: { directory: request.cwd },
      signal: eventAbort.signal,
    });

    eventTask = (async () => {
      for await (const event of events.stream) {
        if (signal.aborted || eventAbort.signal.aborted) {
          break;
        }

        const type = event?.type;
        const properties = event?.properties ?? event?.data;
        if (!properties) {
          continue;
        }

        const eventSessionID =
          properties.sessionID ??
          properties.sessionId ??
          properties.part?.sessionID ??
          properties.info?.sessionID ??
          null;
        if (eventSessionID && eventSessionID !== sessionID) {
          continue;
        }

        if (type === "message.updated") {
          const info = properties.info;
          if (info?.role === "user" && info.id) {
            userMessageIDs.add(info.id);
          }
          continue;
        }

        if (type === "message.part.updated") {
          const part = properties.part;
          // never echo the prompt we sent back as assistant output
          if (part && !userMessageIDs.has(part.messageID)) {
            partTypes.set(part.id, part.type);
            handlePartUpdate(part, textByPart, toolStatusByPart);
          }
          continue;
        }

        // newer 1.x servers stream text as deltas against an existing part
        if (type === "message.part.delta") {
          const { partID, messageID, field, delta } = properties;
          if (
            field !== "text" ||
            typeof delta !== "string" ||
            delta.length === 0 ||
            userMessageIDs.has(messageID)
          ) {
            continue;
          }
          const partType = partTypes.get(partID);
          if (partType !== "text" && partType !== "reasoning") {
            continue;
          }
          textByPart.set(partID, (textByPart.get(partID) ?? "") + delta);
          if (partType === "text") {
            emitText(delta);
          } else {
            emitThinking(delta);
          }
          continue;
        }

        if (type === "session.next.text.delta") {
          const delta = properties.delta;
          if (typeof delta === "string" && delta.length > 0) {
            emitText(delta);
          }
          continue;
        }

        if (type === "session.next.reasoning.delta") {
          const delta = properties.delta;
          if (typeof delta === "string" && delta.length > 0) {
            emitThinking(delta);
          }
        }
      }
    })();

    const { providerID, modelID } = splitModel(request.model);
    const promptResult = await opencode.client.session.prompt({
      path: { id: sessionID },
      query: { directory: request.cwd },
      body: {
        model: { providerID, modelID },
        agent: "build",
        parts: [{ type: "text", text: request.prompt }],
      },
      signal,
    });

    if (signal.aborted) {
      completed = true;
      emitComplete("failed", "aborted");
      return { status: "failed", result: "aborted" };
    }

    if (promptResult.error) {
      const err =
        /** @type {{ message?: string, data?: { message?: string } }} */ (
          promptResult.error
        );
      throw new Error(
        err.data?.message ?? err.message ?? "opencode prompt failed",
      );
    }

    // provider/model failures come back as a 200 with info.error set
    const info = promptResult.data?.info;
    if (info?.error) {
      throw new Error(describeMessageError(info.error));
    }

    const parts = promptResult.data?.parts ?? [];
    const result = extractAssistantText(parts);
    completed = true;
    emitComplete("success", result);
    return { status: "success", result };
  } catch (err) {
    const text = signal.aborted
      ? "aborted"
      : err instanceof Error
        ? err.message
        : String(err);
    if (!completed) {
      emitComplete("failed", text);
    }
    return { status: "failed", result: text };
  } finally {
    signal.removeEventListener("abort", onAbort);
    eventAbort.abort();
    if (server) {
      try {
        server.close();
      } catch {
        // noop
      }
    }
    if (eventTask) {
      await settleWithin(eventTask, EVENT_DRAIN_TIMEOUT_MS);
    }
  }
}
