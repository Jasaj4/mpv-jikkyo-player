-- danmaku_renderer.lua — XML comment parsing + ASS subtitle generation
-- No mpv dependency

local M = {}

---------------------------------------------------------------------------
-- Default options
---------------------------------------------------------------------------
local DEFAULTS = {
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
}

---------------------------------------------------------------------------
-- Color mapping (mail command -> ASS BGR)
---------------------------------------------------------------------------
local COLOR_MAP = {
    red     = "&H0000FF&",
    orange  = "&H00A5FF&",
    green   = "&H00FF00&",
    blue    = "&HFF0000&",
    yellow  = "&H00FFFF&",
    cyan    = "&HFFFF00&",
    purple  = "&HFF00FF&",
    pink    = "&HCB69FF&",
    white   = nil,
}

---------------------------------------------------------------------------
-- Utility: ASS time format
---------------------------------------------------------------------------
local function to_ass_time(seconds)
    if seconds < 0 then seconds = 0 end
    local h = math.floor(seconds / 3600)
    local m = math.floor(seconds / 60) % 60
    local s = seconds % 60
    return string.format("%d:%02d:%05.2f", h, m, s)
end

---------------------------------------------------------------------------
-- Utility: XML entity decode
---------------------------------------------------------------------------
local function xml_decode(s)
    s = s:gsub("&amp;", "&")
    s = s:gsub("&lt;", "<")
    s = s:gsub("&gt;", ">")
    s = s:gsub("&quot;", '"')
    s = s:gsub("&apos;", "'")
    return s
end

---------------------------------------------------------------------------
-- Utility: estimate text width in ASS pixels
---------------------------------------------------------------------------
local function estimate_text_width(text, font_size)
    local width = 0
    local i = 1
    local len = #text
    while i <= len do
        local b = text:byte(i)
        local cp_len
        if b < 0x80 then cp_len = 1
        elseif b < 0xE0 then cp_len = 2
        elseif b < 0xF0 then cp_len = 3
        else cp_len = 4 end
        if cp_len == 1 then
            width = width + font_size * 0.5
        else
            width = width + font_size * 1.0
        end
        i = i + cp_len
    end
    return width
end

---------------------------------------------------------------------------
-- Utility: escape ASS special chars in text
---------------------------------------------------------------------------
local function ass_escape(text)
    text = text:gsub("{", "\\{")
    text = text:gsub("}", "\\}")
    text = text:gsub("\n", " ")
    text = text:gsub("\r", "")
    return text
end

local function ass_round(value)
    if value >= 0 then
        return math.floor(value + 0.5)
    end
    return math.ceil(value - 0.5)
end

---------------------------------------------------------------------------
-- Utility: detect emoji codepoints and wrap with emoji font
---------------------------------------------------------------------------
local function is_emoji_codepoint(cp)
    if cp >= 0x1F000 and cp <= 0x1FAFF then return true end
    if cp >= 0x1FC00 and cp <= 0x1FFFF then return true end
    if cp >= 0x2600 and cp <= 0x27BF then return true end
    if cp >= 0x2300 and cp <= 0x23FF then return true end
    if cp >= 0x2B05 and cp <= 0x2B55 then return true end
    if cp == 0x200D then return true end
    if cp >= 0xFE00 and cp <= 0xFE0F then return true end
    if cp == 0x20E3 then return true end
    if cp == 0x00A9 or cp == 0x00AE then return true end
    if cp == 0x2139 then return true end
    if cp >= 0x2194 and cp <= 0x21AA then return true end
    if cp == 0x3030 or cp == 0x303D then return true end
    if cp == 0x3297 or cp == 0x3299 then return true end
    return false
end

local function utf8_codepoint(s, i)
    local b = s:byte(i)
    if not b then return nil, i end
    local cp, len
    if b < 0x80 then
        cp, len = b, 1
    elseif b < 0xE0 then
        cp = (b - 0xC0) * 0x40 + (s:byte(i+1) - 0x80)
        len = 2
    elseif b < 0xF0 then
        cp = (b - 0xE0) * 0x1000 + (s:byte(i+1) - 0x80) * 0x40 + (s:byte(i+2) - 0x80)
        len = 3
    else
        cp = (b - 0xF0) * 0x40000 + (s:byte(i+1) - 0x80) * 0x1000
           + (s:byte(i+2) - 0x80) * 0x40 + (s:byte(i+3) - 0x80)
        len = 4
    end
    return cp, len
end

