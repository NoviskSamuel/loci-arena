-- Loci Arena - Love2D Client
-- Entrypoint for the game client connecting to the authoritative loci2d server.

package.path = package.path .. ";./loci2d/?.lua;./loci2d/lib/?.lua;./client/loci2d/?.lua;./client/loci2d/lib/?.lua;./src/?.lua;./client/src/?.lua;./?.lua;./lib/?.lua"
package.cpath = package.cpath .. ";./loci2d/lib/?.so;./loci2d/?.so;./client/loci2d/lib/?.so;./client/loci2d/?.so;./?.so;./lib/?.so"

local ok, loci = pcall(require, "loci_client")
if not ok then
    ok, loci = pcall(require, "loci2d.loci_client")
    if not ok then
        error("Could not load loci_client SDK module. Details: " .. tostring(loci))
    end
end

-- Connection config
local SERVER_IP = os.getenv("LOCI_SERVER_IP") or "127.0.0.1"
local SERVER_PORT = tonumber(os.getenv("LOCI_SERVER_PORT")) or 8080

-- UI & State variables
local connection_status = "Connecting..."
local rejection_msg = ""
local rejection_timer = 0
local visual_fx = {}
local show_debug_overlay = false

-- Sistema de Dash - detecção de double-tap
local last_key_time = {}
local DASH_DOUBLE_TAP_TIME = 0.3
local DASH_COOLDOWN = 1.0
local last_dash_time = 0

-- Rastrear última direção de movimento para habilidades
local last_move_dir_x = 1
local last_move_dir_y = 0

-- Rastrear últimas teclas pressionadas para garantir direção
local last_movement_dx = 1
local last_movement_dy = 0

-- Camera state (tracked directly in world coordinates)
local cam_x, cam_y = 0, 0

-- Server authoritative arena boundaries: [-500, +500] (1000x1000 pixels)
local ARENA_MIN = -500
local ARENA_MAX = 500
local ARENA_SIZE = ARENA_MAX - ARENA_MIN

function love.load(arg)
    love.graphics.setDefaultFilter("linear", "linear")
    
    local random_suffix = tostring(love.math and love.math.random(1000, 9999) or math.random(1000, 9999))
    local player_name = "Player_" .. random_suffix

    print(string.format("[Client] Connecting to %s:%d as '%s'...", SERVER_IP, SERVER_PORT, player_name))
    
    local ok_connect = loci.connect(SERVER_IP, SERVER_PORT, player_name, "loci2d/lib/")
    if not ok_connect then
        ok_connect = loci.connect(SERVER_IP, SERVER_PORT, player_name, "client/loci2d/lib/")
    end

    if not ok_connect then
        connection_status = "Connection error"
        print("[Client] Failed to initialize connection to " .. SERVER_IP .. ":" .. SERVER_PORT)
        return
    end

    connection_status = "Connected to " .. SERVER_IP .. ":" .. SERVER_PORT .. " (" .. player_name .. ")"

    loci.on_entity_spawned = function(entity)
        print(string.format("[Event] Entity spawned: ID %s at (%.1f, %.1f)", tostring(entity.id), entity.x, entity.y))
    end

    loci.on_entity_despawned = function(entity_id)
        print("[Event] Entity despawned: ID " .. tostring(entity_id))
    end

    loci.on_property_changed = function(entity, key, old_val, new_val)
    end

    loci.on_action_cast = function(entity, ability_id, dir_x, dir_y)
        table.insert(visual_fx, {
            x = entity and entity.x or 0,
            y = entity and entity.y or 0,
            dir_x = dir_x,
            dir_y = dir_y,
            ability_id = ability_id,
            lifetime = 0.35,
            max_lifetime = 0.35
        })
    end

    loci.on_intent_rejected = function(reason)
        rejection_msg = reason
        rejection_timer = 2.5
    end
end

local last_sent_dx, last_sent_dy = 0, 0

