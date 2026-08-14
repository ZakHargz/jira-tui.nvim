local Config = require("jira-tui.config")
local Auth = require("jira-tui.auth")

local M = {}

local function base_url()
  return (Config.get().server or ""):gsub("/+$", "")
end

local function no_token(cb, ...)
  vim.schedule(function()
    vim.notify(
      "jira-tui: no API token configured (see |jira-tui-auth| / README#authentication)",
      vim.log.levels.ERROR
    )
  end)
  cb(nil, ...)
end

--- GET a Jira REST endpoint (path relative to `server`).
---@param path string
---@param cb fun(data: table?)
function M.get(path, cb)
  local token = Auth.token()
  if not token then
    no_token(cb)
    return
  end

  local url = base_url() .. path
  local auth = Auth.email() .. ":" .. token
  vim.system(
    { "curl", "-s", "-u", auth, "-H", "Accept: application/json", url },
    { text = true },
    function(result)
      local body = result.stdout or ""
      local ok, data = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
      if not ok or type(data) ~= "table" then
        vim.schedule(function()
          vim.notify("jira-tui: bad response: " .. body:sub(1, 200), vim.log.levels.ERROR)
        end)
        cb(nil)
        return
      end
      local errs = data.errorMessages or (data.errors and next(data.errors) and { vim.inspect(data.errors) })
      if errs and #errs > 0 then
        vim.schedule(function()
          vim.notify("jira-tui: " .. table.concat(errs, ", "), vim.log.levels.ERROR)
        end)
        cb(nil)
        return
      end
      cb(data)
    end
  )
end

--- POST to a Jira REST endpoint.
---@param path string
---@param body table
---@param cb fun(data: table?, err: string?)
function M.post(path, body, cb)
  local token = Auth.token()
  if not token then
    no_token(cb, "no token")
    return
  end

  local url = base_url() .. path
  local auth = Auth.email() .. ":" .. token
  local payload = vim.json.encode(body)
  vim.system(
    {
      "curl", "-s", "-u", auth,
      "-X", "POST",
      "-H", "Content-Type: application/json",
      "-H", "Accept: application/json",
      "--data-binary", "@-",
      url,
    },
    { text = true, stdin = payload },
    function(result)
      local resp_body = vim.trim(result.stdout or "")
      if resp_body == "" then
        cb({})
        return
      end
      local ok, data = pcall(vim.json.decode, resp_body, { luanil = { object = true, array = true } })
      if not ok or type(data) ~= "table" then
        cb(nil, "bad response: " .. resp_body:sub(1, 200))
        return
      end
      local errs = data.errorMessages or (data.errors and next(data.errors) and { vim.inspect(data.errors) })
      if errs and #errs > 0 then
        cb(nil, table.concat(errs, ", "))
        return
      end
      cb(data)
    end
  )
end

return M
