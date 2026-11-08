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
      return value.length > 120 ? `...${value.slice(-117)}` : value;
    }
  }
  return undefined;
}

/**
 * Pick the failure text out of a result message. `errors` is often an empty
 * array, so fall back to the subtype instead of returning "".
 *
 * @param {{ subtype?: string, errors?: string[], result?: string }} message
 * @returns {string}
 */
export function resultErrorText(message) {
  const errors = Array.isArray(message.errors)
    ? message.errors.filter((e) => typeof e === "string" && e.length > 0)
    : [];
  if (errors.length > 0) {
    return errors.join("\n");
  }
  if (typeof message.result === "string" && message.result.length > 0) {
    return message.result;
  }
  return message.subtype ?? "claude run failed";
}

/**
 * Query options shared by requests and model listing.
 *
 * 99 asks the agent to edit files in place and write its answer to a temp
 * file without a human in the loop, so permission prompts must never block:
 * this matches `claude --dangerously-skip-permissions` used by the CLI
 * provider.
 *
 * @param {{ model?: string, cwd: string }} request
 * @param {AbortController} abortController
 */
export function buildOptions(request, abortController) {
  /** @type {import("@anthropic-ai/claude-agent-sdk").Options} */
  const options = {
    cwd: request.cwd,
    permissionMode: "bypassPermissions",
    allowDangerouslySkipPermissions: true,
    abortController,
    // keep the CLI's own stderr visible to the Lua side for debugging
    stderr: (data) => {
      process.stderr.write(data);
    },
  };
  if (request.model && request.model !== "default") {
    options.model = request.model;
  }
  return options;
}

/**
 * Ask the bundled Claude Code for the models it accepts (aliases such as
 * "sonnet"/"opus" plus full ids). Uses streaming input mode without ever
 * sending a prompt, so no tokens are spent.
 *
 * @param {{ cwd?: string }} [options]
 * @returns {Promise<string[]>}
 */
export async function listClaudeModels(options = {}) {
  const abortController = new AbortController();
  /** @type {() => void} */
  let release = () => {};
  const idle = new Promise((resolve) => {
    release = () => resolve(undefined);
  });
  async function* noPrompt() {
    await idle;
  }

  const q = query({
    prompt: noPrompt(),
    options: buildOptions(
      { cwd: options.cwd ?? process.cwd() },
      abortController,
    ),
  });
  try {
    const models = await q.supportedModels();
    /** @type {string[]} */
    const ids = [];
    for (const model of models) {
      if (model && typeof model.value === "string" && !ids.includes(model.value)) {
        ids.push(model.value);
      }
    }
    return ids;
  } finally {
    release();
    abortController.abort();
  }
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
    if (signal.aborted) {
      emitComplete("failed", "aborted");
      return { status: "failed", result: "aborted" };
    }

    const stream = query({
      prompt: request.prompt,
      options: buildOptions(request, abortController),
    });

    for await (const message of stream) {
      if (signal.aborted) {
        break;
      }

      if (message.type === "system") {
        if (message.subtype === "init") {
          emitStatus(
            message.model ? `session started (${message.model})` : "session started",
          );
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
        // a "success" subtype can still carry is_error (e.g. API/auth errors)
        if (message.subtype === "success" && !message.is_error) {
          emitComplete("success", message.result ?? "");
          return { status: "success", result: message.result ?? "" };
        }
        const errText = resultErrorText(message);
        emitComplete("failed", errText);
        return { status: "failed", result: errText };
      }
    }

    if (signal.aborted) {
      emitComplete("failed", "aborted");
      return { status: "failed", result: "aborted" };
    }

    if (!completed) {
      emitComplete("failed", "claude run ended without result");
      return { status: "failed", result: "claude run ended without result" };
    }

    return { status: "success", result: "" };
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
    try {
      abortController.abort();
    } catch {
      // noop
    }
  }
}
