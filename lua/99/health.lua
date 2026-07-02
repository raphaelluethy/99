local Sdk = require("99.sdk")

local M = {}

--- @param name string
--- @param ok boolean
--- @param detail? string
local function report_binary(name, ok, detail)
  if ok then
    vim.health.ok(string.format("%s: %s", name, detail or "executable"))
  else
    vim.health.warn(string.format("%s: not found", name))
  end
end

function M.check()
  vim.health.start("99 node")
  if Sdk.node_available() then
    local version = vim.fn.trim(vim.fn.system({ "node", "--version" }))
    vim.health.ok("node: " .. version)
  else
    vim.health.error("node is not installed or not on PATH")
  end

  vim.health.start("99 sdk-runner")
  local runner_dir = Sdk.runner_dir()
  if Sdk.is_installed() then
    vim.health.ok("sdk-runner installed at " .. runner_dir)
  else
    vim.health.warn(
      "sdk-runner dependencies are not installed at "
        .. runner_dir
        .. " (run npm install or use a request to auto-install)"
    )
  end

  vim.health.start("99 provider API keys")
  if vim.env.CURSOR_API_KEY and vim.env.CURSOR_API_KEY ~= "" then
    vim.health.ok("CURSOR_API_KEY is set")
  else
    vim.health.warn(
      "CURSOR_API_KEY is not set (required for CursorSdkProvider)"
    )
  end
  if vim.env.ANTHROPIC_API_KEY and vim.env.ANTHROPIC_API_KEY ~= "" then
    vim.health.ok("ANTHROPIC_API_KEY is set")
  else
    vim.health.warn(
      "ANTHROPIC_API_KEY is not set (may be required for ClaudeSdkProvider)"
    )
  end

  vim.health.start("99 CLI providers")
  report_binary("opencode", vim.fn.executable("opencode") == 1)
  report_binary("claude", vim.fn.executable("claude") == 1)
  report_binary("agent", vim.fn.executable("agent") == 1)
  report_binary("gemini", vim.fn.executable("gemini") == 1)
  report_binary("kiro-cli", vim.fn.executable("kiro-cli") == 1)
end

return M
