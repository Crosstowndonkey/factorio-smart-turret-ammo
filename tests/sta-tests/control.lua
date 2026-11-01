-- Test harness for Smart Turret Ammo (not part of the mod). Builds a small base on Nauvis and a space
-- platform, lets the game run, then checks every turret and prints PASS / FAIL lines.

local function ammo_of(t)
  local inv = t.get_inventory(defines.inventory.turret_ammo)
  for i = 1, #inv do
    if inv[i].valid_for_read then return inv[i].name, inv[i].quality.name, inv[i].count end
  end
  return nil, nil, 0
end

local function build_ground(f)
  local s = game.surfaces.nauvis
  s.always_day = true
  local area = {{-40, -40}, {40, 40}}
  for _, e in pairs(s.find_entities_filtered{area = area}) do if e.type ~= "character" then e.destroy() end end
  local tiles = {}
  for x = -40, 40 do for y = -40, 40 do table.insert(tiles, {name = "concrete", position = {x, y}}) end end
  s.set_tiles(tiles)
  local eei = s.create_entity{name = "electric-energy-interface", position = {-6, -6}, force = f}
  eei.power_production = 1e9 / 60
  eei.electric_buffer_size = 1e10
  s.create_entity{name = "substation", position = {-3, -3}, force = f}
  s.create_entity{name = "substation", position = {12, 12}, force = f}
  local rp = s.create_entity{name = "roboport", position = {0, 0}, force = f}
  rp.insert{name = "construction-robot", count = 150}
  rp.energy = 1e8
  local chest = s.create_entity{name = "storage-chest", position = {3, -3}, force = f}
  chest.insert{name = "firearm-magazine", count = 200}
  chest.insert{name = "piercing-rounds-magazine", count = 200}
  chest.insert{name = "uranium-rounds-magazine", count = 300, quality = "rare"}
  chest.insert{name = "rocket", count = 100}
  chest.insert{name = "explosive-rocket", count = 100}
  chest.insert{name = "atomic-bomb", count = 10}
  chest.insert{name = "railgun-ammo", count = 50}
  -- shells stack one per slot, so they get their own chests
  for i = 0, 1 do
    s.create_entity{name = "storage-chest", position = {5 + i, -3}, force = f}.insert{name = "artillery-shell", count = 40}
  end
  -- the fake "other mod's" ammo
  chest.insert{name = "sta-weak-laser", count = 200}
  chest.insert{name = "sta-laser-round", count = 100}
  chest.insert{name = "sta-mega-nuke", count = 10}
  chest.insert{name = "sta-spawner-round", count = 10}

  local T = {}
  local function place(key, name, pos) T[key] = s.create_entity{name = name, position = pos, force = f} end
  place("empty_gun", "gun-turret", {8, 8})
  place("yellow_gun", "gun-turret", {12, 8});      T.yellow_gun.insert{name = "firearm-magazine", count = 10}
  place("low_gun", "gun-turret", {16, 8});         T.low_gun.insert{name = "uranium-rounds-magazine", count = 5, quality = "rare"}
  place("rocket", "rocket-turret", {-8, 8})
  place("railgun", "railgun-turret", {8, -12})
  place("nuke_rocket", "rocket-turret", {-12, 8}); T.nuke_rocket.insert{name = "atomic-bomb", count = 1}
  -- a turret fed by an inserter (from an empty chest): the mod must leave it alone
  place("inserter_gun", "gun-turret", {8, 16})
  s.create_entity{name = "wooden-chest", position = {8.5, 18.5}, force = f}
  local ins
  for _, dir in pairs({defines.direction.north, defines.direction.south}) do
    ins = s.create_entity{name = "inserter", position = {8.5, 17.5}, direction = dir, force = f}
    local b, p = T.inserter_gun.bounding_box, ins.drop_position
    if p.x > b.left_top.x and p.x < b.right_bottom.x and p.y > b.left_top.y and p.y < b.right_bottom.y then break end
    ins.destroy()
    ins = nil
  end
  print("STA setup: inserter drops into the turret: " .. tostring(ins ~= nil))
  place("laser", "sta-laser-turret", {-8, -12})
  place("artillery", "artillery-turret", {-16, -8})
  -- an artillery wagon standing on a straight piece of track
  for y = -24, 24, 2 do s.create_entity{name = "straight-rail", position = {21, y}, force = f} end
  T.wagon = s.create_entity{name = "artillery-wagon", position = {21, 0}, force = f}
  print("STA setup: artillery wagon placed: " .. tostring(T.wagon ~= nil))
  return T
end

