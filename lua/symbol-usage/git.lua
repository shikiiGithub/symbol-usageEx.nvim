local M = {}

-- cache[bufnr] = { tick = integer, data = { [line] = { author = string, days_ago = integer, summary = string } } }
local cache = {}
-- pending[bufnr] = { callback1, callback2, ... }
local pending = {}

---Clear cache for buffer
---@param bufnr integer
function M.clear_cache(bufnr)
  cache[bufnr] = nil
  pending[bufnr] = nil
end

---Get git info for a line from cache
---@param bufnr integer
---@param line integer 0-based line number
---@return { author: string, days_ago: integer, summary: string }|nil
function M.get_line_info(bufnr, line)
  local c = cache[bufnr]
  if not c then
    return nil
  end
  return c.data[line]
end

---Check if cache is valid for buffer
---@param bufnr integer
---@return boolean
function M.is_cache_valid(bufnr)
  local c = cache[bufnr]
  if not c then
    return false
  end
  return c.tick == vim.api.nvim_buf_get_changedtick(bufnr)
end

---Parse git blame --line-porcelain output
---@param lines string[]
---@return table
function M._parse_porcelain(lines)
  local result = {}
  local current = {}
  local line_num = 0

  for _, line in ipairs(lines) do
    if line:sub(1, 1) == '\t' then
      line_num = line_num + 1
      if current.author and current.author_time then
        local now = os.time()
        local diff = now - current.author_time
        local days_ago = math.floor(diff / 86400)
        result[line_num - 1] = {
          author = current.author,
          days_ago = days_ago,
          summary = current.summary or '',
        }
      end
    else
      local author = line:match('^author (.+)$')
      local author_time = line:match('^author%-time (%d+)$')
      local summary = line:match('^summary (.+)$')
      if author then
        current.author = author
      end
      if author_time then
        current.author_time = tonumber(author_time)
      end
      if summary then
        current.summary = summary
      end
    end
  end

  return result
end

---Fetch git blame info asynchronously for entire buffer
---@param bufnr integer
---@param callback fun(ok: boolean)
function M.fetch_async(bufnr, callback)
  if pending[bufnr] then
    table.insert(pending[bufnr], callback)
    return
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == '' then
    callback(false)
    return
  end

  if vim.fn.executable('git') == 0 then
    callback(false)
    return
  end

  local git_dir = vim.fn.fnamemodify(filepath, ':h')
  local filename = vim.fn.fnamemodify(filepath, ':t')
  local cmd = { 'git', '-C', git_dir, 'blame', '--line-porcelain', '--', filename }

  pending[bufnr] = { callback }
  local stdout_lines = {}

  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= '' then
            table.insert(stdout_lines, line)
          end
        end
      end
    end,
    on_stderr = function() end,
    on_exit = function(_, code)
      vim.schedule(function()
        local cbs = pending[bufnr]
        pending[bufnr] = nil

        if not cbs then
          return
        end

        if code ~= 0 or #stdout_lines == 0 then
          for _, cb in ipairs(cbs) do
            cb(false)
          end
          return
        end

        local data = M._parse_porcelain(stdout_lines)
        local tick = vim.api.nvim_buf_get_changedtick(bufnr)
        cache[bufnr] = { tick = tick, data = data }

        for _, cb in ipairs(cbs) do
          cb(true)
        end
      end)
    end,
  })

  if job_id <= 0 then
    pending[bufnr] = nil
    callback(false)
  end
end

return M
