-- tests/locale_tools.lua -- static localization checks for the test suite
-- (tests/run_tests.lua). They work on the addon's SOURCE TEXT, so they also cover
-- UI.lua and Casting.lua -- the files the harness never loads.

local M = {}

-- The files that read the string table (ns.L). Locales/ files define it.
M.SOURCE_FILES = { "Locale.lua", "Core.lua", "Casting.lua", "UI.lua", "Settings.lua" }
M.BASE_LOCALE = "Locales/enUS.lua"

-- The client languages a translation file may register (GetLocale() values).
M.LOCALE_CODES = {
  enUS = true, deDE = true, esES = true, esMX = true, frFR = true, itIT = true,
  koKR = true, ptBR = true, ruRU = true, zhCN = true, zhTW = true,
}

local function readFile(path)
  local f = assert(io.open(path, "r"))
  local text = f:read("*a")
  f:close()
  return text
end
M.readFile = readFile

-- Source text with its "--" line comments blanked out (string contents are left alone),
-- so a key that is only mentioned in a comment doesn't count as read.
local function stripComments(text)
  local out = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local quote, i, cut = nil, 1, nil
    while i <= #line do
      local c = line:sub(i, i)
      if quote then
        if c == "\\" then i = i + 1 elseif c == quote then quote = nil end
      elseif c == '"' or c == "'" then
        quote = c
      elseif c == "-" and line:sub(i + 1, i + 1) == "-" then
        cut = i
        break
      end
      i = i + 1
    end
    out[#out + 1] = cut and line:sub(1, cut - 1) or line
  end
  return table.concat(out, "\n")
end

-- How the code reads the string table. Returns
--   read    = { [KEY] = "File.lua" }          -- every key read as L.KEY / ns.L.KEY
--   byFile  = { ["File.lua"] = { [KEY] = true } }
--   dynamic = { "File.lua: <snippet>", ... }  -- L[...] lookups: a computed key would be
--             invisible to this scan, so the code never uses that form
function M.scanKeys(root)
  local out = { read = {}, byFile = {}, dynamic = {} }
  for _, file in ipairs(M.SOURCE_FILES) do
    local text = stripComments(readFile(root .. file))
    out.byFile[file] = {}
    for key in text:gmatch("%f[%w_]L%.([%u][%u%d_]*)") do
      out.read[key] = out.read[key] or file
      out.byFile[file][key] = true
    end
    for snippet in text:gmatch("%f[%w_]L%[[^\n]*") do
      out.dynamic[#out.dynamic + 1] = file .. ": " .. snippet
    end
  end
  return out
end

-- The format placeholders a string consumes: { [argument position] = conversion letter }.
-- Positional specifiers ("%2$s" -- the game's format() accepts them, stock Lua does not,
-- so they are parsed here and never executed) name their position; plain ones take the
-- next. "%%" is a literal percent. Returns nil + reason for a malformed string, and a
-- third result telling whether positional forms were used.
function M.signature(s)
  local sig, nextPos, i = {}, 1, 1
  local sawPositional, sawPlain = false, false
  while true do
    local at = s:find("%", i, true)
    if not at then break end
    if s:sub(at + 1, at + 1) == "%" then
      i = at + 2
    else
      local pos, afterPos = s:match("^(%d+)%$()", at + 1)
      local flags, conv = s:match("^([%-%+ #0]*%d*%.?%d*)(%a)", afterPos or (at + 1))
      -- Only the conversions format() knows; a stray "%" in prose ("100% more") must be
      -- written "%%".
      if not conv or not ("cdiouxXeEfgGqs"):find(conv, 1, true) then
        return nil, "malformed placeholder at character " .. at .. " (a literal percent sign is written %%)"
      end
      local index
      if pos then
        sawPositional = true
        index = tonumber(pos)
      else
        sawPlain = true
        index = nextPos
        nextPos = nextPos + 1
      end
      if sig[index] and sig[index] ~= conv then
        return nil, "argument " .. index .. " is used as both %" .. sig[index] .. " and %" .. conv
      end
      sig[index] = conv
      i = (afterPos or (at + 1)) + #flags + 1
    end
  end
  if sawPositional and sawPlain then
    return nil, "mixes positional (%1$s) and plain (%s) placeholders"
  end
  return sig, nil, sawPositional
end

local function sameSignature(a, b)
  local max = 0
  for index in pairs(a) do if index > max then max = index end end
  for index in pairs(b) do if index > max then max = index end end
  for index = 1, max do
    if a[index] ~= b[index] then return false end
  end
  return true
end

-- What is wrong with a translation `overlay` (the keys a Locales/xxXX.lua assigned),
-- measured against the base table: a sorted list of problems, empty when it is fine.
function M.checkTranslation(base, overlay)
  local keys = {}
  for key in pairs(overlay) do keys[#keys + 1] = tostring(key) end
  table.sort(keys)
  local problems = {}
  for _, key in ipairs(keys) do
    local value = overlay[key]
    if base[key] == nil then
      problems[#problems + 1] = key .. ": not a key of the base locale"
    elseif type(value) ~= "string" or value == "" then
      problems[#problems + 1] = key .. ": must be a non-empty string"
    else
      local got, reason = M.signature(value)
      if not got then
        problems[#problems + 1] = key .. ": " .. reason
      elseif not sameSignature(got, (M.signature(base[key]))) then
        problems[#problems + 1] = key .. ": placeholders differ from the base locale"
      end
    end
  end
  return problems
end

-- The addon files the TOC loads, in order (comments and ## directives skipped,
-- backslashes normalized).
function M.tocFiles(root)
  local files = {}
  for line in readFile(root .. "FishTips.toc"):gmatch("[^\r\n]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      files[#files + 1] = (line:gsub("\\", "/"))
    end
  end
  return files
end

return M