local function build_platform(f)
  local pl = f.create_space_platform{name = "Test", planet = "nauvis", starter_pack = "space-platform-starter-pack"}
  local hub = pl.apply_starter_pack()
  local s = pl.surface
  local tiles = {}
  for x = -12, 12 do for y = -12, 12 do table.insert(tiles, {name = "space-platform-foundation", position = {x, y}}) end end
  s.set_tiles(tiles)
  hub.insert{name = "firearm-magazine", count = 100}
  hub.insert{name = "piercing-rounds-magazine", count = 100}
  hub.insert{name = "rocket", count = 100}
  hub.insert{name = "railgun-ammo", count = 30}
  local T = {}
  T.p_gun = s.create_entity{name = "gun-turret", position = {8, 8}, force = f}
  T.p_rocket = s.create_entity{name = "rocket-turret", position = {-8, 8}, force = f}
  T.p_railgun = s.create_entity{name = "railgun-turret", position = {8, -8}, force = f}
  return T
end

script.on_init(function()
  local f = game.forces.player
  f.research_all_technologies()
  -- no biters: a test turret must never fire (the hand-loaded nuke especially)
  game.map_settings.enemy_expansion.enabled = false
  game.surfaces.nauvis.peaceful_mode = true
  for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{force = "enemy"}) do e.destroy() end
  storage.T = build_ground(f)
  for k, v in pairs(build_platform(f)) do storage.T[k] = v end
  -- the mod was initialised before these turrets existed: tell it about them like a build would
  for _, t in pairs(storage.T) do script.raise_script_built{entity = t} end

  -- picking the ammo for one turret
  local s, T = game.surfaces.nauvis, storage.T
  T.locked_gun = s.create_entity{name = "gun-turret", position = {16, 12}, force = f}
  T.locked_gun.insert{name = "uranium-rounds-magazine", count = 20, quality = "rare"}
  script.raise_script_built{entity = T.locked_gun}
  remote.call("smart-turret-ammo", "set_turret_ammo", T.locked_gun, "piercing-rounds-magazine", "normal")
  -- a turret built from a blueprint whose tag says "yellow ammo"
  local ghost = s.create_entity{name = "entity-ghost", inner_name = "gun-turret", position = {16, 16}, force = f,
    tags = {sta_ammo = {name = "firearm-magazine", quality = "normal"}}}
  storage.bp_ghost_pos = {16, 16}
  -- (construction robots build it from the chest, like a real blueprint)
  game.surfaces.nauvis.find_entities_filtered{name = "storage-chest", position = {3.5, -2.5}, radius = 1}[1].insert{name = "gun-turret", count = 1}
  -- locking a rocket turret to the atomic bomb must be refused
  T.nuke_lock = s.create_entity{name = "rocket-turret", position = {-12, 13}, force = f}
  script.raise_script_built{entity = T.nuke_lock}
  remote.call("smart-turret-ammo", "set_turret_ammo", T.nuke_lock, "atomic-bomb", "normal")
end)

local function check(name, ok, detail)
  print(string.format("STA %s %s (%s)", ok and "PASS" or "FAIL", name, detail))
  if not ok then storage.failed = (storage.failed or 0) + 1 end
end

