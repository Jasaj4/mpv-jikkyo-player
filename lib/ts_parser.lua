-- ts_parser.lua — Parse ISDB-T TS stream for EIT/TOT/channel info
-- No mpv dependency (io.open + binary read only)

local M = {}

---------------------------------------------------------------------------
-- Decode 40-bit MJD+BCD time field to UNIX timestamp (UTC)
---------------------------------------------------------------------------
local function decode_mjd_bcd(data, off)
    local b1, b2, b3, b4, b5 = data:byte(off, off + 4)
    if not b5 then return nil end
    if b1 == 0xFF and b2 == 0xFF and b3 == 0xFF
        and b4 == 0xFF and b5 == 0xFF then return nil end
    if b3 == 0xFF or b4 == 0xFF or b5 == 0xFF then return nil end

    local mjd  = b1 * 256 + b2
    local hour = math.floor(b3 / 16) * 10 + (b3 % 16)
    local min  = math.floor(b4 / 16) * 10 + (b4 % 16)
    local sec  = math.floor(b5 / 16) * 10 + (b5 % 16)

    local y_ = math.floor((mjd - 15078.2) / 365.25)
    local m_ = math.floor((mjd - 14956.1 - math.floor(y_ * 365.25)) / 30.6001)
    local day = mjd - 14956 - math.floor(y_ * 365.25) - math.floor(m_ * 30.6001)
    local k = (m_ == 14 or m_ == 15) and 1 or 0
    local year  = y_ + k + 1900
    local month = m_ - 1 - k * 12

    local JST_OFFSET = 9 * 3600
    local t = os.time({year=year, month=month, day=day,
                       hour=hour, min=min, sec=sec, isdst=false})
    local utc_t = t + os.difftime(t, os.time(os.date("!*t", t)))
    return utc_t - JST_OFFSET
end

---------------------------------------------------------------------------
-- Decode 24-bit BCD duration to seconds
---------------------------------------------------------------------------
local function decode_bcd_dur(data, off)
    local b1, b2, b3 = data:byte(off, off + 2)
    if not b3 then return 0 end
    return (math.floor(b1/16)*10 + b1%16) * 3600
         + (math.floor(b2/16)*10 + b2%16) * 60
         + (math.floor(b3/16)*10 + b3%16)
end

