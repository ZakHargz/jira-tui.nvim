Output "assets/screenshot.png"
Output "assets/demo.gif"

Set Shell "zsh"
Set FontSize 14
Set Width 1400
Set Height 820
Set Theme "Ayu Mirage"
Set Padding 20
Set WindowBar "Colorful"
Set WindowBarSize 40

# NVIM_APPNAME isolates this to its own throwaway data dir
# (~/.local/share/jira-tui-demo) so `vim.pack.add` in demo.lua never touches
# your real Neovim plugin install. Run from the repo root: vhs scripts/demo.tape
Type "NVIM_APPNAME=jira-tui-demo nvim -u scripts/demo.lua"
Enter
Sleep 5s
Screenshot "assets/screenshot.png"
Sleep 1s
