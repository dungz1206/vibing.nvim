local Config = require("vibing.config")

---@class Vibing
---@field config Vibing.Config
---@field adapter Vibing.Adapter
local M = {}

---@type Vibing.Adapter?
M.adapter = nil

---@param opts? Vibing.Config
function M.setup(opts)
  Config.setup(opts)
  M.config = Config.get()

  -- アダプターの初期化
  local adapter_name = M.config.adapter
  local ok, adapter_module = pcall(require, "vibing.adapters." .. adapter_name)
  if not ok then
    vim.notify(
      string.format("[vibing.nvim] Adapter '%s' not found", adapter_name),
      vim.log.levels.ERROR
    )
    return
  end

  M.adapter = adapter_module:new(M.config)

  -- コマンド登録
  M._register_commands()
end

---コマンドを登録
function M._register_commands()
  vim.api.nvim_create_user_command("VibingChat", function()
    require("vibing.actions.chat").open()
  end, { desc = "Open Vibing chat" })

  vim.api.nvim_create_user_command("VibingContext", function(opts)
    require("vibing.context").add(opts.args)
  end, { nargs = "?", desc = "Add context to Vibing", complete = "file" })

  vim.api.nvim_create_user_command("VibingClearContext", function()
    require("vibing.context").clear()
  end, { desc = "Clear Vibing context" })

  vim.api.nvim_create_user_command("VibingInline", function(opts)
    require("vibing.actions.inline").execute(opts.args)
  end, { nargs = "?", range = true, desc = "Run inline action" })

  vim.api.nvim_create_user_command("VibingCancel", function()
    if M.adapter then
      M.adapter:cancel()
    end
  end, { desc = "Cancel current Vibing request" })

  vim.api.nvim_create_user_command("VibingOpenChat", function(opts)
    require("vibing.actions.chat").open_file(opts.args)
  end, { nargs = 1, desc = "Open saved chat file", complete = "file" })

  -- 保存済みチャットファイルを自動検出
  vim.api.nvim_create_autocmd("BufReadPost", {
    pattern = "*.md",
    callback = function(ev)
      local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, 5, false)
      -- フロントマターにvibing.nvimマーカーがあるかチェック
      local is_vibing_chat = false
      for _, line in ipairs(lines) do
        if line:match("^vibing%.nvim:") then
          is_vibing_chat = true
          break
        end
      end

      if is_vibing_chat then
        vim.schedule(function()
          require("vibing.actions.chat").attach_to_buffer(ev.buf, ev.file)
        end)
      end
    end,
  })
end

---@return Vibing.Adapter?
function M.get_adapter()
  return M.adapter
end

---@return Vibing.Config
function M.get_config()
  return M.config or Config.defaults
end

return M
