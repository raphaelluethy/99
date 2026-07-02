-- luacheck: globals describe it assert
local eq = assert.are.same
local Sdk = require("99.sdk")

describe("sdk", function()
  it("derives plugin paths from this module", function()
    assert.matches("sdk%-runner$", Sdk.runner_dir())
    assert.matches("runner%.mjs$", Sdk.runner_script())
    eq(1, vim.fn.filereadable(Sdk.runner_script()))
  end)

  it("reports node availability from executable lookup", function()
    eq(vim.fn.executable("node") == 1, Sdk.node_available())
  end)

  describe("is_installed_at", function()
    it("is false without node_modules", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      eq(false, Sdk.is_installed_at(dir))
      vim.fn.delete(dir, "rf")
    end)

    it("is false when stamp does not match package.json", function()
      local dir = vim.fn.tempname()
      local node_modules = dir .. "/node_modules"
      vim.fn.mkdir(node_modules, "p")
      vim.fn.writefile({ "wrong-stamp" }, node_modules .. "/.99-stamp")
      vim.fn.writefile({ '{"name":"test"}' }, dir .. "/package.json")
      eq(false, Sdk.is_installed_at(dir))
      vim.fn.delete(dir, "rf")
    end)

    it("is true when stamp matches package.json", function()
      local dir = vim.fn.tempname()
      local node_modules = dir .. "/node_modules"
      vim.fn.mkdir(node_modules, "p")
      local package_json = '{"name":"test"}'
      vim.fn.writefile({ package_json }, dir .. "/package.json")
      local stamp = vim.fn.sha256(package_json)
      vim.fn.writefile({ stamp }, node_modules .. "/.99-stamp")
      eq(true, Sdk.is_installed_at(dir))
      vim.fn.delete(dir, "rf")
    end)
  end)
end)
