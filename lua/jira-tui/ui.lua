local Config = require("jira-tui.config")
local Api = require("jira-tui.api")
local Adf = require("jira-tui.adf")
local Ai = require("jira-tui.ai")

local M = {}

-- ── State ─────────────────────────────────────────────────────────────────────
-- state[list_buf] = {
--   columns       = { { name, issues={item,...} }, ... }
--   col_idx       = selected column index (1-based)
--   row_idx       = selected row within column (1-based)
--   list_win      = window number
--   detail_buf    = buffer for right pane
--   detail_win    = window number for right pane (nil when hidden)
--   detail_hidden = bool
--   loading       = bool
--   filter        = { assignee="me"|""|nil, text=nil|string, labels=nil|string[] }
-- }
local state = {}

-- Most recently opened Jira TUI list buffer — used by
-- `M.get_current_ticket_context()` (a `{ticket}`-style context provider for
-- integrations like sidekick.nvim) to find "the issue you're looking at"
-- without an explicit handle passed in.
local last_list_buf = nil

-- Cache of the last issue whose *full* detail was fetched (via <CR> or the
-- `i` "send to AI" keymap), keyed by issue key. Some AI-context integrations
-- (e.g. sidekick.nvim's context functions) must be synchronous — they can't
-- await an HTTP request — so we serve back whatever was last actually looked
-- at, falling back to the lightweight board-list fields (no
-- description/comments) if you haven't opened an issue's detail yet.
local last_rich_context = nil ---@type { key: string, text: string }?

-- Forward declarations: setup_detail_keymaps/hide/show/toggle all reference
-- each other (and are referenced from setup_keymaps, defined earlier in the
-- file), so they're declared here and assigned further down.
local setup_detail_keymaps
local hide_detail_pane
local show_detail_pane
local toggle_detail_pane

-- ── Highlights ────────────────────────────────────────────────────────────────
local ns = vim.api.nvim_create_namespace("JiraTUI")

local function define_highlights()
  local hl = function(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end
  hl("JiraColHeader",    { link = "Title" })
  hl("JiraColSep",       { link = "WinSeparator" })
  hl("JiraSelected",     { link = "CursorLine" })
  hl("JiraKey",          { link = "Identifier" })
  hl("JiraStatusTodo",   { link = "DiagnosticHint" })
  hl("JiraStatusProg",   { link = "DiagnosticWarn" })
  hl("JiraStatusDone",   { link = "DiagnosticOk" })
  hl("JiraStatusBlock",  { link = "DiagnosticError" })
  hl("JiraStatusReview", { link = "DiagnosticInfo" })
  hl("JiraType",         { link = "Comment" })
  hl("JiraAssignee",     { link = "Comment" })
  hl("JiraHint",         { link = "Comment" })
  hl("JiraLoading",      { link = "DiagnosticInfo" })
  hl("JiraMetaLabel",    { link = "Label" })
  hl("JiraMetaValue",    { link = "Normal" })
  hl("JiraDetailKey",    { link = "Title" })
end

define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group    = vim.api.nvim_create_augroup("JiraTUIHL", { clear = true }),
  callback = define_highlights,
})

-- ── sidekick.nvim / generic AI-context integration ───────────────────────────

