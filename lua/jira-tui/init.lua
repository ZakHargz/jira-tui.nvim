local M = {}

--- Configure jira-tui.nvim. See README.md / :help jira-tui-setup for the
--- full list of options.
---@param opts? jira_tui.Config
function M.setup(opts)
  require("jira-tui.config").setup(opts)
end

--- Open the Jira Kanban TUI in a new tab.
function M.open()
  require("jira-tui.ui").open()
end

--- Synchronous getter for "the issue you're currently looking at" — intended
--- for AI-context integrations that can't await an HTTP request (e.g.
--- sidekick.nvim's `context.Fn`). Returns the issue's formatted text, or
--- `false` if there's nothing to show yet. See README.md#sidekick-integration.
---@return string|false
function M.get_current_ticket_context()
  return require("jira-tui.ui").get_current_ticket_context()
end

return M
