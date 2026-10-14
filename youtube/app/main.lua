function love.errorhandler(msg)
    local err = debug.traceback("Error: " .. tostring(msg), 2)
    local f = io.open("/tmp/love_crash.txt", "w")
    if f then f:write(err); f:close() end
    print(err)
    local orig = love.errhand or function() end
    return orig(msg)
end

-- Helper URL encoder
local function url_encode(str)
    if str then
        str = string.gsub(str, "([^%w %-%_%.%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        str = string.gsub(str, " ", "+")
    end
    return str or ""
end

-- Pure Lua JSON parser
local function decode_json(s)
    if not s or #s == 0 then return nil end
    local pos = 1
    local function skip_whitespace()
        while pos <= #s and s:sub(pos, pos):match("%s") do pos = pos + 1 end
    end
    local function parse_value()
        skip_whitespace()
        local c = s:sub(pos, pos)
        if c == '"' then
            pos = pos + 1
            local start = pos
            while pos <= #s do
                local ch = s:sub(pos, pos)
                if ch == '"' and s:sub(pos-1, pos-1) ~= "\\" then break end
                pos = pos + 1
            end
            local str = s:sub(start, pos - 1):gsub('\\"', '"'):gsub('\\\\', '\\'):gsub('\\n', '\n')
            pos = pos + 1
            return str
        elseif c == '{' then
            pos = pos + 1
            local obj = {}
            skip_whitespace()
            if s:sub(pos, pos) == '}' then pos = pos + 1; return obj end
            while pos <= #s do
                local k = parse_value()
                skip_whitespace()
                if s:sub(pos, pos) == ':' then pos = pos + 1 end
                local v = parse_value()
                obj[k] = v
                skip_whitespace()
                local sep = s:sub(pos, pos)
                if sep == ',' then pos = pos + 1
                elseif sep == '}' then pos = pos + 1; break end
            end
            return obj
        elseif c == '[' then
            pos = pos + 1
            local arr = {}
            skip_whitespace()
            if s:sub(pos, pos) == ']' then pos = pos + 1; return arr end
            while pos <= #s do
                local v = parse_value()
                table.insert(arr, v)
                skip_whitespace()
                local sep = s:sub(pos, pos)
                if sep == ',' then pos = pos + 1
                elseif sep == ']' then pos = pos + 1; break end
            end
            return arr
        elseif c:match("[%d%-]") then
            local start = pos
            while pos <= #s and s:sub(pos, pos):match("[%d%.%-%+eE]") do pos = pos + 1 end
            return tonumber(s:sub(start, pos - 1))
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
        end
        pos = pos + 1
        return nil
    end
    local ok, res = pcall(parse_value)
    return ok and res or nil
end

local state = "FEED" -- "FEED", "PLAYER", "SEARCH", "SUBS", "ACCOUNT"
local current_tab = 1 -- 1: Início, 2: Em Alta, 3: Buscar, 4: Inscrições, 5: Você
local categories = {"Tudo", "Jogos Retrô", "Nintendo DS", "Música", "Documentários", "Speedruns"}
local cat_idx = 1
local videos = {}
local subs_videos = {}
local sel_idx = 1
local scroll_y = 0
local target_scroll_y = 0

local thumbs = {}
local is_fetching_feed = false
local now_playing = nil
local is_playing = false
local player_status = { time_pos = 0, duration = 0, pause = false }
local search_query = ""
local kb_r, kb_c = 1, 1 -- kb_r = 0 is Quick Tags! kb_r = 1..5 is Virtual Keyboard
local acc_sel = 1 -- Account view button selection

local auth_info = { connected = false, name = "", connect_url = "http://127.0.0.1:8989/connect", ip = "127.0.0.1" }
local last_auth_check = 0

local quick_tags = {"Jogos Retrô", "Nintendo DS", "Super Mario", "Zelda", "Pokemon", "Speedrun", "Documentário"}

-- Background worker thread
local thread_code = [[
    require("love.timer")
    local http = require("socket.http")
    local req_ch = love.thread.getChannel("bg_req")
    local res_ch = love.thread.getChannel("bg_res")
    
    while true do
        local task = req_ch:pop()
        if task then
            if task.type == "feed" then
                local url = "http://127.0.0.1:8989/feed?"
                if task.browse then
                    url = url .. "browse=" .. task.browse
                else
                    url = url .. "q=" .. (task.query or "")
                end
                local body, code = http.request(url)
                res_ch:push({ type = "feed", data = body, code = code, browse = task.browse, cat_idx = task.cat_idx })
            elseif task.type == "thumb" then
                local url = "http://127.0.0.1:8989/thumb?id=" .. task.id
                local body, code = http.request(url)
                if code == 200 and body and #body > 500 then
                    res_ch:push({ type = "thumb", id = task.id, data = body })
                end
            elseif task.type == "mpv" then
                local url = "http://127.0.0.1:8989/mpv?action=" .. task.action .. (task.id and ("&id=" .. task.id) or "") .. (task.val and ("&val=" .. task.val) or "")
                http.request(url)
            elseif task.type == "status" then
                local body, code = http.request("http://127.0.0.1:8989/status")
                if code == 200 and body then
                    res_ch:push({ type = "status", data = body })
                end
            elseif task.type == "auth_status" then
                local body, code = http.request("http://127.0.0.1:8989/auth/status")
                if code == 200 and body then
                    res_ch:push({ type = "auth_status", data = body })
                end
            elseif task.type == "logout" then
                http.request("http://127.0.0.1:8989/auth/logout")
                res_ch:push({ type = "auth_status_update", connected = false })
            end
        end
        love.timer.sleep(0.02)
    end
]]

local bg_thread = nil
local req_ch = nil
local res_ch = nil

local font_title = nil
local font_small = nil
local font_logo = nil
local font_badge = nil
local font_big = nil

function love.load()
    love.graphics.setDefaultFilter("linear", "linear")
    
    font_logo = love.graphics.newFont(16)
    font_title = love.graphics.newFont(13)
    font_small = love.graphics.newFont(11)
    font_badge = love.graphics.newFont(10)
    font_big = love.graphics.newFont(15)
    
    req_ch = love.thread.getChannel("bg_req")
    res_ch = love.thread.getChannel("bg_res")
    bg_thread = love.thread.newThread(thread_code)
    bg_thread:start()
    
    -- Check initial auth status
    req_ch:push({ type = "auth_status" })
    
    load_category(categories[cat_idx])
end

function update_categories_list()
    if auth_info.connected then
        categories = {"⭐ Para Você", "Tudo", "Jogos Retrô", "Nintendo DS", "Música", "Speedruns"}
    else
        categories = {"Tudo", "Jogos Retrô", "Nintendo DS", "Música", "Documentários", "Speedruns"}
    end
end

function load_category(cat_name)
    is_fetching_feed = true
    videos = {}
    sel_idx = 1
    scroll_y = 0
    target_scroll_y = 0
    
    if cat_name == "⭐ Para Você" then
        req_ch:push({ type = "feed", browse = "home", cat_idx = cat_idx })
    elseif cat_name == "Tudo" then
        req_ch:push({ type = "feed", query = url_encode("Retro Gaming"), cat_idx = cat_idx })
    else
        req_ch:push({ type = "feed", query = url_encode(cat_name), cat_idx = cat_idx })
    end
end

function load_subs_feed()
    is_fetching_feed = true
    subs_videos = {}
    sel_idx = 1
    scroll_y = 0
    target_scroll_y = 0
    req_ch:push({ type = "feed", browse = "subs" })
end

function switch_tab(tab_idx)
    current_tab = tab_idx
    sel_idx = 1
    target_scroll_y = 0
    scroll_y = 0
    
    if tab_idx == 1 then
        state = "FEED"
        cat_idx = 1
        load_category(categories[cat_idx])
    elseif tab_idx == 2 then
        state = "FEED"
        cat_idx = math.min(3, #categories)
        load_category(categories[cat_idx])
    elseif tab_idx == 3 then
        state = "SEARCH"
    elseif tab_idx == 4 then
        state = "SUBS"
        if auth_info.connected then load_subs_feed() end
    elseif tab_idx == 5 then
        state = "ACCOUNT"
        acc_sel = 1
        req_ch:push({ type = "auth_status" })
    end
end

function start_search(query)
    if not query or #query == 0 then return end
    current_tab = 1
    state = "FEED"
    is_fetching_feed = true
    videos = {}
    sel_idx = 1
    scroll_y = 0
    target_scroll_y = 0
    
    local label = "🔍 " .. query
    local found = false
    for i, c in ipairs(categories) do
        if c == label then
            cat_idx = i
            found = true
            break
        end
    end
    if not found then
        table.insert(categories, 2, label)
        cat_idx = 2
    end
    req_ch:push({ type = "feed", query = url_encode(query), cat_idx = cat_idx })
end

function play_video(v)
    now_playing = v
    is_playing = true
    req_ch:push({ type = "mpv", action = "play", id = v.id })
end

function stop_video()
    is_playing = false
    now_playing = nil
    req_ch:push({ type = "mpv", action = "stop" })
    if state == "PLAYER" then
        state = "FEED"
    end
    local list = (state == "SUBS") and subs_videos or videos
    if list[sel_idx] then
        req_ch:push({ type = "mpv", action = "preview", id = list[sel_idx].id })
    end
end

function toggle_pause()
    if is_playing then
        req_ch:push({ type = "mpv", action = "pause" })
    end
end

function love.update(dt)
    while true do
        local msg = res_ch:pop()
        if not msg then break end
        
        if msg.type == "feed" then
            is_fetching_feed = false
            if msg.data then
                local items = decode_json(msg.data)
                if items and #items > 0 then
                    if msg.browse == "subs" then
                        subs_videos = items
                    else
                        videos = items
                    end
                    for i = 1, math.min(10, #items) do
                        req_ch:push({ type = "thumb", id = items[i].id })
                    end
                    -- Preview thumbnail on top screen only if NO video is playing!
                    if not is_playing and items[1] then
                        req_ch:push({ type = "mpv", action = "preview", id = items[1].id })
                    end
                end
            end
        elseif msg.type == "thumb" then
            if msg.data and not thumbs[msg.id] then
                local pcall_ok, img = pcall(function()
                    local filedata = love.filesystem.newFileData(msg.data, msg.id .. ".jpg")
                    return love.graphics.newImage(filedata)
                end)
                if pcall_ok and img then
                    thumbs[msg.id] = img
                end
            end
        elseif msg.type == "status" then
            if msg.data then
                local s = decode_json(msg.data)
                if s then
                    player_status.time_pos = s.time_pos or 0
                    player_status.duration = s.duration or 0
                    player_status.pause = s.pause or false
                end
            end
        elseif msg.type == "auth_status" then
            if msg.data then
                local a = decode_json(msg.data)
                if a then
                    local was_conn = auth_info.connected
                    auth_info.connected = bool(a.connected)
                    auth_info.name = a.name or ""
                    auth_info.connect_url = a.connect_url or auth_info.connect_url
                    auth_info.ip = a.ip or auth_info.ip
                    if not was_conn and auth_info.connected then
                        update_categories_list()
                        load_category(categories[1])
                    end
                end
            end
        elseif msg.type == "auth_status_update" then
            auth_info.connected = false
            auth_info.name = ""
            update_categories_list()
        end
    end
    
    scroll_y = scroll_y + (target_scroll_y - scroll_y) * math.min(1, dt * 14)
    
    local now = love.timer.getTime()
    if is_playing and (now % 0.5 < dt) then
        req_ch:push({ type = "status" })
    end
    
    if (state == "ACCOUNT" or not auth_info.connected) and (now - last_auth_check > 2.5) then
        last_auth_check = now
        req_ch:push({ type = "auth_status" })
    end
end

function bool(val)
    return val == true or val == "true" or val == 1
end

function love.draw()
    love.graphics.clear(0.06, 0.06, 0.06)
    
    if state == "FEED" then
        draw_feed_view(videos, false)
    elseif state == "SUBS" then
        draw_feed_view(subs_videos, true)
    elseif state == "PLAYER" then
        draw_full_player_view()
    elseif state == "SEARCH" then
        draw_search_view()
    elseif state == "ACCOUNT" then
        draw_account_view()
    end
    
    -- Draw Mini-Player docked above bottom nav when video is playing and not in full player
    if is_playing and state ~= "PLAYER" then
        draw_mini_player()
    end
    
    draw_bottom_nav()
end

function draw_feed_view(items_list, is_subs)
    -- Header Bar
    love.graphics.setColor(0.08, 0.08, 0.08)
    love.graphics.rectangle("fill", 0, 0, 640, 42)
    
    -- YouTube Logo
    love.graphics.setColor(1.0, 0.0, 0.0)
    love.graphics.rectangle("fill", 16, 11, 24, 18, 5, 5)
    love.graphics.setColor(1, 1, 1)
    love.graphics.polygon("fill", 24, 15, 24, 25, 33, 20)
    
    love.graphics.setFont(font_logo)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(is_subs and "Inscrições" or "YouTube", 46, 10)
    
    -- Account status or hints
    love.graphics.setFont(font_small)
    if auth_info.connected and auth_info.name and #auth_info.name > 0 then
        love.graphics.setColor(0.2, 0.8, 0.4)
        love.graphics.print("● " .. auth_info.name, 260, 14)
    end
    
    love.graphics.setColor(0.85, 0.85, 0.85)
    love.graphics.print("[L1/R1: Abas]", 420, 14)
    love.graphics.print("🔍 [Y]", 535, 14)
    love.graphics.print("⚙ [SEL]", 585, 14)
    
    love.graphics.setColor(0.18, 0.18, 0.18)
    love.graphics.rectangle("fill", 0, 42, 640, 1)
    
    local start_content_y = 43
    if not is_subs then
        -- Category Carousel
        love.graphics.setColor(0.07, 0.07, 0.07)
        love.graphics.rectangle("fill", 0, 43, 640, 36)
        
        local pill_x = 14
        for i, cat in ipairs(categories) do
            local is_active = (i == cat_idx)
            local pill_w = font_small:getWidth(cat) + 20
            if is_active then
                love.graphics.setColor(1, 1, 1)
                love.graphics.rectangle("fill", pill_x, 48, pill_w, 24, 12, 12)
                love.graphics.setColor(0, 0, 0)
            else
                love.graphics.setColor(0.18, 0.18, 0.18)
                love.graphics.rectangle("fill", pill_x, 48, pill_w, 24, 12, 12)
                love.graphics.setColor(0.9, 0.9, 0.9)
            end
            love.graphics.setFont(font_small)
            love.graphics.print(cat, pill_x + 10, 52)
            pill_x = pill_x + pill_w + 8
        end
        start_content_y = 80
    end
    
    -- Feed Cards
    local bottom_limit_y = (is_playing and 388 or 434)
    love.graphics.setScissor(0, start_content_y, 640, bottom_limit_y - start_content_y)
    love.graphics.push()
    love.graphics.translate(0, -scroll_y)
    
    if is_subs and not auth_info.connected then
        love.graphics.setColor(0.15, 0.15, 0.15)
        love.graphics.rectangle("fill", 30, 120, 580, 150, 10, 10)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(font_big)
        love.graphics.printf("Conecte sua conta para ver suas inscrições", 30, 145, 580, "center")
        love.graphics.setFont(font_small)
        love.graphics.setColor(0.7, 0.7, 0.7)
        love.graphics.printf("Acesse a aba 'Você' no menu inferior para sincronizar sua conta do YouTube.", 30, 175, 580, "center")
        love.graphics.setColor(0.8, 0.1, 0.1)
        love.graphics.rectangle("fill", 220, 210, 200, 36, 18, 18)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(font_title)
        love.graphics.printf("Conectar Agora [A]", 220, 220, 200, "center")
    elseif is_fetching_feed and #items_list == 0 then
        love.graphics.setColor(0.7, 0.7, 0.7)
        love.graphics.setFont(font_title)
        love.graphics.printf("Carregando vídeos do YouTube...", 0, 200, 640, "center")
    else
        local card_y = start_content_y + 6
        local card_h = 108
        
        for i, v in ipairs(items_list) do
            local is_sel = (i == sel_idx)
            
            if is_sel then
                love.graphics.setColor(0.18, 0.18, 0.18)
                love.graphics.rectangle("fill", 14, card_y, 612, card_h - 6, 8, 8)
                love.graphics.setColor(1.0, 0.2, 0.2)
                love.graphics.setLineWidth(2)
                love.graphics.rectangle("line", 14, card_y, 612, card_h - 6, 8, 8)
            else
                love.graphics.setColor(0.11, 0.11, 0.11)
                love.graphics.rectangle("fill", 14, card_y, 612, card_h - 6, 8, 8)
            end
            
            local thumb_img = thumbs[v.id]
            if thumb_img then
                love.graphics.setColor(1, 1, 1)
                local sx = 160 / thumb_img:getWidth()
                local sy = 90 / thumb_img:getHeight()
                love.graphics.draw(thumb_img, 20, card_y + 6, 0, sx, sy)
            else
                love.graphics.setColor(0.2, 0.2, 0.2)
                love.graphics.rectangle("fill", 20, card_y + 6, 160, 90, 6, 6)
                love.graphics.setColor(0.5, 0.5, 0.5)
                love.graphics.polygon("fill", 95, card_y + 40, 95, card_y + 60, 110, card_y + 50)
            end
            
            -- Badge Duração
            love.graphics.setColor(0, 0, 0, 0.8)
            local badge_w = font_badge:getWidth(v.duration) + 8
            love.graphics.rectangle("fill", 175 - badge_w, card_y + 78, badge_w, 16, 3, 3)
            love.graphics.setColor(1, 1, 1)
            love.graphics.setFont(font_badge)
            love.graphics.print(v.duration, 179 - badge_w, card_y + 80)
            
            -- Texto
            local text_x = 192
            love.graphics.setColor(1, 1, 1)
            love.graphics.setFont(font_title)
            love.graphics.printf(v.title, text_x, card_y + 8, 410, "left")
            
            love.graphics.setColor(0.65, 0.65, 0.65)
            love.graphics.setFont(font_small)
            love.graphics.print(v.channel, text_x, card_y + 54)
            love.graphics.print(v.views, text_x, card_y + 72)
            
            card_y = card_y + card_h
        end
    end
    
    love.graphics.pop()
    love.graphics.setScissor()
end

function draw_mini_player()
    if not now_playing then return end
    
    -- Progress Line at top of miniplayer
    love.graphics.setColor(0.25, 0.25, 0.25)
    love.graphics.rectangle("fill", 0, 388, 640, 3)
    local pos = player_status.time_pos or 0
    local dur = player_status.duration or 0
    if dur > 0 then
        local prog_w = math.min(640, (pos / dur) * 640)
        love.graphics.setColor(1, 0, 0)
        love.graphics.rectangle("fill", 0, 388, prog_w, 3)
    end
    
    -- Miniplayer Body
    love.graphics.setColor(0.14, 0.14, 0.14)
    love.graphics.rectangle("fill", 0, 391, 640, 43)
    love.graphics.setColor(0.22, 0.22, 0.22)
    love.graphics.rectangle("fill", 0, 391, 640, 1)
    
    -- Mini Thumbnail
    local thumb = thumbs[now_playing.id]
    if thumb then
        love.graphics.setColor(1, 1, 1)
        love.graphics.draw(thumb, 8, 394, 0, 60 / thumb:getWidth(), 36 / thumb:getHeight())
    else
        love.graphics.setColor(0.25, 0.25, 0.25)
        love.graphics.rectangle("fill", 8, 394, 60, 36, 4, 4)
    end
    
    -- Title & Info
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(font_small)
    love.graphics.printf(now_playing.title, 76, 396, 385, "left")
    
    local pos_str = string.format("%02d:%02d", math.floor(pos / 60), math.floor(pos % 60))
    local dur_str = string.format("%02d:%02d", math.floor(dur / 60), math.floor(dur % 60))
    love.graphics.setColor(0.7, 0.7, 0.7)
    love.graphics.setFont(font_badge)
    love.graphics.print(now_playing.channel .. " • " .. pos_str .. " / " .. dur_str, 76, 416)
    
    -- Play/Pause Button [X]
    love.graphics.setColor(0.2, 0.2, 0.2)
    love.graphics.circle("fill", 496, 412, 16)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(font_small)
    local play_icon = player_status.pause and "▶" or "⏸"
    love.graphics.printf(play_icon, 480, 404, 32, "center")
    
    -- Expand Dashboard Button [⛶]
    love.graphics.setColor(0.2, 0.2, 0.2)
    love.graphics.circle("fill", 544, 412, 16)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf("⛶", 528, 404, 32, "center")
    
    -- Close Video Button [✕]
    love.graphics.setColor(0.25, 0.25, 0.25)
    love.graphics.circle("fill", 592, 412, 16)
    love.graphics.setColor(0.9, 0.9, 0.9)
    love.graphics.printf("✕", 576, 404, 32, "center")
end

function draw_full_player_view()
    if not now_playing then return end
    
    love.graphics.setColor(0.09, 0.09, 0.09)
    love.graphics.rectangle("fill", 0, 0, 640, 434)
    
    -- Top Bar with Minimize
    love.graphics.setColor(0.15, 0.15, 0.15)
    love.graphics.rectangle("fill", 14, 12, 100, 28, 14, 14)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(font_small)
    love.graphics.printf("▼ Minimizar [B]", 14, 18, 100, "center")
    
    love.graphics.setFont(font_title)
    love.graphics.printf(now_playing.title, 20, 52, 600, "left")
    
    -- Channel row
    love.graphics.setColor(0.2, 0.2, 0.2)
    love.graphics.circle("fill", 36, 110, 16)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(font_small)
    love.graphics.print(now_playing.channel, 60, 102)
    
    love.graphics.setColor(0.9, 0.1, 0.1)
    love.graphics.rectangle("fill", 500, 96, 110, 28, 14, 14)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("INSCREVER", 518, 102)
    
    -- Actions
    local btn_x = 20
    local actions = {"👍 Curtir", "👎 Não curti", "↗ Compartilhar", "⬇ Salvar"}
    for _, act in ipairs(actions) do
        local w = font_small:getWidth(act) + 20
        love.graphics.setColor(0.18, 0.18, 0.18)
        love.graphics.rectangle("fill", btn_x, 140, w, 28, 14, 14)
        love.graphics.setColor(0.9, 0.9, 0.9)
        love.graphics.print(act, btn_x + 10, 146)
        btn_x = btn_x + w + 10
    end
    
    -- Timeline Bar
    love.graphics.setColor(0.18, 0.18, 0.18)
    love.graphics.rectangle("fill", 20, 196, 600, 6, 3, 3)
    
    local pos = player_status.time_pos or 0
    local dur = player_status.duration or 0
    if dur > 0 then
        local prog_w = math.min(600, (pos / dur) * 600)
        love.graphics.setColor(1, 0, 0)
        love.graphics.rectangle("fill", 20, 196, prog_w, 6, 3, 3)
        love.graphics.setColor(1, 1, 1)
        love.graphics.circle("fill", 20 + prog_w, 199, 6)
    end
    
    local pos_str = string.format("%02d:%02d", math.floor(pos / 60), math.floor(pos % 60))
    local dur_str = string.format("%02d:%02d", math.floor(dur / 60), math.floor(dur % 60))
    love.graphics.setColor(0.75, 0.75, 0.75)
    love.graphics.setFont(font_small)
    love.graphics.print(pos_str .. " / " .. dur_str, 20, 210)
    love.graphics.print("[B: Minimizar | X: Pause | Esquerda/Direita: 10s | L2/R2: Vol]", 260, 210)
    
    love.graphics.setColor(0.13, 0.13, 0.13)
    love.graphics.rectangle("fill", 20, 246, 600, 160, 8, 8)
    love.graphics.setColor(0.4, 0.8, 0.4)
    love.graphics.setFont(font_title)
    love.graphics.printf("▶ VÍDEO EM REPRODUÇÃO NA TELA SUPERIOR", 20, 270, 600, "center")
    love.graphics.setColor(0.7, 0.7, 0.7)
    love.graphics.setFont(font_small)
    love.graphics.printf("Decodificação por hardware a 60 FPS (Rockchip RK3566)", 20, 300, 600, "center")
    love.graphics.printf("Pressione B para navegar livremente pela Home enquanto assiste", 20, 330, 600, "center")
end

local search_keys = {
    {"1","2","3","4","5","6","7","8","9","0"},
    {"Q","W","E","R","T","Y","U","I","O","P"},
    {"A","S","D","F","G","H","J","K","L","-"},
    {"Z","X","C","V","B","N","M",".","_","?"},
    {"⌫ APAGAR", "ESPAÇO", "🔍 BUSCAR"}
}

function draw_search_view()
    love.graphics.setColor(0.08, 0.08, 0.08)
    love.graphics.rectangle("fill", 0, 0, 640, 434)
    
    -- Header
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(font_logo)
    love.graphics.print("Buscar no YouTube", 20, 12)
    
    -- Search Input Box
    love.graphics.setColor(0.15, 0.15, 0.15)
    love.graphics.rectangle("fill", 20, 38, 600, 36, 8, 8)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(font_title)
    
    local cursor = (math.floor(love.timer.getTime() * 2) % 2 == 0) and "_" or " "
    local disp_q = search_query
    if #disp_q == 0 then
        love.graphics.setColor(0.5, 0.5, 0.5)
        love.graphics.print("Digite com os botões ou toque nas sugestões...", 32, 47)
    else
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(disp_q .. cursor, 32, 47)
        -- Clear button
        love.graphics.setColor(0.3, 0.3, 0.3)
        love.graphics.circle("fill", 596, 56, 12)
        love.graphics.setColor(0.8, 0.8, 0.8)
        love.graphics.setFont(font_small)
        love.graphics.print("✕", 592, 49)
    end
    
    -- Quick Tags Carousel (kb_r == 0)
    local qx = 20
    local qy = 82
    for t_idx, tag in ipairs(quick_tags) do
        local qw = font_small:getWidth(tag) + 16
        if qx + qw < 620 then
            local is_tag_sel = (kb_r == 0 and kb_c == t_idx)
            if is_tag_sel then
                love.graphics.setColor(1, 0, 0)
            else
                love.graphics.setColor(0.2, 0.2, 0.2)
            end
            love.graphics.rectangle("fill", qx, qy, qw, 24, 6, 6)
            love.graphics.setColor(1, 1, 1)
            love.graphics.setFont(font_small)
            love.graphics.print(tag, qx + 8, qy + 5)
            qx = qx + qw + 8
        end
    end
    
    -- Virtual Keyboard (kb_r == 1..5)
    local ky = 118
    for r_idx, row in ipairs(search_keys) do
        local kx = 24
        for c_idx, key in ipairs(row) do
            local kw = 54
            if r_idx == 5 then
                if key == "⌫ APAGAR" then kw = 150
                elseif key == "ESPAÇO" then kw = 240
                elseif key == "🔍 BUSCAR" then kw = 186
                end
            end
            
            local is_k_sel = (r_idx == kb_r and c_idx == kb_c)
            if is_k_sel then
                love.graphics.setColor(1, 0, 0)
            elseif key == "🔍 BUSCAR" then
                love.graphics.setColor(0.8, 0.1, 0.1)
            elseif key == "⌫ APAGAR" then
                love.graphics.setColor(0.25, 0.25, 0.25)
            else
                love.graphics.setColor(0.18, 0.18, 0.18)
            end
            love.graphics.rectangle("fill", kx, ky, kw, 34, 6, 6)
            
            love.graphics.setColor(1, 1, 1)
            love.graphics.setFont(font_small)
            love.graphics.printf(key, kx, ky + 10, kw, "center")
            kx = kx + kw + 6
        end
        ky = ky + 40
    end
    
    love.graphics.setColor(0.6, 0.6, 0.6)
    love.graphics.setFont(font_badge)
    love.graphics.printf("D-Pad + A: Digitar | Cima (kb): Sugestões | X: Apagar | START: Buscar | B: Voltar", 0, 320, 640, "center")
end

function draw_account_view()
    love.graphics.setColor(0.08, 0.08, 0.08)
    love.graphics.rectangle("fill", 0, 0, 640, 434)
    
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(font_logo)
    love.graphics.print("Sua Conta & Recomendações", 20, 16)
    
    if auth_info.connected then
        -- Card Conectado
        love.graphics.setColor(0.12, 0.12, 0.12)
        love.graphics.rectangle("fill", 20, 56, 600, 140, 10, 10)
        love.graphics.setColor(0.1, 0.7, 0.3)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", 20, 56, 600, 140, 10, 10)
        
        love.graphics.setColor(0.2, 0.2, 0.2)
        love.graphics.circle("fill", 60, 106, 26)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(font_big)
        local initial = auth_info.name and auth_info.name:sub(1, 1):upper() or "Y"
        love.graphics.printf(initial, 34, 96, 52, "center")
        
        love.graphics.setFont(font_big)
        love.graphics.setColor(1, 1, 1)
        love.graphics.print(auth_info.name or "Conta do YouTube", 100, 80)
        
        love.graphics.setFont(font_small)
        love.graphics.setColor(0.3, 0.9, 0.4)
        love.graphics.print("● Conectado com sucesso", 100, 106)
        love.graphics.setColor(0.7, 0.7, 0.7)
        love.graphics.print("Suas recomendações e inscrições estão ativas no console.", 100, 126)
        
        -- Botões com seleção via D-Pad
        if acc_sel == 1 then
            love.graphics.setColor(1, 0, 0)
        else
            love.graphics.setColor(0.2, 0.2, 0.2)
        end
        love.graphics.rectangle("fill", 20, 216, 600, 44, 8, 8)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(font_title)
        love.graphics.printf("🔄 Recarregar Recomendações [A]", 20, 230, 600, "center")
        
        if acc_sel == 2 then
            love.graphics.setColor(1, 0, 0)
        else
            love.graphics.setColor(0.6, 0.1, 0.1)
        end
        love.graphics.rectangle("fill", 20, 276, 600, 44, 8, 8)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(font_title)
        love.graphics.printf("🚪 Desconectar Conta [A/X]", 20, 290, 600, "center")
    else
        -- Card Desconectado
        love.graphics.setColor(0.12, 0.12, 0.12)
        love.graphics.rectangle("fill", 20, 54, 600, 220, 10, 10)
        love.graphics.setColor(1.0, 0.2, 0.2)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", 20, 54, 600, 220, 10, 10)
        
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(font_big)
        love.graphics.print("Conecte sua Conta para Recomendações", 40, 72)
        
        love.graphics.setFont(font_small)
        love.graphics.setColor(0.85, 0.85, 0.85)
        love.graphics.print("No celular ou PC conectado no mesmo Wi-Fi, abra o navegador e acesse:", 40, 102)
        
        love.graphics.setColor(0.18, 0.18, 0.18)
        love.graphics.rectangle("fill", 40, 126, 560, 46, 6, 6)
        love.graphics.setColor(1, 0.9, 0.2)
        love.graphics.setFont(font_big)
        love.graphics.printf(auth_info.connect_url, 40, 138, 560, "center")
        
        love.graphics.setFont(font_small)
        love.graphics.setColor(0.75, 0.75, 0.75)
        love.graphics.print("• Cole seus cookies do YouTube ou digite seus canais/tópicos favoritos.", 40, 186)
        love.graphics.print("• Esta tela atualizará automaticamente assim que você salvar na página!", 40, 206)
        
        local dot = (math.floor(love.timer.getTime() * 2) % 2 == 0)
        love.graphics.setColor(dot and 0.2 or 0.7, 0.8, 0.3)
        love.graphics.print("● Aguardando conexão pelo navegador...", 40, 238)
        
        if acc_sel == 1 then
            love.graphics.setColor(1, 0, 0)
        else
            love.graphics.setColor(0.2, 0.2, 0.2)
        end
        love.graphics.rectangle("fill", 20, 290, 600, 44, 8, 8)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(font_title)
        love.graphics.printf("Verificar Conexão Agora [A]", 20, 304, 600, "center")
    end
end

function draw_bottom_nav()
    love.graphics.setColor(0.08, 0.08, 0.08)
    love.graphics.rectangle("fill", 0, 434, 640, 46)
    love.graphics.setColor(0.18, 0.18, 0.18)
    love.graphics.rectangle("fill", 0, 434, 640, 1)
    
    local navs = {
        {icon = "🏠", label = "Início"},
        {icon = "🔥", label = "Em Alta"},
        {icon = "🔍", label = "Buscar"},
        {icon = "📺", label = "Inscrições"},
        {icon = "👤", label = "Você"}
    }
    local tab_w = 640 / 5
    for i, tab in ipairs(navs) do
        local tx = (i - 1) * tab_w
        local is_active = (current_tab == i)
        
        if is_active then
            love.graphics.setColor(1, 1, 1)
        else
            love.graphics.setColor(0.55, 0.55, 0.55)
        end
        love.graphics.setFont(font_small)
        love.graphics.printf(tab.icon .. "\n" .. tab.label, tx, 438, tab_w, "center")
    end
end

-- ========================================================
-- INPUT HANDLING: CONTROLLER & GAMEPAD & KEYBOARD
-- ========================================================

local last_input_time = 0
local last_action = ""

function handle_input(action)
    local now = love.timer.getTime()
    if action == last_action and (now - last_input_time < 0.06) then
        return
    end
    last_input_time = now
    last_action = action
    
    -- Global Tab Navigation with Shoulder buttons
    if action == "L1" then
        switch_tab((current_tab - 2 + 5) % 5 + 1)
        return
    elseif action == "R1" then
        switch_tab((current_tab % 5) + 1)
        return
    end
    
    -- Global Exit
    if action == "SELECT" then
        love.event.quit()
        return
    end

    if state == "FEED" or state == "SUBS" then
        local current_list = (state == "SUBS") and subs_videos or videos
        if action == "DOWN" then
            if sel_idx < #current_list then
                sel_idx = sel_idx + 1
                target_scroll_y = math.max(0, (sel_idx - 2) * 108)
                if not is_playing and current_list[sel_idx] then
                    req_ch:push({ type = "mpv", action = "preview", id = current_list[sel_idx].id })
                end
            end
        elseif action == "UP" then
            if sel_idx > 1 then
                sel_idx = sel_idx - 1
                target_scroll_y = math.max(0, (sel_idx - 2) * 108)
                if not is_playing and current_list[sel_idx] then
                    req_ch:push({ type = "mpv", action = "preview", id = current_list[sel_idx].id })
                end
            end
        elseif action == "RIGHT" or action == "R2" then
            if state == "FEED" then
                cat_idx = (cat_idx % #categories) + 1
                load_category(categories[cat_idx])
            end
        elseif action == "LEFT" or action == "L2" then
            if state == "FEED" then
                cat_idx = (cat_idx - 2 + #categories) % #categories + 1
                load_category(categories[cat_idx])
            end
        elseif action == "A" then
            if current_list[sel_idx] then
                play_video(current_list[sel_idx])
            elseif state == "SUBS" and not auth_info.connected then
                switch_tab(5)
            end
        elseif action == "X" then
            if is_playing then
                toggle_pause()
            end
        elseif action == "Y" then
            switch_tab(3)
        elseif action == "B" then
            if is_playing then
                stop_video()
            else
                switch_tab(1)
            end
        end
    elseif state == "PLAYER" then
        if action == "B" then
            state = "FEED" -- Minimizes to mini-player, video keeps playing!
        elseif action == "X" or action == "START" then
            toggle_pause()
        elseif action == "LEFT" then
            req_ch:push({ type = "mpv", action = "seek", val = -10 })
        elseif action == "RIGHT" then
            req_ch:push({ type = "mpv", action = "seek", val = 10 })
        elseif action == "L2" then
            req_ch:push({ type = "mpv", action = "vol", val = -5 })
        elseif action == "R2" then
            req_ch:push({ type = "mpv", action = "vol", val = 5 })
        elseif action == "Y" then
            stop_video()
        end
    elseif state == "SEARCH" then
        if action == "DOWN" then
            if kb_r == 0 then
                kb_r = 1
                kb_c = math.min(#search_keys[1], kb_c)
            else
                kb_r = math.min(#search_keys, kb_r + 1)
                kb_c = math.min(#search_keys[kb_r], kb_c)
            end
        elseif action == "UP" then
            if kb_r == 1 then
                kb_r = 0
                kb_c = math.min(#quick_tags, kb_c)
            elseif kb_r > 1 then
                kb_r = kb_r - 1
                kb_c = math.min(#search_keys[kb_r], kb_c)
            end
        elseif action == "LEFT" then
            if kb_r == 0 then
                kb_c = math.max(1, kb_c - 1)
            else
                kb_c = math.max(1, kb_c - 1)
            end
        elseif action == "RIGHT" then
            if kb_r == 0 then
                kb_c = math.min(#quick_tags, kb_c + 1)
            else
                kb_c = math.min(#search_keys[kb_r], kb_c + 1)
            end
        elseif action == "A" then
            if kb_r == 0 then
                local tag = quick_tags[kb_c]
                if tag then
                    search_query = tag
                    start_search(tag)
                end
            else
                local k = search_keys[kb_r][kb_c]
                if k == "ESPAÇO" then
                    search_query = search_query .. " "
                elseif k == "⌫ APAGAR" then
                    if #search_query > 0 then search_query = search_query:sub(1, -2) end
                elseif k == "🔍 BUSCAR" then
                    start_search(search_query)
                else
                    search_query = search_query .. k:lower()
                end
            end
        elseif action == "X" then
            if #search_query > 0 then search_query = search_query:sub(1, -2) end
        elseif action == "Y" then
            search_query = ""
        elseif action == "START" then
            start_search(search_query)
        elseif action == "B" then
            state = "FEED"
        end
    elseif state == "ACCOUNT" then
        if action == "DOWN" or action == "UP" then
            if auth_info.connected then
                acc_sel = (acc_sel == 1) and 2 or 1
            else
                acc_sel = 1
            end
        elseif action == "A" then
            if auth_info.connected then
                if acc_sel == 1 then
                    load_category(categories[1])
                    state = "FEED"
                else
                    req_ch:push({ type = "logout" })
                end
            else
                req_ch:push({ type = "auth_status" })
            end
        elseif action == "X" and auth_info.connected then
            req_ch:push({ type = "logout" })
        elseif action == "B" then
            state = "FEED"
        end
    end
end

-- SDL Gamepad Mapping
function love.gamepadpressed(joystick, button)
    if button == "a" then handle_input("A")
    elseif button == "b" then handle_input("B")
    elseif button == "x" then handle_input("X")
    elseif button == "y" then handle_input("Y")
    elseif button == "leftshoulder" then handle_input("L1")
    elseif button == "rightshoulder" then handle_input("R1")
    elseif button == "lefttrigger" then handle_input("L2")
    elseif button == "righttrigger" then handle_input("R2")
    elseif button == "start" then handle_input("START")
    elseif button == "back" then handle_input("SELECT")
    elseif button == "dpup" then handle_input("UP")
    elseif button == "dpdown" then handle_input("DOWN")
    elseif button == "dpleft" then handle_input("LEFT")
    elseif button == "dpright" then handle_input("RIGHT")
    end
end

-- Raw Joystick Mapping (for RK3566 / Anbernic default joypad)
function love.joystickpressed(joystick, button)
    if button == 0 or button == 1 then handle_input("A")
    elseif button == 2 then handle_input("X")
    elseif button == 3 then handle_input("Y")
    elseif button == 4 then handle_input("L1")
    elseif button == 5 then handle_input("R1")
    elseif button == 6 then handle_input("L2")
    elseif button == 7 then handle_input("R2")
    elseif button == 8 then handle_input("SELECT")
    elseif button == 9 or button == 10 then handle_input("START")
    elseif button == 13 then handle_input("UP")
    elseif button == 14 then handle_input("DOWN")
    elseif button == 15 then handle_input("LEFT")
    elseif button == 16 then handle_input("RIGHT")
    end
end

-- Physical Keyboard Mapping
function love.keypressed(key)
    if key == "up" then handle_input("UP")
    elseif key == "down" then handle_input("DOWN")
    elseif key == "left" then handle_input("LEFT")
    elseif key == "right" then handle_input("RIGHT")
    elseif key == "return" or key == "a" then handle_input("A")
    elseif key == "b" or key == "escape" then handle_input("B")
    elseif key == "x" or key == "backspace" then handle_input("X")
    elseif key == "y" then handle_input("Y")
    elseif key == "l" or key == "[" then handle_input("L1")
    elseif key == "r" or key == "]" then handle_input("R1")
    elseif key == "space" then
        if state == "SEARCH" then handle_input("A") else handle_input("X") end
    elseif key == "q" then
        love.event.quit()
    end
end

function love.textinput(t)
    if state == "SEARCH" then
        search_query = search_query .. t
    end
end

-- ========================================================
-- TOUCH HANDLING (Screen DSI-1)
-- ========================================================

local touch_start_y = 0
local touch_last_y = 0
local is_touching = false

function love.touchpressed(id, x, y, dx, dy, pressure)
    touch_start_y = y
    touch_last_y = y
    is_touching = true
end

function love.touchmoved(id, x, y, dx, dy, pressure)
    local bottom_limit = (is_playing and 388 or 434)
    if (state == "FEED" or state == "SUBS") and y > 80 and y < bottom_limit then
        local delta = y - touch_last_y
        local current_list = (state == "SUBS") and subs_videos or videos
        target_scroll_y = math.max(0, math.min((#current_list - 1) * 108, target_scroll_y - delta))
    end
    touch_last_y = y
end

function love.touchreleased(id, x, y, dx, dy, pressure)
    is_touching = false
    if math.abs(y - touch_start_y) < 14 then
        -- 1. Bottom Nav Bar Touches
        if y >= 434 then
            local tab_w = 640 / 5
            local tab_idx = math.floor(x / tab_w) + 1
            if tab_idx >= 1 and tab_idx <= 5 then
                switch_tab(tab_idx)
            end
            return
        end
        
        -- 2. Mini-Player Touches
        if is_playing and state ~= "PLAYER" and y >= 388 and y <= 434 then
            if x >= 476 and x <= 516 then
                toggle_pause()
            elseif x >= 522 and x <= 562 then
                state = "PLAYER" -- Expand dashboard
            elseif x >= 568 and x <= 620 then
                stop_video() -- Close video
            else
                state = "PLAYER" -- Tap anywhere to expand
            end
            return
        end
        
        -- 3. Header touches (Buscar ou Sair)
        if y <= 42 then
            if x >= 520 and x <= 570 then
                switch_tab(3)
                return
            elseif x >= 575 then
                love.event.quit()
                return
            end
        end
        
        -- 4. View Specific Touches
        if state == "FEED" then
            -- Category Carousel
            if y >= 43 and y <= 80 then
                local pill_x = 14
                for i, cat in ipairs(categories) do
                    local pill_w = font_small:getWidth(cat) + 20
                    if x >= pill_x and x <= pill_x + pill_w then
                        cat_idx = i
                        load_category(cat)
                        return
                    end
                    pill_x = pill_x + pill_w + 8
                end
            end
            
            -- Video Cards Click
            local bottom_limit = (is_playing and 388 or 434)
            if y > 80 and y < bottom_limit then
                local clicked_y = y + scroll_y - 86
                local item_idx = math.floor(clicked_y / 108) + 1
                if item_idx >= 1 and item_idx <= #videos then
                    sel_idx = item_idx
                    play_video(videos[sel_idx])
                end
            end
        elseif state == "SUBS" then
            if not auth_info.connected then
                if y >= 200 and y <= 250 and x >= 200 and x <= 440 then
                    switch_tab(5)
                end
            else
                local bottom_limit = (is_playing and 388 or 434)
                if y > 43 and y < bottom_limit then
                    local clicked_y = y + scroll_y - 49
                    local item_idx = math.floor(clicked_y / 108) + 1
                    if item_idx >= 1 and item_idx <= #subs_videos then
                        sel_idx = item_idx
                        play_video(subs_videos[sel_idx])
                    end
                end
            end
        elseif state == "PLAYER" then
            -- Minimize button
            if y >= 12 and y <= 42 and x >= 14 and x <= 120 then
                state = "FEED"
            elseif y >= 190 and y <= 220 and x >= 20 and x <= 620 then
                -- Scrubber seek by touch
                local pct = math.max(0, math.min(1, (x - 20) / 600))
                local dur = player_status.duration or 0
                if dur > 0 then
                    local target_s = pct * dur
                    req_ch:push({ type = "mpv", action = "seek", val = math.floor(target_s) })
                end
            end
        elseif state == "SEARCH" then
            -- Clear button on search box
            if y >= 38 and y <= 74 and x >= 580 and x <= 620 then
                search_query = ""
                return
            end
            
            -- Quick tags pills
            if y >= 82 and y <= 108 then
                local qx = 20
                for _, tag in ipairs(quick_tags) do
                    local qw = font_small:getWidth(tag) + 16
                    if x >= qx and x <= qx + qw then
                        search_query = tag
                        start_search(tag)
                        return
                    end
                    qx = qx + qw + 8
                end
            end
            
            -- Virtual Keyboard Keys Touch
            local ky = 118
            for r_idx, row in ipairs(search_keys) do
                if y >= ky and y <= ky + 34 then
                    local kx = 24
                    for c_idx, key in ipairs(row) do
                        local kw = 54
                        if r_idx == 5 then
                            if key == "⌫ APAGAR" then kw = 150
                            elseif key == "ESPAÇO" then kw = 240
                            elseif key == "🔍 BUSCAR" then kw = 186
                            end
                        end
                        if x >= kx and x <= kx + kw then
                            kb_r = r_idx
                            kb_c = c_idx
                            if key == "ESPAÇO" then
                                search_query = search_query .. " "
                            elseif key == "⌫ APAGAR" then
                                if #search_query > 0 then search_query = search_query:sub(1, -2) end
                            elseif key == "🔍 BUSCAR" then
                                start_search(search_query)
                            else
                                search_query = search_query .. key:lower()
                            end
                            return
                        end
                        kx = kx + kw + 6
                    end
                end
                ky = ky + 40
            end
        elseif state == "ACCOUNT" then
            if auth_info.connected then
                if y >= 216 and y <= 260 then
                    load_category(categories[1])
                    state = "FEED"
                elseif y >= 276 and y <= 320 then
                    req_ch:push({ type = "logout" })
                end
            else
                if y >= 290 and y <= 334 then
                    req_ch:push({ type = "auth_status" })
                end
            end
        end
    end
end