local function update_movement()
    local dx, dy = 0, 0
    if love.keyboard.isDown("w") or love.keyboard.isDown("up") then dy = dy - 1 end
    if love.keyboard.isDown("s") or love.keyboard.isDown("down") then dy = dy + 1 end
    if love.keyboard.isDown("a") or love.keyboard.isDown("left") then dx = dx - 1 end
    if love.keyboard.isDown("d") or love.keyboard.isDown("right") then dx = dx + 1 end

    if dx ~= last_sent_dx or dy ~= last_sent_dy then
        last_sent_dx = dx
        last_sent_dy = dy
        loci.send_move(dx, dy)
    end
    
    -- Rastrear última direção normalizada para habilidades
    if dx ~= 0 or dy ~= 0 then
        local len = math.sqrt(dx * dx + dy * dy)
        last_move_dir_x = dx / len
        last_move_dir_y = dy / len
        last_movement_dx = dx
        last_movement_dy = dy
    end
end

function love.update(dt)
    loci.update(dt)

    local my_entity = loci.get_my_entity()
    if my_entity then
        update_movement()
        cam_x = my_entity.x
        cam_y = my_entity.y
    end

    if rejection_timer > 0 then
        rejection_timer = rejection_timer - dt
    end

    for i = #visual_fx, 1, -1 do
        visual_fx[i].lifetime = visual_fx[i].lifetime - dt
        if visual_fx[i].lifetime <= 0 then
            table.remove(visual_fx, i)
        end
    end
end

function love.keypressed(key)
    -- Sistema de Dash - detecta double-tap apenas em teclas de movimento
    local dash_keys = {"w", "a", "s", "d", "up", "down", "left", "right"}
    local is_dash_key = false
    for _, k in ipairs(dash_keys) do
        if key == k then
            is_dash_key = true
            break
        end
    end
    
    if is_dash_key then
        local current_time = love.timer.getTime()
        local last_time = last_key_time[key] or 0
        
        if current_time - last_time < DASH_DOUBLE_TAP_TIME and current_time - last_dash_time > DASH_COOLDOWN then
            local my_entity = loci.get_my_entity()
            if my_entity then
                local dir_x, dir_y = 0, 0
                
                if key == "w" or key == "up" then
                    dir_y = -1
                elseif key == "s" or key == "down" then
                    dir_y = 1
                elseif key == "a" or key == "left" then
                    dir_x = -1
                elseif key == "d" or key == "right" then
                    dir_x = 1
                end
                
                -- Enviar direção normalizada para o dash (ability 2 conforme Trello)
                loci.send_action(2, dir_x, dir_y)
                
                last_dash_time = current_time
            end
        end
        
        last_key_time[key] = current_time
    end

    if key == "f3" then
        show_debug_overlay = not show_debug_overlay
    elseif key == "space" then
        -- Fireball usa última direção de movimento
        local dir_x, dir_y = 1, 0
        if last_move_dir_x ~= 0 or last_move_dir_y ~= 0 then
            dir_x = last_move_dir_x
            dir_y = last_move_dir_y
        end
        loci.send_action(1, dir_x, dir_y)
    elseif key == "e" then
        local my_entity = loci.get_my_entity()
        if my_entity then
            loci.send_action(4, 0, 0)
        end
    end
end

function love.draw()
    local sw, sh = love.graphics.getDimensions()
    local center_x = sw / 2
    local center_y = sh / 2

    love.graphics.push()
    love.graphics.translate(center_x, center_y)
    love.graphics.translate(-cam_x, -cam_y)

    draw_arena_grid()

    for _, fx in ipairs(visual_fx) do
        local progress = fx.lifetime / fx.max_lifetime
        love.graphics.setColor(1, 0.85, 0.2, progress)
        local fx_start_x = fx.x
        local fx_start_y = fx.y
        local fx_end_x = fx_start_x + fx.dir_x * 50
        local fx_end_y = fx_start_y + fx.dir_y * 50
        love.graphics.line(fx_start_x, fx_start_y, fx_end_x, fx_end_y)
        love.graphics.circle("fill", fx_end_x, fx_end_y, 5 * progress)
    end

    local my_entity = loci.get_my_entity()
    local entities = loci.get_entities()
    for _, ent in ipairs(entities) do
        draw_entity(ent, my_entity and (ent.id == my_entity.id))
    end

    love.graphics.pop()

    draw_hud(sw, sh, my_entity)

    if show_debug_overlay then
        draw_debug(sw, sh)
    end
