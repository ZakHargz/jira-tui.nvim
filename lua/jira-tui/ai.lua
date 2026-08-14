local Config = require("jira-tui.config")

local M = {}

--- Hand `text` (a formatted ticket description) to whatever AI tool is
--- configured/available, trying in order:
---   1. `ai.send` — a user-supplied function, if set in setup()
---   2. sidekick.nvim (`require("sidekick.cli").send`), if installed
---   3. CopilotChat.nvim (`.ask()`), if installed
---   4. fallback: copy to the system clipboard and notify
---@param text string
function M.send(text)
  local cfg = Config.get().ai or {}

  if type(cfg.send) == "function" then
    cfg.send(text)
    return
  end

  -- sidekick.nvim: pass via its `text` option (pre-split Text[]) rather than
  -- `msg`, deliberately bypassing sidekick's `{variable}` template engine —
  -- Jira descriptions/comments can easily contain literal `{` `}` (JSON,
  -- code snippets, etc.) that would otherwise be misread as invalid context
  -- variables and silently fail to send.
  local ok_cli, sidekick_cli = pcall(require, "sidekick.cli")
  local ok_text, sidekick_text = pcall(require, "sidekick.text")
  if ok_cli and ok_text then
    sidekick_cli.send({ text = sidekick_text.to_text(text), focus = true })
    vim.notify("jira-tui: sent to sidekick AI CLI", vim.log.levels.INFO)
    return
  end

  local ok_cc, copilotchat = pcall(require, "CopilotChat")
  if ok_cc then
    copilotchat.ask(text)
    vim.notify("jira-tui: sent to CopilotChat", vim.log.levels.INFO)
    return
  end

  vim.fn.setreg("+", text)
  vim.notify(
    "jira-tui: no AI integration available — copied ticket text to the clipboard instead. "
      .. "Install sidekick.nvim or CopilotChat.nvim, or set `ai.send` in setup() (see README#ai-integration).",
    vim.log.levels.WARN
  )
end

return M
