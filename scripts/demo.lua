-- Standalone demo launcher for generating README screenshots/GIFs.
-- Populates the board with fake/sample data (no real Jira credentials or
-- network calls) so screenshots never leak real ticket content.
--
-- Self-contained: fetches its own throwaway copies of nui.nvim (a hard
-- dependency) and neovim-ayu (cosmetic only, matches this repo's own
-- screenshots) via `vim.pack`, so it works for any contributor without
-- assuming anything about their existing Neovim setup.
--
-- Usage: nvim --clean -u scripts/demo.lua
-- Or, to regenerate the README screenshot/gif: vhs scripts/demo.tape
-- (run from the repo root; see scripts/demo.tape)

local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

vim.opt.runtimepath:append(repo_root)
vim.pack.add({
  "https://github.com/MunifTanjim/nui.nvim",
  "https://github.com/Shatur/neovim-ayu",
}, { confirm = false })

vim.cmd("filetype plugin on")
vim.cmd("syntax on")

require("ayu").setup({ mirage = true, terminal = true })
require("ayu").colorscheme()

vim.o.termguicolors = true
vim.o.laststatus = 0
vim.o.showtabline = 0
vim.o.cmdheight = 1
vim.o.number = false
vim.o.signcolumn = "no"

require("jira-tui").setup({
  server = "https://acme.atlassian.net",
  email = "dev@acme.example",
  project = "DEMO",
  board_name = "Product Board",
  auth = { token = "demo" },
})

-- Stub vim.system so no real network call is ever made — everything below
-- is fake sample data.
vim.system = function(cmd, opts, cb)
  local url = cmd[#cmd]
  if url:match("/issue/") then
    cb({
      code = 0,
      stdout = vim.json.encode({
        key = "DEMO-142",
        fields = {
          summary = "Add dark mode toggle to settings panel",
          status = { name = "In Progress" },
          issuetype = { name = "Story" },
          priority = { name = "High" },
          assignee = { displayName = "Jordan Blake" },
          reporter = { displayName = "Sam Rivera" },
          created = "2026-08-01T09:12:00.000+0000",
          updated = "2026-08-13T16:40:00.000+0000",
          labels = { "frontend", "ui-polish" },
          description = {
            type = "doc",
            version = 1,
            content = {
              {
                type = "paragraph",
                content = {
                  { type = "text", text = "Users have asked for a dark mode toggle in the settings panel. Should respect the OS-level preference by default, with a manual override." },
                },
              },
            },
          },
          comment = {
            comments = {
              {
                author = { displayName = "Sam Rivera" },
                created = "2026-08-12T11:05:00.000+0000",
                body = {
                  type = "doc",
                  version = 1,
                  content = {
                    { type = "paragraph", content = { { type = "text", text = "Design mockups are in Figma, linked above." } } },
                  },
                },
              },
            },
          },
        },
      }),
      stderr = "",
    })
  else
    local sample = {
      { key = "DEMO-101", summary = "Set up CI pipeline for the mobile app",        status = "To Do",       type = "Task",  assignee = "Priya Nair" },
      { key = "DEMO-118", summary = "Investigate flaky checkout tests",             status = "To Do",       type = "Bug",   assignee = "Priya Nair" },
      { key = "DEMO-142", summary = "Add dark mode toggle to settings panel",       status = "In Progress", type = "Story", assignee = "Jordan Blake" },
      { key = "DEMO-139", summary = "Refactor auth middleware",                     status = "In Progress", type = "Task",  assignee = "Sam Rivera" },
      { key = "DEMO-127", summary = "API rate limiting returns wrong status code",  status = "In Review",   type = "Bug",   assignee = "Jordan Blake" },
      { key = "DEMO-95",  summary = "Migrate billing service to new SDK",           status = "Done",        type = "Task",  assignee = "Priya Nair" },
      { key = "DEMO-88",  summary = "Write onboarding docs for new hires",          status = "Done",        type = "Task",  assignee = "Sam Rivera" },
    }
    local issues = {}
    for _, it in ipairs(sample) do
      issues[#issues + 1] = {
        key = it.key,
        fields = {
          summary = it.summary,
          status = { id = it.status, name = it.status },
          issuetype = { name = it.type },
          assignee = { displayName = it.assignee },
          priority = { name = "Medium" },
        },
      }
    end
    cb({ code = 0, stdout = vim.json.encode({ issues = issues }), stderr = "" })
  end
end

require("jira-tui").open()

vim.schedule(function()
  -- Open the first issue's detail so the right pane isn't empty in the shot.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  vim.schedule(function()
    -- Force a full redraw to clear any lingering `vim.pack` install-progress
    -- message from the cmdline area before a screenshot is taken.
    vim.cmd("mode")
  end)
end)
