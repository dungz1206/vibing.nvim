---@class Vibing.AdapterOpts
---@field context string[] Array of @file: formatted contexts
---@field tools string[]? Allowed tools
---@field model string? Model override
---@field streaming boolean? Enable streaming

---@class Vibing.Response
---@field content string Response content
---@field error string? Error message if failed

---@class Vibing.Adapter
---@field name string Adapter name
---@field config Vibing.Config
---@field job_id number? Current job ID
local Adapter = {}
Adapter.__index = Adapter

---@param config Vibing.Config
---@return Vibing.Adapter
function Adapter:new(config)
  local instance = setmetatable({}, self)
  instance.name = "base"
  instance.config = config
  instance.job_id = nil
  return instance
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@return Vibing.Response
function Adapter:execute(prompt, opts)
  error("execute() must be implemented by subclass")
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@param on_chunk fun(chunk: string)
---@param on_done fun(response: Vibing.Response)
function Adapter:stream(prompt, opts, on_chunk, on_done)
  error("stream() must be implemented by subclass")
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@return string[]
function Adapter:build_command(prompt, opts)
  error("build_command() must be implemented by subclass")
end

---@return boolean
function Adapter:cancel()
  if self.job_id then
    vim.fn.jobstop(self.job_id)
    self.job_id = nil
    return true
  end
  return false
end

---@param feature string
---@return boolean
function Adapter:supports(feature)
  return false
end

return Adapter
