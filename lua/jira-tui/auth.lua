local Config = require("jira-tui.config")

local M = {}

--- Resolve the API token, trying in order:
---   1. `auth.token` — a literal string, or a function returning one
---   2. `$<auth.token_env>` (default: JIRA_API_TOKEN)
---   3. `auth.token_file` — a plain-text file containing just the token
--- Returns `nil` if none of the above yielded a non-empty string.
---@return string?
function M.token()
  local cfg = Config.get().auth or {}

  if type(cfg.token) == "function" then
    local ok, t = pcall(cfg.token)
    if ok and type(t) == "string" and t ~= "" then
      return t
    end
  elseif type(cfg.token) == "string" and cfg.token ~= "" then
    return cfg.token
  end

  local env_name = cfg.token_env or "JIRA_API_TOKEN"
  local from_env = os.getenv(env_name)
  if from_env and from_env ~= "" then
    return from_env
  end

  if cfg.token_file then
    local path = vim.fn.expand(cfg.token_file)
    local f = io.open(path, "r")
    if f then
      local raw = f:read("*a")
      f:close()
      local trimmed = vim.trim(raw or "")
      if trimmed ~= "" then
        return trimmed
      end
    end
  end

  return nil
end

---@return string?
function M.email()
  return Config.get().email
end

return M
