local Base = require("vibing.adapters.base")

---@class Vibing.ClaudeACPAdapter : Vibing.Adapter
---@field _handle table?
---@field _state { next_id: number, stdout_buffer: string, pending: table, session_id: string? }
local ClaudeACP = setmetatable({}, { __index = Base })
ClaudeACP.__index = ClaudeACP

local METHODS = {
  INITIALIZE = "initialize",
  SESSION_NEW = "session/new",
  SESSION_PROMPT = "session/prompt",
  SESSION_CANCEL = "session/cancel",
  SESSION_UPDATE = "session/update",
}

---@param config Vibing.Config
---@return Vibing.ClaudeACPAdapter
function ClaudeACP:new(config)
  local instance = Base.new(self, config)
  setmetatable(instance, ClaudeACP)
  instance.name = "claude_acp"
  instance._handle = nil
  instance._state = {
    next_id = 1,
    stdout_buffer = "",
    pending = {},
    session_id = nil,
  }
  return instance
end

---@return string[]
function ClaudeACP:build_command()
  return { "claude-code-acp" }
end

---Send JSON-RPC message
---@param method string
---@param params table?
---@param callback fun(result: table?, error: table?)?
function ClaudeACP:send_rpc(method, params, callback)
  if not self._handle then return end

  local id = self._state.next_id
  self._state.next_id = id + 1

  local msg = vim.json.encode({
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or {},
  }) .. "\n"

  if callback then
    self._state.pending[id] = callback
  end

  self._handle:write(msg)
  return id
end

---Send notification (no response expected)
---@param method string
---@param params table?
function ClaudeACP:send_notification(method, params)
  if not self._handle then return end

  local msg = vim.json.encode({
    jsonrpc = "2.0",
    method = method,
    params = params or {},
  }) .. "\n"

  self._handle:write(msg)
end

---Handle stdout data with buffering
---@param data string
---@param on_chunk fun(chunk: string)
function ClaudeACP:handle_stdout(data, on_chunk)
  self._state.stdout_buffer = self._state.stdout_buffer .. data

  while true do
    local newline_pos = self._state.stdout_buffer:find("\n")
    if not newline_pos then break end

    local line = self._state.stdout_buffer:sub(1, newline_pos - 1):gsub("\r$", "")
    self._state.stdout_buffer = self._state.stdout_buffer:sub(newline_pos + 1)

    if line ~= "" and line:match("^%s*{") then
      local ok, msg = pcall(vim.json.decode, line)
      if ok then
        self:handle_rpc_message(msg, on_chunk)
      end
    end
  end
end

---Handle JSON-RPC message
---@param msg table
---@param on_chunk fun(chunk: string)
function ClaudeACP:handle_rpc_message(msg, on_chunk)
  -- Response to our request
  if msg.id and not msg.method then
    vim.notify("[ACP] Response id=" .. msg.id, vim.log.levels.DEBUG)
    local callback = self._state.pending[msg.id]
    if callback then
      self._state.pending[msg.id] = nil
      if msg.error then
        vim.notify("[ACP] Error: " .. vim.inspect(msg.error), vim.log.levels.ERROR)
        callback(nil, msg.error)
      else
        callback(msg.result, nil)
      end
    end
    return
  end

  -- Notification from server
  if msg.method == METHODS.SESSION_UPDATE and msg.params then
    local update = msg.params.update
    if update then
      local update_type = update.sessionUpdate or "unknown"
      vim.notify("[ACP] Update: " .. update_type, vim.log.levels.DEBUG)
      if update_type == "agent_message_chunk" then
        local content = update.content
        if content and content.type == "text" and content.text then
          vim.notify("[ACP] Chunk: " .. content.text:sub(1, 50), vim.log.levels.INFO)
          on_chunk(content.text)
        end
      end
    end
  end
end

