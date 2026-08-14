# jira-tui.nvim

A fast, keyboard-driven Jira Kanban board inside Neovim — browse your board,
read/comment on issues, and hand ticket context straight to your AI tool of
choice (sidekick.nvim, CopilotChat.nvim, or your own integration).

![filetype](https://img.shields.io/badge/filetype-jira--tui-blue)

## Features

- 📋 Kanban board rendered as columns in a single buffer — no floating
  windows, no flicker, just fast plain-text rendering.
- 🔍 Filter by assignee (mine/all), free-text search, and labels.
- 📖 Full issue detail pane (description, comments, parent/subtasks) that
  can be hidden/toggled to free up screen space.
- 💬 Write and post comments without leaving Neovim.
- 🤖 Send any issue's full context to an AI tool with one keypress —
  defaults to [sidekick.nvim](https://github.com/folke/sidekick.nvim) if
  installed, falls back to
  [CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim), or
  plug in your own function.
- 🔌 Optional synchronous `{ticket}`-style context provider for integrations
  that need to read "the issue you're looking at" without an HTTP round trip
  (e.g. sidekick.nvim's context variables).

## Requirements

- Neovim >= 0.10 (uses `vim.system`, `vim.uv`)
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim) (search/label inputs)
- `curl` on `$PATH`
- A Jira Cloud instance + an [Atlassian API
  token](https://id.atlassian.com/manage-profile/security/api-tokens)

## Installation

<details>
<summary><a href="https://github.com/folke/lazy.nvim">lazy.nvim</a></summary>

```lua
{
  "ZakHargz/jira-tui.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  cmd = "JiraTui",
  opts = {
    server = "https://yourteam.atlassian.net",
    email = "you@yourteam.com",
    project = "ABC",
  },
}
```
</details>

<details>
<summary>Native <code>vim.pack</code> / <a href="https://github.com/zuqini/zpack.nvim">zpack.nvim</a></summary>

```lua
-- lua/plugins/jira-tui.lua (auto-imported by zpack)
return {
  "ZakHargz/jira-tui.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  cmd = "JiraTui",
  opts = {
    server = "https://yourteam.atlassian.net",
    email = "you@yourteam.com",
    project = "ABC",
  },
}
```
</details>

<details>
<summary><a href="https://github.com/wbthomason/packer.nvim">packer.nvim</a></summary>

```lua
use({
  "ZakHargz/jira-tui.nvim",
  requires = { "MunifTanjim/nui.nvim" },
  config = function()
    require("jira-tui").setup({
      server = "https://yourteam.atlassian.net",
      email = "you@yourteam.com",
      project = "ABC",
    })
  end,
})
```
</details>

If your plugin manager doesn't call `opts`/`config` for you, just call
`require("jira-tui").setup({ ... })` yourself somewhere in your config.

## Quick start

```lua
require("jira-tui").setup({
  server = "https://yourteam.atlassian.net",
  email = "you@yourteam.com",
  project = "ABC",
})

vim.keymap.set("n", "<leader>cj", function()
  require("jira-tui").open()
end, { desc = "Jira board" })
```

Then `:JiraTui` (or your keymap) opens the board in a new tab.

## Setup

Full option list (all defaults shown):

```lua
require("jira-tui").setup({
  -- ── Required ──────────────────────────────────────────────────────────
  server = nil,        -- "https://yourteam.atlassian.net"
  email = nil,          -- your Atlassian account email
  project = nil,         -- Jira project key, e.g. "ABC"

  -- ── Optional ──────────────────────────────────────────────────────────
  board_name = "Board",  -- label shown in the list pane's winbar
  extra_jql = nil,       -- extra clause AND-ed onto every board query, e.g.
                         -- a custom-field team filter:
                         -- '"Team[Team]" = "your-team-uuid"'
  max_results = 200,     -- issues fetched per board load

  -- Kanban columns, in display order. `statuses` entries are matched
  -- against BOTH the Jira status id and its name, so you can use whichever
  -- is convenient — names are usually enough; ids only matter if two
  -- differently-workflowed statuses in your project happen to share a name.
  columns = {
    { name = "To Do", statuses = { "To Do", "Open", "Backlog" } },
    { name = "In Progress", statuses = { "In Progress" } },
    { name = "In Review", statuses = { "In Review", "Ready For Review" } },
    { name = "Done", statuses = { "Done", "Closed" } },
  },

  auth = {
    -- see "Authentication" below
    token = nil,
    token_env = "JIRA_API_TOKEN",
    token_file = nil,
  },

  ai = {
    -- see "AI integration" below
    send = nil,
  },
})
```

### Finding your column statuses

Not sure what statuses your board actually uses? Open a browser dev tools
network tab on your board, or just run this once you've set `server`/`email`/
`project` (even with placeholder `columns`) and check `:messages` for any
issues that land in the fallback last column — then adjust `columns` to
match your project's real workflow.

## Authentication

Auth is resolved in this order — first match wins:

**1. A literal token or function in `setup()`:**

```lua
require("jira-tui").setup({
  auth = {
    -- literal string (simplest, but keep secrets out of version control!)
    token = "your-api-token",

    -- OR a function, called fresh on every request — read from a password
    -- manager, another tool's config file, etc.
    token = function()
      return vim.fn.system("op read op://Personal/Jira/token"):gsub("\n$", "")
    end,
  },
})
```

**2. An environment variable** (default name `JIRA_API_TOKEN`, override with
`auth.token_env`):

```sh
export JIRA_API_TOKEN="your-api-token"
```

**3. A plain-text file** containing just the token:

```lua
require("jira-tui").setup({
  auth = { token_file = "~/.secrets/jira-token" },
})
```

**Reading a JSON file** (e.g. another CLI tool's config): use the `token`
function form, decoding the JSON yourself:

```lua
auth = {
  token = function()
    local f = io.open(vim.fn.expand("~/.some-tool/config.json"), "r")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    local ok, data = pcall(vim.json.decode, raw)
    return ok and data.profiles and data.profiles.default and data.profiles.default.token or nil
  end,
}
```

## AI integration

Press `i` on any issue (list or detail pane) to send its full context
(summary, type, status, priority, assignee, labels, description, last 3
comments) to an AI tool. Resolved in this order:

1. **Your own `ai.send` function**, if configured:

   ```lua
   require("jira-tui").setup({
     ai = {
       send = function(text)
         -- e.g. open a scratch buffer, pipe to a CLI, whatever you want
         vim.fn.setreg("+", text)
         vim.notify("Ticket copied to clipboard")
       end,
     },
   })
   ```

2. **[sidekick.nvim](https://github.com/folke/sidekick.nvim)**, if
   installed — sent via `require("sidekick.cli").send()` to whichever CLI
   tool (Claude, opencode, Gemini, Copilot CLI, ...) you have attached, or
   prompts you to pick one if none is running yet.

3. **[CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim)**,
   if installed — opened via `.ask()`.

4. **Fallback**: copies the ticket text to the system clipboard (`"+`
   register) and notifies you.

### Pure Copilot / Claude setup (no custom callback needed)

If you just want plain Copilot chat or a specific CLI tool without writing
any glue code yourself:

- **CopilotChat.nvim only**: install it, don't install sidekick.nvim — `i`
  will use it automatically.
- **sidekick.nvim, always Claude specifically**: set `ai.send` to force a
  named tool instead of the default/prompted selection:

  ```lua
  ai = {
    send = function(text)
      require("sidekick.cli").send({
        text = require("sidekick.text").to_text(text),
        filter = { name = "claude" },
        focus = true,
      })
    end,
  }
  ```

### sidekick.nvim `{ticket}` context variable

sidekick.nvim's [custom context
variables](https://github.com/folke/sidekick.nvim#-ai-cli-integration) must
be **synchronous** (they can't await an HTTP request), so jira-tui.nvim
exposes `require("jira-tui").get_current_ticket_context()` — a synchronous
getter backed by a small cache (populated whenever you view an issue's full
detail with `<CR>` or send it with `i`). Wire it up as a `{ticket}` context
variable in your sidekick config:

```lua
{
  "folke/sidekick.nvim",
  opts = {
    cli = {
      context = {
        ticket = function()
          local ok, jira_tui = pcall(require, "jira-tui")
          return ok and jira_tui.get_current_ticket_context() or false
        end,
      },
      prompts = {
        ticket = "Please help me implement {ticket}",
      },
    },
  },
}
```

Now `<leader>ap` (or however you've bound `require("sidekick.cli").prompt()`)
offers a "ticket" prompt that pulls in whatever issue you were last looking
at, from anywhere in your session — not just from inside the jira-tui board.

## Keymaps

All keymaps are buffer-local to the jira-tui board/detail buffers, so they
never shadow your global mappings.

**List pane:**

| Key | Action |
|---|---|
| `h` / `l` / `←` / `→` | Move between columns |
| `j` / `k` | Move within a column (native) |
| `<CR>` | Open issue detail |
| `a` | Toggle "my issues only" |
| `A` | Clear all filters |
| `/` | Search |
| `t` | Edit label filters (comma-separated) |
| `c` | Write a comment |
| `i` | Send issue to AI (hides the detail pane) |
| `d` | Toggle the detail pane open/closed |
| `r` | Refresh |
| `<C-o>` | Open in browser |
| `L` | Focus detail pane (auto-shows it if hidden) |
| `q` | Quit |

**Detail pane:**

| Key | Action |
|---|---|
| `q` / `<Esc>` / `<BS>` | Back to list |
| `H` | Focus list pane |
| `Q` | Quit everything |
| `c` | Write a comment |
| `i` | Send issue to AI (hides this pane) |
| `d` | Toggle this pane |
| `<C-o>` | Open in browser |

## Commands

- `:JiraTui` — open the board (equivalent to `require("jira-tui").open()`)

## Health check

`:checkhealth jira-tui` verifies your config, token resolution, `curl`,
`nui.nvim`, and reports which AI integration (if any) will be used.

## Contributing

Issues and PRs welcome. This started as a personal tool extracted out of one
person's dotfiles, so if something's Flutter/Atlassian-instance-specific
that slipped through, please flag it.

## License

[MIT](LICENSE)
