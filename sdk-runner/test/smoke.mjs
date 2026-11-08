import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const runner = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "runner.mjs");

/**
 * @param {number} code
 * @param {string} message
 * @returns {never}
 */
function fail(code, message) {
  console.error(message);
  process.exit(code);
}

/**
 * @param {import("node:child_process").ChildProcessWithoutNullStreams} proc
 * @returns {Promise<{ code: number | null, stdout: string, stderr: string }>}
 */
function waitForExit(proc) {
  return new Promise((resolve, reject) => {
    /** @type {Buffer[]} */
    const stdout = [];
    /** @type {Buffer[]} */
    const stderr = [];
    proc.stdout.on("data", (chunk) => stdout.push(chunk));
    proc.stderr.on("data", (chunk) => stderr.push(chunk));
    proc.on("error", reject);
    proc.on("close", (code) => {
      resolve({
        code,
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: Buffer.concat(stderr).toString("utf8"),
      });
    });
  });
}

/**
 * @param {string} line
 * @returns {Record<string, unknown>}
 */
function parseLine(line) {
  return JSON.parse(line);
}

async function testFakeProvider() {
  const request = JSON.stringify({
    model: "test-model",
    cwd: process.cwd(),
    prompt: "hello",
  });

  const proc = spawn(process.execPath, [runner, "--provider", "fake"], {
    stdio: ["pipe", "pipe", "pipe"],
  });

  proc.stdin.write(`${request}\n`);
  // keep stdin open

  const { code, stdout, stderr } = await waitForExit(proc);
  if (code !== 0) {
    fail(1, `fake provider exited ${code}\nstderr:\n${stderr}\nstdout:\n${stdout}`);
  }

  const lines = stdout
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  const events = lines.map(parseLine);
  const types = events.map((event) => event.type);

  const expected = [
    "start",
    "text",
    "tool_call",
    "tool_call",
    "complete",
  ];

  if (JSON.stringify(types) !== JSON.stringify(expected)) {
    fail(
      1,
      `unexpected fake event sequence: ${JSON.stringify(types)} (expected ${JSON.stringify(expected)})`,
    );
  }

  const complete = events[events.length - 1];
  if (complete.status !== "success" || complete.result !== "fake done") {
    fail(1, `unexpected complete event: ${JSON.stringify(complete)}`);
  }
}

async function testHangTeardown() {
  const request = JSON.stringify({
    model: "test-model",
    cwd: process.cwd(),
    prompt: "hello",
  });

  const proc = spawn(process.execPath, [runner, "--provider", "hang"], {
    stdio: ["pipe", "pipe", "pipe"],
  });

  proc.stdin.write(`${request}\n`);

  await new Promise((resolve) => setTimeout(resolve, 100));
  proc.stdin.end();

  const start = Date.now();
  const timeoutMs = 3000;

  const result = await Promise.race([
    waitForExit(proc),
    new Promise((_, reject) => {
      setTimeout(() => reject(new Error("timeout")), timeoutMs);
    }),
  ]);

  const elapsed = Date.now() - start;
  if (elapsed >= timeoutMs) {
    proc.kill("SIGKILL");
    fail(1, "hang provider did not exit within 3000ms after stdin closed");
  }

  if (result.code === null) {
    fail(1, "hang provider was killed unexpectedly");
  }
}

async function testListModels() {
  const ok = spawn(process.execPath, [runner, "--provider", "fake", "--list-models"], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  const res = await waitForExit(ok);
  if (res.code !== 0 || res.stdout !== "fake-model-a\nfake-model-b\n") {
    fail(1, `unexpected --list-models output: ${res.code} ${JSON.stringify(res.stdout)} ${res.stderr}`);
  }

  const unsupported = spawn(
    process.execPath,
    [runner, "--provider", "opencode", "--list-models"],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  const bad = await waitForExit(unsupported);
  if (bad.code !== 1 || !bad.stderr.includes("not supported")) {
    fail(1, `expected unsupported --list-models to fail: ${bad.code} ${bad.stderr}`);
  }
}

async function testMissingProvider() {
  const proc = spawn(process.execPath, [runner], { stdio: ["ignore", "pipe", "pipe"] });
  const res = await waitForExit(proc);
  if (res.code !== 1 || !res.stderr.includes("--provider")) {
    fail(1, `expected missing --provider to fail: ${res.code} ${res.stderr}`);
  }
}

async function testInvalidRequest() {
  const proc = spawn(process.execPath, [runner, "--provider", "fake"], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  proc.stdin.write('{"model": 1}\n');
  const res = await waitForExit(proc);
  if (res.code !== 1 || !res.stderr.includes("invalid request json")) {
    fail(1, `expected invalid request to fail: ${res.code} ${res.stderr}`);
  }
}

async function main() {
  await testFakeProvider();
  await testHangTeardown();
  await testListModels();
  await testMissingProvider();
  await testInvalidRequest();
  console.log("smoke tests passed");
}

main().catch((err) => {
  fail(1, err instanceof Error ? err.message : String(err));
});