end

function draw_arena_grid()
    love.graphics.setColor(0.06, 0.07, 0.10, 1.0)
    love.graphics.rectangle("fill", -1000, -1000, 2000, 2000)

    love.graphics.setColor(0.10, 0.12, 0.17, 1.0)
    love.graphics.rectangle("fill", ARENA_MIN, ARENA_MIN, ARENA_SIZE, ARENA_SIZE)

    love.graphics.setColor(0.18, 0.22, 0.32, 0.35)
    love.graphics.setLineWidth(1)
    for x = ARENA_MIN, ARENA_MAX, 50 do
        love.graphics.line(x, ARENA_MIN, x, ARENA_MAX)
    end
    for y = ARENA_MIN, ARENA_MAX, 50 do
        love.graphics.line(ARENA_MIN, y, ARENA_MAX, y)
    end

    love.graphics.setColor(0.25, 0.55, 0.95, 0.25)
    love.graphics.setLineWidth(5)
    love.graphics.rectangle("line", ARENA_MIN - 2, ARENA_MIN - 2, ARENA_SIZE + 4, ARENA_SIZE + 4)

    love.graphics.setColor(0.35, 0.65, 1.0, 0.9)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", ARENA_MIN, ARENA_MIN, ARENA_SIZE, ARENA_SIZE)

    love.graphics.setColor(0.4, 0.6, 0.85, 0.7)
    love.graphics.setLineWidth(1.5)
    love.graphics.line(-20, 0, 20, 0)
    love.graphics.line(0, -20, 0, 20)
    love.graphics.setColor(0.6, 0.75, 0.9, 0.6)
    love.graphics.print("(0, 0)", 6, 6)
end

