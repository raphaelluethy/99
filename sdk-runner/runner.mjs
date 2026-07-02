#!/usr/bin/env node

import readline from "node:readline";
import { runClaude } from "./lib/claude.mjs";
import { listCursorModels, runCursor } from "./lib/cursor.mjs";
import { runFake, runHang } from "./lib/fake.mjs";
import { runOpencode } from "./lib/opencode.mjs";

/** @typedef {"claude"|"cursor"|"opencode"|"fake"|"hang"} ProviderName */

/**
 * @param {string[]} argv
 */
function parseArgs(argv) {
  /** @type {ProviderName | null} */
  let provider = null;
  let listModels = false;

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--provider") {
      provider = /** @type {ProviderName} */ (argv[i + 1]);
      i += 1;
      continue;
    }
    if (arg === "--list-models") {
      listModels = true;
    }
  }

  return { provider, listModels };
}

/**
 * @param {string} message
 * @returns {never}
 */
function startupError(message) {
  console.error(message);
  process.exit(1);
}

/**
 * @param {ProviderName} provider
 * @param {{ model: string, cwd: string, prompt: string }} request
 * @param {AbortSignal} signal
 */
async function runProvider(provider, request, signal) {
  switch (provider) {
    case "fake":
      return runFake(request, signal);
    case "hang":
      return runHang(request, signal);
    case "claude":
      return runClaude(request, signal);
    case "cursor":
      return runCursor(request, signal);
    case "opencode":
      return runOpencode(request, signal);
    default:
      throw new Error(`unknown provider: ${provider}`);
  }
}

/**
 * @returns {Promise<{ model: string, cwd: string, prompt: string }>}
 */
function readRequestLine() {
  return new Promise((resolve, reject) => {
    const rl = readline.createInterface({
      input: process.stdin,
      crlfDelay: Infinity,
    });

    let settled = false;

    rl.once("line", (line) => {
      settled = true;
      rl.close();
      try {
        const parsed = JSON.parse(line);
        if (
          !parsed ||
          typeof parsed.model !== "string" ||
          typeof parsed.cwd !== "string" ||
          typeof parsed.prompt !== "string"
        ) {
          reject(new Error("invalid request json on stdin"));
          return;
        }
        resolve(parsed);
      } catch (err) {
        reject(err);
      }
    });

    rl.once("close", () => {
      if (!settled) {
        reject(new Error("stdin closed before request line"));
      }
    });
  });
}

async function main() {
  const { provider, listModels } = parseArgs(process.argv.slice(2));

  if (!provider) {
    startupError("missing required --provider argument");
  }

  if (listModels) {
    if (provider === "cursor") {
      try {
        const models = await listCursorModels();
        for (const id of models) {
          process.stdout.write(`${id}\n`);
        }
        process.exit(0);
      } catch (err) {
        const text = err instanceof Error ? err.message : String(err);
        startupError(text);
      }
    }
    startupError("not supported");
  }

  if (provider === "cursor" && !process.env.CURSOR_API_KEY) {
    startupError("CURSOR_API_KEY is not set");
  }

  let request;
  try {
    request = await readRequestLine();
  } catch (err) {
    const text = err instanceof Error ? err.message : String(err);
    startupError(text);
  }

  const abortController = new AbortController();
  let tearingDown = false;
  let exitCode = 1;

  const teardown = (reason) => {
    if (tearingDown) {
      return;
    }
    tearingDown = true;
    if (reason) {
      console.error(reason);
    }
    abortController.abort();
  };

  process.stdin.on("end", () => {
    teardown("stdin closed");
  });
  process.stdin.on("close", () => {
    teardown("stdin closed");
  });

  const onSignal = () => {
    teardown("received signal");
  };
  process.on("SIGTERM", onSignal);
  process.on("SIGHUP", onSignal);

  const ppidTimer = setInterval(() => {
    if (process.ppid === 1) {
      teardown("parent process exited");
    }
  }, 5000);
  ppidTimer.unref();

  try {
    const result = await runProvider(provider, request, abortController.signal);
    exitCode = result.status === "success" ? 0 : 2;
  } catch (err) {
    const text = err instanceof Error ? err.message : String(err);
    console.error(text);
    exitCode = 1;
  } finally {
    clearInterval(ppidTimer);
    process.exit(exitCode);
  }
}

main().catch((err) => {
  const text = err instanceof Error ? err.message : String(err);
  console.error(text);
  process.exit(1);
});
