// One-shot runner used by the CursorSdkProvider in lua/99/providers.lua.
//
// Usage:
//   node runner.mjs --model <model-id> <query>
//   node runner.mjs --list-models
//
// Requires CURSOR_API_KEY in the environment. Exit codes follow the SDK's
// two failure modes: 1 = the run never started (auth/config/network),
// 2 = the run executed but ended in an error state.
import { Agent, Cursor, CursorAgentError } from "@cursor/sdk";

function fail(message, code) {
  process.stderr.write(message + "\n");
  process.exit(code);
}

const apiKey = process.env.CURSOR_API_KEY;
if (!apiKey) {
  fail("CURSOR_API_KEY is not set", 1);
}

const args = process.argv.slice(2);

async function listModels() {
  const models = await Cursor.models.list({ apiKey });
  for (const model of models) {
    process.stdout.write(model.id + "\n");
  }
}

async function runPrompt() {
  let model;
  let query;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--model") {
      model = args[++i];
    } else if (query === undefined) {
      query = args[i];
    }
  }
  if (!model || !query) {
    fail("usage: runner.mjs --model <model-id> <query>", 1);
  }

  const result = await Agent.prompt(query, {
    apiKey,
    model: { id: model },
    local: { cwd: process.cwd() },
  });

  if (result.result) {
    process.stdout.write(result.result + "\n");
  }
  if (result.status !== "finished") {
    fail("run ended with status: " + result.status, 2);
  }
}

try {
  if (args.includes("--list-models")) {
    await listModels();
  } else {
    await runPrompt();
  }
} catch (err) {
  if (err instanceof CursorAgentError) {
    fail("cursor sdk startup failed: " + err.message, 1);
  }
  throw err;
}
