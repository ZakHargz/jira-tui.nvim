if vim.g.loaded_jira_tui then
  return
end
vim.g.loaded_jira_tui = true

vim.api.nvim_create_user_command("JiraTui", function()
  require("jira-tui").open()
end, { desc = "Open the jira-tui.nvim Kanban board" })
