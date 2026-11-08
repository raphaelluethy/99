-- luacheck: globals describe it assert
local eq = assert.are.same
local Sdk = require("99.sdk")
local Providers = require("99.providers")
local Prompt = require("99.prompt")
local test_utils = require("99.test.test_utils")

--- @param ndjson string
--- @return _99.Providers.SdkProvider
local function stub_provider(ndjson)
  local Stub = setmetatable({}, { __index = Providers.SdkProvider })

  function Stub._ensure_ready(_, _, cb)
    cb(true)
  end

  function Stub._build_command()
    return {
      "sh",
      "-c",
      string.format("printf %s", vim.fn.shellescape(ndjson)),
    }
  end

  function Stub._get_sdk_provider_arg()
    return "fake"
  end

  function Stub._get_provider_name()
    return "StubSdkProvider"
  end

  function Stub._get_default_model()
    return "test-model"
  end

  return Stub
end

--- @param ndjson string
--- @param on_complete fun(status: _99.Prompt.EndingState, result: string): nil
--- @return _99.Providers.Event[], string?, string?
local function run_stub(ndjson, on_complete)
  local _99 = require("99")
  local provider = stub_provider(ndjson)
  _99.setup(
    test_utils.get_test_setup_options(
      { sdk = { auto_install = false } },
      provider
    )
  )
  test_utils.create_file({ "local value = 99" }, "lua", 1, 0)

  local events = {}
  local stdout_chunks = {}
  local context = Prompt.search(_99.__get_state())
  local completed = false
  local completed_status = nil
  local completed_result = nil

  context:start_request({
    on_start = function() end,
    on_complete = function(status, result)
      completed = true
      completed_status = status
      completed_result = result
      on_complete(status, result)
    end,
    on_stdout = function(line)
      table.insert(stdout_chunks, line)
    end,
    on_stderr = function() end,
    on_event = function(event)
      table.insert(events, event)
    end,
  })

  vim.wait(2000, function()
    return completed
  end)

  return events, completed_status, completed_result, stdout_chunks
end

describe("sdk providers", function()
  it("resolves the runner script inside the plugin root", function()
    assert.matches("sdk%-runner/runner%.mjs$", Sdk.runner_script())
    eq(1, vim.fn.filereadable(Sdk.runner_script()))
  end)

  it(
    "forwards streamed events and completes from runner complete event",
    function()
      local ndjson = table.concat({
        '{"type":"text","text":"hello"}',
        '{"type":"tool_call","tool":{"name":"Read","status":"started","detail":"foo.lua"}}',
        '{"type":"complete","status":"success","result":"done"}',
      }, "\n") .. "\n"

      local events, status, result, stdout_chunks = run_stub(
        ndjson,
        function() end
      )

      assert.is_true(status ~= nil)
      eq("success", status)
      eq("done", result)
      eq({ "hello" }, stdout_chunks)

      local types = vim.tbl_map(function(event)
        return event.type
      end, events)
      eq({ "start", "text", "tool_call", "complete" }, types)
    end
  )

  it("does not spawn the runner when cancelled during install", function()
    local _99 = require("99")
    local provider = stub_provider(
      '{"type":"complete","status":"success","result":"should not run"}\n'
    )
    local pending_ready = nil
    function provider._ensure_ready(_, _, cb)
      pending_ready = cb
    end
    local built = false
    local original_build = provider._build_command
    function provider._build_command(...)
      built = true
      return original_build(...)
    end

    _99.setup(
      test_utils.get_test_setup_options(
        { sdk = { auto_install = false } },
        provider
      )
    )
    test_utils.create_file({ "local value = 99" }, "lua", 1, 0)
    local context = Prompt.search(_99.__get_state())
    local status = nil
    context:start_request({
      on_start = function() end,
      on_complete = function(s)
        status = s
      end,
      on_stdout = function() end,
      on_stderr = function() end,
    })

    context:cancel()
    assert(pending_ready, "ensure_ready was not called")
    pending_ready(true)

    eq("cancelled", status)
    eq(false, built)
  end)

  it("maps failed complete events to on_complete failed", function()
    local ndjson = '{"type":"complete","status":"failed","result":"boom"}\n'

    local _, status, result = run_stub(ndjson, function() end)

    eq("failed", status)
    eq("boom", result)
  end)

  it("skips malformed json lines between valid events", function()
    local ndjson = table.concat({
      '{"type":"text","text":"a"}',
      "not-json",
      '{"type":"complete","status":"success","result":"ok"}',
    }, "\n") .. "\n"

    local _, status, result = run_stub(ndjson, function() end)

    eq("success", status)
    eq("ok", result)
  end)

  it("fails when runner exits zero without a complete event", function()
    local ndjson = '{"type":"text","text":"partial"}\n'

    local _, status, result = run_stub(ndjson, function() end)

    eq("failed", status)
    assert.matches("no complete event", result)
  end)

  describe("ClaudeSdkProvider", function()
    it("has the expected default model", function()
      eq("sonnet", Providers.ClaudeSdkProvider._get_default_model())
    end)

    it("builds the claude sdk-runner command", function()
      local cmd = Providers.ClaudeSdkProvider._build_command(
        Providers.ClaudeSdkProvider,
        "q",
        { model = "sonnet" }
      )
      eq("node", cmd[1])
      assert.matches("runner%.mjs$", cmd[2])
      eq({ "--provider", "claude" }, { cmd[3], cmd[4] })
    end)

    it("falls back to model aliases when the runner is unavailable", function()
      local original = Sdk.is_installed
      Sdk.is_installed = function()
        return false
      end
      local got
      Providers.ClaudeSdkProvider.fetch_models(function(models)
        got = models
      end)
      Sdk.is_installed = original
      eq({ "sonnet", "opus", "haiku", "default" }, got)
    end)

    it("exposes make_request", function()
      eq("function", type(Providers.ClaudeSdkProvider.make_request))
    end)
  end)

  describe("CursorSdkProvider", function()
    it("has the expected default model", function()
      eq("composer-2.5", Providers.CursorSdkProvider._get_default_model())
    end)

    it("exposes make_request", function()
      eq("function", type(Providers.CursorSdkProvider.make_request))
    end)
  end)

  describe("OpenCodeSdkProvider", function()
    it("has the expected default model", function()
      eq(
        "opencode/claude-sonnet-4-5",
        Providers.OpenCodeSdkProvider._get_default_model()
      )
    end)

    it("exposes make_request", function()
      eq("function", type(Providers.OpenCodeSdkProvider.make_request))
    end)
  end)
end)
