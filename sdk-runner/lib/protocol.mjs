/** @typedef {"start"|"text"|"thinking"|"tool_call"|"status"|"usage"|"complete"} EventType */

/**
 * @param {Record<string, unknown>} event
 */
export function emit(event) {
  process.stdout.write(`${JSON.stringify(event)}\n`);
}

/**
 * @param {"success"|"failed"} status
 * @param {string} result
 */
export function emitComplete(status, result) {
  emit({ type: "complete", status, result });
}

/**
 * @param {string} message
 */
export function emitStatus(message) {
  emit({ type: "status", text: message });
}

/**
 * @param {string} text
 */
export function emitText(text) {
  if (text) {
    emit({ type: "text", text });
  }
}

/**
 * @param {string} text
 */
export function emitThinking(text) {
  if (text) {
    emit({ type: "thinking", text });
  }
}

/**
 * @param {string} name
 * @param {"started"|"completed"} status
 * @param {string} [detail]
 */
export function emitToolCall(name, status, detail) {
  /** @type {{ name: string, status: "started"|"completed", detail?: string }} */
  const tool = { name, status };
  if (detail) {
    tool.detail = detail;
  }
  emit({ type: "tool_call", tool });
}