---Start ACP process and initialize session
---@param on_ready fun(success: boolean)
---@param on_chunk fun(chunk: string)
---@param on_done fun(response: Vibing.Response)
function ClaudeACP:start(on_ready, on_chunk, on_done)
  if self._handle then
    on_ready(true)
    return
  end

  local cmd = self:build_command()
  self._state.stdout_buffer = ""
  self._state.pending = {}

  self._handle = vim.system(cmd, {
    stdin = true,
    stdout = function(err, data)
      if err then return end
      if data then
        vim.schedule(function()
          self:handle_stdout(data, on_chunk)
        end)
      end
    end,
    stderr = function(err, data)
      if data then
        vim.schedule(function()
          vim.notify("[vibing] ACP stderr: " .. data, vim.log.levels.DEBUG)
        end)
      end
    end,
  }, function(obj)
    vim.schedule(function()
      self._handle = nil
      self._state.session_id = nil
      on_done({ content = "", error = obj.code ~= 0 and "Process exited" or nil })
    end)
  end)

  -- Initialize
  self:send_rpc(METHODS.INITIALIZE, {
    protocolVersion = 1,
    clientCapabilities = {
      fs = { readTextFile = true, writeTextFile = true },
    },
    clientInfo = {
      name = "vibing.nvim",
      version = "1.0.0",
    },
  }, function(result, err)
    if err then
      on_ready(false)
      return
    end

    -- Create session
    self:send_rpc(METHODS.SESSION_NEW, {
      cwd = vim.fn.getcwd(),
      mcpServers = {},
    }, function(session_result, session_err)
      if session_err or not session_result or not session_result.sessionId then
        on_ready(false)
        return
      end
      self._state.session_id = session_result.sessionId
      on_ready(true)
    end)
  end)
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@return Vibing.Response
function ClaudeACP:execute(prompt, opts)
  -- ACP is streaming-only, use stream internally
  local result = { content = "" }
  local done = false

  self:stream(prompt, opts, function(chunk)
    result.content = result.content .. chunk
  end, function(response)
    if response.error then
      result.error = response.error
    end
    done = true
  end)

  -- Wait for completion (blocking)
  vim.wait(60000, function() return done end, 100)
  return result
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@param on_chunk fun(chunk: string)
---@param on_done fun(response: Vibing.Response)
function ClaudeACP:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}
  local output = {}

  local function do_prompt()
    -- Build prompt content blocks (ACP format: array of content blocks, no role)
    local prompt_blocks = {}

    -- Add context files as resource blocks
    for _, ctx in ipairs(opts.context or {}) do
      if ctx:match("^@file:") then
        local path = ctx:sub(7)
        local ok, content = pcall(function()
          return table.concat(vim.fn.readfile(path), "\n")
        end)
        if ok and content then
          table.insert(prompt_blocks, {
            type = "resource",
            resource = {
              uri = "file://" .. path,
              text = content,
            },
          })
        end
      end
    end

    -- Add user prompt as text block
    table.insert(prompt_blocks, {
      type = "text",
      text = prompt,
    })

    self:send_rpc(METHODS.SESSION_PROMPT, {
      sessionId = self._state.session_id,
      prompt = prompt_blocks,
    }, function(result, err)
      if err then
        on_done({ content = table.concat(output, ""), error = err.message or "Unknown error" })
      else
        on_done({ content = table.concat(output, "") })
      end
    end)
  end

  -- Wrap on_chunk to collect output
  local wrapped_on_chunk = function(chunk)
    table.insert(output, chunk)
    on_chunk(chunk)
  end

  -- Start or reuse connection
  if self._handle and self._state.session_id then
    -- Reuse existing session - update on_chunk handler
    self._current_on_chunk = wrapped_on_chunk
    do_prompt()
  else
    self._current_on_chunk = wrapped_on_chunk
    self:start(function(success)
      if not success then
        on_done({ content = "", error = "Failed to start ACP" })
        return
      end
      do_prompt()
    end, function(chunk)
      -- Delegate to current handler
      if self._current_on_chunk then
        self._current_on_chunk(chunk)
      end
    end, on_done)
  end
end

function ClaudeACP:cancel()
  if self._handle and self._state.session_id then
    self:send_notification(METHODS.SESSION_CANCEL, {
      sessionId = self._state.session_id,
    })
  end
end

---@param feature string
---@return boolean
function ClaudeACP:supports(feature)
  local features = {
    streaming = true,
    tools = true,
    model_selection = false,
    context = true,
  }
  return features[feature] or false
end

return ClaudeACP
