-- jikkyo-player.lua — mpv script: load niconico jikkyo comments as ASS subtitles
-- Delegates TS parsing, API fetch, and ASS rendering to lib/ modules.
-- Communicates with osc_tethys via script-message for UI button integration.
--
-- Loaded via main.lua (mpv script directory entry point), which sets up
-- package.path so that lib/ modules are require-able.

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local opt = require 'mp.options'

local ts_parser = require("ts_parser")
local jikkyo_api = require("jikkyo_api")
local danmaku_renderer = require("danmaku_renderer")

-- ARIB module is optional
local arib_available, arib = pcall(require, "arib")
if not arib_available then
    msg.info("jikkyo-player: arib module not available, ARIB captions disabled")
    arib = nil
end

---------------------------------------------------------------------------
-- Options (overridable via script-opts/jikkyo-player.conf)
---------------------------------------------------------------------------
local opts = {
    play_res_x       = 1920,
    play_res_y       = 1080,
    scroll_duration  = 7.0,
    fixed_duration   = 5.0,
    font_name        = "Hiragino Sans W5",
    font_outline     = 1.0,
    emoji_font       = "Noto Emoji",
    font_size        = 0,
    lane_count       = 20,
    lane_margin      = 4,
    scroll_area_ratio = 0.75,
    recording_offset = 7,
    danmaku_offset   = 0,
    -- Default subtitle track: "both", "danmaku", "arib"
    default_track    = "both",
    -- Colon-separated list of directories to recursively search for danmaku XML.
    -- When set, the same-directory lookup is skipped.
    -- Example: /path/to/xmls:/another/path
    danmaku_search_dirs = "",
}
opt.read_options(opts, "jikkyo-player")

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local loaded = false
local visible = true
local loading = false

-- Track management: up to 3 subtitle tracks
-- "arib"    = ARIB captions only
-- "danmaku" = danmaku comments only
-- "both"    = merged danmaku + ARIB
local tracks = {
    arib    = { path = nil, id = nil, pending = false },
    danmaku = { path = nil, id = nil, pending = false },
    both    = { path = nil, id = nil, pending = false },
}

-- Cycle order for n key
local cycle_order = { "danmaku", "arib", "both" }

-- Raw ASS content for building merged track
local danmaku_ass_content = nil
local arib_ass_content = nil
local active_track = nil  -- which track key is currently selected

---------------------------------------------------------------------------
-- Platform detection
---------------------------------------------------------------------------
local is_windows = package.config:sub(1,1) == "\\"

---------------------------------------------------------------------------
-- Notify OSC of state change
---------------------------------------------------------------------------
local function notify_osc()
    mp.commandv("script-message-to", "osc_tethys", "danmaku-update",
        loaded and "1" or "0",
        visible and "1" or "0",
        loading and "1" or "0")
end

