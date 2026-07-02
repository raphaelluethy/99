--- @class _99.Ndjson
--- @field buffer string
--- @field dropped number
local Ndjson = {}
Ndjson.__index = Ndjson

--- @return _99.Ndjson
function Ndjson.new()
  return setmetatable({
    buffer = "",
    dropped = 0,
  }, Ndjson)
end

--- @param line string
--- @return table|nil
function Ndjson:_decode_line(line)
  if vim.trim(line) == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, line)
  if ok and type(decoded) == "table" then
    return decoded
  end
  self.dropped = self.dropped + 1
  return nil
end

--- @param chunk string
--- @return table[]
function Ndjson:feed(chunk)
  self.buffer = self.buffer .. chunk
  local events = {}

  while true do
    local newline_pos = self.buffer:find("\n", 1, true)
    if not newline_pos then
      break
    end
    local line = self.buffer:sub(1, newline_pos - 1)
    self.buffer = self.buffer:sub(newline_pos + 1)
    local decoded = self:_decode_line(line)
    if decoded then
      table.insert(events, decoded)
    end
  end

  return events
end

--- @return table[]
function Ndjson:flush()
  local events = {}
  if self.buffer ~= "" then
    local decoded = self:_decode_line(self.buffer)
    if decoded then
      table.insert(events, decoded)
    end
    self.buffer = ""
  end
  return events
end

return Ndjson
