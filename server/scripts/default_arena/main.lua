-- Loci Arena - Authoritative Game Logic (Lua Server Script)
-- This script runs inside the loci2d server environment.
-- Rules, physics modifications, damage and game mechanics must be handled here.

-- Arena bounds (deve corresponder ao cliente: -500 a +500)
local ARENA_MIN = -500
local ARENA_MAX = 500

-- Arena personalizada com fireball e dash
local fireballs = {}
local current_tick = 0

-- Configurações da fireball
local FIREBALL_SPEED = 4.0  -- Aumentado para se afastar mais rápido
local FIREBALL_LIFETIME = 120  -- ticks (~4 segundos)
local FIREBALL_DAMAGE = 10
local FIREBALL_RADIUS = 2
local FIREBALL_SPAWN_OFFSET = 50.0  -- Aumentado para evitar colisão com dono ao andar
local HIT_RADIUS = 5.0

-- Configurações de movimento
local PLAYER_SPEED = 5.0

-- Configurações de dash
local DASH_DISTANCE = 25.0
local DASH_COOLDOWN = 30
local dash_cooldowns = {}

-- Configurações de escudo
local SHIELD_DURATION = 180  -- ticks (~6 segundos)
local SHIELD_REDUCTION = 0.5  -- 50% de redução de dano
local shield_active_list = {}  -- lista de {entity_id, end_tick}

-- Configurações de slow
local SLOW_FACTOR = 0.5  -- 50% da velocidade normal
local SLOW_DURATION = 30  -- ticks (~1 segundo)
local slow_active_list = {}  -- lista de {entity_id, end_tick}

-- Rastrear última direção de movimento
local last_move_directions = {}

-- Função para verificar se é jogador
local function is_player(entity_id)
    local kind = Loci.get_entity_property(entity_id, "kind")
    return kind == "player"
end

-- Função para aplicar slow
local function apply_slow(entity_id)
    slow_active_list[#slow_active_list + 1] = {
        entity_id = entity_id,
        end_tick = current_tick + SLOW_DURATION
    }
    Loci.Commands.set_property(entity_id, "status_slow", "true")
end

-- Função para aplicar dano
local function apply_damage(entity_id, damage)
    -- Verificar escudo
    local shield_active = false
    for _, shield in ipairs(shield_active_list) do
        if shield.entity_id == entity_id and current_tick < shield.end_tick then
            shield_active = true
            break
        end
    end
    
    if shield_active then
        damage = damage * SHIELD_REDUCTION
    end
    
    local current_hp = Loci.get_entity_property(entity_id, "hp") or 100
    local new_hp = current_hp - damage
    Loci.Commands.set_property(entity_id, "hp", tostring(new_hp))
    
    -- Aplicar slow quando recebe dano
    apply_slow(entity_id)
    
    if new_hp <= 0 then
        Loci.Commands.destroy_entity(entity_id)
    end
end

function on_player_join(entity_id)
    Loci.Log.info("[Arena] Player joined with entity ID " .. tostring(entity_id))

    Loci.Commands.set_property(entity_id, "team", "1")
    Loci.Commands.set_property(entity_id, "hp", "100")
    Loci.Commands.set_property(entity_id, "max_hp", "100")
    Loci.Commands.set_property(entity_id, "score", "0")
    Loci.Commands.set_property(entity_id, "kind", "player")
end

function on_move_intent(entity_id, dir_x, dir_y)
    -- Rastrear direção
    if dir_x ~= 0 or dir_y ~= 0 then
        last_move_directions[entity_id] = {x = dir_x, y = dir_y}
    end
    
    -- Normalizar movimento
    local len = math.sqrt(dir_x * dir_x + dir_y * dir_y)
    if len > 0 then
        dir_x = dir_x / len
        dir_y = dir_y / len
    end
    
    -- Verificar se está em slow
    local speed = PLAYER_SPEED
    for _, slow in ipairs(slow_active_list) do
        if slow.entity_id == entity_id and current_tick < slow.end_tick then
            speed = PLAYER_SPEED * SLOW_FACTOR
            break
        end
    end
    
    Loci.Commands.set_velocity(entity_id, {
        x = dir_x * speed,
        y = dir_y * speed
    })
    return true
end