---------------------------------------------------------------------------
-- Detect TS packet size and sync position within data chunk
---------------------------------------------------------------------------
local function detect_ts_sync(data)
    for _, size in ipairs({188, 192}) do
        for i = 1, math.min(#data - size * 2, size) do
            if data:byte(i) == 0x47
                and data:byte(i + size) == 0x47
                and data:byte(i + size * 2) == 0x47 then
                return size, i
            end
        end
    end
    return nil, nil
end

---------------------------------------------------------------------------
-- Scan a data chunk for EIT/TOT
-- Returns (eit_events, tot_time, onid, tsid, sid)
-- eit_events: {[0]={start,dur}, [1]={start,dur}} (present/following)
---------------------------------------------------------------------------
local function scan_ts_chunk(data, pkt_size, sync_pos, want_eit)
    local ts_off = pkt_size - 188
    local eit_events = {}
    local tot_time
    local onid, tsid, sid
    local pos = sync_pos

    while pos + pkt_size - 1 <= #data do
        local p = pos + ts_off
        local advance = pkt_size

        if data:byte(p) ~= 0x47 then
            advance = 1
        else
            local h1, h2, h3 = data:byte(p + 1, p + 3)
            local pusi  = math.floor(h1 / 64) % 2 == 1
            local pid   = (h1 % 32) * 256 + h2
            local adapt = math.floor(h3 / 16) % 4

            if pusi and adapt ~= 2 and (pid == 0x0012 or pid == 0x0014) then
                local pl = p + 4
                if adapt == 3 then
                    pl = pl + 1 + data:byte(p + 4)
                end

                local pointer = data:byte(pl)
                if pointer then
                    local s = pl + 1 + pointer
                    if s + 14 <= p + 188 then
                        local tid = data:byte(s)

                        if want_eit and pid == 0x0012 and tid == 0x4E then
                            local sec_num = data:byte(s + 6)
                            if (sec_num == 0 or sec_num == 1) and not eit_events[sec_num] then
                                if not onid then
                                    sid  = data:byte(s + 3) * 256 + data:byte(s + 4)
                                    tsid = data:byte(s + 8) * 256 + data:byte(s + 9)
                                    onid = data:byte(s + 10) * 256 + data:byte(s + 11)
                                end
                                local ev = s + 14
                                if ev + 12 <= p + 188 then
                                    local ev_start = decode_mjd_bcd(data, ev + 2)
                                    if ev_start then
                                        local dur = decode_bcd_dur(data, ev + 7)
                                        eit_events[sec_num] = {start = ev_start, dur = dur}
                                    end
                                end
                            end

                        elseif pid == 0x0014 and (tid == 0x73 or tid == 0x70) then
                            local t = decode_mjd_bcd(data, s + 3)
                            if t then tot_time = t end
                        end
                    end
                end
            end
        end

        pos = pos + advance
    end

    return eit_events, tot_time, onid, tsid, sid
end

---------------------------------------------------------------------------
-- Parse TS stream -> {onid, tsid, sid, rec_start, rec_end, eit_events}
-- All timestamps are UNIX (UTC).  Returns nil on failure.
-- log_fn: optional function(level, msg) for logging ("info"/"verbose")
---------------------------------------------------------------------------
function M.parse(filepath, log_fn)
    local log = log_fn or function() end

    local f = io.open(filepath, "rb")
    if not f then return nil end

    -- Read head (16 MB)
    local HEAD_SIZE = 16 * 1024 * 1024
    local head = f:read(HEAD_SIZE)
    if not head or #head < 188 * 3 then f:close(); return nil end

    local pkt_size, sync_pos = detect_ts_sync(head)
    if not pkt_size then f:close(); return nil end

    -- Scan head: EIT + first TOT + channel IDs
    local eit_events, rec_start, onid, tsid, sid =
        scan_ts_chunk(head, pkt_size, sync_pos, true)

    -- Find the real end of data (skip trailing zero-padding)
    local rec_end
    local fsize = f:seek("end")
    local TAIL_SIZE = 16 * 1024 * 1024
    if fsize and fsize > HEAD_SIZE then
        local real_end = fsize
        -- Check if file ends with zeros (pre-allocated recording)
        local probe_size = 4096
        f:seek("set", fsize - probe_size)
        local probe = f:read(probe_size)
        if probe then
            local all_zero = true
            for i = 1, #probe do
                if probe:byte(i) ~= 0 then all_zero = false; break end
            end
            if all_zero then
                -- Binary search for the real end of data
                local lo, hi = HEAD_SIZE, fsize
                while hi - lo > 1024 * 1024 do
                    local mid = math.floor((lo + hi) / 2)
                    f:seek("set", mid)
                    local chunk = f:read(4096)
                    local has_data = false
                    if chunk then
                        for i = 1, #chunk do
                            if chunk:byte(i) ~= 0 then has_data = true; break end
                        end
                    end
                    if has_data then lo = mid else hi = mid end
                end
                real_end = hi
                log("info", string.format(
                    "zero-padding detected, real data ends at %.1f MB (file %.1f MB)",
                    real_end / 1048576, fsize / 1048576))
            end
        end

        -- Read tail from real data end
        local tail_offset = math.max(HEAD_SIZE, real_end - TAIL_SIZE)
        f:seek("set", tail_offset)
        local tail = f:read(real_end - tail_offset)
        if tail and #tail >= 188 * 3 then
            local ps2, sp2 = detect_ts_sync(tail)
            if ps2 then
                local _, last_tot = scan_ts_chunk(tail, ps2, sp2, false)
                if last_tot then rec_end = last_tot end
            end
        end
    end
    f:close()

    -- Logging
    if onid then
        log("info", string.format("TS stream — ONID=%d TSID=%d SID=%d", onid, tsid, sid))
    end
    if rec_start then
        log("info", string.format("TOT head — rec_start %d", rec_start))
    end
    if rec_end then
        log("info", string.format("TOT tail — rec_end %d", rec_end))
    end
    for i = 0, 1 do
        if eit_events[i] then
            log("info", string.format("EIT sec%d — %d → %d (%ds)",
                i, eit_events[i].start, eit_events[i].start + eit_events[i].dur,
                eit_events[i].dur))
        end
    end

    return {
        onid = onid, tsid = tsid, sid = sid,
        rec_start = rec_start, rec_end = rec_end,
        eit_events = eit_events,
    }
end

return M
