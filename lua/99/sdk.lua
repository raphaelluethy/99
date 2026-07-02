local M = {}

local plugin_root_cache = nil

--- @return string
function M.plugin_root()
  if plugin_root_cache then
    return plugin_root_cache
  end
  local info = debug.getinfo(1, "S")
  local source = info.source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  local dir = vim.fs.dirname(source)
  plugin_root_cache = vim.fs.dirname(dir)
  return plugin_root_cache
end

--- @return string
function M.runner_dir()
  return M.plugin_root() .. "/sdk-runner"
end

--- @return string
function M.runner_script()
  return M.runner_dir() .. "/runner.mjs"
end

--- @return boolean
function M.node_available()
  return vim.fn.executable("node") == 1
end

--- @param dir string
--- @return boolean
function M.is_installed_at(dir)
  local node_modules = dir .. "/node_modules"
  if vim.fn.isdirectory(node_modules) ~= 1 then
    return false
  end

  local stamp_path = node_modules .. "/.99-stamp"
  local package_path = dir .. "/package.json"
  if
    vim.fn.filereadable(stamp_path) ~= 1
    or vim.fn.filereadable(package_path) ~= 1
  then
    return false
  end

  local package_json = table.concat(vim.fn.readfile(package_path), "\n")
  local expected = vim.fn.sha256(package_json)
  local stamp = vim.fn.readfile(stamp_path)
  return stamp[1] == expected
end

--- @return boolean
function M.is_installed()
  return M.is_installed_at(M.runner_dir())
end

local install_in_flight = false
--- @type fun(success: boolean, err?: string)[]
local install_callbacks = {}

--- @param success boolean
--- @param err? string
local function finish_install(success, err)
  install_in_flight = false
  local callbacks = install_callbacks
  install_callbacks = {}
  for _, cb in ipairs(callbacks) do
    vim.schedule(function()
      cb(success, err)
    end)
  end
end

--- @param cb fun(success: boolean, err?: string): nil
function M.ensure_installed(cb)
  if M.is_installed() then
    vim.schedule(function()
      cb(true)
    end)
    return
  end

  table.insert(install_callbacks, cb)
  if install_in_flight then
    return
  end
  install_in_flight = true

  vim.system({
    "npm",
    "install",
    "--omit=dev",
    "--no-audit",
    "--no-fund",
  }, {
    cwd = M.runner_dir(),
    text = true,
  }, function(obj)
    if obj.code ~= 0 then
      finish_install(false, obj.stderr or "npm install failed")
      return
    end

    local package_path = M.runner_dir() .. "/package.json"
    local package_json = table.concat(vim.fn.readfile(package_path), "\n")
    local stamp = vim.fn.sha256(package_json)
    vim.fn.writefile({ stamp }, M.runner_dir() .. "/node_modules/.99-stamp")
    finish_install(true)
  end)
end

return M
