-- arib.lua — arib-ts2ass.js wrapper for ARIB STD-B24 caption extraction
-- No mpv dependency. Requires node + arib-ts2ass.js (not redistributed).

local M = {}

---------------------------------------------------------------------------
-- Platform detection
---------------------------------------------------------------------------
local is_windows = package.config:sub(1,1) == "\\"

---------------------------------------------------------------------------
-- Extract ARIB captions from TS file (synchronous)
-- ts_path: path to .ts file
-- arib_script_path: path to arib-ts2ass.js
-- Returns ASS content string or nil
---------------------------------------------------------------------------
function M.extract(ts_path, arib_script_path)
    -- Check if script exists
    local f = io.open(arib_script_path, "r")
    if not f then return nil end
    f:close()

    local tmp_ass
    if is_windows then
        tmp_ass = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\arib2ass_" .. os.time() .. ".ass"
    else
        tmp_ass = os.tmpname() .. "_arib.ass"
    end

    local cmd = string.format('node "%s" "%s" "%s"', arib_script_path, ts_path, tmp_ass)
    local ok = os.execute(cmd)

    if ok then
        local af = io.open(tmp_ass, "r")
        if af then
            local content = af:read("*a")
            af:close()
            os.remove(tmp_ass)
            return content
        end
    end
    os.remove(tmp_ass)
    return nil
end

---------------------------------------------------------------------------
-- Parse ASS content to extract styles and dialogue lines
-- Returns styles[], dialogues[]
---------------------------------------------------------------------------
function M.parse_ass(arib_ass_content)
    local styles = {}
    local dialogues = {}
    local in_styles = false
    local in_events = false

    for line in arib_ass_content:gmatch("[^\r\n]+") do
        if line:match("^%[V4%+ Styles%]") then
            in_styles = true
            in_events = false
        elseif line:match("^%[Events%]") then
            in_styles = false
            in_events = true
        elseif line:match("^%[") then
            in_styles = false
            in_events = false
        elseif in_styles and line:match("^Style:") then
            styles[#styles + 1] = line
        elseif in_events and line:match("^Dialogue:") then
            dialogues[#dialogues + 1] = line
        end
    end

    return styles, dialogues
end

return M
