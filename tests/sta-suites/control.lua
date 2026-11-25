-- Test suites that need a world of their own (part of the test harness, not the mod). tools/run_tests.sh copies
-- this mod into its throwaway folder and writes suite.lua to say which suite this run is:
--   main      nothing here (sta-tests runs; it only borrows scenes.lua)
--   baseonly  C1: the base game alone - no Space Age, no Quality mod (the "normal" quality is then hidden)
--   settings  R11, R8: "use ammo from other mods" off (settings-updates.lua), and a picked ammo blocked by script
--   badpicks  R1: picks with a quality the game doesn't have (0.1.1 crashes on these, which would end any suite)
--   removed   R2: phase 1 (--create) picks an ammo from sta-removed-ammo; phase 2 loads the save without that mod
--   upgrade, upgrade010  a save made mid-action by release 0.1.1 / 0.1.0 (on a headless server), loaded with the
--             current code: no errors, picks kept, everything filled within 90 s, reservations sane (see below)
-- Each suite prints "STA PASS/FAIL <check> (<detail>)" lines and, at its last tick, "STA DONE failures=N".
-- Finding ids are the QA pass's of 2026-11-25 (~/.local/share/qa-runs/smart-turret-ammo-2026-11-25).

local suite = require("suite")
local scenes = require("scenes")
local ammo_of, describe = scenes.ammo_of, scenes.describe

local function check(name, ok, detail)
  print(string.format("STA %s %s (%s)", ok and "PASS" or "FAIL", name, detail))
  if not ok then storage.failed = (storage.failed or 0) + 1 end
end
local function pick_of(t)
  return t and t.valid and remote.call("smart-turret-ammo", "get_turret_ammo", t) or nil
end
local function pick_text(t)
  local c = pick_of(t)
  return c and (c.name .. "/" .. tostring(c.quality)) or "none"
end

local function quiet_world()
  game.forces.player.research_all_technologies()
  game.map_settings.enemy_expansion.enabled = false
  local s = game.surfaces.nauvis
  s.peaceful_mode = true
  s.always_day = true
  for _, e in pairs(s.find_entities_filtered{force = "enemy"}) do e.destroy() end
  return s, game.forces.player
end

-- A ghost of a gun turret as a blueprint would leave it (tags and all), and a turret item for robots to build it.
local function ghost(s, f, x, y, tags, chest)
  chest.insert{name = "gun-turret", count = 1}
  return s.create_entity{name = "entity-ghost", inner_name = "gun-turret", position = {x, y}, force = f, tags = tags}
end
local function built_at(s, x, y)
  return s.find_entities_filtered{name = "gun-turret", position = {x, y}, radius = 0.5}[1]
end

local suites = {}

-- C1 -------------------------------------------------------------------------------------------------------------
suites.baseonly = {done = 1800}
function suites.baseonly.setup()
  local s, f = quiet_world()
  local T = {}
  storage.T = T
  local chest = scenes.base(s, f, 200, 0, {{name = "firearm-magazine", count = 200}, {name = "piercing-rounds-magazine", count = 200}})
  for i = 0, 1 do scenes.chest(s, f, 209 + i, -3, {{name = "artillery-shell", count = 30}}) end
  T.empty = scenes.turret(s, f, 195, 15)
  T.yellow = scenes.turret(s, f, 201, 15, {name = "firearm-magazine", count = 20})
  T.artillery = scenes.turret(s, f, 210, 15, nil, "artillery-turret")
  -- a blueprint made in a Space Age game: its turret was picked to uncommon red, a quality this game doesn't have
  ghost(s, f, 216, 15, {sta_ammo = {name = "piercing-rounds-magazine", quality = "uncommon"}}, chest)
  local names = {}
  for name, q in pairs(prototypes.quality) do table.insert(names, name .. (q.hidden and " (hidden)" or "")) end
  print("STA fact: qualities in this game: " .. table.concat(names, ", "))
