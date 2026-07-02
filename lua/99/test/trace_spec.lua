-- luacheck: globals describe it assert
local _99 = require("99")
local Trace = require("99.trace")
local Prompt = require("99.prompt")
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

--- @param start_row number
--- @param start_col number
--- @param end_row number
--- @param end_col number
--- @return _99.test.Provider, _99.Prompt, _99.Range
local function visual_setup(start_row, start_col, end_row, end_col)
  local p = test_utils.TestProvider.new()
  _99.setup(test_utils.get_test_setup_options({}, p))
  local buffer = test_utils.create_file(content, "lua", start_row, start_col)
  local start_point = Point:from_1_based(start_row, start_col)
  local end_point = Point:from_1_based(end_row, end_col)
  local range = Range:new(buffer, start_point, end_point)
  local state = _99.__get_state()
  local context = Prompt.visual(state)
  context.data.range = range
  visual_fn(context, { additional_prompt = "test prompt" })
  return p, context, range
end

describe("trace", function()
  describe("Trace.format", function()
    it("formats start events", function()
      eq("> started", Trace.format({ type = "start" }))
    end)

    it("formats text events from the first non-empty line", function()
      eq("hello", Trace.format({ type = "text", text = "\n  hello  \nworld" }))
    end)

    it("returns nil for empty text events", function()
      eq(nil, Trace.format({ type = "text", text = "\n   \n" }))
      eq(nil, Trace.format({ type = "text" }))
    end)

    it("truncates text events to 80 characters", function()
      local long = string.rep("x", 100)
      eq(string.rep("x", 80), Trace.format({ type = "text", text = long }))
    end)

    it("formats thinking events", function()
      eq("~ thinking...", Trace.format({ type = "thinking" }))
    end)

    it("formats tool_call started events", function()
      eq(
        "⚒ read_file path.lua",
        Trace.format({
          type = "tool_call",
          tool = {
            name = "read_file",
            status = "started",
            detail = "path.lua",
          },
        })
      )
      eq(
        "⚒ grep",
        Trace.format({
          type = "tool_call",
          tool = { name = "grep", status = "started" },
        })
      )
    end)

    it("formats tool_call completed events", function()
      eq(
        "✓ read_file",
        Trace.format({
          type = "tool_call",
          tool = { name = "read_file", status = "completed" },
        })
      )
    end)

    it("formats status events", function()
      eq("working", Trace.format({ type = "status", text = "working" }))
      eq(nil, Trace.format({ type = "status", text = "   " }))
    end)

    it("returns nil for usage events", function()
      eq(nil, Trace.format({ type = "usage" }))
    end)

    it("formats complete events", function()
      eq("= success", Trace.format({ type = "complete", status = "success" }))
    end)
  end)

  describe("Prompt trace", function()
    it("records events through the request pipeline", function()
      local p, context = visual_setup(2, 1, 2, 23)

      eq({ "> started" }, context:trace_lines(10))

      p:emit({ type = "text", text = "first line\nsecond line" })
      p:emit({
        type = "tool_call",
        tool = { name = "grep", status = "started", detail = "pattern" },
      })
      p:emit({
        type = "tool_call",
        tool = { name = "grep", status = "completed" },
      })

      eq({
        "> started",
        "first line",
        "⚒ grep pattern",
        "✓ grep",
      }, context:trace_lines(10))

      p:resolve("success", "done")
      eq({
        "> started",
        "first line",
        "⚒ grep pattern",
        "✓ grep",
        "= success",
      }, context:trace_lines(10))
    end)

    it("bounds the ring buffer to 50 entries", function()
      local state = _99.__get_state()
      local context = Prompt.search(state)
      for i = 1, 60 do
        context:push_trace("line-" .. i)
      end
      eq(50, #context.trace)
      eq("line-11", context.trace[1])
      eq("line-60", context.trace[50])
      eq({
        "line-51",
        "line-52",
        "line-53",
        "line-54",
        "line-55",
        "line-56",
        "line-57",
        "line-58",
        "line-59",
        "line-60",
      }, context:trace_lines(10))
    end)

    it("collapses consecutive duplicate lines", function()
      local state = _99.__get_state()
      local context = Prompt.search(state)
      context:push_trace("~ thinking...")
      context:push_trace("~ thinking...")
      context:push_trace("done")
      context:push_trace("done")
      eq({ "~ thinking...", "done" }, context.trace)
    end)

    it("collapses consecutive thinking events from the pipeline", function()
      local p, context = visual_setup(2, 1, 2, 23)

      p:emit({ type = "thinking" })
      p:emit({ type = "thinking" })
      p:emit({ type = "text", text = "answer" })

      eq({
        "> started",
        "~ thinking...",
        "answer",
      }, context:trace_lines(10))
    end)
  end)
end)
