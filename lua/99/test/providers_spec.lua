-- luacheck: globals describe it assert
local eq = assert.are.same
local Providers = require("99.providers")
local Prompt = require("99.prompt")
local test_utils = require("99.test.test_utils")

local FailingProcessProvider = setmetatable(
  {},
  { __index = Providers.BaseProvider }
)

function FailingProcessProvider._build_command()
  return {
    "sh",
    "-c",
    "printf 'sdk missing\\n' >&2; exit 1",
  }
end

function FailingProcessProvider._get_provider_name()
  return "FailingProcessProvider"
end

function FailingProcessProvider._get_default_model()
  return "test-model"
end

local StdoutOnlyProvider = setmetatable(
  {},
  { __index = Providers.BaseProvider }
)

function StdoutOnlyProvider._build_command()
  return {
    "sh",
    "-c",
    "printf 'stdout response'",
  }
end

function StdoutOnlyProvider._get_provider_name()
  return "StdoutOnlyProvider"
end

function StdoutOnlyProvider._get_default_model()
  return "test-model"
end

describe("providers", function()
  describe("OpenCodeProvider", function()
    it("builds correct command with model", function()
      local request = { model = "anthropic/claude-sonnet-4-5" }
      local cmd =
        Providers.OpenCodeProvider._build_command(nil, "test query", request)
      eq({
        "opencode",
        "run",
        "--agent",
        "build",
        "-m",
        "anthropic/claude-sonnet-4-5",
        "test query",
      }, cmd)
    end)

    it("has correct default model", function()
      eq(
        "opencode/claude-sonnet-4-5",
        Providers.OpenCodeProvider._get_default_model()
      )
    end)
  end)

  describe("ClaudeCodeProvider", function()
    it("builds correct command with model", function()
      local request = { model = "anthropic/claude-sonnet-4-5" }
      local cmd =
        Providers.ClaudeCodeProvider._build_command(nil, "test query", request)
      eq({
        "claude",
        "--dangerously-skip-permissions",
        "--model",
        "anthropic/claude-sonnet-4-5",
        "--print",
        "test query",
      }, cmd)
    end)

    it("has correct default model", function()
      eq("claude-sonnet-4-5", Providers.ClaudeCodeProvider._get_default_model())
    end)
  end)

  describe("CursorAgentProvider", function()
    it("builds correct command with model", function()
      local request = { model = "anthropic/claude-sonnet-4-5" }
      local cmd =
        Providers.CursorAgentProvider._build_command(nil, "test query", request)
      eq({
        "agent",
        "--trust",
        "--model",
        "anthropic/claude-sonnet-4-5",
        "--force",
        "--print",
        "test query",
      }, cmd)
    end)

    it("has correct default model", function()
      eq("sonnet-4.5", Providers.CursorAgentProvider._get_default_model())
    end)

    it("uses agent for model listing", function()
      local old_system = vim.system
      local captured_command = nil
      local models = nil
      vim.system = function(command, _, callback)
        captured_command = command
        callback({
          code = 0,
          stdout = "sonnet-4.5 - Sonnet\nopus-4.5 - Opus\n",
        })
      end

      local ok, err = xpcall(function()
        Providers.CursorAgentProvider.fetch_models(function(result)
          models = result
        end)
        test_utils.next_frame()
      end, debug.traceback)
      vim.system = old_system

      assert.is_true(ok, err)
      eq({ "agent", "models" }, captured_command)
      eq({ "sonnet-4.5", "opus-4.5" }, models)
    end)
  end)

  describe("CursorSdkProvider", function()
    it("builds the sdk-runner command", function()
      local cmd = Providers.CursorSdkProvider._build_command(
        Providers.CursorSdkProvider,
        "test query",
        { model = "composer-2.5" }
      )
      eq("node", cmd[1])
      assert.matches("runner%.mjs$", cmd[2])
      eq("--provider", cmd[3])
      eq("cursor", cmd[4])
    end)

    it("keeps the composer default model", function()
      eq("composer-2.5", Providers.CursorSdkProvider._get_default_model())
    end)
  end)

  describe("GeminiCLIProvider", function()
    it("builds correct command with model", function()
      local request = { model = "gemini-2.5-pro" }
      local cmd =
        Providers.GeminiCLIProvider._build_command(nil, "test query", request)
      eq({
        "gemini",
        "--approval-mode",
        "auto_edit",
        "--model",
        "gemini-2.5-pro",
        "--prompt",
        "test query",
      }, cmd)
    end)

    it("has correct default model", function()
      eq("auto", Providers.GeminiCLIProvider._get_default_model())
    end)
  end)

  describe("provider integration", function()
    it("can be set as provider override", function()
      local _99 = require("99")

      _99.setup({ provider = Providers.ClaudeCodeProvider })
      local state = _99.__get_state()
      eq(Providers.ClaudeCodeProvider, state.provider_override)
    end)

    it(
      "uses OpenCodeProvider default model when no provider or model specified",
      function()
        local _99 = require("99")

        _99.setup({})
        local state = _99.__get_state()
        eq("opencode/claude-sonnet-4-5", state.model)
      end
    )

    it(
      "uses ClaudeCodeProvider default model when provider specified but no model",
      function()
        local _99 = require("99")

        _99.setup({ provider = Providers.ClaudeCodeProvider })
        local state = _99.__get_state()
        eq("claude-sonnet-4-5", state.model)
      end
    )

    it(
      "uses CursorAgentProvider default model when provider specified but no model",
      function()
        local _99 = require("99")

        _99.setup({ provider = Providers.CursorAgentProvider })
        local state = _99.__get_state()
        eq("sonnet-4.5", state.model)
      end
    )

    it(
      "uses CursorSdkProvider default model when provider specified but no model",
      function()
        local _99 = require("99")

        _99.setup({ provider = Providers.CursorSdkProvider })
        local state = _99.__get_state()
        eq("composer-2.5", state.model)
      end
    )

    it(
      "uses GeminiCLIProvider default model when provider specified but no model",
      function()
        local _99 = require("99")

        _99.setup({ provider = Providers.GeminiCLIProvider })
        local state = _99.__get_state()
        eq("auto", state.model)
      end
    )

    it("uses custom model when both provider and model specified", function()
      local _99 = require("99")

      _99.setup({
        provider = Providers.ClaudeCodeProvider,
        model = "custom-model",
      })
      local state = _99.__get_state()
      eq("custom-model", state.model)
    end)
  end)

  describe("provider_extra_args", function()
    it("stores provider_extra_args on state", function()
      local _99 = require("99")
      _99.setup({
        provider_extra_args = { "--no-session-persistence" },
      })
      local state = _99.__get_state()
      eq({ "--no-session-persistence" }, state.provider_extra_args)
    end)

    it("defaults provider_extra_args to empty table", function()
      local _99 = require("99")
      _99.setup({})
      local state = _99.__get_state()
      eq({}, state.provider_extra_args)
    end)
  end)

  describe("BaseProvider", function()
    it("all providers have make_request", function()
      eq("function", type(Providers.OpenCodeProvider.make_request))
      eq("function", type(Providers.ClaudeCodeProvider.make_request))
      eq("function", type(Providers.CursorAgentProvider.make_request))
      eq("function", type(Providers.CursorSdkProvider.make_request))
      eq("function", type(Providers.ClaudeSdkProvider.make_request))
      eq("function", type(Providers.OpenCodeSdkProvider.make_request))
      eq("function", type(Providers.GeminiCLIProvider.make_request))
    end)

    it("returns stderr when a provider process exits non-zero", function()
      local _99 = require("99")
      _99.setup(test_utils.get_test_setup_options({}, FailingProcessProvider))
      test_utils.create_file({ "local value = 99" }, "lua", 1, 0)

      local state = _99.__get_state()
      local context = Prompt.search(state)
      local completed = false
      local completed_status = nil
      local completed_result = nil

      context:start_request({
        on_start = function() end,
        on_complete = function(status, result)
          completed = true
          completed_status = status
          completed_result = result
        end,
        on_stdout = function() end,
        on_stderr = function() end,
      })

      vim.wait(1000, function()
        return completed
      end)

      assert.is_true(completed)
      eq("failed", completed_status)
      assert.matches("sdk missing", completed_result)
    end)

    it("falls back to stdout when temp file is empty", function()
      local _99 = require("99")
      _99.setup(test_utils.get_test_setup_options({}, StdoutOnlyProvider))
      test_utils.create_file({ "local value = 99" }, "lua", 1, 0)

      local state = _99.__get_state()
      local context = Prompt.search(state)
      local completed = false
      local completed_status = nil
      local completed_result = nil

      context:start_request({
        on_start = function() end,
        on_complete = function(status, result)
          completed = true
          completed_status = status
          completed_result = result
        end,
        on_stdout = function() end,
        on_stderr = function() end,
      })

      vim.wait(1000, function()
        return completed
      end)

      assert.is_true(completed)
      eq("success", completed_status)
      assert.matches("stdout response", completed_result)
    end)
  end)
end)