end
function suites.baseonly.final()
  local T, s = storage.T, game.surfaces.nauvis
  check("baseonly: the game runs without Space Age and without the Quality mod",
    script.active_mods["space-age"] == nil and script.active_mods["quality"] == nil, serpent.line(script.active_mods))
  local n, _, c = ammo_of(T.empty)
  check("C1: without the Quality mod an empty gun turret gets the best ammo (red), a full load",
    n == "piercing-rounds-magazine" and c == 20, describe(T.empty))
  n, _, c = ammo_of(T.yellow)
  check("C1: without the Quality mod yellow ammo is swapped for red", n == "piercing-rounds-magazine" and c == 20, describe(T.yellow))
  n, _, c = ammo_of(T.artillery)
  check("C1: without the Quality mod an artillery turret gets shells", n == "artillery-shell" and c == 15, describe(T.artillery))
  local bp = built_at(s, 216, 15)
  n, _, c = nil, nil, 0
  if bp then n, _, c = ammo_of(bp) end
  check("C1 / R1: a blueprint turret picked to 'uncommon' red (a quality this game lacks) is built and gets red",
    bp ~= nil and n == "piercing-rounds-magazine" and c == 20,
    bp and (describe(bp) .. ", pick " .. pick_text(bp)) or "not built")
end

