import assert from "node:assert/strict";
import { buildOptions, resultErrorText } from "../lib/claude.mjs";
import {
  describeMessageError,
  parseMajorVersion,
  splitModel,
} from "../lib/opencode.mjs";

/** @type {Array<[string, () => void]>} */
const tests = [
  [
    "claude: buildOptions bypasses permissions for in-place edits",
    () => {
      const ac = new AbortController();
      const opts = buildOptions({ model: "sonnet", cwd: "/repo" }, ac);
      assert.equal(opts.cwd, "/repo");
      assert.equal(opts.model, "sonnet");
      assert.equal(opts.permissionMode, "bypassPermissions");
      assert.equal(opts.allowDangerouslySkipPermissions, true);
      assert.equal(opts.abortController, ac);
      assert.equal(typeof opts.stderr, "function");
    },
  ],
  [
    "claude: model 'default' and empty model leave the CLI default",
    () => {
      const ac = new AbortController();
      assert.equal(buildOptions({ model: "default", cwd: "/" }, ac).model, undefined);
      assert.equal(buildOptions({ model: "", cwd: "/" }, ac).model, undefined);
    },
  ],
  [
    "claude: resultErrorText prefers errors, then result, then subtype",
    () => {
      assert.equal(
        resultErrorText({ subtype: "error_during_execution", errors: ["a", "b"] }),
        "a\nb",
      );
      assert.equal(
        resultErrorText({ subtype: "error_max_turns", errors: [] }),
        "error_max_turns",
      );
      assert.equal(
        resultErrorText({ subtype: "success", result: "Invalid API key" }),
        "Invalid API key",
      );
      assert.equal(resultErrorText({}), "claude run failed");
    },
  ],
  [
    "opencode: splitModel",
    () => {
      assert.deepEqual(splitModel("anthropic/claude-sonnet-5"), {
        providerID: "anthropic",
        modelID: "claude-sonnet-5",
      });
      assert.deepEqual(splitModel("big-pickle"), {
        providerID: "opencode",
        modelID: "big-pickle",
      });
      assert.deepEqual(splitModel("openrouter/a/b"), {
        providerID: "openrouter",
        modelID: "a/b",
      });
    },
  ],
  [
    "opencode: parseMajorVersion",
    () => {
      assert.equal(parseMajorVersion("1.19.3\n"), 1);
      assert.equal(parseMajorVersion("opencode v2.2.6"), 2);
      assert.equal(parseMajorVersion("garbage"), null);
    },
  ],
  [
    "opencode: describeMessageError",
    () => {
      assert.equal(
        describeMessageError({ name: "APIError", data: { message: "upgrade" } }),
        "APIError: upgrade",
      );
      assert.equal(describeMessageError({ name: "ProviderAuthError" }), "ProviderAuthError");
      assert.equal(describeMessageError(undefined), "opencode prompt failed");
    },
  ],
];

let failed = 0;
for (const [name, fn] of tests) {
  try {
    fn();
  } catch (err) {
    failed += 1;
    console.error(`FAIL ${name}\n${err instanceof Error ? err.stack : err}`);
  }
}
if (failed > 0) {
  process.exit(1);
}
console.log(`unit tests passed (${tests.length})`);