function draw_entity(ent, is_me)
    -- Raio visual ajustado para corresponder ao raio de colisão do servidor (2.0)
    -- Escala: 1 unidade = 1 pixel, então raio 2.0 = 2px, mas para visibilidade usamos 8px
    local radius = 8
    local px = ent.x
    local py = ent.y

    if is_me then
        love.graphics.setColor(0.2, 0.6, 1.0, 1)
    else
        love.graphics.setColor(0.9, 0.3, 0.3, 1)
    end

    love.graphics.circle("fill", px, py, radius)
    love.graphics.setColor(1, 1, 1, 0.85)
    love.graphics.setLineWidth(2)
    love.graphics.circle("line", px, py, radius)
    
    -- Visual effect for Dash
    if ent.properties and ent.properties.dash_active == "true" then
        love.graphics.setColor(1.0, 0.8, 0.2, 0.5)
        love.graphics.circle("fill", px, py, 10)
        love.graphics.setColor(1, 1, 1)
        love.graphics.circle("line", px, py, 10)
    end
    
    -- Visual effect for Shield (aura animada)
    if ent.properties and ent.properties.shield_active == "true" then
        local time = love.timer.getTime()
        local pulse = math.sin(time * 3) * 0.3 + 0.7  -- Pulsação entre 0.4 e 1.0

        -- Círculo base do escudo
        love.graphics.setColor(0.2, 0.8, 0.9, 0.2 * pulse)
        love.graphics.circle("fill", px, py, 16)

        -- Anéis externos com pulsação
        love.graphics.setColor(0.2, 0.8, 0.9, 0.4 * pulse)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", px, py, 16)

        love.graphics.setColor(0.2, 0.8, 0.9, 0.3 * pulse)
        love.graphics.setLineWidth(1)
        love.graphics.circle("line", px, py, 18 + math.sin(time * 5) * 2)

        love.graphics.setColor(0.2, 0.8, 0.9, 0.2 * pulse)
        love.graphics.circle("line", px, py, 20 + math.cos(time * 4) * 2)

        -- Partículas de escudo (círculos menores)
        love.graphics.setColor(0.3, 0.9, 1.0, 0.6 * pulse)
        for i = 0, 7 do
            local angle = (i / 8) * math.pi * 2 + time * 2
            local dist = 14 + math.sin(time * 3 + i) * 2
            local part_x = px + math.cos(angle) * dist
            local part_y = py + math.sin(angle) * dist
            love.graphics.circle("fill", part_x, part_y, 2)
        end
    end

    local hp = tonumber(ent.hp or (ent.properties and ent.properties["hp"]) or 100) or 100
    local max_hp = tonumber(ent.max_hp or (ent.properties and ent.properties["max_hp"]) or 100) or 100
    local bar_w = 24
    local bar_h = 4
    local bar_x = px - bar_w / 2
    local bar_y = py - radius - 10

    love.graphics.setColor(0, 0, 0, 0.7)
    love.graphics.rectangle("fill", bar_x, bar_y, bar_w, bar_h)
    love.graphics.setColor(0.2, 0.9, 0.3, 1)
    love.graphics.rectangle("fill", bar_x, bar_y, bar_w * (math.max(0, math.min(1, hp / max_hp))), bar_h)

    love.graphics.setColor(1, 1, 1, 0.95)
    local label = is_me and "YOU" or ("P" .. tostring(ent.id))
    local font = love.graphics.getFont()
    local tw = font:getWidth(label)
    love.graphics.print(label, px - tw / 2, py - radius - 5)
end

function draw_hud(sw, sh, my_entity)
    love.graphics.setColor(0, 0, 0, 0.55)
    love.graphics.rectangle("fill", 10, 10, 360, 55, 6, 6)

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print("Loci Arena", 20, 16)
    love.graphics.setColor(0.7, 0.7, 0.85, 1)
    love.graphics.print(connection_status, 20, 34)

    love.graphics.setColor(1, 1, 1, 0.7)
    love.graphics.print("WASD: Move  |  Space: Fireball  |  E: Shield  |  DD: Dash  |  F3: Debug", 20, sh - 28)

    if rejection_timer > 0 then
        love.graphics.setColor(0.95, 0.25, 0.25, 0.95)
        love.graphics.printf(rejection_msg, 0, 80, sw, "center")
    end
end

function draw_debug(sw, sh)
    love.graphics.setColor(0, 0, 0, 0.75)
    love.graphics.rectangle("fill", sw - 240, 10, 230, 120, 6, 6)

    local ent_count = #loci.get_entities()
    local me = loci.get_my_entity()
    local tick_rate = loci.get_server_tick_rate and loci.get_server_tick_rate() or 30

    love.graphics.setColor(0.4, 1.0, 0.5, 1)
    love.graphics.print(string.format("FPS: %d", love.timer.getFPS()), sw - 225, 20)
    love.graphics.print(string.format("Sequence: %d", loci._sequence_id or 0), sw - 225, 40)
    love.graphics.print(string.format("Entities: %d", ent_count), sw - 225, 60)
    love.graphics.print(string.format("Tick Rate: %d Hz", tick_rate), sw - 225, 80)
    if me then
        love.graphics.print(string.format("Pos: (%.1f, %.1f)", me.x, me.y), sw - 225, 100)
    end
end

function love.focus(focused)
    -- Window focus change - network updates continue with backgroundupdates=true
end

function love.quit()
    print("[Client] Closing connection...")
    loci.disconnect("Client exiting")
end