function on_action(entity_id, ability_id, dir_x, dir_y)
    Loci.Log.info("[Arena] Action from entity " .. tostring(entity_id) .. " -> Ability: " .. tostring(ability_id))

    if ability_id == 1 then
        -- Fireball
        local pos = Loci.get_entity_position(entity_id)
        if pos then
            local px, py = pos:x_float(), pos:y_float()

            -- Pegar direção (última movimento ou padrão)
            local last_dir = last_move_directions[entity_id]
            local fb_dir_x, fb_dir_y = 1, 0
            if last_dir then
                fb_dir_x = last_dir.x
                fb_dir_y = last_dir.y
            end

            -- Normalizar direção
            local len = math.sqrt(fb_dir_x * fb_dir_x + fb_dir_y * fb_dir_y)
            if len > 0.01 then
                fb_dir_x = fb_dir_x / len
                fb_dir_y = fb_dir_y / len
            end

            -- Verificar se spawn está dentro dos limites
            local spawn_x = px + fb_dir_x * FIREBALL_SPAWN_OFFSET
            local spawn_y = py + fb_dir_y * FIREBALL_SPAWN_OFFSET

            if spawn_x < ARENA_MIN or spawn_x > ARENA_MAX or spawn_y < ARENA_MIN or spawn_y > ARENA_MAX then
                -- Spawn fora dos limites, não criar fireball
                return false, "Fireball spawn out of bounds"
            end

            local fireball_id = Loci.Commands.spawn_entity({
                position = {x = spawn_x, y = spawn_y},
                blueprint = "fireball",
                entity_type = "Prop",
                move_speed = FIREBALL_SPEED,
                radius = FIREBALL_RADIUS,
                properties = {
                    owner = tostring(entity_id),
                    kind = "fireball"
                }
            })

            if fireball_id then
                -- Tornar fireball intangível ao dono (API set_intangible)
                if Loci.set_intangible then
                    Loci.set_intangible(fireball_id, true)
                end

                Loci.Commands.set_velocity(fireball_id, {x = fb_dir_x * FIREBALL_SPEED, y = fb_dir_y * FIREBALL_SPEED})
                fireballs[#fireballs + 1] = {
                    id = fireball_id,
                    owner = entity_id,  -- Armazenar como número para comparação correta
                    expires_at = current_tick + FIREBALL_LIFETIME,
                    spawn_pos = {x = spawn_x, y = spawn_y},  -- Guardar posição inicial
                    direction = {x = fb_dir_x, y = fb_dir_y},  -- Guardar direção
                    spawn_tick = current_tick  -- Guardar tick de spawn
                }
            end
        end
    elseif ability_id == 2 then
        -- Dash
        local cooldown_end = dash_cooldowns[entity_id] or 0
        if current_tick < cooldown_end then
            return false, "Dash em cooldown"
        end
        
        -- Usar última direção de movimento
        local last_dir = last_move_directions[entity_id]
        local dash_dir_x, dash_dir_y = 1, 0
        if last_dir then
            dash_dir_x = last_dir.x
            dash_dir_y = last_dir.y
        end
        
        local len_sq = dash_dir_x * dash_dir_x + dash_dir_y * dash_dir_y
        if len_sq > 0.01 then
            local pos = Loci.get_entity_position(entity_id)
            if pos then
                local px, py = pos:x_float(), pos:y_float()
                
                -- Usar raycast para verificar se o caminho está livre
                local hit = Loci.Physics.raycast(
                    {x = px, y = py},
                    {x = dash_dir_x, y = dash_dir_y},
                    DASH_DISTANCE
                )
                
                local new_x = px + dash_dir_x * DASH_DISTANCE
                local new_y = py + dash_dir_y * DASH_DISTANCE
                
                -- Se houver colisão, reduzir a distância
                if hit then
                    local hit_x = hit.x or new_x
                    local hit_y = hit.y or new_y
                    local dist_to_hit = math.sqrt((hit_x - px)^2 + (hit_y - py)^2)
                    if dist_to_hit < DASH_DISTANCE then
                        new_x = px + dash_dir_x * (dist_to_hit - 1)
                        new_y = py + dash_dir_y * (dist_to_hit - 1)
                    end
                end
                
                Loci.Commands.set_position(entity_id, {x = new_x, y = new_y})
                dash_cooldowns[entity_id] = current_tick + DASH_COOLDOWN
                return true
            end
        end
        return false, "Direção inválida para dash"
    elseif ability_id == 4 then
        -- Escudo
        shield_active_list[#shield_active_list + 1] = {
            entity_id = entity_id,
            end_tick = current_tick + SHIELD_DURATION
        }
        Loci.Commands.set_property(entity_id, "shield_active", "true")
    end
    
    return true
end

