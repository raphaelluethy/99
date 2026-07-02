-- luacheck: globals describe it assert after_each
local _99 = require("99")
local Prompt = require("99.prompt")
local Window = require("99.window")
local test_utils = require("99.test.test_utils")
local visual_fn = require("99.ops.over-range")
local Range = require("99.geo").Range
local Point = require("99.geo").Point
local eq = assert.are.same

local content = {
  "local function foo()",
  "    -- TODO: implement",
  "end",
}

local original_nvim_list_uis = vim.api.nvim_list_uis
local function nvim_list_uis()
  return {
    { width = 120, height = 40 },
  }
end

--- @param start_row number
--- @param start_col number
--- @param end_row number
--- @param end_col number
--- @param opts _99.Options | nil
--- @return _99.test.Provider, _99.Prompt
local function visual_setup(start_row, start_col, end_row, end_col, opts)
  opts = opts or {}
  opts.in_flight_options = vim.tbl_deep_extend("force", {
    throbber_opts = {
      tick_time = 10,
      throb_time = 1000,
      cooldown_time = 500,
    },
    in_flight_interval = 10,
    enable = true,
  }, opts.in_flight_options or {})

  local p = test_utils.TestProvider.new()
  _99.setup(test_utils.get_test_setup_options(opts, p))
  local buffer = test_utils.create_file(content, "lua", start_row, start_col)
  local start_point = Point:from_1_based(start_row, start_col)
  local end_point = Point:from_1_based(end_row, end_col)
  local range = Range:new(buffer, start_point, end_point)
  local state = _99.__get_state()
  local context = Prompt.visual(state)
  context.data.range = range
  visual_fn(context, { additional_prompt = "test prompt" })
  return p, context
end

--- @param predicate fun(lines: string[]): boolean
--- @return string[]
local function wait_for_status_lines(predicate)
  local lines = {}
  vim.wait(1000, function()
    if #Window.active_windows == 0 then
      return false
    end
    local win = Window.active_windows[1]
    lines = vim.api.nvim_buf_get_lines(win.buf_id, 0, -1, false)
    return predicate(lines)
  end)
  return lines
end

describe("agent trace status window", function()
  before_each(function()
    vim.api.nvim_list_uis = nvim_list_uis
    Window.clear_active_popups()
  end)

  after_each(function()
    _99.stop_all_requests()
    vim.api.nvim_list_uis = original_nvim_list_uis
    Window.clear_active_popups()
  end)

  --- @param p _99.test.Provider
  local function finish_request(p)
    p:resolve("success", "done")
    vim.wait(1000, function()
      return #Window.active_windows == 0
    end)
  end

  it("shows trace lines after the operation when enabled", function()
    local p = visual_setup(2, 1, 2, 23, {
      in_flight_options = {
        agent_trace = { enable = true, max_lines = 3 },
      },
    })

    p:emit({ type = "text", text = "hello" })
    p:emit({
      type = "tool_call",
      tool = { name = "grep", status = "started", detail = "x" },
    })

    local lines = wait_for_status_lines(function(buf_lines)
      for _, line in ipairs(buf_lines) do
        if line:match("^  hello$") then
          return true
        end
      end
      return false
    end)

    assert.matches("requests%(1%)", lines[1])
    eq("visual", lines[2])
    eq("  > started", lines[3])
    eq("  hello", lines[4])
    eq("  ⚒ grep x", lines[5])

    finish_request(p)
  end)

  it("respects max_lines per request", function()
    local p, context = visual_setup(2, 1, 2, 23, {
      in_flight_options = {
        agent_trace = { enable = true, max_lines = 3 },
      },
    })

    for i = 1, 5 do
      p:emit({ type = "text", text = "line-" .. i .. "\n" })
    end

    eq({
      "line-3",
      "line-4",
      "line-5",
    }, context:trace_lines(3))

    local lines = wait_for_status_lines(function(buf_lines)
      return #buf_lines == 5
        and buf_lines[3] == "  line-3"
        and buf_lines[4] == "  line-4"
        and buf_lines[5] == "  line-5"
    end)

    eq("visual", lines[2])
    eq("  line-3", lines[3])
    eq("  line-4", lines[4])
    eq("  line-5", lines[5])
    eq(nil, lines[6])

    finish_request(p)
  end)

  it("keeps a fixed width and truncates long tool call lines", function()
    local p = visual_setup(2, 1, 2, 23, {
      in_flight_options = {
        agent_trace = { enable = true, max_lines = 5 },
      },
    })

    p:emit({ type = "text", text = "short\n" })
    wait_for_status_lines(function(buf_lines)
      for _, line in ipairs(buf_lines) do
        if line:match("short") then
          return true
        end
      end
      return false
    end)

    local expected_width = Window.status_window_max_width(true)
    eq(
      expected_width,
      vim.api.nvim_win_get_config(Window.active_windows[1].win_id).width
    )

    p:emit({
      type = "tool_call",
      tool = {
        name = "read",
        status = "started",
        detail = string.rep("/very-long-path-segment", 10) .. ".lua",
      },
    })

    local lines = wait_for_status_lines(function(buf_lines)
      for _, line in ipairs(buf_lines) do
        if line:match("read") then
          return true
        end
      end
      return false
    end)

    eq(
      expected_width,
      vim.api.nvim_win_get_config(Window.active_windows[1].win_id).width
    )
    for _, line in ipairs(lines) do
      assert(
        vim.fn.strdisplaywidth(line) <= expected_width,
        "line overflows window: " .. line
      )
    end

    finish_request(p)
  end)

  it("does not show trace lines when disabled", function()
    local p = visual_setup(2, 1, 2, 23, {
      in_flight_options = {
        agent_trace = { enable = false },
      },
    })

    p:emit({ type = "text", text = "hello" })
    p:emit({
      type = "tool_call",
      tool = { name = "grep", status = "started", detail = "x" },
    })

    local lines = wait_for_status_lines(function(buf_lines)
      return #buf_lines >= 2
    end)

    assert.matches("requests%(1%)", lines[1])
    eq("visual", lines[2])
    eq(nil, lines[3])
    eq(
      Window.status_window_max_width(false),
      vim.api.nvim_win_get_config(Window.active_windows[1].win_id).width
    )

    finish_request(p)
  end)
end)
