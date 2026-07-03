local CleanUp = require("99.ops.clean-up")
local Window = require("99.window")
local make_prompt = require("99.ops.make-prompt")
local Range = require("99.geo").Range

local make_observer = CleanUp.make_observer

local function preserve_visual_marks()
  local mode = vim.api.nvim_get_mode().mode
  if mode == "visual" or mode == "linewise" or mode == "blockwise" then
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
      "x",
      false
    )
  end
end

--- @param context _99.Prompt
--- @return string|nil
local function visual_selection_prompt(context)
  if vim.fn.line("'<") == 0 or vim.fn.line("'>") == 0 then
    return nil
  end

  local ok, range = pcall(Range.from_visual_selection)
  if not ok then
    return nil
  end

  return context._99.prompts.prompts.visual_selection(range)
end

--- @param context _99.Prompt
---@param response string
---@return _99.Prompt.Data.Question
local function open_question(context, response)
  local content = vim.split(response, "\n")
  local win = Window.create_split(content)

  --- @type _99.Prompt.Data.Question
  local data = {
    type = "question",
    buffer = win.buffer,
    window = win.win,
    xid = context.xid,
    question = content,
  }
  context.data = data
  return data
end

--- @param context _99.Prompt
---@param opts _99.ops.Opts
local function question(context, opts)
  opts = opts or {}

  local logger = context.logger:set_area("question")
  logger:debug("starting", "with opts", opts)

  preserve_visual_marks()

  local system_cmd = context._99.prompts.prompts.question()
  local selection_prompt = visual_selection_prompt(context)
  if selection_prompt then
    system_cmd = system_cmd .. "\n" .. selection_prompt
    logger:debug("including visual selection in question prompt")
  end

  local prompt, refs = make_prompt(context, system_cmd, opts)

  context:add_references(refs)
  context:add_prompt_content(prompt)

  context:start_request(make_observer(context, function(status, response)
    if status == "cancelled" then
      logger:debug("cancelled")
    elseif status == "failed" then
      logger:error(
        "failed",
        "error response",
        response or "no response provided"
      )
    elseif status == "success" then
      open_question(context, response)
      context._99:sync()
    end
  end))
end
return question
