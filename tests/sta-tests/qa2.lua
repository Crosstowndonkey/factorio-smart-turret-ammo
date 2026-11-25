-- Scenarios from the second QA pass (2026-11-25, on release 0.1.1), part of the test harness, not the mod.
-- Each finding gets its own little base, far from the others (rows at y = -500 and y = -1000), so robot networks
-- never overlap. The finding ids (C1-C7, R1-R18) are the pass's: ~/.local/share/qa-runs/smart-turret-ammo-2026-11-25.
-- control.lua calls setup() once, on_tick() every tick and final_checks() at tick 6000. Turrets keep the default 20.
--
-- Findings that need a world of their own are in the other suites (tools/run_tests.sh):
--   baseonly (C1, no Space Age / Quality), settings (R11, R8), badpicks (R1), removed (R2).

local scenes = require("__sta-suites__/scenes")
local ammo_of, describe, wants = scenes.ammo_of, scenes.describe, scenes.wants

local qa2 = {}

local ROW, ROW2 = -500, -1000

function qa2.setup(f)
  local s = game.surfaces.nauvis
  local slow = scenes.slow_force()
  local Q = {}
  storage.qa2 = Q

  -- C3 / R18: a turret in reach of two networks. A has robots and yellow; B (a roboport whose robots haven't
  -- arrived yet, or a Repair Turret) has no construction robots but red in storage. The turret must get yellow from
  -- A, not wait forever for red that nobody can bring.
  scenes.ground(s, -40, ROW - 40, 100, ROW + 40)
  scenes.roboport(s, f, 0, ROW, 50)
  scenes.chest(s, f, 3, ROW - 3, {{name = "firearm-magazine", count = 200}})
  scenes.roboport(s, f, 60, ROW, 0)
  scenes.chest(s, f, 63, ROW - 3, {{name = "piercing-rounds-magazine", count = 100}})
  Q.two_nets = scenes.turret(s, f, 30, ROW + 15)

  -- R18: a turret reached only by a network with no construction robots: nothing can be delivered, so it must not
  -- ask (a request there is a permanent "missing construction robots" alert and keeps the red reserved).
  scenes.base(s, f, 400, ROW, {{name = "piercing-rounds-magazine", count = 100}}, {robots = 0})
  Q.no_robots = scenes.turret(s, f, 400, ROW + 15)

  -- R3: no storage chest, the uranium in a passive provider. A yellow turret asks to swap to uranium, but the robots
  -- can never take its yellow out (nowhere to put it). That swap must give up, and the empty turret next to it must
  -- get the uranium it was holding back. (A is built first, so it asks first.)
  scenes.base(s, f, 800, ROW, {{name = "uranium-rounds-magazine", count = 20}}, {chest = "passive-provider-chest"})
  Q.swap_stuck = scenes.turret(s, f, 800, ROW + 15, {name = "firearm-magazine", count = 30})
  Q.swap_starved = scenes.turret(s, f, 806, ROW + 15)

  -- R5: storage has 2 rare uranium (a trickle from quality assemblers) and 200 normal uranium. An empty turret must
  -- not be filled with the 2 rare magazines and left there, below its refill line, for good.
  scenes.base(s, f, 1200, ROW, {{name = "uranium-rounds-magazine", count = 2, quality = "rare"},
    {name = "uranium-rounds-magazine", count = 200}})
  Q.trickle = scenes.turret(s, f, 1200, ROW + 15)

  -- R6: a turret with 5 uncommon red (below the refill line of 8); no uncommon red left, 500 normal red in storage.
  -- It must be refilled (with normal red), not left at 5 until it is empty in the middle of a fight.
  scenes.base(s, f, 1600, ROW, {{name = "piercing-rounds-magazine", count = 500}})
  Q.low_run_out = scenes.turret(s, f, 1600, ROW + 15, {name = "piercing-rounds-magazine", count = 5, quality = "uncommon"})

  -- R7: three full yellow turrets, all picked to red, while only 5 red exist (more being made). None may throw out
  -- its 20 yellow for a handful of red.
  scenes.base(s, f, 2000, ROW, {{name = "piercing-rounds-magazine", count = 5}, {name = "firearm-magazine", count = 200}})
  Q.picked_wall = {}
  for i = 0, 2 do
    local t = scenes.turret(s, f, 1995 + i * 3, ROW + 15, {name = "firearm-magazine", count = 20})
    remote.call("smart-turret-ammo", "set_turret_ammo", t, "piercing-rounds-magazine", "normal")
    table.insert(Q.picked_wall, t)
  end
  -- (R7 guard, passes on 0.1.1 too: an EMPTY picked turret still takes whatever there is of its pick)
  scenes.base(s, f, 2400, ROW, {{name = "piercing-rounds-magazine", count = 5}, {name = "firearm-magazine", count = 200}})
  Q.picked_empty = scenes.turret(s, f, 2400, ROW + 15)
  remote.call("smart-turret-ammo", "set_turret_ammo", Q.picked_empty, "piercing-rounds-magazine", "normal")

  -- R9 (design check, the triage's default): quality multiplies damage (+30% a level, legendary 2.5x). Legendary
  -- yellow (5 x 2.5 = 12.5 a shot) beats normal red (8): it must not be swapped out for red.
  scenes.base(s, f, 2800, ROW, {{name = "piercing-rounds-magazine", count = 100}})
  Q.legendary_yellow = scenes.turret(s, f, 2800, ROW + 15, {name = "firearm-magazine", count = 20, quality = "legendary"})

  -- C2: artillery with normal shells and a Cerys-style "neutron" shell in storage (sta-fake-content: its projectile
  -- creates an explosion whose created_effect hides a radius-200 blast in source_effects). Only normal shells.
  scenes.base(s, f, 3200, ROW, {{name = "artillery-shell", count = 20}})
  scenes.chest(s, f, 3206, ROW - 3, {{name = "sta-neutron-shell", count = 20}})
  Q.neutron_chest_pos = {3206.5, ROW - 2.5}
  Q.artillery = scenes.turret(s, f, 3200, ROW + 15, nil, "artillery-turret")

  -- R16: a turret placed by another mod's script without a build event; the player then picks red for it (the
  -- panel and the remote call both go through the same pick). Picking must make the mod look after it.
  scenes.base(s, f, 3600, ROW, {{name = "piercing-rounds-magazine", count = 100}, {name = "firearm-magazine", count = 100}})
  Q.no_event = scenes.turret(s, f, 3600, ROW + 15, nil, nil, true)

  -- R17: a hidden, non-selectable ammo turret (another mod's internal part, sta-fake-content) must be left alone.
  scenes.base(s, f, 4000, ROW, {{name = "firearm-magazine", count = 100}})
  Q.hidden = scenes.turret(s, f, 4000, ROW + 15, nil, "sta-hidden-turret")

  -- R4: early game (no research: robots fly slowly and carry one magazine each). The only 20 red sit ~200 tiles from
  -- an empty turret at the end of a long network. The robots set off at once; the request must not be cancelled
  -- while they are on their way (0.1.1 did, at 20 s: the robots turned back and the turret waited 2-3 times longer).
  local _, last = scenes.long_network(s, slow, 0, ROW2, 4, 40, {{name = "piercing-rounds-magazine", count = 20}})
  Q.far = scenes.turret(s, slow, last + 8, ROW2 + 4)

  -- R10: a turret with an open request is moved by cloning (a spaceship or "move base" mod). Source: a long network
  -- on the slow force whose red is ~190 tiles away (so the request is still open at tick 600). Destination: a base
  -- with robots and only yellow. The clone arrives with a copy of the red request; it must be dealt with and the
  -- turret filled with yellow.
  local _, last10 = scenes.long_network(s, slow, 400, ROW2, 3, 50, {{name = "piercing-rounds-magazine", count = 200}})
  Q.clone_src = scenes.turret(s, slow, last10 + 46, ROW2 + 10)
  scenes.base(s, slow, 4400, ROW, {{name = "firearm-magazine", count = 200}}, {robots = 20})
  Q.clone_dst_pos = {4410, ROW + 10}
end

function qa2.on_tick(tick)
  local Q = storage.qa2
  if not Q then return end
  local s = game.surfaces.nauvis

  if tick == 60 then
    -- R16: the pick, a second after the turret appeared (as a player opening it would)
    remote.call("smart-turret-ammo", "set_turret_ammo", Q.no_event, "piercing-rounds-magazine", "normal")
  end

  -- R4: watch the first request. It ends either when the last magazine is delivered (the turret holds 20) or when
  -- the mod withdraws it (the turret holds less).
  if Q.far.valid then
    if not Q.far_proxy and Q.far.item_request_proxy then
      Q.far_proxy = Q.far.item_request_proxy
      Q.far_asked_at = tick
    elseif Q.far_proxy and not Q.far_ended_at and not Q.far_proxy.valid then
      local _, _, c = ammo_of(Q.far)
      Q.far_ended_at, Q.far_count_at_end = tick, c
    end
    if not Q.far_full_at then
      local _, _, c = ammo_of(Q.far)
      if c >= 20 then Q.far_full_at = tick end
    end
  end

  -- R10: move the turret (and, as the game does, its open request) to the yellow base
  if tick == 600 and Q.clone_src.valid then
    local p = Q.clone_src.position
    Q.clone_src_request = describe(Q.clone_src)
    s.clone_area{source_area = {{p.x - 2, p.y - 2}, {p.x + 2, p.y + 2}},
      destination_area = {{Q.clone_dst_pos[1] - 2, Q.clone_dst_pos[2] - 2}, {Q.clone_dst_pos[1] + 2, Q.clone_dst_pos[2] + 2}},
      clone_entities = true, clone_tiles = false}
    Q.clone_src.destroy()
    Q.clone = s.find_entities_filtered{name = "gun-turret", position = Q.clone_dst_pos, radius = 1}[1]
    Q.clone_request_copied = Q.clone ~= nil and Q.clone.item_request_proxy ~= nil
  end
end

function qa2.final_checks(check)
  local Q = storage.qa2
  local s = game.surfaces.nauvis
  local function info(name) return remote.call("smart-turret-ammo", "get_ammo_info", name) end
  local n, q, c

  -- C3 / R18
  n = ammo_of(Q.two_nets)
  check("C3: a turret in reach of a network without robots (holding red) and one with robots (yellow) gets yellow",
    n == "firearm-magazine" and Q.two_nets.item_request_proxy == nil, describe(Q.two_nets))
  check("R18: a turret reached only by a network without construction robots asks for nothing",
    Q.no_robots.item_request_proxy == nil, describe(Q.no_robots))

  -- R3
  n = ammo_of(Q.swap_starved)
  local a = ammo_of(Q.swap_stuck)
  check("R3: a swap the robots can't finish (nowhere to put the old ammo) gives up, and the empty turret gets the uranium",
    n == "uranium-rounds-magazine" and a == "firearm-magazine" and Q.swap_stuck.item_request_proxy == nil,
    "swapping turret: " .. describe(Q.swap_stuck) .. "; empty turret: " .. describe(Q.swap_starved))

  -- R5
  n, q, c = ammo_of(Q.trickle)
  check("R5: an empty turret is not left with 2 rare uranium when 200 normal uranium are in storage",
    n == "uranium-rounds-magazine" and c >= 20, describe(Q.trickle))

  -- R6
  n, q, c = ammo_of(Q.low_run_out)
  check("R6: a low turret whose ammo (uncommon red) has run out is refilled with normal red before it is empty",
    n == "piercing-rounds-magazine" and c >= 20, describe(Q.low_run_out))

  -- R7
  local kept, text = 0, {}
  for _, t in ipairs(Q.picked_wall) do
    n, q, c = ammo_of(t)
    if n == "firearm-magazine" and c == 20 then kept = kept + 1 end
    table.insert(text, describe(t))
  end
  check("R7: turrets picked to red keep their 20 yellow while only 5 red are free (no swap for a handful)",
    kept == 3, table.concat(text, "; "))
  n, q, c = ammo_of(Q.picked_empty)
  check("R7 guard: an empty turret picked to red takes the 5 red there are",
    n == "piercing-rounds-magazine" and c == 5, describe(Q.picked_empty))

  -- R9 (design)
  n, q, c = ammo_of(Q.legendary_yellow)
  check("R9 [design check]: legendary yellow (12.5 a shot) is not swapped out for normal red (8 a shot)",
    n == "firearm-magazine" and q == "legendary" and c == 20 and Q.legendary_yellow.item_request_proxy == nil,
    describe(Q.legendary_yellow))

  -- C2
  local neutron = info("sta-neutron-shell")
  check("C2: a shell whose explosion hides a radius-200 blast in created_effect / source_effects is flagged dangerous",
    neutron.danger ~= nil and not neutron.allowed,
    "score " .. tostring(neutron.score) .. ", danger " .. tostring(neutron.danger) .. ", allowed " .. tostring(neutron.allowed))
  local backblast = info("sta-backblast-round")
  check("C2: a round whose radius-40 blast is in its delivery's source_effects is flagged dangerous",
    backblast.danger ~= nil and not backblast.allowed,
    "score " .. tostring(backblast.score) .. ", danger " .. tostring(backblast.danger) .. ", allowed " .. tostring(backblast.allowed))
  n, q, c = ammo_of(Q.artillery)
  local nchest = s.find_entities_filtered{name = "storage-chest", position = Q.neutron_chest_pos, radius = 1}[1]
  local neutron_left = nchest and nchest.get_item_count("sta-neutron-shell") or -1
  check("C2: artillery with neutron shells in storage gets normal shells; no neutron shell leaves its chest",
    n == "artillery-shell" and neutron_left == 20, describe(Q.artillery) .. "; neutron shells in chest " .. neutron_left)

  -- C6 (hardening)
  local plague = info("se-plague-bomb")
  check("C6: se-plague-bomb (its effect is script-made, invisible to the prototype walk) is never automatic",
    not plague.allowed, "score " .. tostring(plague.score) .. ", danger " .. tostring(plague.danger) .. ", allowed " .. tostring(plague.allowed))

  -- R16 (hardening)
  n, q, c = ammo_of(Q.no_event)
  check("R16: a turret placed without a build event is looked after once ammo is picked for it",
    n == "piercing-rounds-magazine" and c == 20, describe(Q.no_event))

  -- R17 (hardening)
  check("R17: a hidden, non-selectable turret (another mod's part) gets no ammo and no request",
    (ammo_of(Q.hidden)) == nil and Q.hidden.item_request_proxy == nil, describe(Q.hidden))

  -- R4
  check("R4: a far turret's request for the last 20 red is not withdrawn while slow robots carry them",
    Q.far_asked_at ~= nil and (Q.far_ended_at == nil or Q.far_count_at_end >= 20),
    "asked at tick " .. tostring(Q.far_asked_at) .. "; first request ended at tick " .. tostring(Q.far_ended_at)
      .. " with " .. tostring(Q.far_count_at_end) .. " in the turret; now " .. describe(Q.far))
  check("R4: that far turret has its full load (20) within 100 s",
    Q.far_full_at ~= nil, "full at tick " .. tostring(Q.far_full_at) .. "; now " .. describe(Q.far))

  -- R10
  n = Q.clone and Q.clone.valid and ammo_of(Q.clone)
  check("R10: a turret cloned with an open request for red (none at the new place) is filled with yellow",
    Q.clone_request_copied and n == "firearm-magazine" and not wants(Q.clone, "piercing-rounds-magazine"),
    "before the move: " .. tostring(Q.clone_src_request) .. "; request copied: " .. tostring(Q.clone_request_copied)
      .. "; clone now: " .. describe(Q.clone))
end

return qa2