local function wrap_emoji_font(text, emoji_font)
    if not emoji_font or emoji_font == "" then return text end
    local parts = {}
    local in_emoji = false
    local i = 1
    local len = #text

    while i <= len do
        if text:byte(i) == 0x7B and (i == 1 or text:byte(i-1) ~= 0x5C) then
            if in_emoji then
                parts[#parts+1] = "{\\fn}"
                in_emoji = false
            end
            local j = text:find("}", i + 1, true)
            if j then
                parts[#parts+1] = text:sub(i, j)
                i = j + 1
            else
                parts[#parts+1] = text:sub(i)
                break
            end
        else
            local cp, cp_len = utf8_codepoint(text, i)
            if cp and is_emoji_codepoint(cp) then
                if not in_emoji then
                    parts[#parts+1] = "{\\fn" .. emoji_font .. "}"
                    in_emoji = true
                end
                parts[#parts+1] = text:sub(i, i + cp_len - 1)
            else
                if in_emoji then
                    parts[#parts+1] = "{\\fn}"
                    in_emoji = false
                end
                if cp then
                    parts[#parts+1] = text:sub(i, i + cp_len - 1)
                else
                    parts[#parts+1] = text:sub(i, i)
                    cp_len = 1
                end
            end
            i = i + cp_len
        end
    end

    if in_emoji then
        parts[#parts+1] = "{\\fn}"
    end
    return table.concat(parts)
end

---------------------------------------------------------------------------
-- Parse mail attribute into style properties
---------------------------------------------------------------------------
local function parse_mail(mail, font_size_medium, font_size_big, font_size_small)
    local color = nil
    local pos = "scroll"
    local size = font_size_medium
    local alpha = nil

    for cmd in mail:gmatch("%S+") do
        local lower = cmd:lower()
        if lower == "184" or lower == "white" then
            -- ignore
        elseif COLOR_MAP[lower] then
            color = COLOR_MAP[lower]
        elseif lower == "ue" or lower == "naka" then
            pos = "top"
        elseif lower == "shita" then
            pos = "bottom"
        elseif lower == "big" then
            size = font_size_big
        elseif lower == "small" then
            size = font_size_small
        elseif lower == "medium" then
            size = font_size_medium
        elseif lower == "translucent" then
            alpha = "&H80&"
        end
    end
    return color, pos, size, alpha
end

---------------------------------------------------------------------------
-- Parse XML string into comment array
---------------------------------------------------------------------------
local function parse_xml(xml_string, rec_start_ts, o)
    local comments = {}
    local base_date = rec_start_ts

    for attrs, text in xml_string:gmatch('<chat ([^>]-)>(.-)</chat>') do
        local date = tonumber(attrs:match('date="(%d+)"'))
        local date_usec = tonumber(attrs:match('date_usec="(%d+)"')) or 0
        local mail = attrs:match('mail="([^"]*)"') or ""

        if date then
            if not base_date then
                base_date = date
            end
            local offset = o.danmaku_offset
                         + (rec_start_ts and 0 or o.recording_offset)
            local time = (date - base_date) + (date_usec / 1000000) + offset
            if time >= 0 then
                local color, pos, size, alpha = parse_mail(
                    mail, o.font_size_medium, o.font_size_big, o.font_size_small)
                comments[#comments + 1] = {
                    time = time,
                    text = ass_escape(xml_decode(text)),
                    color = color,
                    pos = pos,
                    size = size,
                    alpha = alpha,
                    raw_text = text,
                }
            end
        end
    end

    table.sort(comments, function(a, b) return a.time < b.time end)
    return comments
end

---------------------------------------------------------------------------
-- ASS header
---------------------------------------------------------------------------
local function ass_header(o)
    return string.format([[[Script Info]
Title: Danmaku
ScriptType: v4.00+
PlayResX: %d
PlayResY: %d
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Danmaku,%s,%d,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,%.1f,0,7,0,0,0,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
]], o.play_res_x, o.play_res_y, o.font_name, o.font_size_medium, o.font_outline)
end

---------------------------------------------------------------------------
-- Lane allocator (scroll)
---------------------------------------------------------------------------
local function create_lane_allocator(max_y, default_size, o)
    local lanes = {}
    local lane_count = math.floor(max_y / (default_size + o.lane_margin))

    for i = 1, lane_count do
        lanes[i] = { end_time = -1, full_clear = -1 }
    end

    return {
        lanes = lanes,
        lane_count = lane_count,
        get_y = function(self, lane_idx, font_size)
            return (lane_idx - 1) * (font_size + o.lane_margin)
        end,
        find_scroll_lane = function(self, time, font_size)
            local lane_h = font_size + o.lane_margin
            local usable = math.floor(max_y / lane_h)
            for i = 1, math.min(usable, self.lane_count) do
                if self.lanes[i].end_time <= time then
                    return i
                end
            end
            local best_i, best_clear = 1, math.huge
            for i = 1, math.min(usable, self.lane_count) do
                if self.lanes[i].full_clear < best_clear then
                    best_clear = self.lanes[i].full_clear
                    best_i = i
                end
            end
            return best_i
        end,
        mark_scroll = function(self, lane_idx, time, text_width)
            local speed = o.play_res_x / o.scroll_duration
            local duration = (o.play_res_x + text_width) / speed
            self.lanes[lane_idx].end_time = time + text_width / speed
            self.lanes[lane_idx].full_clear = time + duration
        end,
    }
end

---------------------------------------------------------------------------
-- Lane allocator (fixed: top/bottom)
---------------------------------------------------------------------------
local function create_fixed_lane_allocator(max_lanes, fixed_duration)
    local lanes = {}
    for i = 1, max_lanes do
        lanes[i] = { clear_time = -1 }
    end
    return {
        lanes = lanes,
        find_lane = function(self, time)
            for i = 1, max_lanes do
                if self.lanes[i].clear_time <= time then
                    return i
                end
            end
            local best_i, best_t = 1, math.huge
            for i = 1, max_lanes do
                if self.lanes[i].clear_time < best_t then
                    best_t = self.lanes[i].clear_time
                    best_i = i
                end
            end
            return best_i
        end,
        mark = function(self, lane_idx, time)
            self.lanes[lane_idx].clear_time = time + fixed_duration
        end,
    }
end

---------------------------------------------------------------------------
-- Convert comments to ASS dialogue lines
---------------------------------------------------------------------------
local function comments_to_ass(comments, o)
    local scroll_area_h = math.floor(o.play_res_y * o.scroll_area_ratio)
    local scroll_lanes = create_lane_allocator(scroll_area_h, o.font_size_medium, o)
    local top_lanes = create_fixed_lane_allocator(10, o.fixed_duration)
    local bottom_lanes = create_fixed_lane_allocator(10, o.fixed_duration)

    local lines = {}

    for _, c in ipairs(comments) do
        local display_text = wrap_emoji_font(c.text, o.emoji_font)
        local tags = {}
        if c.color then
            tags[#tags + 1] = "\\c" .. c.color
        end
        if c.alpha then
            tags[#tags + 1] = "\\1a" .. c.alpha
        end
        if c.size ~= o.font_size_medium then
            tags[#tags + 1] = "\\fs" .. c.size
        end

        local text_width = estimate_text_width(xml_decode(c.raw_text), c.size)
        local start_time = to_ass_time(c.time)

        if c.pos == "scroll" then
            local speed = o.play_res_x / o.scroll_duration
            local duration = (o.play_res_x + text_width) / speed
            local end_time = to_ass_time(c.time + duration)
            local lane = scroll_lanes:find_scroll_lane(c.time, c.size)
            local y = scroll_lanes:get_y(lane, c.size)
            scroll_lanes:mark_scroll(lane, c.time, text_width)

            local x1 = o.play_res_x
            local x2 = math.floor(-text_width)
            tags[#tags + 1] = string.format(
                "\\move(%d,%d,%d,%d)",
                ass_round(x1), ass_round(y), ass_round(x2), ass_round(y))

            local tag_str = table.concat(tags)
            lines[#lines + 1] = string.format(
                "Dialogue: 0,%s,%s,Danmaku,,0,0,0,,{%s}%s",
                start_time, end_time, tag_str, display_text
            )

        elseif c.pos == "top" then
            local end_time = to_ass_time(c.time + o.fixed_duration)
            local lane = top_lanes:find_lane(c.time)
            local y = (lane - 1) * (c.size + o.lane_margin) + c.size / 2
            top_lanes:mark(lane, c.time)

            tags[#tags + 1] = "\\an8"
            tags[#tags + 1] = string.format(
                "\\pos(%d,%d)",
                ass_round(o.play_res_x / 2),
                ass_round(y))

            local tag_str = table.concat(tags)
            lines[#lines + 1] = string.format(
                "Dialogue: 0,%s,%s,Danmaku,,0,0,0,,{%s}%s",
                start_time, end_time, tag_str, display_text
            )

        elseif c.pos == "bottom" then
            local end_time = to_ass_time(c.time + o.fixed_duration)
            local lane = bottom_lanes:find_lane(c.time)
            local y = o.play_res_y - (lane - 1) * (c.size + o.lane_margin) - c.size / 2
            bottom_lanes:mark(lane, c.time)

            tags[#tags + 1] = "\\an2"
            tags[#tags + 1] = string.format(
                "\\pos(%d,%d)",
                ass_round(o.play_res_x / 2),
                ass_round(y))

            local tag_str = table.concat(tags)
            lines[#lines + 1] = string.format(
                "Dialogue: 0,%s,%s,Danmaku,,0,0,0,,{%s}%s",
                start_time, end_time, tag_str, display_text
            )
        end
    end

    return ass_header(o) .. table.concat(lines, "\n") .. "\n"
end

---------------------------------------------------------------------------
-- Public API: render(xml_string, rec_start_ts, opts) -> ass_string
---------------------------------------------------------------------------
function M.render(xml_string, rec_start_ts, user_opts)
    local o = {}
    for k, v in pairs(DEFAULTS) do o[k] = v end
    if user_opts then
        for k, v in pairs(user_opts) do o[k] = v end
    end

    -- Derive font sizes
    if o.font_size > 0 then
        o.font_size_medium = o.font_size
    else
        local scroll_area_h = math.floor(o.play_res_y * o.scroll_area_ratio)
        o.font_size_medium = math.floor(scroll_area_h / o.lane_count - o.lane_margin)
    end
    o.font_size_big   = math.floor(o.font_size_medium * 1.25)
    o.font_size_small = math.floor(o.font_size_medium * 0.75)

    local comments = parse_xml(xml_string, rec_start_ts, o)
    return comments_to_ass(comments, o), #comments
end

return M
