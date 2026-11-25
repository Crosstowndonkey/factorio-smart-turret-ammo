-- Scenarios from the 0.1.1 QA pass (part of the test harness, not the mod). Each one gets its own little base,
-- 400 tiles from the others, so the robot networks never overlap. control.lua calls setup() once, on_tick()
-- every tick and final_checks() at tick 6000. (Turrets keep the default 20 ammo.)

local qa = {}
local scenes = require("__sta-suites__/scenes") -- (case 5's long network and slow robots)

local function ammo_of(t)
  local inv = t.get_inventory(defines.inventory.turret_ammo)
  for i = 1, #inv do
    if inv[i].valid_for_read then return inv[i].name, inv[i].quality.name, inv[i].count end
  end
  return nil, nil, 0
end

local function describe(t)
  if not (t and t.valid) then return "gone" end
  local n, q, c = ammo_of(t)
  local text = tostring(n) .. "/" .. tostring(q) .. " x" .. c
  local p = t.item_request_proxy
  if p then
    for _, r in pairs(p.item_requests) do text = text .. ", wants " .. r.name .. " x" .. r.count end
  end
  return text
end

local function wants(t, name)
  local p = t.valid and t.item_request_proxy
  if not p then return false end
  for _, r in pairs(p.item_requests) do if r.name == name then return true end end
  return false
end

-- A powered roboport with robots (or none) and a storage chest holding the given items.
local function base(s, f, cx, robots, items)
  local cy = 0
  s.request_to_generate_chunks({cx, cy}, 3)
  s.force_generate_chunk_requests()
  local tiles = {}
  for x = cx - 40, cx + 40 do for y = cy - 40, cy + 40 do table.insert(tiles, {name = "concrete", position = {x, y}}) end end
  s.set_tiles(tiles)
  for _, e in pairs(s.find_entities_filtered{area = {{cx - 40, cy - 40}, {cx + 40, cy + 40}}}) do e.destroy() end
  local eei = s.create_entity{name = "electric-energy-interface", position = {cx - 6, cy - 6}, force = f}
  eei.power_production = 1e9 / 60
  eei.electric_buffer_size = 1e10
  s.create_entity{name = "substation", position = {cx - 3, cy - 3}, force = f}
  local rp = s.create_entity{name = "roboport", position = {cx, cy}, force = f}
  if robots > 0 then rp.insert{name = "construction-robot", count = robots} end
  rp.energy = 1e8
  local chest = s.create_entity{name = "storage-chest", position = {cx + 3, cy - 3}, force = f}
  for _, it in pairs(items) do chest.insert(it) end
  return chest
end

local function turret(s, f, x, y, load)
  local t = s.create_entity{name = "gun-turret", position = {x, y}, force = f}
  if load then t.insert(load) end
  script.raise_script_built{entity = t}
  return t
end

function qa.setup(f)
  local s = game.surfaces.nauvis
  f.create_ghost_on_entity_death = true
  local Q = {}
  storage.qa = Q

  -- 1. ten empty turrets, 30 red and plenty of yellow: nobody may wait forever for red
  base(s, f, 400, 50, {{name = "piercing-rounds-magazine", count = 30}, {name = "firearm-magazine", count = 500}})
  Q.scarce = {}
  for i = 0, 9 do table.insert(Q.scarce, turret(s, f, 390 + i * 3, 15)) end

  -- 2. three yellow turrets, one load (20) of uranium: only one swaps, the others keep their yellow
  base(s, f, 800, 50, {{name = "uranium-rounds-magazine", count = 20}, {name = "firearm-magazine", count = 200}})
  Q.one_load = {}
  for i = 0, 2 do table.insert(Q.one_load, turret(s, f, 795 + i * 3, 15, {name = "firearm-magazine", count = 30})) end

  -- 3. a swap whose uranium is taken away before the robots get it: the request is cancelled, yellow goes back in
  Q.stuck_chest = base(s, f, 1200, 50, {{name = "uranium-rounds-magazine", count = 50}, {name = "firearm-magazine", count = 200}})
  Q.stuck = turret(s, f, 1200, 15, {name = "firearm-magazine", count = 30})

  -- 4. a player with a personal roboport and no roboport near: the player's own ammo is never handed out
  s.request_to_generate_chunks({1600, 0}, 2)
  s.force_generate_chunk_requests()
  local ch = s.create_entity{name = "character", position = {1600, 0}, force = f}
  ch.get_inventory(defines.inventory.character_armor).insert{name = "power-armor-mk2"}
  ch.grid.put{name = "fission-reactor-equipment"}
  ch.grid.put{name = "personal-roboport-mk2-equipment"}
  ch.grid.put{name = "battery-mk2-equipment"}
  local inv = ch.get_main_inventory()
  inv.insert{name = "construction-robot", count = 20}
  inv.insert{name = "piercing-rounds-magazine", count = 100}
  inv.insert{name = "uranium-rounds-magazine", count = 60}
  Q.character = ch
  Q.personal = {}
  for i = 0, 2 do
    table.insert(Q.personal, turret(s, f, 1595 + i * 3, 6, i == 0 and {name = "piercing-rounds-magazine", count = 20} or nil))
  end

  -- 5. requests that stay open for a while: a turret marked for deconstruction asks for nothing; a turret whose
  -- pick changes from red to yellow gets its request changed at once. (Until the 2026-11-25 pass this used a network
  -- with no robots to keep requests open; the mod now ignores such networks (C3), so instead the robots are slow -
  -- a force with no research - and the ammo is ~150 tiles from the turrets, ~40 s of flying. Both are looked at at
  -- tick 900, long before any robot arrives, also the one coming to deconstruct the marked turret.)
  local slow = scenes.slow_force()
  local _, last = scenes.long_network(s, slow, 2000, 0, 3, 50,
    {{name = "piercing-rounds-magazine", count = 200}, {name = "firearm-magazine", count = 200}})
  Q.marked = turret(s, slow, last + 6, 15)
  Q.marked.order_deconstruction(slow)
  Q.unmarked = turret(s, slow, last + 12, 15)
  Q.repick = turret(s, slow, last + 18, 15)
  remote.call("smart-turret-ammo", "set_turret_ammo", Q.repick, "piercing-rounds-magazine", "normal")

  -- 6. a turret in a long fight (yellow ammo barely scratches a behemoth): no swap to uranium until it's over
  base(s, f, 2400, 50, {{name = "uranium-rounds-magazine", count = 100}})
  Q.fighter = turret(s, f, 2400, 15, {name = "firearm-magazine", count = 200})
  Q.fighter.destructible = false
  Q.biter = s.create_entity{name = "behemoth-biter", position = {2400, 24}, force = "enemy"}
  Q.biter.disabled_by_script = true -- stays in range (peaceful mode would make it run off)

  -- 7. a turret locked to red, upgraded to uncommon by robots: the new turret keeps the pick
  -- 8. a turret locked to red, destroyed and rebuilt from its ghost: the new turret keeps the pick
  base(s, f, 2800, 50, {{name = "piercing-rounds-magazine", count = 200}})
  local chest = s.find_entities_filtered{name = "storage-chest", position = {2803.5, -2.5}, radius = 1}[1]
  chest.insert{name = "gun-turret", count = 1, quality = "uncommon"}
  chest.insert{name = "gun-turret", count = 1}
  Q.upgrade_pos = {2800, 15}
  Q.upgraded = turret(s, f, 2800, 15)
  remote.call("smart-turret-ammo", "set_turret_ammo", Q.upgraded, "piercing-rounds-magazine", "normal")
  Q.upgraded.order_upgrade{target = {name = "gun-turret", quality = "uncommon"}, force = f}
  Q.died_pos = {2806, 15}
  Q.died = turret(s, f, 2806, 15)
  remote.call("smart-turret-ammo", "set_turret_ammo", Q.died, "piercing-rounds-magazine", "normal")
end

function qa.on_tick(tick)
  local Q = storage.qa
  if not Q then return end
  -- 3: the moment the swap request appears, the uranium is used up elsewhere
  if not Q.stuck_taken and Q.stuck.valid and Q.stuck.item_request_proxy then
    Q.stuck_chest.remove_item{name = "uranium-rounds-magazine", count = 50}
    Q.stuck_taken = tick
  end
  if tick == 300 then
    Q.repick_first = describe(Q.repick)
    Q.repick_wanted_red = wants(Q.repick, "piercing-rounds-magazine")
    remote.call("smart-turret-ammo", "set_turret_ammo", Q.repick, "firearm-magazine", "normal")
    Q.died.die("enemy")
  end
  if tick == 900 then -- 5: robots are still on their way (see setup)
    Q.marked_ok = Q.marked.valid and Q.marked.item_request_proxy == nil
    Q.unmarked_asks = Q.unmarked.item_request_proxy ~= nil
    Q.marked_text = "marked: " .. describe(Q.marked) .. "; unmarked: " .. describe(Q.unmarked)
    Q.repick_wants_yellow = wants(Q.repick, "firearm-magazine") and not wants(Q.repick, "piercing-rounds-magazine")
    Q.repick_after = describe(Q.repick)
  end
  if tick == 480 and Q.biter.valid then -- (researched damage kills the behemoth at about tick 650)
    Q.fighter_had_target = Q.fighter.shooting_target ~= nil
    Q.fighter_mid_fight = describe(Q.fighter)
    Q.fighter_kept_yellow = (ammo_of(Q.fighter)) == "firearm-magazine" and not wants(Q.fighter, "uranium-rounds-magazine")
    Q.biter.destroy()
  end
end

function qa.final_checks(check)
  local Q = storage.qa
  local s = game.surfaces.nauvis

  local empty, waiting, red, text = 0, 0, 0, {}
  for _, t in ipairs(Q.scarce) do
    local n = ammo_of(t)
    if not n then empty = empty + 1 end
    if t.item_request_proxy then waiting = waiting + 1 end
    if n == "piercing-rounds-magazine" then red = red + 1 end
    table.insert(text, describe(t))
  end
  check("scarce red ammo: no turret is left empty or waiting, the rest take yellow",
    empty == 0 and waiting == 0 and red >= 1, table.concat(text, "; "))

  local uranium, emptied = 0, 0
  text = {}
  for _, t in ipairs(Q.one_load) do
    local n = ammo_of(t)
    if n == "uranium-rounds-magazine" then uranium = uranium + 1 end
    if not n then emptied = emptied + 1 end
    table.insert(text, describe(t))
  end
  check("one load of uranium: one turret swaps, the other two keep their yellow",
    uranium == 1 and emptied == 0, table.concat(text, "; "))

  local n = ammo_of(Q.stuck)
  check("a swap whose ammo vanished is cancelled and the turret refilled with yellow",
    Q.stuck_taken ~= nil and n == "firearm-magazine" and Q.stuck.item_request_proxy == nil,
    "uranium taken at tick " .. tostring(Q.stuck_taken) .. "; now " .. describe(Q.stuck))

  local inv = Q.character.get_main_inventory()
  local red_left, uranium_left = inv.get_item_count("piercing-rounds-magazine"), inv.get_item_count("uranium-rounds-magazine")
  local asked = false
  for _, t in ipairs(Q.personal) do if t.item_request_proxy then asked = true end end
  check("a personal roboport's ammo is never handed out (setting off)",
    red_left == 100 and uranium_left == 60 and not asked and (ammo_of(Q.personal[1])) == "piercing-rounds-magazine",
    "player has red " .. red_left .. ", uranium " .. uranium_left .. "; turrets: " .. describe(Q.personal[1]) .. "; "
      .. describe(Q.personal[2]) .. "; " .. describe(Q.personal[3]))

  check("a turret marked for deconstruction asks for nothing (an unmarked one does)",
    Q.marked_ok and Q.unmarked_asks, "at tick 900: " .. tostring(Q.marked_text))

  check("changing a turret's pick changes its open request at once",
    Q.repick_wanted_red and Q.repick_wants_yellow,
    "before (tick 300): " .. tostring(Q.repick_first) .. "; after (tick 900): " .. tostring(Q.repick_after))

  check("a shooting turret keeps its ammo until the fight is over, then swaps to uranium",
    Q.fighter_had_target and Q.fighter_kept_yellow and (ammo_of(Q.fighter)) == "uranium-rounds-magazine",
    "had a target: " .. tostring(Q.fighter_had_target) .. "; mid-fight: " .. tostring(Q.fighter_mid_fight)
      .. "; after: " .. describe(Q.fighter))

  local up = s.find_entities_filtered{name = "gun-turret", position = Q.upgrade_pos, radius = 0.5}[1]
  local up_choice = up and remote.call("smart-turret-ammo", "get_turret_ammo", up)
  check("a quality upgrade keeps the turret's picked ammo",
    up and up.quality.name == "uncommon" and up_choice and up_choice.name == "piercing-rounds-magazine",
    up and (up.quality.name .. " turret, pick " .. tostring(up_choice and up_choice.name) .. ", " .. describe(up)) or "no turret")

  local rebuilt = s.find_entities_filtered{name = "gun-turret", position = Q.died_pos, radius = 0.5}[1]
  local rb_choice = rebuilt and remote.call("smart-turret-ammo", "get_turret_ammo", rebuilt)
  check("a destroyed turret rebuilt from its ghost keeps its picked ammo",
    rebuilt and rb_choice and rb_choice.name == "piercing-rounds-magazine",
    rebuilt and ("pick " .. tostring(rb_choice and rb_choice.name) .. ", " .. describe(rebuilt)) or "not rebuilt")
end

return qa