function on_collision(entity_a_id, entity_b_id)
    local kind_a = Loci.get_entity_property(entity_a_id, "kind")
    local kind_b = Loci.get_entity_property(entity_b_id, "kind")

    -- Fireball A colidiu com algo
    if kind_a == "fireball" then
        local owner_a = Loci.get_entity_property(entity_a_id, "owner")

        -- Se colidiu com jogador
        if kind_b == "player" then
            -- Se for o dono, ignorar completamente
            if entity_b_id == tonumber(owner_a) then
                return
            end
            -- Se for inimigo, aplicar dano e destruir
            apply_damage(entity_b_id, FIREBALL_DAMAGE)
            Loci.Commands.destroy_entity(entity_a_id)
        -- Se colidiu com outra fireball de dono diferente, destruir ambas
        elseif kind_b == "fireball" then
            local owner_b = Loci.get_entity_property(entity_b_id, "owner")
            if owner_a ~= owner_b then
                Loci.Commands.destroy_entity(entity_a_id)
                Loci.Commands.destroy_entity(entity_b_id)
            end
        -- Se colidiu com qualquer outra coisa (parede/obstáculo), destruir
        else
            Loci.Commands.destroy_entity(entity_a_id)
        end
    end

    -- Fireball B colidiu com algo (caso reverso)
    if kind_b == "fireball" then
        local owner_b = Loci.get_entity_property(entity_b_id, "owner")

        -- Se colidiu com jogador
        if kind_a == "player" then
            -- Se for o dono, ignorar completamente
            if entity_a_id == tonumber(owner_b) then
                return
            end
            -- Se for inimigo, aplicar dano e destruir
            apply_damage(entity_a_id, FIREBALL_DAMAGE)
            Loci.Commands.destroy_entity(entity_b_id)
        -- Se colidiu com qualquer outra coisa (parede/obstáculo), destruir
        else
            Loci.Commands.destroy_entity(entity_b_id)
        end
    end

    -- Player-player collision - não fazer nada (motor de física trata)
end

function on_tick(tick)
    current_tick = tick

    -- Gerenciar escudo ativo
    local active_shields = {}
    for _, shield in ipairs(shield_active_list) do
        if tick >= shield.end_tick then
            Loci.Commands.set_property(shield.entity_id, "shield_active", "false")
        else
            active_shields[#active_shields + 1] = shield
        end
    end
    shield_active_list = active_shields

    -- Gerenciar slow ativo
    local active_slow = {}
    for _, slow in ipairs(slow_active_list) do
        if tick >= slow.end_tick then
            -- Slow terminou, restaurar velocidade normal
            Loci.Commands.set_property(slow.entity_id, "status_slow", "false")
        else
            active_slow[#active_slow + 1] = slow
        end
    end
    slow_active_list = active_slow

    if #fireballs == 0 then
        return
    end

    local alive = {}
    local destroyed = {}

    for _, fb in ipairs(fireballs) do
        local keep = true

        if tick >= fb.expires_at then
            if not destroyed[fb.id] then
                Loci.Commands.destroy_entity(fb.id)
                destroyed[fb.id] = true
            end
            keep = false
        else
            -- Calcular posição manualmente baseada no spawn e direção
            local elapsed_ticks = tick - (fb.expires_at - FIREBALL_LIFETIME)
            local distance_traveled = elapsed_ticks * FIREBALL_SPEED
            local px = fb.spawn_pos.x + fb.direction.x * distance_traveled
            local py = fb.spawn_pos.y + fb.direction.y * distance_traveled

            -- Verificar colisão com paredes da arena
            if px < ARENA_MIN or px > ARENA_MAX or py < ARENA_MIN or py > ARENA_MAX then
                if not destroyed[fb.id] then
                    Loci.Commands.destroy_entity(fb.id)
                    destroyed[fb.id] = true
                end
                keep = false
            else
                -- Verificar se ainda está no período de grace com o dono (primeiros 20 ticks)
                local grace_period = fb.spawn_tick and (tick - fb.spawn_tick) < 20

                -- Tentar obter posição real da entidade também para colisão
                local real_pos = Loci.get_entity_position(fb.id)
                local check_x, check_y = px, py

                if real_pos then
                    -- Usar posição real se disponível, caso contrário posição calculada
                    check_x = real_pos:x_float()
                    check_y = real_pos:y_float()
                end

                -- Verificar colisão com entidades
                local near = Loci.get_entities_in_radius({x = check_x, y = check_y}, HIT_RADIUS)
                for _, id in ipairs(near) do
                    if keep and id ~= fb.id and not destroyed[id] then
                        local entity_kind = Loci.get_entity_property(id, "kind")
                        if is_player(id) then
                            -- Colidiu com jogador
                            if id == fb.owner and grace_period then
                                -- Colidiu com dono durante grace period - ignorar
                            else
                                -- Colidiu com inimigo ou grace period acabou - aplicar dano
                                apply_damage(id, FIREBALL_DAMAGE)
                            end
                        elseif entity_kind == "fireball" then
                            -- Colidiu com outra fireball - verificar dono
                            local other_owner = Loci.get_entity_property(id, "owner")
                            if fb.owner ~= tonumber(other_owner) then
                                -- Donos diferentes - destruir ambas
                                if fb.id < id and not destroyed[fb.id] then
                                    Loci.Commands.destroy_entity(fb.id)
                                    destroyed[fb.id] = true
                                    keep = false
                                end
                            end
                            -- Se for do mesmo dono, não fazer nada (passam uma pela outra)
                        end
                    end
                end
            end
        end

        if keep then
            alive[#alive + 1] = fb
        end
    end
    fireballs = alive
end

function on_player_leave(entity_id)
    Loci.Log.info("[Arena] Player left: " .. tostring(entity_id))
    Loci.Commands.destroy_entity(entity_id)
end
