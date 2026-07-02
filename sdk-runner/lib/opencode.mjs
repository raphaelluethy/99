import { createOpencode } from "@opencode-ai/sdk";
import {
  emit,
  emitComplete,
  emitStatus,
  emitText,
  emitThinking,
  emitToolCall,
} from "./protocol.mjs";

/**
 * @param {string} model
 * @returns {{ providerID: string, modelID: string }}
 */
function splitModel(model) {
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
 * @param {import("@opencode-ai/sdk").Part} part
 * @param {Map<string, string>} textByPart
 * @param {Map<string, string>} toolStatusByPart
 */
function handlePartUpdate(part, textByPart, toolStatusByPart) {
  if (part.type === "text") {
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
    .filter((part) => part.type === "text")
    .map((part) => part.text)
    .join("\n");
}

/**
 * @param {{ model: string, cwd: string, prompt: string }} request
 * @param {AbortSignal} signal
 */
export async function runOpencode(request, signal) {
  emit({ type: "start" });
  emitStatus("starting opencode server");

  /** @type {{ close(): void } | null} */
  let server = null;
  let completed = false;
  /** @type {Promise<void> | null} */
  let eventTask = null;

  const textByPart = new Map();
  const toolStatusByPart = new Map();

  try {
    const opencode = await createOpencode({
      hostname: "127.0.0.1",
      port: 0,
      signal,
    });
    server = opencode.server;

    const sessionResult = await opencode.client.session.create({
      directory: request.cwd,
    });
    if (sessionResult.error || !sessionResult.data) {
      throw new Error(
        sessionResult.error?.message ?? "failed to create opencode session",
      );
    }
    const sessionID = sessionResult.data.id;

    const events = await opencode.client.event.subscribe({
      directory: request.cwd,
    });

    eventTask = (async () => {
      for await (const event of events.stream) {
        if (signal.aborted) {
          break;
        }

        const type = event?.type;
        const properties = event?.properties ?? event?.data;
        if (!properties) {
          continue;
        }

        const eventSessionID =
          properties.sessionID ?? properties.sessionId ?? null;
        if (eventSessionID && eventSessionID !== sessionID) {
          continue;
        }

        if (type === "message.part.updated") {
          const part = properties.part;
          if (part) {
            handlePartUpdate(part, textByPart, toolStatusByPart);
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
      sessionID,
      directory: request.cwd,
      model: { providerID, modelID },
      parts: [{ type: "text", text: request.prompt }],
    });

    if (signal.aborted) {
      return { status: "failed", result: "aborted" };
    }

    if (promptResult.error) {
      throw new Error(promptResult.error.message ?? "opencode prompt failed");
    }

    const parts = promptResult.data?.parts ?? [];
    const result = extractAssistantText(parts);
    completed = true;
    emitComplete("success", result);
    return { status: "success", result };
  } catch (err) {
    const text = err instanceof Error ? err.message : String(err);
    if (!completed) {
      emitComplete("failed", text);
    }
    return { status: "failed", result: text };
  } finally {
    if (eventTask) {
      try {
        await eventTask.catch(() => undefined);
      } catch {
        // noop
      }
    }
    if (server) {
      try {
        server.close();
      } catch {
        // noop
      }
    }
  }
}