-- R11, R8 --------------------------------------------------------------------------------------------------------
local VANILLA_MODS = {base = true, ["space-age"] = true, quality = true, ["elevated-rails"] = true}
suites.settings = {done = 1800}
function suites.settings.setup()
  local s, f = quiet_world()
  local T = {}
  storage.T = T
  -- R11: a cannon turret (sta-fake-content) and the base game's cannon shells
  scenes.base(s, f, 200, 0, {{name = "cannon-shell", count = 100}, {name = "explosive-cannon-shell", count = 100}})
  T.cannon = scenes.turret(s, f, 200, 15, nil, "sta-cannon-turret")
  -- R8: a turret picked to red; then red is blocked (set_ammo_score(name, false) uses the same check as the
  -- "Never use these ammo items" setting, which a script can't change). Red and yellow in storage.
  scenes.base(s, f, 600, 0, {{name = "piercing-rounds-magazine", count = 200}, {name = "firearm-magazine", count = 200}})
  T.blocked_pick = scenes.turret(s, f, 600, 15)
  remote.call("smart-turret-ammo", "set_turret_ammo", T.blocked_pick, "piercing-rounds-magazine", "normal")
  T.pick_made = pick_text(T.blocked_pick)
  remote.call("smart-turret-ammo", "set_ammo_score", "piercing-rounds-magazine", false)
end
function suites.settings.final()
  local T = storage.T
  check("settings: 'Use ammo from other mods' is off in this suite", settings.global["sta-use-modded-ammo"].value == false,
    tostring(settings.global["sta-use-modded-ammo"].value))
  -- every ammo item the base game / Space Age / Quality / Elevated rails create must still be usable (unless dangerous)
  local bad, seen = {}, 0
  for name in pairs(prototypes.get_item_filtered{{filter = "type", type = "ammo"}}) do
    local ok_h, h = pcall(prototypes.get_history, "ammo", name)
    if ok_h and h and VANILLA_MODS[h.created] and name ~= "piercing-rounds-magazine" then -- (red: blocked for R8 below)
      seen = seen + 1
      local i = remote.call("smart-turret-ammo", "get_ammo_info", name)
      if not (i.allowed or i.danger) then table.insert(bad, name) end
    end
  end
  table.sort(bad)
  check("R11: with modded ammo off, every vanilla ammo item (by the mod that made it) is still allowed unless dangerous",
    #bad == 0 and seen > 0, seen .. " vanilla ammo items; not allowed: " .. (#bad > 0 and table.concat(bad, ", ") or "none"))
  local laser = remote.call("smart-turret-ammo", "get_ammo_info", "sta-laser-round")
  check("R11 guard: with modded ammo off, a modded ammo (sta-laser-round) is not allowed", not laser.allowed,
    "allowed " .. tostring(laser.allowed))
  local n, _, c = ammo_of(T.cannon)
  check("R11: with modded ammo off, a cannon turret gets the base game's cannon shells",
    (n == "cannon-shell" or n == "explosive-cannon-shell") and c == 20, describe(T.cannon))
  n, _, c = ammo_of(T.blocked_pick)
  check("R8: a turret picked to red gets no red once red is blocked (it falls back to automatic: yellow)",
    n == "firearm-magazine" and c == 20, describe(T.blocked_pick) .. "; pick made: " .. T.pick_made)
  check("R8: the blocked pick is kept, so it comes back when unblocked", pick_text(T.blocked_pick) == "piercing-rounds-magazine/normal",
    "pick now: " .. pick_text(T.blocked_pick))
end

-- R1 -------------------------------------------------------------------------------------------------------------
suites.badpicks = {done = 1800}
function suites.badpicks.setup()
  local s, f = quiet_world()
  local T = {}
  storage.T = T
  local chest = scenes.base(s, f, 200, 0, {{name = "piercing-rounds-magazine", count = 200}, {name = "firearm-magazine", count = 200}})
  -- a remote call (another mod) picking red with a quality that doesn't exist
  T.remote = scenes.turret(s, f, 195, 15)
  remote.call("smart-turret-ammo", "set_turret_ammo", T.remote, "piercing-rounds-magazine", "mythic")
  -- a blueprint from a game with an extra quality mod ("mythic"), and one whose tag isn't a table at all
  ghost(s, f, 201, 15, {sta_ammo = {name = "piercing-rounds-magazine", quality = "mythic"}}, chest)
  ghost(s, f, 207, 15, {sta_ammo = 5}, chest)
end
function suites.badpicks.final()
  local T, s = storage.T, game.surfaces.nauvis
  local n, q, c = ammo_of(T.remote)
  check("R1: picking red with an unknown quality ('mythic') by remote call doesn't crash; the turret gets normal red",
    n == "piercing-rounds-magazine" and q == "normal" and c == 20, describe(T.remote) .. ", pick " .. pick_text(T.remote))
  local bp = built_at(s, 201, 15)
  n, q, c = nil, nil, 0
  if bp then n, q, c = ammo_of(bp) end
  check("R1: a blueprint turret picked to 'mythic' red is built and gets normal red",
    bp ~= nil and n == "piercing-rounds-magazine" and q == "normal" and c == 20,
    bp and (describe(bp) .. ", pick " .. pick_text(bp)) or "not built")
  local junk = built_at(s, 207, 15)
  n, q, c = nil, nil, 0
  if junk then n, q, c = ammo_of(junk) end
  check("R1: a blueprint turret whose ammo tag isn't a table is built, stays automatic and gets ammo",
    junk ~= nil and pick_of(junk) == nil and n ~= nil and c == 20,
    junk and (describe(junk) .. ", pick " .. pick_text(junk)) or "not built")
end

-- R2 -------------------------------------------------------------------------------------------------------------
suites.removed = {done = 600}
function suites.removed.setup()
  local s, f = quiet_world()
  local T = {}
  storage.T = T
  T.phase1_had_round = prototypes.item["sta-removed-round"] ~= nil
  local items = {{name = "firearm-magazine", count = 200}}
  if T.phase1_had_round then table.insert(items, {name = "sta-removed-round", count = 100}) end
  scenes.base(s, f, 200, 0, items)
  T.turret = scenes.turret(s, f, 200, 15, T.phase1_had_round and {name = "sta-removed-round", count = 20} or nil)
  if T.phase1_had_round then
    remote.call("smart-turret-ammo", "set_turret_ammo", T.turret, "sta-removed-round", "normal")
  end
  T.phase1_pick = pick_text(T.turret)
end
function suites.removed.final()
  local T = storage.T
  check("removed: phase 1 picked the modded ammo, and phase 2 runs without its mod",
    T.phase1_had_round and T.phase1_pick == "sta-removed-round/normal" and prototypes.item["sta-removed-round"] == nil,
    "phase 1 pick " .. tostring(T.phase1_pick) .. "; ammo still there: " .. tostring(prototypes.item["sta-removed-round"] ~= nil))
  check("R2: a save whose turret was picked to ammo from a removed mod loads and runs; the pick is dropped",
    pick_of(T.turret) == nil, "pick now: " .. pick_text(T.turret))
  local n, _, c = ammo_of(T.turret)
  check("R2: that turret goes back to automatic and gets yellow", n == "firearm-magazine" and c == 20, describe(T.turret))
end

-- Upgrade: a save made by an old release in the middle of the action, loaded with the current code -------------
-- Phase 1 runs on the OLD Smart Turret Ammo (0.1.1 or 0.1.0, from git) on a headless server: setup() builds the
-- scene; at SAVE_TICK the state is noted and the server saves (game.server_save, so the save is always made at the
-- same tick). Phase 2 loads that save with the current code (on_configuration_changed: a new version): at +60 s
-- probe turrets are placed, at +90 s everything is checked. Most bases are on the no-research force (slow robots
-- carrying one magazine each, 30 tiles from storage), so at the save robots are in the air, swaps are half done
-- (old ammo taken out, new not yet in) and scarce-ammo requests are open - and all of it can still finish in 90 s.
local SAVE_TICK = 900
local function upgrade_suite(from)
  local U = {upgrade = true, from = from}
  function U.setup()
    local s, f = quiet_world()
    local slow = scenes.slow_force()
    local T = {turrets = {}}
    storage.T = T
    local function add(key, t) T[key] = t table.insert(T.turrets, t) return t end
    -- scarce red: six empty turrets, 30 red and plenty of yellow
    scenes.base(s, slow, 200, 0, {{name = "piercing-rounds-magazine", count = 30}, {name = "firearm-magazine", count = 600}}, {robots = 100})
    for i = 0, 5 do add("scarce" .. i, scenes.turret(s, slow, 190 + i * 4, 27)) end
    -- swaps: three yellow turrets, 80 uranium (old ammo goes back to the chest first, then the uranium comes)
    T.uranium_chest = scenes.base(s, slow, 600, 0, {{name = "uranium-rounds-magazine", count = 80}}, {robots = 100})
    for i = 0, 2 do add("swap" .. i, scenes.turret(s, slow, 596 + i * 4, 27, {name = "firearm-magazine", count = 30})) end
    -- picks: an empty turret picked to red, and a yellow one picked to UNCOMMON red (a quality pick, a swap)
    scenes.base(s, slow, 1000, 0, {{name = "piercing-rounds-magazine", count = 100},
      {name = "piercing-rounds-magazine", count = 100, quality = "uncommon"}, {name = "firearm-magazine", count = 100}}, {robots = 60})
    add("pick_red", scenes.turret(s, slow, 996, 27))
    remote.call("smart-turret-ammo", "set_turret_ammo", T.pick_red, "piercing-rounds-magazine", "normal")
    add("pick_uncommon", scenes.turret(s, slow, 1002, 27, {name = "firearm-magazine", count = 20}))
    remote.call("smart-turret-ammo", "set_turret_ammo", T.pick_uncommon, "piercing-rounds-magazine", "uncommon")
    -- far: one empty turret ~150 tiles from its red (robots still flying at the save)
    local _, last = scenes.long_network(s, slow, 1400, 0, 3, 60, {{name = "piercing-rounds-magazine", count = 60}})
    add("far", scenes.turret(s, slow, last + 8, 4))
    -- a space platform: the hub throws red / yellow to two turrets
    local pl = f.create_space_platform{name = "Upgrade", planet = "nauvis", starter_pack = "space-platform-starter-pack"}
    local hub = pl.apply_starter_pack()
    local tiles = {}
    for x = -12, 12 do for y = -12, 12 do table.insert(tiles, {name = "space-platform-foundation", position = {x, y}}) end end
    pl.surface.set_tiles(tiles)
    hub.insert{name = "piercing-rounds-magazine", count = 200} -- (enough for 0.1.0's keep of 50 too)
    hub.insert{name = "firearm-magazine", count = 100}
    T.hub = hub
    for _, x in pairs({8, -8}) do add("platform" .. x, scenes.turret(pl.surface, f, x, 8)) end
    T.made_with = script.active_mods["smart-turret-ammo"]
  end
  function U.at_save()
    local T = storage.T
    local open, empty_waiting, half_swaps = 0, 0, 0
    for _, t in ipairs(T.turrets) do
      if t.valid and t.item_request_proxy then
        open = open + 1
        if (ammo_of(t)) == nil then empty_waiting = empty_waiting + 1 end
      end
    end
    for i = 0, 2 do
      local t = T["swap" .. i]
      if t.valid and (ammo_of(t)) == nil and scenes.wants(t, "uranium-rounds-magazine") then half_swaps = half_swaps + 1 end
    end
    T.save_state = {tick = game.tick, open = open, empty_waiting = empty_waiting, half_swaps = half_swaps,
      flying = #game.surfaces.nauvis.find_entities_filtered{type = "construction-robot"}}
    print("STA fact: saved at tick " .. game.tick .. " by Smart Turret Ammo " .. tostring(T.made_with) .. ": "
      .. serpent.line(T.save_state))
    game.server_save("sta-midaction")
  end
  function U.probes()
    local T, s = storage.T, game.surfaces.nauvis
    -- by now every request should be done: whatever ammo is left must really be free, not held by a reservation
    -- the update got wrong (one from the old save counted twice, or never let go)
    T.uranium_left = T.uranium_chest.logistic_network.get_item_count("uranium-rounds-magazine")
    T.probe_uranium = scenes.turret(s, T.pick_red.force, 608, 27)
    T.hub_red_left = T.hub.get_inventory(defines.inventory.hub_main).get_item_count("piercing-rounds-magazine")
    T.probe_platform = scenes.turret(T.hub.surface, T.hub.force, 0, -8)
  end
  function U.final()
    local T = storage.T
    local st = T.save_state or {}
    print("STA fact: 'Ammo to keep' in the loaded save: " .. settings.global["sta-keep"].value)
    check("upgrade: the save was made mid-action by the old version",
      T.made_with == U.from and (st.open or 0) >= 3 and (st.flying or 0) > 0 and (st.empty_waiting or 0) >= 1,
      "made with " .. tostring(T.made_with) .. ", at the save: " .. serpent.line(st))
    check("upgrade: the save was loaded with the current version (a mod update)",
      storage.upgraded_from == U.from and script.active_mods["smart-turret-ammo"] ~= U.from,
      tostring(storage.upgraded_from) .. " -> " .. tostring(script.active_mods["smart-turret-ammo"]))
    check("upgrade: both picks survive the update (red, and uncommon red)",
      pick_text(T.pick_red) == "piercing-rounds-magazine/normal" and pick_text(T.pick_uncommon) == "piercing-rounds-magazine/uncommon",
      pick_text(T.pick_red) .. "; " .. pick_text(T.pick_uncommon))
    local n1, q1 = ammo_of(T.pick_red)
    local n2, q2 = ammo_of(T.pick_uncommon)
    check("upgrade: the picked turrets hold their pick 90 s after loading",
      n1 == "piercing-rounds-magazine" and q1 == "normal" and n2 == "piercing-rounds-magazine" and q2 == "uncommon",
      describe(T.pick_red) .. "; " .. describe(T.pick_uncommon))
    local bad, text = 0, {}
    for _, t in ipairs(T.turrets) do
      if not (t.valid and (ammo_of(t)) ~= nil and t.item_request_proxy == nil) then
        bad = bad + 1
        table.insert(text, (t.valid and (t.position.x .. "," .. t.position.y .. " ") or "") .. describe(t))
      end
    end
    check("upgrade: within 90 s of loading every turret has ammo and none is left with an open request",
      bad == 0, bad == 0 and (#T.turrets .. " turrets fine") or table.concat(text, "; "))
    local n, _, c = ammo_of(T.probe_uranium)
    check("upgrade: reservations are sane - a new turret gets the uranium still free in storage",
      (T.uranium_left or 0) > 0 and n == "uranium-rounds-magazine" and c == math.min(T.uranium_left, settings.global["sta-keep"].value),
      "uranium free at +60 s: " .. tostring(T.uranium_left) .. "; new turret: " .. describe(T.probe_uranium))
    n, _, c = ammo_of(T.probe_platform)
    check("upgrade: reservations are sane on the platform too - a new turret gets red from the hub",
      (T.hub_red_left or 0) > 0 and n == "piercing-rounds-magazine" and c == math.min(T.hub_red_left, settings.global["sta-keep"].value),
      "red in the hub at +60 s: " .. tostring(T.hub_red_left) .. "; new turret: " .. describe(T.probe_platform))
  end
  return U
end
suites.upgrade = upgrade_suite("0.1.1")
suites.upgrade010 = upgrade_suite("0.1.0")

-- Wiring ---------------------------------------------------------------------------------------------------------
local S = suites[suite]
if S and S.upgrade then
  script.on_init(function() S.setup() end)
  script.on_configuration_changed(function(data)
    local c = data.mod_changes and data.mod_changes["smart-turret-ammo"]
    if c and c.old_version and storage.T then
      storage.loaded_at = game.tick
      storage.upgraded_from = c.old_version
    end
  end)
  script.on_event(defines.events.on_tick, function(e)
    if not storage.loaded_at then
      if e.tick == SAVE_TICK then S.at_save() end
      return
    end
    local dt = e.tick - storage.loaded_at
    if dt == 3600 then S.probes() end
    if dt == 5400 then
      S.final()
      print("STA DONE failures=" .. (storage.failed or 0))
    end
  end)
elseif S then
  script.on_init(function() S.setup() end)
  script.on_event(defines.events.on_tick, function(e)
    if e.tick ~= S.done then return end
    S.final()
    print("STA DONE failures=" .. (storage.failed or 0))
  end)
end
