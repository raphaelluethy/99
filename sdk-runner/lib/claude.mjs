import { query } from "@anthropic-ai/claude-agent-sdk";
import {
  emit,
  emitComplete,
  emitStatus,
  emitText,
  emitThinking,
  emitToolCall,
} from "./protocol.mjs";

/**
 * @param {unknown} input
 * @returns {string|undefined}
 */
function toolDetail(input) {
  if (!input || typeof input !== "object") {
    return undefined;
  }
  const record = /** @type {Record<string, unknown>} */ (input);
  for (const key of ["file_path", "path", "file", "target"]) {
    const value = record[key];
    if (typeof value === "string" && value.length > 0) {
      return value.length > 120 ? `${value.slice(0, 117)}...` : value;
    }
  }
  return undefined;
}

/**
 * @param {{ model: string, cwd: string, prompt: string }} request
 * @param {AbortSignal} signal
 */
export async function runClaude(request, signal) {
  emit({ type: "start" });

  const abortController = new AbortController();
  const onAbort = () => abortController.abort();
  signal.addEventListener("abort", onAbort);

  /** @type {Set<string>} */
  const openTools = new Set();
  let completed = false;

  try {
    const stream = query({
      prompt: request.prompt,
      options: {
        cwd: request.cwd,
        model: request.model,
        permissionMode: "bypassPermissions",
        allowDangerouslySkipPermissions: true,
        abortController,
      },
    });

    for await (const message of stream) {
      if (signal.aborted) {
        break;
      }

      if (message.type === "system") {
        if (message.subtype === "init") {
          emitStatus("session started");
        }
        continue;
      }

      if (message.type === "assistant") {
        for (const toolId of openTools) {
          emitToolCall(toolId, "completed");
        }
        openTools.clear();

        const content = message.message?.content ?? [];
        for (const block of content) {
          if (block.type === "text") {
            emitText(block.text);
          } else if (block.type === "tool_use") {
            openTools.add(block.name);
            emitToolCall(block.name, "started", toolDetail(block.input));
          } else if (block.type === "thinking") {
            const thinkingText =
              typeof block.thinking === "string" ? block.thinking : "";
            emitThinking(thinkingText);
          }
        }
        continue;
      }

      if (message.type === "result") {
        completed = true;
        if (message.subtype === "success") {
          emitComplete("success", message.result ?? "");
          return { status: "success", result: message.result ?? "" };
        }
        const errText =
          message.errors?.join("\n") ??
          message.subtype ??
          "claude run failed";
        emitComplete("failed", errText);
        return { status: "failed", result: errText };
      }
    }

    if (signal.aborted) {
      return { status: "failed", result: "aborted" };
    }

    if (!completed) {
      emitComplete("failed", "claude run ended without result");
      return { status: "failed", result: "claude run ended without result" };
    }

    return { status: "success", result: "" };
  } catch (err) {
    const text = err instanceof Error ? err.message : String(err);
    if (!completed) {
      emitComplete("failed", text);
    }
    return { status: "failed", result: text };
  } finally {
    signal.removeEventListener("abort", onAbort);
    try {
      abortController.abort();
    } catch {
      // noop
    }
  }
}
