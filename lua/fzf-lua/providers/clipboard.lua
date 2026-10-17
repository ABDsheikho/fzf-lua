local core = require "fzf-lua.core"
local utils = require "fzf-lua.utils"
local libuv = require "fzf-lua.libuv"
local config = require "fzf-lua.config"

local M = {}

---@class fzf-lua.clipboard.Provider
---Source of clipboard history entries, one per line.
---Either a shell command string or a function yielding entries.
---List rows use a format (example: `id<TAB>text`) with the entry's full
---content flattened to a single line, so fuzzy search covers the whole
---content while display stays on one row per entry. Rows may fall back to
---a short preview when the full content is unavailable.
---@field list string|fun(cb: fun(line: string?))
---Maps a raw entry to its text content, used for the text preview
---and as the default `<enter>` copy payload.
---@field decode fun(entry: string): string
---Optional, enables image preview. Writes the entry's raw bytes to a
---`<base>.<ext>` temp file (extension chosen by the provider) and returns
---the final path, or `nil` when the entry cannot be materialized.
---Must stay byte-exact: never round-trip binary data through a Lua string.
---@field file? fun(entry: string, base: string): string?

---Flatten decoded content to a single searchable line.
---Newlines must go or the row would split into multiple fzf entries;
---NULs must go or they corrupt the feed to fzf's stdin.
---@param text string
---@return string
local function flatten(text)
  return text:gsub("%z", ""):gsub("[\r\n]", " "):gsub("%s+$", "")
end

---Decode ids in parallel with a single synchronous spawn.
---Each worker writes its raw bytes to `<tmpdir>/<id>`; per-file output
---avoids interleaving on a shared pipe, keeps bytes exact (no framing
---protocol to corrupt), and makes order preservation trivial. Returns
---`nil` when the batch path is unavailable so the caller can fall back
---to sequential decode.
---@param ids string[]
---@return table<string, string>?
local function batch_decode(ids)
  if #ids == 0 then return {} end
  if vim.fn.executable("xargs") ~= 1 then return nil end
  local tmpdir = vim.fn.tempname()
  if tmpdir == "" or vim.fn.mkdir(tmpdir, "p") ~= 1 then return nil end
  local ok, flat = pcall(function()
    local jobs = 16
    if vim.uv and vim.uv.available_parallelism then
      local pok, n = pcall(vim.uv.available_parallelism)
      if pok and type(n) == "number" and n >= 1 then
        jobs = math.min(16, math.max(4, math.floor(n)))
      end
    end
    local esc = libuv.shellescape(tmpdir)
    local script = ([[xargs -0 -P%d -n1 sh -c 'cliphist decode "$2" > %s/"$2" 2>/dev/null' _ %s]])
        :format(jobs, esc, esc)
    local obj = vim.system({ "sh", "-c", script }, { stdin = table.concat(ids, "\0") .. "\0" }):wait()
    assert(obj.code == 0, "xargs batch decode failed")
    local res = {}
    for _, id in ipairs(ids) do
      local f = io.open(tmpdir .. "/" .. id, "rb")
      if f then
        local data = f:read("*a")
        f:close()
        if data and #data > 0 then res[id] = flatten(data) end
      end
    end
    return res
  end)
  vim.fn.delete(tmpdir, "rf")
  if not ok then return nil end
  return flat
end

---Default `cliphist` provider.
---`cliphist list` prints rows (example: `id<TAB>preview`), newest first,
---and `cliphist decode <id>` returns the byte-exact entry content, with
---binary entries rendered as `[[ binary data <size> <format> <WxH> ]]`.
---Each row carries the decoded full text flattened to a single line, so
---fuzzy search matches words anywhere in the entry, not just the one-line
---`cliphist list` preview (which is itself just a truncated prefix of the
---full text, keeping it would show every line doubled). Rows fall back to
---the plain preview when decoding fails; binary entries keep their
---preview-only row.
M.provider = {
  list = function(cb)
    local rows, rc = utils.io_systemlist({ "cliphist", "list" })
    if rc ~= 0 then
      utils.warn("clipboard: 'cliphist list' failed%s",
        rows[1] and (": " .. rows[1]) or "")
      cb(nil)
      return
    end
    ---@type { row: string, id: string?, preview: string? }[]
    local parsed, ids = {}, {}
    for _, row in ipairs(rows) do
      local id, preview = row:match("^(%d+)\t(.*)$")
      parsed[#parsed + 1] = { row = row, id = id, preview = preview }
      if id and not (preview and preview:match("^%[%[ binary data")) then
        ids[#ids + 1] = id
      end
    end
    local flat = batch_decode(ids)
    if flat == nil then
      -- batch path unavailable: sequential decode
      flat = {}
      for _, id in ipairs(ids) do
        local text, drc = utils.io_system({ "cliphist", "decode", id })
        if drc == 0 and text and #text > 0 then flat[id] = flatten(text) end
      end
    end
    for _, p in ipairs(parsed) do
      local tail = p.id and flat[p.id] or nil
      if tail and #tail > 0 then
        cb(("%s\t%s"):format(p.id, tail))
      else
        cb(p.row)
      end
    end
    cb(nil)
  end,
  decode = function(entry)
    local id = entry:match("^(%d+)")
    if not id then return entry end
    local out, rc = utils.io_system({ "cliphist", "decode", id })
    if rc == 0 and out then return out end
    return entry
  end,
  file = function(entry, base)
    local id, preview = entry:match("^(%d+)\t([^\t]*)")
    if not id or not preview or not preview:match("^%[%[ binary data") then
      return nil
    end
    local format = preview:match("^%[%[ binary data %S+ (%S+)")
    local dst = format and (base .. "." .. format:lower()) or base
    -- shell redirection keeps the decoded bytes byte-exact, `vim.system`
    -- `stdout` redirection does not reliably write binary output to a file
    local cmd = string.format("cliphist decode %s > %s",
      libuv.shellescape(id), libuv.shellescape(dst))
    local _, rc = utils.io_system({ "sh", "-c", cmd })
    ---@diagnostic disable-next-line: deprecated
    if rc == 0 and (vim.uv or vim.loop).fs_stat(dst) then
      return dst
    end
    return nil
  end,
}

---@param opts fzf-lua.config.Clipboard|{}?
---@return thread?, string?, table?
M.clipboard = function(opts)
  ---@type fzf-lua.config.Clipboard
  opts = config.normalize_opts(opts, "clipboard")
  if not opts then return end
  local provider = opts.provider
  if provider == nil then
    if vim.fn.executable("cliphist") == 1 then
      provider = M.provider
    else
      utils.error("clipboard: no provider configured and 'cliphist' was not found, "
        .. "install 'cliphist' or set `clipboard = { provider = { list = ..., decode = ... } }`.")
      return
    end
  end
  if type(provider) ~= "table"
      or (type(provider.list) ~= "string" and type(provider.list) ~= "function")
      or type(provider.decode) ~= "function"
      or (provider.file ~= nil and type(provider.file) ~= "function") then
    utils.error("clipboard: invalid provider, expected "
      .. "`{ list = <cmd|fn>, decode = <fn>, file = <fn>? }`.")
    return
  end
  opts.provider = provider
  return core.fzf_exec(provider.list, opts)
end

return M
