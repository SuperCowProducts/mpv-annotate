-- annotate.lua: per-frame rectangle annotations for mpv (needs mpv >= 0.38)
--
-- Install: ~/.config/mpv/scripts/annotate.lua
-- Data:    ~/Nextcloud/mpv-annotations/<md5 of the video file>.annotations.json
--          (the md5 is computed with md5sum / md5 / certutil in the background
--           and cached in ~/.config/mpv/annotate-md5-cache.json)
-- Log:     ~/.config/mpv/annotate.log  (rewritten every time mpv starts)
-- Prefs:   ~/.config/mpv/annotate-settings.json (label size / label visibility,
--          written automatically when you change them)
-- Options (script-opts/annotate.conf):
--          dir=~/Nextcloud/mpv-annotations   thickness=3
--          label_size=4    (initial label height, % of the video height)
--          labels=yes      (initial label visibility)
--          tolerance=0.003 (seconds; how close time-pos must be to a box's frame time)
--          log=yes
--
-- Keys: every key is an option, so you can change it in script-opts/annotate.conf.
-- A value may hold several keys separated by spaces; an empty value unbinds the
-- command. Defaults:
--   key_red=d key_orange=o key_yellow=y key_green=e key_blue=b key_purple=p
--   key_pink=k key_gray=a      arm a box of that color, then drag to draw it
--   key_draw=MBTN_LEFT         mouse button used to drag a box
--   key_cancel=ESC             cancel drawing
--   key_label=l                edit the label of the current box
--   key_toggle_labels=L        show / hide all labels
--   key_label_bigger="Ctrl++ Ctrl+="   key_label_smaller=Ctrl+-
--   key_search=Ctrl+f          search labels and jump to an annotation
--   key_next=Ctrl+n  key_prev=Ctrl+p   next / previous annotated frame
--   key_visibility=v           all on frame / only selected / hidden
--   key_delete=x               delete the current box
--   key_undo=Ctrl+z  key_redo="Ctrl+y Ctrl+Z"
-- Example annotate.conf:
--   key_next=RIGHT
--   key_prev=LEFT
--   key_delete=DEL BS
-- Command names for input.conf ("KEY script-binding annotate/<name>"): draw-red,
-- draw-orange, ..., label, toggle-labels, label-bigger, label-smaller, search,
-- next, prev, visibility, delete, undo, redo. Note that input.conf only ADDS a
-- key; to also drop a default key there, add "Ctrl+n ignore" (or use annotate.conf).

local mp = require "mp"
local utils = require "mp.utils"
local options = require "mp.options"
local has_input, input = pcall(require, "mp.input")

local opts = {
    dir = "~/Nextcloud/mpv-annotations",
    thickness = 3,    -- border thickness in pixels
    label_size = 4,   -- label height as % of the video height
    labels = true,
    tolerance = 0.003,
    log = true,
    -- keys (see header)
    key_red = "d", key_orange = "o", key_yellow = "y", key_green = "e",
    key_blue = "b", key_purple = "p", key_pink = "k", key_gray = "a",
    key_draw = "MBTN_LEFT", key_cancel = "ESC",
    key_label = "l", key_toggle_labels = "L",
    key_label_bigger = "Ctrl++ Ctrl+=", key_label_smaller = "Ctrl+-",
    key_search = "Ctrl+f", key_next = "Ctrl+n", key_prev = "Ctrl+p",
    key_visibility = "v", key_delete = "x",
    key_undo = "Ctrl+z", key_redo = "Ctrl+y Ctrl+Z",
}
options.read_options(opts, "annotate")

local WIN = package.config:sub(1, 1) == "\\"

local function expand(p)
    local r = mp.command_native({ "expand-path", p })
    return type(r) == "string" and r or nil
end

-- logging --------------------------------------------------------------------
local log_path = expand("~~/annotate.log")
if opts.log and log_path then
    local f = io.open(log_path, "w")
    if f then f:close() else log_path = nil end
end

local function n(v) -- number-or-nil -> string, safe for %s
    if type(v) == "number" then return string.format("%.4f", v) end
    return tostring(v)
end

local function log(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    if not ok then line = tostring(fmt) .. "  [log format error: " .. tostring(line) .. "]" end
    mp.msg.info(line)
    if opts.log and log_path then
        local f = io.open(log_path, "a")
        if f then
            f:write(os.date("%H:%M:%S  "), line, "\n")
            f:close()
        end
    end
end

-- small helpers --------------------------------------------------------------
local function msg(text)
    log("osd: %s", text)
    mp.osd_message(text, 2.5)
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function round5(v) return math.floor(v * 1e5 + 0.5) / 1e5 end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function bgr(rgb) return rgb:sub(5, 6) .. rgb:sub(3, 4) .. rgb:sub(1, 2) end

local function ass_escape(s)
    s = s:gsub("\\", "\\\226\129\160") -- backslash + U+2060 so libass doesn't parse it
    s = s:gsub("{", "\\{")
    s = s:gsub("\r?\n", "\\N")
    return s
end

local function timecode(t)
    return string.format("%02d:%02d:%06.3f", math.floor(t / 3600), math.floor(t / 60) % 60, t % 60)
end

local function write_atomic(path, text)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return false, err end
    f:write(text)
    f:close()
    if not os.rename(tmp, path) then
        os.remove(path)          -- Windows can't rename over an existing file
        os.rename(tmp, path)
    end
    return true
end

local function read_json(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return utils.parse_json(text)
end

local function ensure_dir(dir)
    local info = utils.file_info(dir)
    if info and info.is_dir then return true end
    local args = WIN and { "cmd", "/c", "mkdir", dir } or { "mkdir", "-p", dir }
    local r = mp.command_native({
        name = "subprocess", args = args, playback_only = false, capture_stderr = true,
    })
    log("mkdir %s -> status=%s", dir, r and tostring(r.status) or "nil")
    return r and r.status == 0
end

-- settings (label size / visibility) ------------------------------------------
local settings_path = expand("~~/annotate-settings.json")
local settings = { label_size = opts.label_size, labels = opts.labels }
do
    local d = settings_path and read_json(settings_path)
    if type(d) == "table" then
        if type(d.label_size) == "number" then settings.label_size = d.label_size end
        if type(d.labels) == "boolean" then settings.labels = d.labels end
    end
    settings.label_size = clamp(settings.label_size, 1.5, 15)
end

local function save_settings()
    if not settings_path then return end
    local json = utils.format_json({ label_size = settings.label_size, labels = settings.labels })
    if json then write_atomic(settings_path, json) end
end

-- palette / state --------------------------------------------------------------
local PALETTE = {
    { name = "red",    rgb = "E53935" },
    { name = "orange", rgb = "FB8C00" },
    { name = "yellow", rgb = "FDD835" },
    { name = "green",  rgb = "43A047" },
    { name = "blue",   rgb = "1E88E5" },
    { name = "purple", rgb = "AB47BC" },
    { name = "pink",   rgb = "EC407A" },
    { name = "gray",   rgb = "9E9E9E" },
}
local RGB = {}
for _, c in ipairs(PALETTE) do RGB[c.name] = c.rgb end

local MODES = { "all", "one", "off" }
local MODE_TEXT = {
    all = "showing all annotations on this frame",
    one = "showing only the selected annotation",
    off = "annotations hidden",
}

local boxes = {}          -- { time, color, x, y, w, h (normalized to video), label, frame? }
local selected = nil      -- last created / last jumped-to box
local mode = "all"
local armed = nil         -- color name while waiting for / doing a drag
local drag = nil          -- { x0, y0, x1, y1 } in OSD pixels
local data_file, data_dir, video_name = nil, nil, nil
local hashing = false     -- true while the video's md5 is being computed
local undo_stack, redo_stack = {}, {}
local conf_problems = {}  -- filled by the annotate.conf check near the end

local overlay = mp.create_osd_overlay("ass-events")

-- frame identity -----------------------------------------------------------------
-- A frame is identified by the timestamp mpv reports for it while paused.
-- A box is "on" the current frame when time-pos is within a few ms of its time.
local function video_fps()
    local fps = mp.get_property_number("container-fps")
        or mp.get_property_number("estimated-vf-fps")
    if not fps or fps <= 0 then fps = 25 end
    return fps
end

local function now() return mp.get_property_number("time-pos") end

local function tolerance() return math.min(opts.tolerance, 0.4 / video_fps()) end

local function at_time(t)
    local c = now()
    return c ~= nil and math.abs(c - t) <= tolerance()
end

local function frame_boxes(t)
    local list = {}
    if not t then return list end
    local tol = tolerance()
    for _, b in ipairs(boxes) do
        if math.abs(b.time - t) <= tol then list[#list + 1] = b end
    end
    return list
end

local function nearest(t)
    local best, best_dt
    if not t then return nil end
    for _, b in ipairs(boxes) do
        local dt = math.abs(b.time - t)
        if not best_dt or dt < best_dt then best, best_dt = b, dt end
    end
    return best, best_dt
end

local function video_rect()
    local d = mp.get_property_native("osd-dimensions")
    if not d or not d.w or d.w <= 0 or d.h <= 0 then return nil end
    local vw, vh = d.w - d.ml - d.mr, d.h - d.mt - d.mb
    if vw <= 0 or vh <= 0 then return nil end
    return { w = d.w, h = d.h, x = d.ml, y = d.mt, vw = vw, vh = vh }
end

-- the box that "l" / "x" act on and that "only selected" mode shows
local function target()
    local t = now()
    local list = frame_boxes(t)
    if #list == 0 then
        local _, dt = nearest(t)
        log("target: none on frame (time-pos=%s, boxes=%d, nearest dt=%s, tol=%s)",
            n(t), #boxes, n(dt), n(tolerance()))
        return nil
    end
    for _, b in ipairs(list) do
        if b == selected then return b end
    end
    return list[#list]
end

local function seek_to(t)
    mp.set_property_native("pause", true)
    -- exact seek lands on the frame with pts <= target; the small margin guards
    -- against float noise (it is far below the matching tolerance)
    local to = t + 0.0005
    log("seek: box time=%s -> seek to %s (time-pos now %s)", n(t), n(to), n(now()))
    mp.commandv("seek", string.format("%.6f", to), "absolute+exact")
end

-- persistence ----------------------------------------------------------------
local function save()
    if not data_file then log("save: skipped, no data file"); return false end
    if not ensure_dir(data_dir) then
        msg("Annotate: cannot create " .. data_dir)
        return false
    end
    local out = {}
    for i, b in ipairs(boxes) do
        out[i] = {
            time = b.time, frame = b.frame, color = b.color,
            x = b.x, y = b.y, w = b.w, h = b.h, label = b.label,
        }
    end
    local json = utils.format_json({
        version = 3, video = video_name, md5 = data_file:match("([^/\\]+)%.annotations%.json$"),
        fps = video_fps(), boxes = out,
    })
    if not json then msg("Annotate: could not serialize data"); return false end
    local ok, err = write_atomic(data_file, json)
    if not ok then msg("Annotate: cannot write " .. data_file); log("save error: %s", tostring(err)); return false end
    log("saved %d boxes -> %s", #boxes, data_file)
    return true
end

local function load_data(md5)
    boxes, selected, data_file = {}, nil, nil
    local name = mp.get_property("filename")
    local dir = expand(opts.dir)
    if not name or not dir then log("load: no filename or expand-path failed for %s", opts.dir); return end
    data_dir, video_name = dir, name

    local file = utils.join_path(dir, md5 .. ".annotations.json")
    -- older versions keyed the file by filename; pick that up if there is no md5 file yet
    local legacy = utils.join_path(dir, name:gsub('[/\\:*?"<>|%c]', "_") .. ".annotations.json")
    local read_from = file
    local f = io.open(file, "rb")
    if f then
        f:close()
    else
        local lf = io.open(legacy, "rb")
        if lf then
            lf:close()
            read_from = legacy
            log("load: no md5 file yet, importing legacy file %s", legacy)
        else
            read_from = nil
        end
    end

    if read_from then
        local data = read_json(read_from)
        if not data or type(data.boxes) ~= "table" then
            log("load: annotation file unreadable, not touching it: %s", read_from)
            msg("Annotate: annotation file unreadable, saving disabled")
            return
        end
        for _, b in ipairs(data.boxes) do
            if type(b) == "table" and b.time and b.x and b.y and b.w and b.h then
                b.label = b.label or ""
                if not RGB[b.color] then b.color = "red" end
                boxes[#boxes + 1] = b
            else
                log("load: skipped malformed box entry")
            end
        end
    end
    data_file = file
    log("loaded %d boxes (md5 %s) from %s", #boxes, md5, tostring(read_from))
    for i, b in ipairs(boxes) do
        if i > 20 then log("  ... (%d more)", #boxes - 20); break end
        log("  box %d: time=%s %s label=%q", i, n(b.time), b.color, b.label)
    end
end

-- rendering ------------------------------------------------------------------
-- hollow rectangle = four filled bars (same winding, so they union cleanly)
local function outline_path(x1, y1, x2, y2, t)
    t = math.min(t, (x2 - x1) / 2, (y2 - y1) / 2)
    local function r(a, b, c, d)
        return string.format("m %.1f %.1f l %.1f %.1f %.1f %.1f %.1f %.1f", a, b, c, b, c, d, a, d)
    end
    return table.concat({
        r(x1, y1, x2, y1 + t), r(x1, y2 - t, x2, y2),
        r(x1, y1 + t, x1 + t, y2 - t), r(x2 - t, y1 + t, x2, y2 - t),
    }, " ")
end

-- label: bold white text with a thick black outline, readable on any background
local function add_box(parts, x1, y1, x2, y2, color, label, thickness, fs)
    local c = bgr(RGB[color] or "FFFFFF")
    parts[#parts + 1] = string.format(
        "{\\an7\\pos(0,0)\\bord0\\shad0\\1a&H00&\\1c&H%s&\\p1}%s{\\p0}",
        c, outline_path(x1, y1, x2, y2, thickness))
    if label and label ~= "" then
        local bord = math.max(2, fs * 0.12)
        local tag
        if y1 - 2 >= fs * 1.35 then
            tag = string.format("\\an1\\pos(%.1f,%.1f)", x1, y1 - 2)
        else
            tag = string.format("\\an7\\pos(%.1f,%.1f)", x1 + thickness + 4, y1 + thickness + 2)
        end
        parts[#parts + 1] = string.format(
            "{%s\\q2\\b1\\fs%.0f\\bord%.1f\\shad0\\1a&H00&\\1c&HFFFFFF&\\3c&H000000&}%s",
            tag, fs, bord, ass_escape(label))
    end
end

local last_state = ""

local function render()
    local vr, t = video_rect(), now()
    if not vr or not t then overlay:remove(); return end

    local on_frame = frame_boxes(t)
    local shown = {}
    if mode == "all" then
        shown = on_frame
    elseif mode == "one" then
        local tg
        for _, b in ipairs(on_frame) do
            if b == selected then tg = b end
        end
        tg = tg or on_frame[#on_frame]
        if tg then shown = { tg } end
    end

    -- log state changes, but only while paused (during playback this fires every frame)
    if mp.get_property_bool("pause") then
        local key = string.format("%s|%s|%d|%d|%d", n(t), mode, #boxes, #on_frame, #shown)
        if key ~= last_state then
            last_state = key
            local _, dt = nearest(t)
            log("render: time-pos=%s mode=%s boxes_total=%d on_frame=%d shown=%d nearest_dt=%s tol=%s",
                n(t), mode, #boxes, #on_frame, #shown, n(dt), n(tolerance()))
        end
    end

    local parts = {}
    local fs = math.max(14, vr.vh * settings.label_size / 100)
    local tgt = (mode == "all" and #on_frame > 1) and target() or nil
    for _, b in ipairs(shown) do
        local th = opts.thickness + (b == tgt and 2 or 0)
        add_box(parts,
            vr.x + b.x * vr.vw, vr.y + b.y * vr.vh,
            vr.x + (b.x + b.w) * vr.vw, vr.y + (b.y + b.h) * vr.vh,
            b.color, settings.labels and b.label or nil, th, fs)
    end

    if drag and armed then
        add_box(parts,
            math.min(drag.x0, drag.x1), math.min(drag.y0, drag.y1),
            math.max(drag.x0, drag.x1), math.max(drag.y0, drag.y1),
            armed, nil, opts.thickness, fs)
    end

    if #parts == 0 then overlay:remove(); return end
    overlay.res_x, overlay.res_y = vr.w, vr.h
    overlay.data = table.concat(parts, "\n")
    overlay:update()
end

-- undo / redo ----------------------------------------------------------------
-- ops: { type="add", box } | { type="delete", box, index } | { type="label", box, old, new }
local function record(op)
    undo_stack[#undo_stack + 1] = op
    redo_stack = {}
    log("history: recorded %s (undo=%d)", op.type, #undo_stack)
end

local function remove_box(b)
    for i, x in ipairs(boxes) do
        if x == b then table.remove(boxes, i); break end
    end
    if selected == b then selected = nil end
end

local function insert_box(b, index)
    table.insert(boxes, math.min(index or (#boxes + 1), #boxes + 1), b)
    selected = b
end

local function describe(op)
    local b = op.box
    local what = b.color .. " box" .. (b.label ~= "" and (" '" .. b.label .. "'") or "")
    if op.type == "add" then return "added " .. what end
    if op.type == "delete" then return "deleted " .. what end
    return "label of " .. what
end

local function apply(op, undoing)
    local b = op.box
    if op.type == "add" then
        if undoing then remove_box(b) else insert_box(b) end
    elseif op.type == "delete" then
        if undoing then insert_box(b, op.index) else remove_box(b) end
    elseif op.type == "label" then
        b.label = undoing and op.old or op.new
        selected = b
    end
    save()
    if not at_time(b.time) then seek_to(b.time) end -- bring the affected frame into view
    last_state = ""
    render()
end

local function undo()
    local op = table.remove(undo_stack)
    if not op then msg("Nothing to undo"); return end
    redo_stack[#redo_stack + 1] = op
    apply(op, true)
    msg("Undo: " .. describe(op))
end

local function redo()
    local op = table.remove(redo_stack)
    if not op then msg("Nothing to redo"); return end
    undo_stack[#undo_stack + 1] = op
    apply(op, false)
    msg("Redo: " .. describe(op))
end

-- labels ---------------------------------------------------------------------
-- merge=true: this is the prompt right after drawing, so the label belongs to
-- the "add" history step instead of being a step of its own
local function prompt_label(box, merge)
    if not has_input then msg("Labels need mpv 0.38+ (mp.input)"); return end
    input.get({
        prompt = "Label (empty = none): ",
        default_text = box.label or "",
        submit = function(text)
            input.terminate()
            local new = trim(text or "")
            local old = box.label or ""
            log("label set: %q -> %q (box time=%s, merge=%s)", old, new, n(box.time), tostring(merge))
            if new ~= old then
                box.label = new
                if not merge then record({ type = "label", box = box, old = old, new = new }) end
                save()
            end
            -- a label should be visible right away
            if not settings.labels and new ~= "" then
                settings.labels = true
                save_settings()
            end
            render()
        end,
    })
end

local function edit_label()
    local b = target()
    if not b then msg("No annotation on this frame"); return end
    selected = b
    prompt_label(b, false)
end

local function toggle_labels()
    settings.labels = not settings.labels
    save_settings()
    msg(settings.labels and "Labels shown" or "Labels hidden")
    render()
end

local function change_label_size(factor)
    settings.label_size = clamp(settings.label_size * factor, 1.5, 15)
    settings.labels = true
    save_settings()
    msg(string.format("Label size: %.1f%% of video height", settings.label_size))
    render()
end

-- drawing --------------------------------------------------------------------
local disarm

local function finish_drag()
    local d = drag
    drag = nil
    local vr = video_rect()
    local t = now()
    if not d or not vr or not t then log("finish_drag: no drag/video rect/time-pos"); render(); return end

    local x0 = clamp(math.min(d.x0, d.x1), vr.x, vr.x + vr.vw)
    local x1 = clamp(math.max(d.x0, d.x1), vr.x, vr.x + vr.vw)
    local y0 = clamp(math.min(d.y0, d.y1), vr.y, vr.y + vr.vh)
    local y1 = clamp(math.max(d.y0, d.y1), vr.y, vr.y + vr.vh)
    if x1 - x0 < 4 or y1 - y0 < 4 then
        log("finish_drag: too small (%.0fx%.0f px), ignored", x1 - x0, y1 - y0)
        render()
        return -- a click, not a box; stay armed
    end

    local box = {
        time = t,
        frame = mp.get_property_number("estimated-frame-number"), -- informational only
        color = armed,
        x = round5((x0 - vr.x) / vr.vw), y = round5((y0 - vr.y) / vr.vh),
        w = round5((x1 - x0) / vr.vw),   h = round5((y1 - y0) / vr.vh),
        label = "",
    }
    boxes[#boxes + 1] = box
    selected = box
    record({ type = "add", box = box })
    log("box created: time-pos=%s playback-time=%s est-frame=%s fps=%s %s x=%.4f y=%.4f w=%.4f h=%.4f (osd %dx%d, video %.0fx%.0f at %.0f,%.0f)",
        n(t), n(mp.get_property_number("playback-time")), n(box.frame), n(video_fps()),
        box.color, box.x, box.y, box.w, box.h, vr.w, vr.h, vr.vw, vr.vh, vr.x, vr.y)
    disarm()
    save()
    prompt_label(box, true)
end

local function on_mouse(e)
    if not armed then return end
    local x, y = mp.get_mouse_pos()
    if e.event == "down" then
        drag = { x0 = x, y0 = y, x1 = x, y1 = y }
        render()
    elseif e.event == "up" and drag then
        drag.x1, drag.y1 = x, y
        finish_drag()
    end
end

disarm = function()
    armed, drag = nil, nil
    mp.remove_key_binding("annotate-draw")
    mp.remove_key_binding("annotate-draw-dbl")
    mp.remove_key_binding("annotate-cancel")
    render()
end

local function arm(color)
    if not now() then log("arm: ignored, no time-pos"); return end
    if not data_file then
        msg(hashing and "Annotate: still computing the video's md5, try again in a moment"
            or "Annotate: no usable annotation file for this video")
        return
    end
    if armed == color.name then
        disarm()
        msg("Drawing cancelled")
        return
    end
    local was_armed = armed ~= nil
    armed = color.name
    mp.set_property_native("pause", true)
    if mode == "off" then mode = "all" end
    if not was_armed then
        mp.add_forced_key_binding(opts.key_draw, "annotate-draw", on_mouse, { complex = true })
        if opts.key_draw:find("^MBTN_") then -- swallow double clicks (fullscreen toggle)
            mp.add_forced_key_binding(opts.key_draw .. "_DBL", "annotate-draw-dbl", function() end)
        end
        mp.add_forced_key_binding(opts.key_cancel, "annotate-cancel", function()
            disarm()
            msg("Drawing cancelled")
        end)
    end
    msg("Drag to draw a " .. color.name .. " box (" .. opts.key_cancel .. " cancels)")
    render()
end

-- visibility / delete / search -----------------------------------------------
local function cycle_mode()
    for i, m in ipairs(MODES) do
        if m == mode then
            mode = MODES[i % #MODES + 1]
            break
        end
    end
    msg("Annotations: " .. MODE_TEXT[mode])
    last_state = ""
    render()
end

local function delete_target()
    local b = target()
    if not b then msg("No annotation on this frame"); return end
    local index
    for i, x in ipairs(boxes) do
        if x == b then index = i; break end
    end
    remove_box(b)
    record({ type = "delete", box = b, index = index })
    save()
    render()
    msg("Deleted " .. b.color .. " box" .. (b.label ~= "" and (": " .. b.label) or "") .. "  (Ctrl+z undoes)")
end

local function jump(b, note)
    selected = b
    log("jump: label=%q", b.label)
    seek_to(b.time)
    last_state = ""
    render()
    msg(string.format("%s  [%s]%s", b.label ~= "" and b.label or "(no label)", timecode(b.time),
        note or ""))
end

-- go to the nearest annotated frame after (dir=1) / before (dir=-1) the current one,
-- wrapping around at the ends
local function step_annotation(dir)
    if #boxes == 0 then msg("No annotations for this video"); return end
    local t = now() or 0
    local tol = tolerance()
    local best, first
    for _, b in ipairs(boxes) do
        if dir > 0 then
            if b.time > t + tol and (not best or b.time < best.time) then best = b end
            if not first or b.time < first.time then first = b end
        else
            if b.time < t - tol and (not best or b.time > best.time) then best = b end
            if not first or b.time > first.time then first = b end
        end
    end
    local wrapped = false
    if not best then best, wrapped = first, true end
    log("step_annotation: dir=%d from time-pos=%s -> %s%s", dir, n(t), n(best.time),
        wrapped and " (wrapped)" or "")
    jump(best, wrapped and "  (wrapped around)" or nil)
end

local function search()
    if not has_input then msg("Search needs mpv 0.38+ (mp.input)"); return end
    if #boxes == 0 then msg("No annotations for this video"); return end

    local order = {}
    for i, b in ipairs(boxes) do order[i] = { b = b, i = i } end
    table.sort(order, function(p, q)
        if p.b.time ~= q.b.time then return p.b.time < q.b.time end
        return p.i < q.i
    end)

    local items = {}
    for i, o in ipairs(order) do
        items[i] = string.format("%s  [%s, %s]",
            o.b.label ~= "" and o.b.label or "(no label)", timecode(o.b.time), o.b.color)
    end

    input.select({
        prompt = "Jump to annotation:",
        items = items,
        submit = function(i)
            input.terminate()
            log("search: picked item %s", tostring(i))
            if order[i] then jump(order[i].b) end
        end,
    })
end

-- md5 of the video file ------------------------------------------------------
local cache_path = expand("~~/annotate-md5-cache.json")
local load_token, pending = 0, nil

local function abort_hashing()
    load_token = load_token + 1
    if pending then
        mp.abort_async_command(pending)
        pending = nil
    end
    hashing = false
end

local function abs_path(p)
    if p:find("^%a[%w+.-]*://") then return nil end -- URL / dvd:// etc.
    if p:find("^/") or p:find("^%a:[/\\]") or p:find("^\\\\") then return p end
    return utils.join_path(mp.get_property("working-directory") or ".", p)
end

local function parse_md5(out)
    if not out then return nil end
    for tok in out:gmatch("%x+") do
        if #tok == 32 then return tok:lower() end
    end
    for line in out:gmatch("[^\r\n]+") do -- certutil prints the hash with spaces
        local s = line:gsub("%s", "")
        if #s == 32 and s:match("^%x+$") then return s:lower() end
    end
    return nil
end

local function hash_file(token, path, cb)
    local cmds
    if WIN then
        cmds = { { "certutil", "-hashfile", path, "MD5" } }
    else
        cmds = { { "md5sum", path }, { "md5", "-q", path } }
    end
    local idx, t0 = 1, mp.get_time()
    local function try()
        local args = cmds[idx]
        if not args then cb(nil); return end
        log("hashing: %s", table.concat(args, " "))
        pending = mp.command_native_async({
            name = "subprocess", args = args, capture_stdout = true, capture_stderr = true,
            playback_only = false,
        }, function(ok, res, err)
            if token ~= load_token then return end -- another file was loaded meanwhile
            pending = nil
            local h = ok and res and res.status == 0 and parse_md5(res.stdout)
            if h then
                log("md5 %s computed in %.1fs", h, mp.get_time() - t0)
                cb(h)
            else
                log("hash command failed: ok=%s status=%s error=%s stderr=%s err=%s",
                    tostring(ok), tostring(res and res.status), tostring(res and res.error_string),
                    tostring(res and res.stderr), tostring(err))
                idx = idx + 1
                try()
            end
        end)
    end
    try()
end

local function on_file_loaded()
    if armed then disarm() end
    abort_hashing()
    boxes, selected, data_file = {}, nil, nil
    undo_stack, redo_stack = {}, {}
    last_state = ""
    local token = load_token

    log("file-loaded: %s (mpv %s, container-fps=%s, estimated-vf-fps=%s)",
        tostring(mp.get_property("path")), tostring(mp.get_property("mpv-version")),
        n(mp.get_property_number("container-fps")), n(mp.get_property_number("estimated-vf-fps")))
    log("log file: %s", tostring(log_path))
    if #conf_problems > 0 then
        mp.osd_message("Annotate config problem:\n" .. table.concat(conf_problems, "\n"), 8)
    end
    render()

    local path = mp.get_property("path")
    local abs = path and abs_path(path)
    if not abs then msg("Annotate: only local files are supported"); return end
    local info = utils.file_info(abs)
    if not info or not info.is_file then log("file_info failed for %s", abs); return end

    local function done(md5)
        if token ~= load_token then return end
        hashing = false
        if not md5 then msg("Annotate: could not compute md5 (see annotate.log)"); return end
        load_data(md5)
        last_state = ""
        render()
        if data_file then
            msg(#boxes > 0 and string.format("Annotate: loaded %d annotations", #boxes) or "Annotate: ready")
        end
    end

    local key = string.format("%s|%s|%s", abs, tostring(info.size), tostring(info.mtime))
    local cache = cache_path and read_json(cache_path)
    if type(cache) ~= "table" then cache = {} end
    if type(cache[key]) == "string" and #cache[key] == 32 then
        log("md5 cache hit for %s", abs)
        done(cache[key])
        return
    end

    hashing = true
    msg("Annotate: computing md5 of the video (first time only)...")
    hash_file(token, abs, function(md5)
        if md5 and cache_path then
            local c = read_json(cache_path)
            if type(c) ~= "table" then c = {} end
            c[key] = md5
            local json = utils.format_json(c)
            if json then write_atomic(cache_path, json) end
        end
        done(md5)
    end)
end

-- annotate.conf sanity check: mpv silently ignores lines it can't match
-- (spaces around "=", typos in option names), which looks like "my key does nothing"
do
    local conf = mp.find_config_file("script-opts/annotate.conf")
    local f = conf and io.open(conf, "r")
    if f then
        local ln = 0
        for line in f:lines() do
            ln = ln + 1
            line = line:gsub("\r$", "")
            if line:find("#") ~= 1 and line:find("=") then
                local k = line:sub(1, line:find("=") - 1)
                if opts[k] == nil then
                    local hint = opts[k:match("^%s*(.-)%s*$")] ~= nil
                        and " (remove the spaces around the name / '=')" or ""
                    conf_problems[#conf_problems + 1] = string.format(
                        "annotate.conf line %d: unknown option '%s', ignored%s", ln, k, hint)
                end
            end
        end
        f:close()
    end
    for _, pr in ipairs(conf_problems) do log("%s", pr) end
end

-- wiring ---------------------------------------------------------------------
-- keys may be several, space separated; none = reachable only via input.conf.
-- Quotes are stripped (people copy "Ctrl++ Ctrl+=" from the docs), and a failing
-- registration is logged instead of aborting the rest of the script.
local registered = {}
local function bind(name, keys, fn, flags)
    local clean = tostring(keys or ""):gsub('["\']', "")
    local i = 0
    for k in clean:gmatch("%S+") do
        i = i + 1
        local ok, err = pcall(mp.add_key_binding, k, i == 1 and name or (name .. "-" .. i), fn, flags)
        if not ok then log("bind FAILED for %s (key %q): %s", name, k, tostring(err)) end
    end
    if i == 0 then
        local ok, err = pcall(mp.add_key_binding, nil, name, fn, flags)
        if not ok then log("bind FAILED for %s (no key): %s", name, tostring(err)) end
    end
    registered[#registered + 1] = name .. "=" .. (clean ~= "" and clean or "<input.conf only>")
end

for _, c in ipairs(PALETTE) do
    bind("draw-" .. c.name, opts["key_" .. c.name], function() arm(c) end)
end
bind("label", opts.key_label, edit_label)
bind("toggle-labels", opts.key_toggle_labels, toggle_labels)
bind("label-bigger", opts.key_label_bigger, function() change_label_size(1.15) end, { repeatable = true })
bind("label-smaller", opts.key_label_smaller, function() change_label_size(1 / 1.15) end, { repeatable = true })
bind("search", opts.key_search, search)
bind("next", opts.key_next, function() step_annotation(1) end, { repeatable = true })
bind("prev", opts.key_prev, function() step_annotation(-1) end, { repeatable = true })
bind("visibility", opts.key_visibility, cycle_mode)
bind("delete", opts.key_delete, delete_target)
bind("undo", opts.key_undo, undo, { repeatable = true })
bind("redo", opts.key_redo, redo, { repeatable = true })

log("script loaded; config file: %s", tostring(mp.find_config_file("script-opts/annotate.conf")))
log("key bindings: %s", table.concat(registered, "  "))

mp.observe_property("mouse-pos", "native", function(_, v)
    if drag and v then
        drag.x1, drag.y1 = v.x, v.y
        render()
    end
end)
mp.observe_property("time-pos", "number", function() render() end)
mp.observe_property("osd-dimensions", "native", function() render() end)

mp.register_event("file-loaded", on_file_loaded)
mp.register_event("playback-restart", function()
    log("playback-restart: time-pos=%s playback-time=%s pause=%s",
        n(now()), n(mp.get_property_number("playback-time")), tostring(mp.get_property_bool("pause")))
    last_state = ""
    render()
end)
mp.register_event("end-file", function()
    if armed then disarm() end
    abort_hashing()
    boxes, selected, data_file = {}, nil, nil
    undo_stack, redo_stack = {}, {}
    overlay:remove()
end)
