import { emit, emitComplete, emitText, emitToolCall } from "./protocol.mjs";

/**
 * @param {{ model: string, cwd: string, prompt: string }} _request
 * @param {AbortSignal} signal
 */
export async function runFake(_request, signal) {
  emit({ type: "start" });

  if (signal.aborted) {
    return { status: "failed", result: "aborted" };
  }

  emitText("fake response");
  emitToolCall("fake_tool", "started", "/tmp/example");
  emitToolCall("fake_tool", "completed", "/tmp/example");
  emitComplete("success", "fake done");
  return { status: "success", result: "fake done" };
}

/**
 * @param {{ model: string, cwd: string, prompt: string }} _request
 * @param {AbortSignal} signal
 */
export async function runHang(_request, signal) {
  emit({ type: "start" });

  await new Promise((resolve) => {
    if (signal.aborted) {
      resolve(undefined);
      return;
    }
    const onAbort = () => {
      signal.removeEventListener("abort", onAbort);
      resolve(undefined);
    };
    signal.addEventListener("abort", onAbort);
  });

  return { status: "failed", result: "aborted" };
}