--- Build a plain-text block describing an issue, suitable for handing to an
--- AI as context. `f` is a Jira "fields" table — accepts either the full
--- fields object from a REST fetch, or the lightweight shape built from
--- board-list data (summary/status/issuetype/assignee/priority only).
local function build_ticket_text(key, f)
  local parts = {}
  local function add(line)
    parts[#parts + 1] = line
  end

  add(string.format("Jira issue %s: %s", key, f.summary or ""))
  add(string.format(
    "Type: %s | Status: %s | Priority: %s | Assignee: %s",
    (f.issuetype or {}).name or "",
    (f.status or {}).name or "",
    (f.priority or {}).name or "",
    (f.assignee or {}).displayName or "Unassigned"
  ))

  local labels = f.labels or {}
  if #labels > 0 then
    add("Labels: " .. table.concat(labels, ", "))
  end

  if f.description then
    add("")
    add("Description:")
    add(vim.trim(Adf.to_text(f.description, 0)))
  end

  local comments = (f.comment or {}).comments or {}
  if #comments > 0 then
    add("")
    add(string.format("Comments (%d total, newest first, showing last 3):", #comments))
    local start = math.max(1, #comments - 2)
    for i = #comments, start, -1 do
      local c = comments[i]
      local author = (c.author or {}).displayName or "?"
      local date = (c.created or ""):sub(1, 10)
      add(string.format("%s (%s): %s", author, date, vim.trim(Adf.to_text(c.body, 0))))
    end
  end

  return table.concat(parts, "\n")
end

--- Whatever issue is currently highlighted in the last-opened Jira TUI board
--- (no HTTP call — reads what's already in memory from the last load_board).
local function current_selected_issue()
  if not last_list_buf then
    return nil
  end
  local s = state[last_list_buf]
  if not s or not s.columns then
    return nil
  end
  local col = s.columns[s.col_idx]
  return col and col.issues[s.row_idx]
end

--- Public: synchronous getter for AI-context integrations that can't await
--- an HTTP request (e.g. sidekick.nvim's `context.Fn`). Prefers the rich
--- cache populated by viewing an issue's full detail (`<CR>` or the `i`
--- "send to AI" keymap); falls back to the lightweight board-list fields for
--- whatever's currently highlighted if you haven't opened its detail yet
--- this session; returns `false` if nothing to show.
---@return string|false
function M.get_current_ticket_context()
  local issue = current_selected_issue()
  if not issue then
    return (last_rich_context and last_rich_context.text) or false
  end
  if last_rich_context and last_rich_context.key == issue.key then
    return last_rich_context.text
  end
  return build_ticket_text(issue.key, {
    summary = issue.summary,
    status = { name = issue.status },
    issuetype = { name = issue.type },
    assignee = issue.assignee_raw,
    priority = { name = issue.priority },
  })
end

--- Add a comment to an issue. `cb(ok, err)`.
local function add_comment(issue_key, text, cb)
  Api.post(string.format("/rest/api/3/issue/%s/comment", issue_key), { body = Adf.from_text(text) }, function(data, err)
    cb(data ~= nil, err)
  end)
end

-- ── Data helpers ──────────────────────────────────────────────────────────────

local STATUS_HL = {
  ["Backlog"]          = "JiraStatusTodo",
  ["To Do"]            = "JiraStatusTodo",
  ["Open"]             = "JiraStatusTodo",
  ["In Progress"]      = "JiraStatusProg",
  ["Ready For Review"] = "JiraStatusReview",
  ["In Review"]        = "JiraStatusReview",
  ["Blocked"]          = "JiraStatusBlock",
  ["Done"]             = "JiraStatusDone",
  ["Closed"]           = "JiraStatusDone",
}

local TYPE_ICONS = {
  ["Bug"]       = "B",
  ["Story"]     = "S",
  ["Task"]      = "T",
  ["Epic"]      = "E",
  ["Sub-task"]  = "s",
  ["Spike"]     = "~",
  ["Support"]   = "?",
}

local function status_hl(status_name)
  return STATUS_HL[status_name] or "JiraType"
end

local function type_icon(type_name)
  return TYPE_ICONS[type_name] or "·"
end

local function assignee_short(assignee_field)
  if not assignee_field or type(assignee_field) ~= "table" then return "---" end
  local name = assignee_field.displayName or ""
  return name:match("^(%S+)") or name
end

--- Build status-id/name -> column-index lookups. `statuses` entries are
--- matched against both `status.id` and `status.name`, so config authors can
--- use whichever's more convenient (names are friendlier to set up; ids
--- disambiguate two differently-workflowed statuses sharing a name).
local function build_status_index(columns)
  local by_id, by_name = {}, {}
  for ci, col in ipairs(columns) do
    for _, s in ipairs(col.statuses or {}) do
      by_id[tostring(s)] = ci
      by_name[s] = ci
    end
  end
  return by_id, by_name
end

-- ── Rendering ─────────────────────────────────────────────────────────────────

-- Each "column" in the list buffer is rendered as a vertical section.
-- Layout:
--   Line 1:   hint bar
--   Line 2:   separator
--   Then for each board column:
--     ── Column Name (N) ──
--     [T] KEY  Assignee  Summary…
--     ...
--     (blank line between columns)

local HINT = "  h/l col  <CR> detail  a mine  A all  / search  t labels  c comment  i AI chat  d toggle detail  r refresh  <C-o> browser  q quit"

local function truncate(s, max)
  if #s <= max then return s end
  return s:sub(1, max - 1) .. "…"
end

--- Build lines + line_meta, write to buffer. Call on load or column switch.
local function render_lines(buf)
  local s = state[buf]
  if not s then return end

  vim.bo[buf].modifiable = true

  local width = 80
  if s.list_win and vim.api.nvim_win_is_valid(s.list_win) then
    width = vim.api.nvim_win_get_width(s.list_win)
  end

  local lines     = {}
  local line_meta = {}

  lines[1]     = HINT
  line_meta[1] = nil
  lines[2]     = string.rep("─", width)
  line_meta[2] = nil

  local function add(line, meta)
    lines[#lines + 1] = line
    line_meta[#lines] = meta
  end

  -- Fixed-width prefix in the issue line format below: "  [%s] %-12s %-10s "
  local ISSUE_PREFIX_WIDTH = 30
  local summary_width = math.max(10, width - ISSUE_PREFIX_WIDTH)

  for ci, col in ipairs(s.columns) do
    local issues = col.issues or {}
    local header = string.format("── %s (%d) ", col.name, #issues)
      .. string.rep("─", math.max(0, width - #col.name - #tostring(#issues) - 7))
    add(header, nil)

    if #issues == 0 then
      add("   (empty)", nil)
    else
      for ri, issue in ipairs(issues) do
        local icon = type_icon(issue.type)
        local who  = assignee_short(issue.assignee_raw)
        local summ = truncate(issue.summary, summary_width)
        add(string.format("  [%s] %-12s %-10s %s", icon, issue.key, who, summ),
            { col = ci, row = ri })
      end
    end

    add("", nil)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  s._line_meta = line_meta
  s._lines     = lines
end

--- Reapply all extmarks based on current s.col_idx / s.row_idx. Cheap — no line writes.
local function render_highlights(buf)
  local s = state[buf]
  if not s or not s._line_meta then return end

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local line_meta = s._line_meta
  local lines     = s._lines
  local sel_col   = s.col_idx
  local sel_row   = s.row_idx

  -- Hint bar
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #HINT, hl_group = "JiraHint" })

  for lnum = 1, #lines do
    local meta = line_meta[lnum]
    local row0 = lnum - 1
    local line = lines[lnum]
    if meta then
      if meta.col == sel_col and meta.row == sel_row then
        vim.api.nvim_buf_set_extmark(buf, ns, row0, 0, { line_hl_group = "JiraSelected" })
      end
      local key_s, key_e = line:find("%u+%-%d+")
      if key_s then
        vim.api.nvim_buf_set_extmark(buf, ns, row0, key_s - 1, {
          end_col = key_e, hl_group = "JiraKey",
        })
      end
      local issue = s.columns[meta.col] and s.columns[meta.col].issues[meta.row]
      if issue then
        vim.api.nvim_buf_set_extmark(buf, ns, row0, 2, {
          end_col = 5, hl_group = status_hl(issue.status),
        })
      end
    else
      if line and line:match("^──") then
        vim.api.nvim_buf_set_extmark(buf, ns, row0, 0, {
          end_col = #line, hl_group = "JiraColHeader",
        })
      end
    end
  end
end

--- Full render: lines + highlights + cursor sync.
local function render(buf)
  render_lines(buf)
  render_highlights(buf)

  -- Place cursor on current selection
  local s = state[buf]
  if not s or not s._line_meta then return end
  if s.list_win and vim.api.nvim_win_is_valid(s.list_win) then
    for lnum = 1, #s._lines do
      local meta = s._line_meta[lnum]
      if meta and meta.col == s.col_idx and meta.row == s.row_idx then
        vim.api.nvim_win_set_cursor(s.list_win, { lnum, 0 })
        break
      end
    end
  end
end

-- ── Detail pane ───────────────────────────────────────────────────────────────

local function render_detail(buf, s, issue)
  if not issue then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "  Select an issue with <CR>" })
    vim.bo[buf].modifiable = false
    return
  end

  -- Fetch full issue detail
  local path = string.format(
    "/rest/api/3/issue/%s?fields=summary,status,issuetype,assignee,priority,reporter,created,updated,description,comment,parent,subtasks,labels",
    issue.key
  )
  Api.get(path, function(data)
    if not data then return end
    vim.schedule(function()
      if not state[buf] then return end -- buf is list_buf here
      local detail_buf = state[buf] and state[buf].detail_buf
      if not detail_buf or not vim.api.nvim_buf_is_valid(detail_buf) then return end

      local f = data.fields or {}

      -- Cache for AI-context integrations (see build_ticket_text above).
      last_rich_context = { key = data.key, text = build_ticket_text(data.key, f) }

      local lines = {}
      local function add(line) lines[#lines + 1] = line end

      add("")
      add("  " .. (f.summary or ""))
      add("")
      add(string.format("  %-14s %s", "Key:",       data.key))
      add(string.format("  %-14s %s", "Type:",      (f.issuetype or {}).name or ""))
      add(string.format("  %-14s %s", "Status:",    (f.status or {}).name or ""))
      add(string.format("  %-14s %s", "Priority:",  (f.priority or {}).name or ""))
      add(string.format("  %-14s %s", "Assignee:",  (f.assignee or {}).displayName or "Unassigned"))
      add(string.format("  %-14s %s", "Reporter:",  (f.reporter or {}).displayName or ""))
      add(string.format("  %-14s %s", "Created:",   (f.created or ""):sub(1, 10)))
      add(string.format("  %-14s %s", "Updated:",   (f.updated or ""):sub(1, 10)))

      -- Labels
      local labels = f.labels or {}
      if #labels > 0 then
        add(string.format("  %-14s %s", "Labels:", table.concat(labels, ", ")))
      end

      -- Parent
      if f.parent then
        add(string.format("  %-14s %s — %s", "Parent:", f.parent.key, (f.parent.fields or {}).summary or ""))
      end

      -- Subtasks
      local subtasks = f.subtasks or {}
      if #subtasks > 0 then
        add("")
        add("  Subtasks:")
        for _, st in ipairs(subtasks) do
          add(string.format("    · %-14s %s", st.key, (st.fields or {}).summary or ""))
        end
      end

      -- Description (flatten ADF to plain text)
      if f.description then
        add("")
        add("  Description:")
        add("  " .. string.rep("─", 40))
        local desc_text = Adf.to_text(f.description, 0)
        for _, dline in ipairs(vim.split(desc_text, "\n", { plain = true })) do
          add("  " .. dline)
        end
      end

      -- Comments (latest 3, newest first)
      local comments = (f.comment or {}).comments or {}
      if #comments > 0 then
        add("")
        add("  Comments (" .. #comments .. " total, newest first, showing last 3):")
        add("  " .. string.rep("─", 40))
        local start = math.max(1, #comments - 2)
        for i = #comments, start, -1 do
          local c = comments[i]
          local author = (c.author or {}).displayName or "?"
          local date   = (c.created or ""):sub(1, 10)
          add(string.format("  %s  (%s)", author, date))
          local body = Adf.to_text(c.body, 0)
          for _, bline in ipairs(vim.split(body, "\n", { plain = true })) do
            add("    " .. bline)
          end
          add("")
        end
      end

      vim.bo[detail_buf].modifiable = true
      vim.api.nvim_buf_set_lines(detail_buf, 0, -1, false, lines)
      vim.bo[detail_buf].modifiable = false
      vim.bo[detail_buf].filetype = "text"

      -- Highlight summary line
      local detail_ns = vim.api.nvim_create_namespace("JiraTUIDetail")
      vim.api.nvim_buf_clear_namespace(detail_buf, detail_ns, 0, -1)
      vim.api.nvim_buf_set_extmark(detail_buf, detail_ns, 1, 2, {
        end_col  = #lines[2],
        hl_group = "JiraDetailKey",
      })
      -- Highlight metadata labels
      for i, line in ipairs(lines) do
        local label_end = line:find("%S.*:")
        if label_end and i > 2 then
          local ls, le = line:find("^%s+%S[^:]*:")
          if ls then
            vim.api.nvim_buf_set_extmark(detail_buf, detail_ns, i - 1, ls - 1, {
              end_col  = le,
              hl_group = "JiraMetaLabel",
            })
          end
        end
      end

      -- Update winbar with issue key
      if state[buf] and state[buf].detail_win and vim.api.nvim_win_is_valid(state[buf].detail_win) then
        local status_name = (f.status or {}).name or ""
        local hl = status_hl(status_name)
        vim.wo[state[buf].detail_win].winbar =
          string.format(" %%#JiraDetailKey#%s%%*  %%#%s#%s%%*", data.key, hl, status_name)
      end

      -- Store URL for <C-o>
      issue.url = string.format("%s/browse/%s", Config.get().server, data.key)

      -- Focus detail window
      if state[buf] and state[buf].detail_win and vim.api.nvim_win_is_valid(state[buf].detail_win) then
        vim.api.nvim_set_current_win(state[buf].detail_win)
      end
    end)
  end)
end

-- ── Comment composer ──────────────────────────────────────────────────────────

--- Open a floating scratch buffer to write a comment, then POST it to the
--- issue on submit. `<C-s>` (normal or insert) submits, `q`/`<Esc>` cancels.
local function open_comment_composer(list_buf, issue)
  if not issue then
    vim.notify("jira-tui: no issue selected", vim.log.levels.WARN)
    return
  end

  local width  = math.min(90, math.floor(vim.o.columns * 0.6))
  local height = math.min(16, math.floor(vim.o.lines * 0.4))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype  = "markdown"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row      = math.floor((vim.o.lines - height) / 2),
    col      = math.floor((vim.o.columns - width) / 2),
    width    = width,
    height   = height,
    style    = "minimal",
    border   = "rounded",
    title    = string.format(" Comment on %s — <C-s> send, q/<Esc> cancel ", issue.key),
    title_pos = "left",
  })
  vim.wo[win].wrap       = true
  vim.wo[win].linebreak  = true
  vim.wo[win].signcolumn = "no"

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function submit()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    if text == "" then
      vim.notify("jira-tui: comment is empty, not sending", vim.log.levels.WARN)
      return
    end
    add_comment(issue.key, text, function(ok, err)
      vim.schedule(function()
        if not ok then
          vim.notify("jira-tui: failed to add comment: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        vim.notify("jira-tui: comment added to " .. issue.key, vim.log.levels.INFO)
        close()
        -- Refresh the detail pane if it's currently showing this issue
        local s = state[list_buf]
        if s and s.detail_buf and vim.api.nvim_buf_is_valid(s.detail_buf) then
          render_detail(list_buf, s, issue)
        end
      end)
    end)
  end

  local o = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    vim.cmd("stopinsert")
    submit()
  end, o)
  vim.keymap.set("n", "q", close, o)
  vim.keymap.set("n", "<Esc>", close, o)

  vim.cmd("startinsert")
end

-- ── Send to AI ────────────────────────────────────────────────────────────────

--- Fetch full issue detail and hand it to `Ai.send()` (sidekick.nvim by
--- default, or whatever `ai.send` you configured). Also refreshes
--- `last_rich_context` so `M.get_current_ticket_context()` picks up the
--- fresh detail on subsequent prompts.
local function send_issue_to_ai(issue)
  if not issue then
    vim.notify("jira-tui: no issue selected", vim.log.levels.WARN)
    return
  end

  local path = string.format(
    "/rest/api/3/issue/%s?fields=summary,status,issuetype,assignee,priority,reporter,description,comment,labels",
    issue.key
  )
  Api.get(path, function(data)
    if not data then return end
    vim.schedule(function()
      local f = data.fields or {}
      local text = build_ticket_text(data.key, f)
      last_rich_context = { key = data.key, text = text }
      Ai.send(text .. "\n\nPlease help me understand and work on this issue.")
    end)
  end)
end

-- ── Data loading ──────────────────────────────────────────────────────────────

local function load_board(list_buf, filter)
  local s = state[list_buf]
  if not s then return end
  s.loading = true
  s.filter  = filter or s.filter or {}

  local cfg = Config.get()

  -- Show loading state
  vim.bo[list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, { "", "  Loading " .. cfg.board_name .. "…" })
  vim.bo[list_buf].modifiable = false

  -- Build JQL
  local jql_parts = { string.format("project = %s", cfg.project) }
  if cfg.extra_jql and cfg.extra_jql ~= "" then
    jql_parts[#jql_parts + 1] = cfg.extra_jql
  end
  if s.filter.assignee == "me" then
    jql_parts[#jql_parts + 1] = "assignee = currentUser()"
  end
  if s.filter.labels and #s.filter.labels > 0 then
    local quoted = {}
    for _, label in ipairs(s.filter.labels) do
      quoted[#quoted + 1] = string.format('"%s"', label:gsub('"', '\\"'))
    end
    jql_parts[#jql_parts + 1] = string.format("labels in (%s)", table.concat(quoted, ", "))
  end
  if s.filter.text and s.filter.text ~= "" then
    jql_parts[#jql_parts + 1] = string.format('text ~ "%s"', s.filter.text:gsub('"', '\\"'))
  end
  local jql = table.concat(jql_parts, " AND ")
  local fields = "summary,status,issuetype,assignee,priority"
  local path = string.format(
    "/rest/api/3/search/jql?jql=%s&orderBy=updated%%20DESC&maxResults=%d&fields=%s",
    vim.uri_encode(jql), cfg.max_results or 200, fields
  )

  Api.get(path, function(data)
    if not data then return end
    vim.schedule(function()
      if not state[list_buf] then return end

      local status_to_col_id, status_to_col_name = build_status_index(cfg.columns)

      -- Initialise empty columns
      local columns = {}
      for ci, col in ipairs(cfg.columns) do
        columns[ci] = { name = col.name, issues = {} }
      end

      -- Bucket issues into columns
      for _, issue in ipairs(data.issues or {}) do
        local f      = issue.fields or {}
        local status = f.status or {}
        local col_i  = status_to_col_id[tostring(status.id)] or status_to_col_name[status.name] or #cfg.columns
        local item = {
          key         = issue.key,
          summary     = f.summary or "",
          status      = status.name or "",
          type        = (f.issuetype or {}).name or "",
          assignee    = assignee_short(f.assignee),
          assignee_raw = f.assignee,
          priority    = (f.priority or {}).name or "",
          url         = "",
        }
        table.insert(columns[col_i].issues, item)
      end

      s.columns = columns
      s.loading = false

      -- Reset selection to first non-empty column
      s.col_idx = 1
      s.row_idx = 1
      for ci, col in ipairs(s.columns) do
        if #col.issues > 0 then
          s.col_idx = ci
          break
        end
      end

      render(list_buf)

      -- Update winbar
      local filter_label = ""
      if s.filter.assignee == "me" then filter_label = "  [mine]" end
      if s.filter.labels and #s.filter.labels > 0 then
        filter_label = filter_label .. string.format("  {%s}", table.concat(s.filter.labels, ","))
      end
      if s.filter.text and s.filter.text ~= "" then
        filter_label = filter_label .. string.format('  ["%s"]', s.filter.text)
      end
      if s.list_win and vim.api.nvim_win_is_valid(s.list_win) then
        vim.wo[s.list_win].winbar =
          string.format(" %%#JiraColHeader#%s%%*  %%#JiraHint#%s%s%%*", cfg.board_name, cfg.project, filter_label)
      end
    end)
  end)
end

-- ── Keymaps ───────────────────────────────────────────────────────────────────

local function setup_keymaps(list_buf)
  local o = { buffer = list_buf, noremap = true, silent = true }

  -- CursorMoved: sync selection + highlights from native cursor
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer   = list_buf,
    callback = function()
      local s = state[list_buf]
      if not s or not s._line_meta then return end
      local row  = vim.api.nvim_win_get_cursor(0)[1]
      local meta = s._line_meta[row]
      if meta then
        s.col_idx = meta.col
        s.row_idx = meta.row
        render_highlights(list_buf)
      end
    end,
  })

  local function current_issue()
    local s = state[list_buf]
    if not s or not s._line_meta then return nil end
    local row  = vim.api.nvim_win_get_cursor(s.list_win)[1]
    local meta = s._line_meta[row]
    if not meta then return nil end
    local col = s.columns and s.columns[meta.col]
    return col and col.issues[meta.row]
  end

  -- Move between columns: jump cursor to first issue in target column
  local function move_col(delta)
    local s = state[list_buf]
    if not s or not s.columns or not s._line_meta then return end
    local new_ci = s.col_idx + delta
    local max_tries = #s.columns
    for _ = 1, max_tries do
      new_ci = ((new_ci - 1) % #s.columns) + 1
      if #s.columns[new_ci].issues > 0 then break end
      new_ci = new_ci + delta
    end
    new_ci = math.max(1, math.min(#s.columns, new_ci))
    -- Find first issue line in that column
    for lnum = 1, #s._lines do
      local meta = s._line_meta[lnum]
      if meta and meta.col == new_ci and meta.row == 1 then
        s.col_idx = new_ci
        s.row_idx = 1
        vim.api.nvim_win_set_cursor(s.list_win, { lnum, 0 })
        render_highlights(list_buf)
        break
      end
    end
  end

  vim.keymap.set("n", "l",       function() move_col(1)  end, o)
  vim.keymap.set("n", "h",       function() move_col(-1) end, o)
  vim.keymap.set("n", "<Right>", function() move_col(1)  end, o)
  vim.keymap.set("n", "<Left>",  function() move_col(-1) end, o)

  -- Open detail
  vim.keymap.set("n", "<CR>", function()
    local issue = current_issue()
    if not issue then return end
    render_detail(list_buf, state[list_buf], issue)
  end, o)

  -- Toggle "my issues" filter
  vim.keymap.set("n", "a", function()
    local s = state[list_buf]
    if not s then return end
    s.filter = s.filter or {}
    s.filter.assignee = (s.filter.assignee == "me") and "" or "me"
    load_board(list_buf)
  end, o)

  -- Show all issues (clear assignee/text/label filters)
  vim.keymap.set("n", "A", function()
    local s = state[list_buf]
    if s then s.filter = {} end
    load_board(list_buf)
  end, o)

  -- Search
  vim.keymap.set("n", "/", function()
    local s = state[list_buf]
    if not s then return end
    local Input = require("nui.input")
    local input = Input({
      relative  = "win",
      position  = { row = "100%", col = 0 },
      size      = { width = vim.api.nvim_win_get_width(s.list_win) - 2 },
      border    = { style = "rounded", text = { top = " Search " .. Config.get().project .. " ", top_align = "left" } },
      win_options = { winhighlight = "Normal:Normal" },
    }, {
      prompt        = " / ",
      default_value = s.filter and s.filter.text or "",
      on_submit = function(value)
        s.filter = s.filter or {}
        s.filter.text = value ~= "" and value or nil
        load_board(list_buf)
        vim.schedule(function()
          if s.list_win and vim.api.nvim_win_is_valid(s.list_win) then
            vim.api.nvim_set_current_win(s.list_win)
          end
        end)
      end,
      on_close = function()
        vim.schedule(function()
          if s.list_win and vim.api.nvim_win_is_valid(s.list_win) then
            vim.api.nvim_set_current_win(s.list_win)
          end
        end)
      end,
    })
    input:mount()
    input:map("i", "<Esc>", function()
      input:unmount()
      if s.list_win and vim.api.nvim_win_is_valid(s.list_win) then
        vim.api.nvim_set_current_win(s.list_win)
      end
    end, { noremap = true })
  end, o)

  -- Edit label filter (comma-separated list of Jira labels)
  vim.keymap.set("n", "t", function()
    local s = state[list_buf]
    if not s then return end
    local Input = require("nui.input")
    local current = s.filter and s.filter.labels and table.concat(s.filter.labels, ", ") or ""
    local input = Input({
      relative  = "win",
      position  = { row = "100%", col = 0 },
      size      = { width = vim.api.nvim_win_get_width(s.list_win) - 2 },
      border    = { style = "rounded", text = { top = " Labels (comma-separated, empty to clear) ", top_align = "left" } },
      win_options = { winhighlight = "Normal:Normal" },
    }, {
      prompt        = " labels: ",
      default_value = current,
      on_submit = function(value)
        s.filter = s.filter or {}
        local labels = {}
        for label in (value or ""):gmatch("[^,]+") do
          label = vim.trim(label)
          if label ~= "" then
            labels[#labels + 1] = label
          end
        end
        s.filter.labels = #labels > 0 and labels or nil
        load_board(list_buf)
        vim.schedule(function()
          if s.list_win and vim.api.nvim_win_is_valid(s.list_win) then
            vim.api.nvim_set_current_win(s.list_win)
          end
        end)
      end,
      on_close = function()
        vim.schedule(function()
          if s.list_win and vim.api.nvim_win_is_valid(s.list_win) then
            vim.api.nvim_set_current_win(s.list_win)
          end
        end)
      end,
    })
    input:mount()
    input:map("i", "<Esc>", function()
      input:unmount()
      if s.list_win and vim.api.nvim_win_is_valid(s.list_win) then
        vim.api.nvim_set_current_win(s.list_win)
      end
    end, { noremap = true })
  end, o)

  -- Refresh
  vim.keymap.set("n", "r", function() load_board(list_buf) end, o)

  -- Write a comment
  vim.keymap.set("n", "c", function()
    open_comment_composer(list_buf, current_issue())
  end, o)

  -- Send issue content to AI. Hides the ticket-detail pane first to free up
  -- screen space for the AI CLI/chat window — toggle it back with `d`.
  vim.keymap.set("n", "i", function()
    hide_detail_pane(list_buf)
    send_issue_to_ai(current_issue())
  end, o)

  -- Toggle the ticket-detail pane open/closed
  vim.keymap.set("n", "d", function()
    toggle_detail_pane(list_buf)
  end, o)

  -- Open in browser
  vim.keymap.set("n", "<C-o>", function()
    local issue = current_issue()
    if not issue then return end
    local url = issue.url ~= "" and issue.url
      or string.format("%s/browse/%s", Config.get().server, issue.key)
    vim.ui.open(url)
  end, o)

  -- Focus detail pane (auto-showing it first if it's currently hidden)
  vim.keymap.set("n", "L", function()
    local s = state[list_buf]
    if not s then return end
    if s.detail_hidden then
      show_detail_pane(list_buf)
    end
    if s.detail_win and vim.api.nvim_win_is_valid(s.detail_win) then
      vim.api.nvim_set_current_win(s.detail_win)
    end
  end, o)

  -- Quit
  vim.keymap.set("n", "q", function()
    local s = state[list_buf]
    if not s then return end
    for _, win in ipairs({ s.list_win, s.detail_win }) do
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
    if s.detail_buf and vim.api.nvim_buf_is_valid(s.detail_buf) then
      pcall(vim.api.nvim_buf_delete, s.detail_buf, { force = true })
    end
    state[list_buf] = nil
  end, o)
end

setup_detail_keymaps = function(list_buf, detail_buf)
  local o = { buffer = detail_buf, noremap = true, silent = true }

  local function back_to_list()
    local s = state[list_buf]
    if not s then return end
    -- Clear detail pane and focus list
    vim.bo[detail_buf].modifiable = true
    vim.api.nvim_buf_set_lines(detail_buf, 0, -1, false, { "", "  Press <CR> on an issue to view details." })
    vim.bo[detail_buf].modifiable = false
    if s.detail_win and vim.api.nvim_win_is_valid(s.detail_win) then
      vim.wo[s.detail_win].winbar = " %#JiraHint#Select an issue with <CR>%*"
    end
    if s.list_win and vim.api.nvim_win_is_valid(s.list_win) then
      vim.api.nvim_set_current_win(s.list_win)
    end
  end

  -- q / <Esc> / <BS>: go back to list
  vim.keymap.set("n", "q",    back_to_list, o)
  vim.keymap.set("n", "<Esc>",back_to_list, o)
  vim.keymap.set("n", "<BS>", back_to_list, o)

  -- H: also go back to list (focus only, keeps detail content)
  vim.keymap.set("n", "H", function()
    local s = state[list_buf]
    if s and s.list_win and vim.api.nvim_win_is_valid(s.list_win) then
      vim.api.nvim_set_current_win(s.list_win)
    end
  end, o)

  -- Q: quit everything
  vim.keymap.set("n", "Q", function()
    local s = state[list_buf]
    if not s then return end
    for _, win in ipairs({ s.list_win, s.detail_win }) do
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
    if s.detail_buf and vim.api.nvim_buf_is_valid(s.detail_buf) then
      pcall(vim.api.nvim_buf_delete, s.detail_buf, { force = true })
    end
    state[list_buf] = nil
  end, o)

  local function current_issue()
    local s = state[list_buf]
    if not s then return nil end
    local col = s.columns and s.columns[s.col_idx]
    return col and col.issues[s.row_idx]
  end

  vim.keymap.set("n", "<C-o>", function()
    local issue = current_issue()
    if issue then
      vim.ui.open(string.format("%s/browse/%s", Config.get().server, issue.key))
    end
  end, o)

  -- Write a comment
  vim.keymap.set("n", "c", function()
    open_comment_composer(list_buf, current_issue())
  end, o)

  -- Send issue content to AI. Hides this very pane first to free up screen
  -- space — toggle it back with `d`.
  vim.keymap.set("n", "i", function()
    local issue = current_issue()
    hide_detail_pane(list_buf)
    send_issue_to_ai(issue)
  end, o)

  -- Toggle the ticket-detail pane open/closed
  vim.keymap.set("n", "d", function()
    toggle_detail_pane(list_buf)
  end, o)
end

-- ── Hide/show the ticket-detail pane ──────────────────────────────────────────

--- Hide the ticket-detail pane. The buffer is kept alive (bufhidden="hide"
--- on this buffer, set in M.open) so re-showing it doesn't need a re-fetch —
--- used e.g. right before handing a ticket to AI after pressing `i`, so
--- that window has the full width to work with.
hide_detail_pane = function(list_buf)
  local s = state[list_buf]
  if not s or not s.detail_win or not vim.api.nvim_win_is_valid(s.detail_win) then
    return
  end
  if vim.api.nvim_get_current_win() == s.detail_win and s.list_win and vim.api.nvim_win_is_valid(s.list_win) then
    vim.api.nvim_set_current_win(s.list_win)
  end
  vim.api.nvim_win_close(s.detail_win, true)
  s.detail_win = nil
  s.detail_hidden = true
end

--- Re-open the ticket-detail pane (vsplit off the list pane) and restore its
--- window-local options/winbar. Buffer content is untouched.
show_detail_pane = function(list_buf)
  local s = state[list_buf]
  if not s or not s.detail_hidden then
    return
  end
  if not s.list_win or not vim.api.nvim_win_is_valid(s.list_win) then
    return
  end

  local cur_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(s.list_win)
  vim.cmd("vsplit")
  local detail_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(detail_win, s.detail_buf)

  local detail_width = math.max(80, math.min(130, math.floor(vim.o.columns * 0.42)))
  vim.api.nvim_win_set_width(detail_win, detail_width)

  vim.wo[detail_win].number         = false
  vim.wo[detail_win].relativenumber = false
  vim.wo[detail_win].signcolumn     = "no"
  vim.wo[detail_win].foldcolumn     = "0"
  vim.wo[detail_win].wrap           = true
  vim.wo[detail_win].linebreak      = true
  vim.wo[detail_win].cursorline     = false

  s.detail_win = detail_win
  s.detail_hidden = false

  setup_detail_keymaps(list_buf, s.detail_buf)

  if vim.api.nvim_win_is_valid(cur_win) and cur_win ~= detail_win then
    vim.api.nvim_set_current_win(cur_win)
  end
end

--- Toggle the ticket-detail pane open/closed (bound to `d` in both panes).
toggle_detail_pane = function(list_buf)
  local s = state[list_buf]
  if not s then
    return
  end
  if s.detail_hidden then
    show_detail_pane(list_buf)
  else
    hide_detail_pane(list_buf)
  end
end

-- ── Layout ────────────────────────────────────────────────────────────────────

function M.open()
  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buf].filetype   = "jira-tui"
  vim.bo[list_buf].buftype    = "nofile"
  vim.bo[list_buf].bufhidden  = "wipe"
  vim.bo[list_buf].swapfile   = false
  vim.bo[list_buf].modifiable = false

  local detail_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[detail_buf].buftype    = "nofile"
  -- "hide" (not "wipe"): hide_detail_pane() closes this buffer's window
  -- without destroying it, so toggling it back with `d`/`L` doesn't need a
  -- re-fetch. Explicitly deleted on quit (q/Q keymaps, BufWipeout below).
  vim.bo[detail_buf].bufhidden  = "hide"
  vim.bo[detail_buf].swapfile   = false
  vim.bo[detail_buf].modifiable = false

  vim.cmd("tabnew")
  local list_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(list_win, list_buf)

  vim.cmd("vsplit")
  local detail_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(detail_win, detail_buf)

  -- List pane is wider (kanban list), detail pane wide enough to read comfortably
  local detail_width = math.max(80, math.min(130, math.floor(vim.o.columns * 0.42)))
  vim.api.nvim_set_current_win(detail_win)
  vim.api.nvim_win_set_width(detail_win, detail_width)

  vim.api.nvim_set_current_win(list_win)

  for _, win in ipairs({ list_win, detail_win }) do
    vim.wo[win].number         = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn     = "no"
    vim.wo[win].foldcolumn     = "0"
    vim.wo[win].wrap           = false
    vim.wo[win].cursorline     = false
  end
  vim.wo[list_win].cursorline  = true
  vim.wo[list_win].scrolloff   = 5
  vim.wo[detail_win].wrap      = true
  vim.wo[detail_win].linebreak = true

  local cfg = Config.get()
  vim.wo[list_win].winbar   = string.format(" %%#JiraColHeader#%s%%*  %%#JiraHint#%s%%*", cfg.board_name, cfg.project)
  vim.wo[detail_win].winbar = " %#JiraHint#Select an issue with <CR>%*"

  -- Track this as the buffer AI-context integrations read from.
  last_list_buf = list_buf

  state[list_buf] = {
    columns       = {},
    col_idx       = 1,
    row_idx       = 1,
    list_win      = list_win,
    detail_buf    = detail_buf,
    detail_win    = detail_win,
    detail_hidden = false,
    loading       = false,
    filter        = {},
  }

  local resize_group = vim.api.nvim_create_augroup("JiraTUIResize" .. list_buf, { clear = true })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer   = list_buf,
    once     = true,
    callback = function()
      local s = state[list_buf]
      if s and s.detail_buf and vim.api.nvim_buf_is_valid(s.detail_buf) then
        pcall(vim.api.nvim_buf_delete, s.detail_buf, { force = true })
      end
      state[list_buf] = nil
      if last_list_buf == list_buf then
        last_list_buf = nil
      end
      pcall(vim.api.nvim_del_augroup_by_id, resize_group)
    end,
  })

  -- Reflow to the new window width whenever the list pane (or the whole
  -- terminal) is resized.
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group    = resize_group,
    callback = function()
      if not state[list_buf] then return end
      if not (list_win and vim.api.nvim_win_is_valid(list_win)) then return end
      render(list_buf)
    end,
  })

  -- Initial detail placeholder
  vim.bo[detail_buf].modifiable = true
  vim.api.nvim_buf_set_lines(detail_buf, 0, -1, false, {
    "",
    "  Press <CR> on an issue to view details.",
    "",
    "  Keymaps:",
    "    j / k       move up / down within column",
    "    h / l       move between columns",
    "    <CR>        open issue detail",
    "    a           toggle: my issues only",
    "    A           clear filters (show all)",
    "    /           search",
    "    t           add/remove label filters",
    "    c           write a comment",
    "    i           send issue to AI (hides this pane)",
    "    d           toggle this detail pane",
    "    r           refresh",
    "    <C-o>       open in browser",
    "    L           focus detail pane",
    "    H           focus list pane",
    "    q           quit",
  })
  vim.bo[detail_buf].modifiable = false

  setup_keymaps(list_buf)
  setup_detail_keymaps(list_buf, detail_buf)

  load_board(list_buf)
end

return M
