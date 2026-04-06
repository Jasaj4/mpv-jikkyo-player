-- jikkyo_api.lua — Channel resolution + jikkyo API communication

local mp_available, mp = pcall(require, 'mp') ---@diagnostic disable-line: unused-local
local msg_available, msg = pcall(require, 'mp.msg')
if not msg_available then
    msg = { info = function(...) end, verbose = function(...) end, warn = function(...) end }
end

local M = {}

---------------------------------------------------------------------------
-- Channel mapping: ONID -> jk_id (terrestrial)
--                  SID  -> jk_id (BS)
---------------------------------------------------------------------------
local ONID_TO_JK = {
    [32336] = "jk1",   -- NHK総合・水戸
    [32736] = "jk1",   -- NHK総合・東京
    [32737] = "jk2",   -- NHKEテレ東京
    [32738] = "jk4",   -- 日本テレビ
    [32741] = "jk5",   -- テレビ朝日
    [32739] = "jk6",   -- TBS
    [32742] = "jk7",   -- テレビ東京
    [32740] = "jk8",   -- フジテレビ
    [32391] = "jk9",   -- TOKYO MX
    [32327] = "jk12",  -- チバテレビ
    [32375] = "jk11",  -- tvk
}

local SID_TO_JK = {
    [101]  = "jk101",  -- NHK BS
    [141]  = "jk141",  -- BS日テレ
    [151]  = "jk151",  -- BS朝日
    [161]  = "jk161",  -- BS-TBS
    [171]  = "jk171",  -- BSテレ東
    [181]  = "jk181",  -- BSフジ
    [191]  = "jk191",  -- WOWOWプライム
    [211]  = "jk211",  -- BS11
    [222]  = "jk222",  -- BS12
}

---------------------------------------------------------------------------
-- Resolve ONID/SID to jikkyo channel ID
-- Returns jk_id string or nil
---------------------------------------------------------------------------
function M.resolve_channel(onid, sid)
    if ONID_TO_JK[onid] then return ONID_TO_JK[onid] end
    if onid == 4 then
        if SID_TO_JK[sid] then return SID_TO_JK[sid] end
        local base = sid - (sid % 10) + 1
        if SID_TO_JK[base] then return SID_TO_JK[base] end
    end
    return nil
end

---------------------------------------------------------------------------
-- Build API URL
---------------------------------------------------------------------------
local function api_url(jk_id, start_ts, end_ts)
    return string.format(
        "https://jikkyo.tsukumijima.net/api/kakolog/%s?starttime=%d&endtime=%d&format=xml",
        jk_id, start_ts, end_ts
    )
end

---------------------------------------------------------------------------
-- Validate API response body
-- Returns xml_string on success, nil + error message on failure
---------------------------------------------------------------------------
local function validate_response(body)
    if not body or body == "" then
        return nil, "API fetch failed: empty response"
    end
    if body:match('<error>') then
        return nil, "API returned error"
    end
    if not body:match('<chat ') then
        return nil, "API returned empty packet (no comments)"
    end
    return body
end

---------------------------------------------------------------------------
-- Fetch comments from jikkyo API (async via mpv subprocess)
-- callback(xml_string) on success, callback(nil) on failure
---------------------------------------------------------------------------
function M.fetch_async(jk_id, start_ts, end_ts, callback)
    local url = api_url(jk_id, start_ts, end_ts)
    msg.info("jikkyo-player: fetching from API: " .. url)

    mp.command_native_async({
        name = "subprocess",
        args = {"curl", "-s", "-f", "--max-time", "10", url},
        capture_stdout = true,
    }, function(success, result)
        if not success or result.status ~= 0 then
            msg.verbose("jikkyo-player: API fetch failed")
            callback(nil)
            return
        end
        local xml, err = validate_response(result.stdout)
        if not xml then
            msg.verbose("jikkyo-player: " .. err)
            callback(nil)
            return
        end
        msg.info("jikkyo-player: API fetch successful")
        callback(xml)
    end)
end

---------------------------------------------------------------------------
-- Fetch comments from jikkyo API (synchronous, for CLI use)
-- Returns xml_string on success, nil + error message on failure
---------------------------------------------------------------------------
function M.fetch(jk_id, start_ts, end_ts)
    local url = api_url(jk_id, start_ts, end_ts)
    local cmd = string.format('curl -s -f --max-time 30 "%s"', url)
    local handle = io.popen(cmd, "r")
    if not handle then
        return nil, "failed to execute curl"
    end
    local body = handle:read("*a")
    handle:close()
    return validate_response(body)
end

return M
