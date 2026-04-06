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
    -- NHK総合 (各地域)
    [32336] = "jk1",   -- NHK総合・水戸
    [32736] = "jk1",   -- NHK総合・東京
    -- NHKEテレ
    [32737] = "jk2",   -- NHKEテレ東京
    -- 在京キー局
    [32738] = "jk4",   -- 日本テレビ
    [32741] = "jk5",   -- テレビ朝日
    [32739] = "jk6",   -- TBS
    [32742] = "jk7",   -- テレビ東京
    [32740] = "jk8",   -- フジテレビ
    -- 独立局
    [32391] = "jk9",   -- TOKYO MX
    [32343] = "jk10",  -- テレ玉
    [32375] = "jk11",  -- tvk
    [32327] = "jk12",  -- チバテレビ
    [32395] = "jk13",  -- サンテレビ
    [32390] = "jk14",  -- KBS京都
}

-- BS (ONID=4) / CS SID -> jk_id
local SID_TO_JK = {
    -- NHK BS
    [101]  = "jk101",  -- NHK BS
    [103]  = "jk103",  -- NHK BSプレミアム
    -- BS在京キー局系
    [141]  = "jk141",  -- BS日テレ
    [151]  = "jk151",  -- BS朝日
    [161]  = "jk161",  -- BS-TBS
    [171]  = "jk171",  -- BSテレ東
    [181]  = "jk181",  -- BSフジ
    -- WOWOW
    [191]  = "jk191",  -- WOWOWプライム
    [192]  = "jk192",  -- WOWOWライブ
    [193]  = "jk193",  -- WOWOWシネマ
    -- BS10
    [200]  = "jk200",  -- BS10
    [201]  = "jk201",  -- BS10スターチャンネル
    -- 無料BS
    [211]  = "jk211",  -- BS11イレブン
    [222]  = "jk222",  -- BS12トゥエルビ
    -- 有料BS
    [236]  = "jk236",  -- BSアニマックス
    [252]  = "jk252",  -- WOWOW PLUS
    [260]  = "jk260",  -- BS松竹東宝
    [263]  = "jk263",  -- BSJapanext
    [265]  = "jk265",  -- BSよしもと
    -- CS (AT-X)
    [333]  = "jk333",  -- AT-X
}

---------------------------------------------------------------------------
-- Resolve ONID/SID to jikkyo channel ID
-- Returns jk_id string or nil
---------------------------------------------------------------------------
function M.resolve_channel(onid, sid)
    if ONID_TO_JK[onid] then return ONID_TO_JK[onid] end
    -- BS (ONID=4) / CS (ONID=6,7,10): resolve by SID
    if onid == 4 or onid == 6 or onid == 7 or onid == 10 then
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
