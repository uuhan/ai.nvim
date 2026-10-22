local M = {}

--- Assign 'filetype' only when it differs. Setting it fires FileType even for
--- the same value, which reruns ftplugins and restarts tree-sitter
--- highlighting; doing that on every streamed chunk churns the parser until it
--- recurses through injections without end.
function M.set_filetype(bufnr, filetype)
  if vim.bo[bufnr].filetype ~= filetype then
    vim.bo[bufnr].filetype = filetype
  end
end

--- Replace the buffer's lines, rewriting only from the first line that
--- differs. Streaming appends to the tail, so tree-sitter sees a small edit at
--- the end instead of every tree and injection being invalidated per chunk.
function M.set_lines(bufnr, lines)
  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local prefix = 0
  local shared = math.min(#current, #lines)
  while prefix < shared and current[prefix + 1] == lines[prefix + 1] do
    prefix = prefix + 1
  end
  if prefix == #current and prefix == #lines then
    return
  end
  vim.api.nvim_buf_set_lines(bufnr, prefix, -1, false, vim.list_slice(lines, prefix + 1))
end

return M