---------------------------------------------------------------------------
-- Create a temp file path
---------------------------------------------------------------------------
local function tmp_path(prefix)
    if is_windows then
        return (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\" .. prefix .. "_" .. os.time() .. ".ass"
    else
        return os.tmpname() .. "_" .. prefix .. ".ass"
    end
end

---------------------------------------------------------------------------
-- Remove current danmaku subtitles (all tracks)
---------------------------------------------------------------------------
local function cleanup()
    for _, t in pairs(tracks) do
        if t.id then
            mp.commandv("sub-remove", t.id)
            t.id = nil
        end
        if t.path then
            os.remove(t.path)
            t.path = nil
        end
        t.pending = false
    end
    danmaku_ass_content = nil
    arib_ass_content = nil
    active_track = nil
    loaded = false
    visible = true
end

---------------------------------------------------------------------------
-- Find the track ID of a subtitle by title (search from end for latest)
---------------------------------------------------------------------------
local function find_track_id_by_title(title)
    local track_list = mp.get_property_native("track-list", {})
    for i = #track_list, 1, -1 do
        local t = track_list[i]
        if t.type == "sub" and t.title == title and t.external then
            return t.id
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Write ASS content to temp file and add as subtitle track
-- Returns true on success
---------------------------------------------------------------------------
local function add_sub_track(key, ass_content, title, auto_select)
    local t = tracks[key]

    -- Write temp file
    local tmp = tmp_path(key)
    local f = io.open(tmp, "w")
    if not f then
        msg.error("Failed to create temp ASS file: " .. tmp)
        return false
    end
    f:write(ass_content)
    f:close()
    t.path = tmp

    -- Add track: "select" makes it active, "auto" adds without selecting
    local flag = auto_select and "select" or "auto"
    t.pending = true
    mp.commandv("sub-add", tmp, flag, title)

    mp.add_timeout(0.1, function()
        t.pending = false
        t.id = find_track_id_by_title(title)
        if t.id then
            msg.info("Subtitle track loaded: " .. title .. " (track " .. t.id .. ")")
            if auto_select then
                active_track = key
            end
        else
            msg.warn("sub-add succeeded but track not found: " .. title)
        end
    end)
    return true
end

---------------------------------------------------------------------------
-- Determine which track to select based on what's available and preference
---------------------------------------------------------------------------
local function select_best_track()
    local pref = opts.default_track

    -- If preferred track is available, use it
    if pref == "both" and tracks.both.id then
        return "both"
    elseif pref == "danmaku" and tracks.danmaku.id then
        return "danmaku"
    elseif pref == "arib" and tracks.arib.id then
        return "arib"
    end

    -- Fallback: merged > danmaku > arib
    if tracks.both.id then return "both" end
    if tracks.danmaku.id then return "danmaku" end
    if tracks.arib.id then return "arib" end
    return nil
end

---------------------------------------------------------------------------
-- Switch active subtitle to the best available track
---------------------------------------------------------------------------
local function activate_best_track()
    local best = select_best_track()
    if not best then return end

    local t = tracks[best]
    if t.id then
        mp.set_property_number("sid", t.id)
        active_track = best
        visible = true
        loaded = true
        msg.info("Active subtitle track: " .. best .. " (track " .. t.id .. ")")
    end
    notify_osc()
end

---------------------------------------------------------------------------
-- Track name for OSD display
---------------------------------------------------------------------------
local track_labels = {
    danmaku = "弾幕",
    arib    = "字幕",
    both    = "弾幕+字幕",
}

---------------------------------------------------------------------------
-- Cycle through available ASS tracks (n key)
-- Order: 弾幕 → 字幕 → 弾幕+字幕 → (off) → 弾幕 → ...
---------------------------------------------------------------------------
local function cycle_danmaku_track()
    if not loaded then return end

    -- Build list of available tracks in cycle order
    local available = {}
    for _, key in ipairs(cycle_order) do
        if tracks[key].id then
            available[#available + 1] = key
        end
    end
    if #available == 0 then return end

    -- Find current position in available list
    local current_idx = 0
    if visible and active_track then
        for i, key in ipairs(available) do
            if key == active_track then
                current_idx = i
                break
            end
        end
    end

    -- Next: advance, wrapping through "off" state
    local next_idx = current_idx + 1
    if next_idx > #available then
        -- Turn off
        mp.set_property("sid", "no")
        visible = false
        active_track = nil
        mp.osd_message("字幕: off")
        notify_osc()
        return
    end

    local next_key = available[next_idx]
    local t = tracks[next_key]
    mp.set_property_number("sid", t.id)
    active_track = next_key
    visible = true
    mp.osd_message("字幕: " .. track_labels[next_key])
    notify_osc()
end

---------------------------------------------------------------------------
-- Merge ARIB caption ASS into danmaku ASS
---------------------------------------------------------------------------
local function merge_arib(danmaku_ass, arib_raw)
    if not arib or not arib_raw then return nil end

    local cap_styles, cap_dialogues = arib.parse_ass(arib_raw)
    if #cap_dialogues == 0 then return nil end

    msg.info("jikkyo-player: merging " .. #cap_dialogues .. " ARIB caption lines")
    local merged = danmaku_ass
    local style_block = table.concat(cap_styles, "\n")
    merged = merged:gsub(
        "(\n%[Events%])",
        "\n" .. style_block .. "%1"
    )
    merged = merged .. table.concat(cap_dialogues, "\n") .. "\n"
    return merged
end

---------------------------------------------------------------------------
-- Called when a component (danmaku or ARIB) finishes loading.
-- Adds/updates tracks as needed.
---------------------------------------------------------------------------
local function on_component_ready()
    -- Always ensure danmaku-only track exists when danmaku is ready
    if danmaku_ass_content and not tracks.danmaku.id and not tracks.danmaku.pending then
        local should_select = (not loaded)
        add_sub_track("danmaku", danmaku_ass_content, "弾幕", should_select)
        if should_select then
            loaded = true
            visible = true
            notify_osc()
        end
    end

    -- Always ensure ARIB-only track exists when ARIB is ready
    if arib_ass_content and not tracks.arib.id and not tracks.arib.pending then
        local should_select = (not loaded and not danmaku_ass_content)
        add_sub_track("arib", arib_ass_content, "字幕", should_select)
        if should_select then
            loaded = true
            visible = true
            notify_osc()
        end
    end

    -- When both are available, create merged track
    if danmaku_ass_content and arib_ass_content and not tracks.both.id and not tracks.both.pending then
        local merged = merge_arib(danmaku_ass_content, arib_ass_content)
        if merged then
            add_sub_track("both", merged, "弾幕+字幕", false)
        end
        -- After adding merged track, switch to best track after a delay
        -- (to let the track be registered)
        mp.add_timeout(0.2, function()
            activate_best_track()
        end)
    end
end

---------------------------------------------------------------------------
-- Process XML string: parse -> render danmaku ASS, start ARIB extraction
---------------------------------------------------------------------------
local function process_xml_string(xml_string, ts_path, rec_start_ts)
    local ass_content, count = danmaku_renderer.render(xml_string, rec_start_ts, opts)
    msg.info("Rendered " .. count .. " comments to ASS")

    danmaku_ass_content = ass_content
    on_component_ready()

    -- Try to extract ARIB captions from TS file (async via mpv subprocess)
    if ts_path and arib then
        local script_dir = mp.get_script_directory()
        local script_path = utils.join_path(script_dir, "vendor/arib-ts2ass.js/arib-ts2ass.js")

        local check = io.open(script_path, "r")
        if check then
            check:close()
            local tmp_ass = tmp_path("arib2ass")

            mp.command_native_async({
                name = "subprocess",
                args = {"node", script_path, ts_path, tmp_ass},
                capture_stdout = true,
                capture_stderr = true,
            }, function(success, result)
                if success and result.status == 0 then
                    local af = io.open(tmp_ass, "r")
                    if af then
                        local content = af:read("*a")
                        af:close()
                        os.remove(tmp_ass)
                        msg.info("jikkyo-player: arib-ts2ass.js extracted captions")
                        arib_ass_content = content
                        on_component_ready()
                        return
                    end
                end
                os.remove(tmp_ass)
                msg.verbose("jikkyo-player: arib-ts2ass.js failed or produced no output")
            end)
        else
            msg.verbose("jikkyo-player: arib-ts2ass.js not found at " .. script_path)
        end
    end
end

---------------------------------------------------------------------------
-- Logging helper for ts_parser
---------------------------------------------------------------------------
local function ts_log(level, message)
    if level == "info" then
        msg.info("jikkyo-player: " .. message)
    else
        msg.verbose("jikkyo-player: " .. message)
    end
end

---------------------------------------------------------------------------
-- Try to fetch from API (async)
---------------------------------------------------------------------------
local function try_api_fetch()
    local video_path = mp.get_property("path", "")

    local info = ts_parser.parse(video_path, ts_log)
    if not info then
        msg.verbose("jikkyo-player: TS stream parse failed, skipping API fetch")
        return
    end

    if not info.onid then
        msg.verbose("jikkyo-player: no ONID in TS stream, skipping API fetch")
        return
    end
    local jk_id = jikkyo_api.resolve_channel(info.onid, info.sid)
    if not jk_id then
        msg.verbose(string.format(
            "jikkyo-player: unknown channel ONID=%d SID=%d, skipping API fetch",
            info.onid, info.sid))
        return
    end

    local start_ts = info.rec_start
    local end_ts   = info.rec_end
    if not start_ts or not end_ts then
        msg.verbose("jikkyo-player: TOT incomplete (need both head and tail), skipping API fetch")
        return
    end

    msg.info(string.format("jikkyo-player: using TOT timing — %d → %d (%ds)",
        start_ts, end_ts, end_ts - start_ts))

    loading = true
    notify_osc()

    jikkyo_api.fetch_async(jk_id, start_ts, end_ts, function(xml_string)
        loading = false
        if xml_string then
            process_xml_string(xml_string, video_path, info.rec_start)
        end
        notify_osc()
    end)
end

---------------------------------------------------------------------------
-- Recursively search a directory for a file with the given name.
-- Returns the full path on first match, or nil.
---------------------------------------------------------------------------
local function find_file_recursive(dir, target_name)
    local entries = utils.readdir(dir, "all")
    if not entries then return nil end
    for _, entry in ipairs(entries) do
        local full = utils.join_path(dir, entry)
        local info = utils.file_info(full)
        if info then
            if info.is_dir then
                local found = find_file_recursive(full, target_name)
                if found then return found end
            elseif entry == target_name then
                return full
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Parse danmaku_search_dirs option into a list of directory paths.
---------------------------------------------------------------------------
local function parse_search_dirs()
    if opts.danmaku_search_dirs == "" then return nil end
    local dirs = {}
    -- Use ";" on Windows (colon conflicts with drive letters), ":" on Unix
    local sep_pattern = is_windows and "[^;]+" or "[^:]+"
    for entry in opts.danmaku_search_dirs:gmatch(sep_pattern) do
        -- Trim whitespace
        local d = entry:match("^%s*(.-)%s*$")
        if d ~= "" then
            dirs[#dirs + 1] = d
        end
    end
    if #dirs == 0 then return nil end
    return dirs
end

---------------------------------------------------------------------------
-- Try to load danmaku: local XML first, then API fetch
---------------------------------------------------------------------------
local function try_load_danmaku()
    local path = mp.get_property("path", "")
    if path == "" then return end

    local dir, filename = utils.split_path(path)

    local base = filename:match("(.+)%.[^%.]+$")
    if base then
        local xml_name = base .. ".xml"
        local search_dirs = parse_search_dirs()

        if search_dirs then
            -- Search specified directories recursively
            for _, search_dir in ipairs(search_dirs) do
                local found = find_file_recursive(search_dir, xml_name)
                if found then
                    local f = io.open(found, "r")
                    if f then
                        local content = f:read("*a")
                        f:close()
                        msg.info("jikkyo-player: auto-loading " .. found)
                        local info = ts_parser.parse(path, ts_log)
                        process_xml_string(content, path, info and info.rec_start)
                        return
                    end
                end
            end
        else
            -- Default: try same-name .xml in same directory
            local xml_path = utils.join_path(dir, xml_name)
            local f = io.open(xml_path, "r")
            if f then
                local content = f:read("*a")
                f:close()
                msg.info("jikkyo-player: auto-loading " .. xml_path)
                local info = ts_parser.parse(path, ts_log)
                process_xml_string(content, path, info and info.rec_start)
                return
            end
        end
    end

    try_api_fetch()
end

---------------------------------------------------------------------------
-- Auto-load on file-loaded
---------------------------------------------------------------------------
local function on_file_loaded()
    cleanup()
    notify_osc()
    try_load_danmaku()
end

---------------------------------------------------------------------------
-- Toggle visibility
---------------------------------------------------------------------------
local function toggle_visibility()
    if not loaded then return end
    visible = not visible

    if visible then
        -- Re-activate the best track
        activate_best_track()
    else
        -- Deselect subtitle
        local current_sid = mp.get_property_number("sid", 0)
        -- Check if current sid is one of our tracks
        for _, t in pairs(tracks) do
            if t.id and current_sid == t.id then
                mp.set_property("sid", "no")
                break
            end
        end
    end
    notify_osc()
end

---------------------------------------------------------------------------
-- Script messages from OSC
---------------------------------------------------------------------------
mp.register_script_message("danmaku-load", function()
    try_load_danmaku()
end)

mp.register_script_message("danmaku-toggle-vis", function()
    toggle_visibility()
end)

---------------------------------------------------------------------------
-- Key bindings
---------------------------------------------------------------------------
mp.add_key_binding("n", "cycle-danmaku-track", cycle_danmaku_track)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
mp.register_event("file-loaded", on_file_loaded)

msg.info("jikkyo-player loaded")
