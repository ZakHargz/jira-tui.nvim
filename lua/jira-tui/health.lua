local M = {}

function M.check()
  vim.health.start("jira-tui.nvim")

  local ok_config, cfg = pcall(function()
    return require("jira-tui.config").get()
  end)
  if not ok_config then
    vim.health.error("Failed to load configuration", { tostring(cfg) })
    return
  end

  for _, key in ipairs({ "server", "email", "project" }) do
    if cfg[key] and cfg[key] ~= "" then
      vim.health.ok(("`%s` is set (%s)"):format(key, tostring(cfg[key])))
    else
      vim.health.error(("`%s` is not set — call require('jira-tui').setup({ %s = ... })"):format(key, key))
    end
  end

  if cfg.columns and #cfg.columns > 0 then
    vim.health.ok(("%d board column(s) configured"):format(#cfg.columns))
  else
    vim.health.error("`columns` must have at least one entry")
  end

  local token = require("jira-tui.auth").token()
  if token then
    vim.health.ok("API token resolved successfully")
  else
    vim.health.error(
      "Could not resolve an API token via auth.token / $" .. (cfg.auth and cfg.auth.token_env or "JIRA_API_TOKEN")
        .. " / auth.token_file",
      { "See README.md#authentication for setup examples" }
    )
  end

  if vim.fn.executable("curl") == 1 then
    vim.health.ok("`curl` is available on $PATH")
  else
    vim.health.error("`curl` was not found on $PATH — required for all Jira API requests")
  end

  local ok_nui = pcall(require, "nui.input")
  if ok_nui then
    vim.health.ok("nui.nvim is installed (required for search `/` and label `t` inputs)")
  else
    vim.health.error("nui.nvim is not installed", { "Add \"MunifTanjim/nui.nvim\" as a dependency" })
  end

  -- AI integration: informational only, none of these are required.
  if type((cfg.ai or {}).send) == "function" then
    vim.health.ok("Custom `ai.send` configured — used instead of the built-in cascade")
  elseif pcall(require, "sidekick.cli") then
    vim.health.ok("sidekick.nvim detected — will be used for `i` (send to AI)")
  elseif pcall(require, "CopilotChat") then
    vim.health.ok("CopilotChat.nvim detected — will be used for `i` (send to AI)")
  else
    vim.health.warn(
      "No AI integration detected — `i` will just copy the ticket text to the clipboard",
      { "Install sidekick.nvim or CopilotChat.nvim, or set `ai.send` in setup()" }
    )
  end
end

return M
