-- Helpers for converting to/from Atlassian Document Format (ADF), the JSON
-- rich-text structure Jira Cloud uses for issue descriptions and comments.
local M = {}

--- Flatten an ADF node tree to plain text.
---@param node table?
---@param depth? integer
---@return string
function M.to_text(node, depth)
  depth = depth or 0
  if not node then
    return ""
  end
  local t = node.type or ""
  local out = {}
  if t == "text" then
    return node.text or ""
  elseif t == "hardBreak" then
    return "\n"
  end
  for _, child in ipairs(node.content or {}) do
    out[#out + 1] = M.to_text(child, depth + 1)
  end
  local joined = table.concat(out, "")
  if t == "paragraph" then
    return joined .. "\n"
  end
  if t == "bulletList" or t == "orderedList" then
    return joined
  end
  if t == "listItem" then
    return "    • " .. joined
  end
  if t == "heading" then
    return joined .. "\n"
  end
  if t == "codeBlock" then
    return joined .. "\n"
  end
  return joined
end

--- Build a minimal ADF document from plain text, preserving blank-line
--- paragraph breaks and single-newline hard breaks.
---@param text string
---@return table
function M.from_text(text)
  local content = {}
  for _, para in ipairs(vim.split(text, "\n%s*\n", { trimempty = true })) do
    local para_content = {}
    local lines = vim.split(para, "\n", { plain = true })
    for i, line in ipairs(lines) do
      if line ~= "" then
        para_content[#para_content + 1] = { type = "text", text = line }
      end
      if i < #lines then
        para_content[#para_content + 1] = { type = "hardBreak" }
      end
    end
    if #para_content > 0 then
      content[#content + 1] = { type = "paragraph", content = para_content }
    end
  end
  if #content == 0 then
    content = { { type = "paragraph", content = { { type = "text", text = text } } } }
  end
  return { type = "doc", version = 1, content = content }
end

return M
