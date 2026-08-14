local M = {}

---@class jira_tui.Column
---@field name string Display name for the column header.
---@field statuses string[] Jira status ids and/or names that map into this
---  column. Matched against both `status.id` and `status.name`, so you can
---  mix either (names are usually easier to set up; ids disambiguate two
---  differently-workflowed statuses that happen to share a name).

---@class jira_tui.AuthConfig
---@field token? string|fun():string? API token, or a function returning one
---  (called each time a request is made — handy for reading it out of a
---  password manager, wrapping another CLI tool's config file, etc.).
---@field token_env? string Env var to fall back to. Default: "JIRA_API_TOKEN".
---@field token_file? string Path to a plain-text file containing just the
---  token (whitespace-trimmed). Tried after `token`/`token_env`.

---@class jira_tui.AiConfig
---@field send? fun(text: string) Called with the formatted ticket text when
---  you press `i`. Overrides the built-in cascade entirely. If omitted,
---  defaults to: sidekick.nvim if installed -> CopilotChat.nvim if installed
---  -> copy to the clipboard.

---@class jira_tui.Config
---@field server? string Your Atlassian site, e.g. "https://yourteam.atlassian.net"
---@field email? string Your Atlassian account email
---@field project? string Jira project key, e.g. "ABC"
---@field board_name? string Label shown in the list pane's winbar. Default: "Board".
---@field extra_jql? string Optional extra clause AND-ed onto every board
---  query, e.g. a custom-field team filter: '"Team[Team]" = "..."'.
---@field max_results? integer Max issues fetched per board load. Default: 200.
---@field columns? jira_tui.Column[]
---@field auth? jira_tui.AuthConfig
---@field ai? jira_tui.AiConfig

---@type jira_tui.Config
local defaults = {
  server = nil,
  email = nil,
  project = nil,
  board_name = "Board",
  extra_jql = nil,
  max_results = 200,
  columns = {
    { name = "To Do", statuses = { "To Do", "Open", "Backlog" } },
    { name = "In Progress", statuses = { "In Progress" } },
    { name = "In Review", statuses = { "In Review", "Ready For Review" } },
    { name = "Done", statuses = { "Done", "Closed" } },
  },
  auth = {
    token = nil,
    token_env = "JIRA_API_TOKEN",
    token_file = nil,
  },
  ai = {
    send = nil,
  },
}

local options ---@type jira_tui.Config

--- Merge `opts` over the defaults and validate required fields.
---@param opts? jira_tui.Config
function M.setup(opts)
  options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  local missing = {}
  for _, key in ipairs({ "server", "email", "project" }) do
    if not options[key] or options[key] == "" then
      table.insert(missing, key)
    end
  end
  if #missing > 0 then
    vim.notify(
      ("jira-tui.nvim: missing required setup() field(s): %s — see :help jira-tui-setup"):format(
        table.concat(missing, ", ")
      ),
      vim.log.levels.ERROR
    )
  end

  if not options.columns or #options.columns == 0 then
    vim.notify("jira-tui.nvim: `columns` must have at least one entry", vim.log.levels.ERROR)
  end
end

--- Current merged config. Falls back to bare defaults (with a warning) if
--- `setup()` was never called, so `require("jira-tui").open()` doesn't hard
--- crash — it'll just fail the "server/email/project missing" check above
--- via a lazily-triggered setup({}).
---@return jira_tui.Config
function M.get()
  if not options then
    M.setup({})
  end
  return options
end

return M
