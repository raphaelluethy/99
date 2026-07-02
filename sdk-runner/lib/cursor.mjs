import { Agent, Cursor } from "@cursor/sdk";
import {
  emit,
  emitComplete,
  emitStatus,
  emitText,
  emitThinking,
  emitToolCall,
} from "./protocol.mjs";

/**
 * @param {unknown} args
 * @returns {string|undefined}
 */
function toolDetail(args) {
  if (!args || typeof args !== "object") {
    return undefined;
  }
  const record = /** @type {Record<string, unknown>} */ (args);
  for (const key of ["path", "file_path", "file", "target", "command"]) {
    const value = record[key];
    if (typeof value === "string" && value.length > 0) {
      return value.length > 120 ? `${value.slice(0, 117)}...` : value;
    }
  }
  return undefined;
}

/**
 * @param {{ apiKey?: string }} [options]
 */
export async function listCursorModels(options = {}) {
  const apiKey = options.apiKey ?? process.env.CURSOR_API_KEY;
  if (!apiKey) {
    throw new Error("CURSOR_API_KEY is not set");
  }
  const models = await Cursor.models.list({ apiKey });
  return models.map((model) => model.id);
}

/**
 * @param {{ model: string, cwd: string, prompt: string }} request
 * @param {AbortSignal} signal
 */
export async function runCursor(request, signal) {
  const apiKey = process.env.CURSOR_API_KEY;
  if (!apiKey) {
    throw new Error("CURSOR_API_KEY is not set");
  }

  emit({ type: "start" });

  /** @type {import("@cursor/sdk").SDKAgent | null} */
  let agent = null;
  let completed = false;

  try {
    agent = await Agent.create({
      apiKey,
      model: { id: request.model },
      local: { cwd: request.cwd },
    });

    const run = await agent.send(request.prompt);

    for await (const event of run.stream()) {
      if (signal.aborted) {
        break;
      }

      switch (event.type) {
        case "assistant": {
          for (const block of event.message.content) {
            if (block.type === "text") {
              emitText(block.text);
            } else if (block.type === "tool_use") {
              emitToolCall(block.name, "started", toolDetail(block.input));
            }
          }
          break;
        }
        case "thinking":
          emitThinking(event.text);
          break;
        case "tool_call": {
          const status =
            event.status === "running" ? "started" : "completed";
          emitToolCall(event.name, status, toolDetail(event.args));
          break;
        }
        case "status":
          if (event.message) {
            emitStatus(event.message);
          }
          break;
        case "usage":
          emit({ type: "usage" });
          break;
        default:
          break;
      }
    }

    if (signal.aborted) {
      try {
        await run.cancel();
      } catch {
        // noop
      }
      return { status: "failed", result: "aborted" };
    }

    const final = await run.wait();
    completed = true;

    if (final.status === "finished") {
      const result = final.result ?? "";
      emitComplete("success", result);
      return { status: "success", result };
    }

    const errText = final.result ?? `cursor run ${final.status}`;
    emitComplete("failed", errText);
    return { status: "failed", result: errText };
  } catch (err) {
    const text = err instanceof Error ? err.message : String(err);
    if (!completed) {
      emitComplete("failed", text);
    }
    return { status: "failed", result: text };
  } finally {
    if (agent) {
      try {
        await agent.close();
      } catch {
        // noop
      }
    }
  }
}
