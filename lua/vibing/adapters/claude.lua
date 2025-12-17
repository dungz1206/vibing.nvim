local Base = require("vibing.adapters.base")

---@class Vibing.ClaudeAdapter : Vibing.Adapter
local Claude = setmetatable({}, { __index = Base })
Claude.__index = Claude

---@param config Vibing.Config
---@return Vibing.ClaudeAdapter
function Claude:new(config)
  local instance = Base.new(self, config)
  setmetatable(instance, Claude)
  instance.name = "claude"
  return instance
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@return string[]
function Claude:build_command(prompt, opts)
  local cmd = { self.config.cli_path, "--print" }

  if opts.streaming then
    table.insert(cmd, "--verbose")
    table.insert(cmd, "--output-format")
    table.insert(cmd, "stream-json")
  end

  if opts.tools and #opts.tools > 0 then
    table.insert(cmd, "--tools")
    table.insert(cmd, table.concat(opts.tools, ","))
  end

  if opts.model then
    table.insert(cmd, "--model")
    table.insert(cmd, opts.model)
  end

  for _, ctx in ipairs(opts.context or {}) do
    table.insert(cmd, ctx)
  end

  table.insert(cmd, prompt)

  return cmd
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@return Vibing.Response
function Claude:execute(prompt, opts)
  opts = opts or {}
  opts.streaming = false
  local cmd = self:build_command(prompt, opts)
  local result = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    return { content = "", error = result }
  end

  return { content = result }
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@param on_chunk fun(chunk: string)
---@param on_done fun(response: Vibing.Response)
function Claude:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}
  opts.streaming = true
  local cmd = self:build_command(prompt, opts)
  local output = {}
  local error_output = {}
  local stdout_buffer = ""

  local handle = vim.system(cmd, {
    text = true,
    stdout = function(err, data)
      if err then return end
      if not data then return end

      -- バッファリング処理（行境界で分割）
      stdout_buffer = stdout_buffer .. data
      while true do
        local newline_pos = stdout_buffer:find("\n")
        if not newline_pos then break end

        local line = stdout_buffer:sub(1, newline_pos - 1)
        stdout_buffer = stdout_buffer:sub(newline_pos + 1)

        if line ~= "" then
          local ok, json = pcall(vim.json.decode, line)
          if ok then
            vim.schedule(function()
              -- assistant メッセージからテキストを抽出
              if json.type == "assistant" and json.message and json.message.content then
                for _, content in ipairs(json.message.content) do
                  if content.type == "text" and content.text then
                    table.insert(output, content.text)
                    on_chunk(content.text)
                  end
                end
              elseif json.type == "result" and json.result then
                if #output == 0 then
                  table.insert(output, json.result)
                  on_chunk(json.result)
                end
              end
            end)
          end
        end
      end
    end,
    stderr = function(err, data)
      if data then
        table.insert(error_output, data)
      end
    end,
  }, function(obj)
    vim.schedule(function()
      self._handle = nil
      if obj.code ~= 0 then
        on_done({ content = "", error = table.concat(error_output, "") })
      else
        on_done({ content = table.concat(output, "") })
      end
    end)
  end)

  self._handle = handle
end

---@param feature string
---@return boolean
function Claude:supports(feature)
  local features = {
    streaming = true,
    tools = true,
    model_selection = true,
    context = true,
  }
  return features[feature] or false
end

return Claude