script.on_event(defines.events.on_tick, function(e)
  if e.tick ~= 6000 then return end
  local T = storage.T
  local function d(t) local n, q, c = ammo_of(t) return tostring(n) .. "/" .. tostring(q) .. " x" .. c end
  local n, q, c

  n, q, c = ammo_of(T.empty_gun)
  check("empty gun turret gets the best ammo (rare uranium), a full load", n == "uranium-rounds-magazine" and q == "rare" and c == 50, d(T.empty_gun))
  n, q, c = ammo_of(T.yellow_gun)
  check("yellow ammo is swapped for rare uranium", n == "uranium-rounds-magazine" and q == "rare" and c == 50, d(T.yellow_gun))
  n, q, c = ammo_of(T.low_gun)
  check("low turret (5) is topped up to 50", n == "uranium-rounds-magazine" and q == "rare" and c == 50, d(T.low_gun))
  n, q, c = ammo_of(T.rocket)
  check("rocket turret gets explosive rockets, never the atomic bomb", n == "explosive-rocket", d(T.rocket))
  n, q, c = ammo_of(T.railgun)
  local keep = math.min(50, prototypes.item["railgun-ammo"].stack_size)
  check("railgun gets railgun ammo, capped at a stack (" .. keep .. ")", n == "railgun-ammo" and c == keep, d(T.railgun))
  n, q, c = ammo_of(T.nuke_rocket)
  check("a hand-loaded atomic bomb is left alone", n == "atomic-bomb" and c == 1, d(T.nuke_rocket))
  n, q, c = ammo_of(T.inserter_gun)
  check("inserter-fed turret is skipped", n == nil and T.inserter_gun.item_request_proxy == nil, d(T.inserter_gun))

  n, q, c = ammo_of(T.p_gun)
  check("platform gun turret gets red ammo from the hub", n == "piercing-rounds-magazine" and c == 50, d(T.p_gun))
  n, q, c = ammo_of(T.p_rocket)
  check("platform rocket turret gets rockets from the hub", n == "rocket" and c == 50, d(T.p_rocket))
  n, q, c = ammo_of(T.p_railgun)
  check("platform railgun gets railgun ammo from the hub", n == "railgun-ammo" and c == keep, d(T.p_railgun))

  n, q, c = ammo_of(T.laser)
  check("modded turret gets the modded ammo with the most damage", n == "sta-laser-round" and c == 50, d(T.laser))
  n, q, c = ammo_of(T.artillery)
  local art_keep = math.min(50, T.artillery.prototype.ammo_stack_limit)
  check("artillery turret gets shells (" .. art_keep .. ", its slot limit)", n == "artillery-shell" and c == art_keep, d(T.artillery))
  if T.wagon then
    n, q, c = ammo_of(T.wagon)
    check("artillery wagon (standing still) gets shells", n == "artillery-shell" and c == 50, d(T.wagon))
  else
    check("artillery wagon could be placed for the test", false, "no wagon")
  end
  local chest = game.surfaces.nauvis.find_entities_filtered{name = "storage-chest", position = {3.5, -2.5}, radius = 1}[1]
  check("the mega nuke and the biter-spawning round never left the chest",
    chest.get_item_count("sta-mega-nuke") == 10 and chest.get_item_count("sta-spawner-round") == 10,
    chest.get_item_count("sta-mega-nuke") .. " / " .. chest.get_item_count("sta-spawner-round"))

  -- the damage scores and danger flags worked out while loading
  local function info(name) return remote.call("smart-turret-ammo", "get_ammo_info", name) end
  local y, r, u = info("firearm-magazine"), info("piercing-rounds-magazine"), info("uranium-rounds-magazine")
  check("scores: yellow < red < uranium", y.score < r.score and r.score < u.score, y.score .. " < " .. r.score .. " < " .. u.score)
  local ro, ex = info("rocket"), info("explosive-rocket")
  check("scores: rocket < explosive rocket", ro.score < ex.score, ro.score .. " < " .. ex.score)
  for _, name in pairs({"atomic-bomb", "capture-robot-rocket", "sta-mega-nuke", "sta-spawner-round"}) do
    local i = info(name)
    check(name .. " is flagged dangerous and never allowed", i.danger ~= nil and not i.allowed, tostring(i.danger))
  end
  for _, name in pairs({"artillery-shell", "railgun-ammo", "sta-laser-round", "sta-weak-laser"}) do
    local i = info(name)
    check(name .. " is allowed", i.allowed and i.danger == nil, "score " .. tostring(i.score) .. ", danger " .. tostring(i.danger))
  end

  n, q, c = ammo_of(T.locked_gun)
  check("a turret locked to red ammo gets red, even with uranium around", n == "piercing-rounds-magazine" and q == "normal" and c == 50, d(T.locked_gun))
  T.bp_gun = game.surfaces.nauvis.find_entities_filtered{name = "gun-turret", position = storage.bp_ghost_pos, radius = 0.5}[1]
  if not T.bp_gun then
    local ghosts = game.surfaces.nauvis.find_entities_filtered{name = "entity-ghost"}
    local chest = game.surfaces.nauvis.find_entities_filtered{name = "storage-chest", position = {3.5, -2.5}, radius = 1}[1]
    local info = {}
    for _, g in pairs(ghosts) do table.insert(info, g.ghost_name .. "@" .. g.position.x .. "," .. g.position.y) end
    check("the blueprint ghost was built by robots", false, "ghosts: " .. table.concat(info, " ") .. "; turrets in chest: " .. chest.get_item_count("gun-turret"))
  end
  n, q, c = nil, nil, 0
  if T.bp_gun then n, q, c = ammo_of(T.bp_gun) end
  check("a turret built from a blueprint tagged 'yellow' gets yellow", n == "firearm-magazine" and c == 50, T.bp_gun and d(T.bp_gun) or "-")
  check("locking a rocket turret to the atomic bomb is refused", remote.call("smart-turret-ammo", "get_turret_ammo", T.nuke_lock) == nil,
    "loaded: " .. d(T.nuke_lock))

  local chest_nukes = game.surfaces.nauvis.find_entities_filtered{name = "storage-chest", position = {3.5, -2.5}, radius = 1}[1].get_item_count("atomic-bomb")
  check("no atomic bombs left the storage chest", chest_nukes == 10, "chest has " .. chest_nukes)
  local yellow_back = game.surfaces.nauvis.find_entities_filtered{name = "storage-chest", position = {3.5, -2.5}, radius = 1}[1].get_item_count("firearm-magazine")
  check("the swapped-out yellow ammo went back to storage (210, minus 50 for the blueprint turret)", yellow_back == 160, "chest has " .. yellow_back)
  print("STA DONE failures=" .. (storage.failed or 0))
end)
