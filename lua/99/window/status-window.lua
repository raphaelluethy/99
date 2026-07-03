local Window = require("99.window")
local Consts = require("99.consts")
local Throbber = require("99.ops.throbber")

--- @alias _99.StatusWindow.State "init" | "running"

--- @class _99.StatusWindow.AgentTraceOpts
--- @docs include
--- Options for live agent trace lines in the status window.
--- @field enable boolean | nil
--- When true, stream trace lines (text, tool calls) under each active request.
--- defaults to false
--- @field max_lines number | nil
--- Maximum trace lines shown per active request.
--- defaults to 8

--- @class _99.StatusWindow.Opts
--- Controls the in-flight status window shown while requests run.
--- @docs include
--- @field throbber_opts _99.Throbber.Opts | nil
--- options for the throbber in the top left
--- @field in_flight_interval number | nil
--- frequency in which the in-flight interval checks to see if it should be
--- displayed / removed
--- @field enable boolean | nil
--- When false, the status window is not shown.
--- defaults to true
--- @field agent_trace _99.StatusWindow.AgentTraceOpts | nil
--- Live trace display for SDK providers; widens the window to one third of the
--- editor width and truncates lines to fit.

--- @param line string
--- @param width number
--- @return string
local function truncate_line(line, width)
  if vim.fn.strdisplaywidth(line) <= width then
    return line
  end
  line = vim.fn.strcharpart(line, 0, width)
  while vim.fn.strdisplaywidth(line) > width do
    line = vim.fn.strcharpart(line, 0, vim.fn.strchars(line) - 1)
  end
  return line
end

--- @param agent_trace _99.StatusWindow.AgentTraceOpts | nil
--- @return _99.StatusWindow.AgentTraceOpts
local function default_agent_trace_opts(agent_trace)
  agent_trace = agent_trace or {}
  agent_trace.enable = agent_trace.enable == nil and false or agent_trace.enable
  agent_trace.max_lines = agent_trace.max_lines or 8
  return agent_trace
end

--- @param opts _99.StatusWindow.Opts | nil
--- @return _99.StatusWindow.Opts
local function default_opts(opts)
  opts = opts or {}
  opts.throbber_opts = opts.throbber_opts
    or {
      throb_time = Consts.throbber_throb_time,
      cooldown_time = Consts.throbber_cooldown_time,
      tick_time = Consts.throbber_tick_time,
    }
  opts.in_flight_interval = opts.in_flight_interval
    or Consts.show_in_flight_requests_loop_time
  opts.enable = opts.enable == nil and true or opts.enable
  opts.agent_trace = default_agent_trace_opts(opts.agent_trace)
  return opts
end

--- @class _99.StatusWindow
--- @field opts _99.StatusWindow.Opts
--- @field state _99.StatusWindow.State
--- @field win _99.window.Window | nil
--- @field throbber _99.Throbber | nil
--- @field _99 _99.State
local StatusWindow = {}
StatusWindow.__index = StatusWindow

--- @param _99 _99.State
--- @param opts _99.StatusWindow.Opts | nil
function StatusWindow.new(_99, opts)
  return setmetatable({
    opts = default_opts(opts),
    state = "init",
    _99 = _99,
  }, StatusWindow)
end

function StatusWindow:_shutdown_status_window()
  if self.throbber then
    self.throbber:stop()
  end

  local win = self.win
  if win ~= nil then
    Window.close(win)
  end
  self.win = nil
  self.throbber = nil
end

function StatusWindow:_run_loop()
  if self.state ~= "running" then
    self:_shutdown_status_window()
    return
  end
  vim.defer_fn(function()
    self:_run_loop()
  end, self.opts.in_flight_interval)

  Window.refresh_active_windows()
  local current_win = self.win
  if current_win ~= nil and not Window.is_active_window(current_win) then
    self:_shutdown_status_window()
  end

  local active_window = Window.has_active_status_window()
  local active_other_window = Window.has_active_windows()
  local active_requests = self._99.tracking:active_count()
  if
    active_window == false and active_other_window
    or active_window and active_requests > 0
    or active_window == false and active_requests == 0
  then
    return
  end

  if current_win == nil then
    local ok, win = pcall(Window.status_window)
    if not ok then
      --- TODO: There needs to be a way to display logs for "all active requests"
      --- this is its own activity and should not be added to any work set
      return
    end

    local throb = Throbber.new(function(throb)
      local count = self._99.tracking:active_count()
      local win_valid = Window.valid(win)

      if count == 0 or not win_valid then
        return self:_shutdown_status_window()
      end

      --- @type string[]
      local lines = {
        throb .. " requests(" .. tostring(count) .. ") " .. throb,
      }

      local agent_trace = self.opts.agent_trace
      for _, c in ipairs(self._99.tracking:active()) do
        if c.state == "requesting" then
          table.insert(lines, c.operation)
          if agent_trace.enable then
            for _, trace_line in ipairs(c:trace_lines(agent_trace.max_lines)) do
              table.insert(lines, "  " .. trace_line)
            end
          end
        end
      end

      local width = Window.status_window_max_width(agent_trace.enable)
      for i, line in ipairs(lines) do
        lines[i] = truncate_line(line, width)
      end
      Window.resize(win, width, #lines)
      vim.api.nvim_buf_set_lines(win.buf_id, 0, -1, false, lines)
    end, self.opts.throbber_opts)

    self.win = win
    self.throbber = throb

    throb:start()
  end
end

function StatusWindow:start()
  if not self.opts.enable then
    return
  end

  assert(
    self.state == "init",
    "you cannot start an inflight request if we are not in init state: "
      .. self.state
  )

  self.state = "running"
  self:_run_loop()
end

function StatusWindow:stop()
  if not self.opts.enable then
    return
  end
  assert(
    self.state == "running",
    "you cannot stop a running status window if its not running"
  )
  self.state = "init"
end

return StatusWindow
