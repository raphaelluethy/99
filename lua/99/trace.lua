local M = {}

--- @param text string
--- @return string|nil
local function format_text_line(text)
  for line in vim.gsplit(text, "\n", { plain = true, trimempty = false }) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" then
      if #trimmed > 80 then
        return trimmed:sub(1, 80)
      end
      return trimmed
    end
  end
  return nil
end

--- @param event _99.Providers.Event
--- @return string|nil
function M.format(event)
  if event.type == "start" then
    return "> started"
  end

  if event.type == "text" then
    if not event.text then
      return nil
    end
    return format_text_line(event.text)
  end

  if event.type == "thinking" then
    return "~ thinking..."
  end

  if event.type == "tool_call" then
    if not event.tool then
      return nil
    end
    if event.tool.status == "started" then
      if event.tool.detail and event.tool.detail ~= "" then
        return "⚒ " .. event.tool.name .. " " .. event.tool.detail
      end
      return "⚒ " .. event.tool.name
    end
    if event.tool.status == "completed" then
      return "✓ " .. event.tool.name
    end
    return nil
  end

  if event.type == "status" then
    if not event.text or vim.trim(event.text) == "" then
      return nil
    end
    return event.text
  end

  if event.type == "usage" then
    return nil
  end

  if event.type == "complete" then
    return "= " .. (event.status or "")
  end

  return nil
end

return M
