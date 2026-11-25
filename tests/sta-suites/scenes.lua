-- Building blocks for the test scenarios (part of the test harness, not the mod): flat ground, powered roboport
-- networks, turrets, and short descriptions of what a turret holds and asks for. Used by sta-suites' own suites and,
-- through require("__sta-suites__/scenes"), by sta-tests (qa2.lua, and qa.lua for its case 5).

local scenes = {}

-- The inventory a turret's ammo is in (gun/rocket/railgun turrets, artillery turrets and wagons).
local function ammo_inventory(t)
  if t.type == "artillery-turret" then return t.get_inventory(defines.inventory.artillery_turret_ammo) end
  if t.type == "artillery-wagon" then return t.get_inventory(defines.inventory.artillery_wagon_ammo) end
  return t.get_inventory(defines.inventory.turret_ammo)
end

function scenes.ammo_of(t)
  local inv = ammo_inventory(t)
  for i = 1, #inv do
    if inv[i].valid_for_read then return inv[i].name, inv[i].quality.name, inv[i].count end
  end
  return nil, nil, 0
end

-- "piercing-rounds-magazine/normal x20, wants firearm-magazine/normal x20" (or "gone").
function scenes.describe(t)
  if not (t and t.valid) then return "gone" end
  local n, q, c = scenes.ammo_of(t)
  local text = tostring(n) .. "/" .. tostring(q) .. " x" .. c
  local p = t.item_request_proxy
  if p then
    for _, r in pairs(p.item_requests) do
      text = text .. ", wants " .. r.name .. "/" .. (r.quality or "normal") .. " x" .. r.count
    end
  end
  return text
end

-- Does the turret have an open request for this item (any quality)?
function scenes.wants(t, name)
  local p = t and t.valid and t.item_request_proxy
  if not p then return false end
  for _, r in pairs(p.item_requests) do if r.name == name then return true end end
  return false
end

-- Concrete from (x1, y1) to (x2, y2), with everything on it removed (chunks generated first).
function scenes.ground(s, x1, y1, x2, y2)
  local cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
  s.request_to_generate_chunks({cx, cy}, math.ceil(math.max(x2 - x1, y2 - y1) / 64) + 1)
  s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities_filtered{area = {{x1, y1}, {x2, y2}}}) do
    if e.type ~= "character" then e.destroy() end
  end
  local tiles = {}
  for x = x1, x2 do for y = y1, y2 do table.insert(tiles, {name = "concrete", position = {x, y}}) end end
  s.set_tiles(tiles)
end

-- A powered roboport (with this many construction robots, 0 for none).
function scenes.roboport(s, f, x, y, robots)
  local eei = s.create_entity{name = "electric-energy-interface", position = {x - 6, y - 6}, force = f}
  eei.power_production = 1e9 / 60
  eei.electric_buffer_size = 1e10
  s.create_entity{name = "substation", position = {x - 3, y - 3}, force = f}
  local rp = s.create_entity{name = "roboport", position = {x, y}, force = f}
  if robots > 0 then rp.insert{name = "construction-robot", count = robots} end
  rp.energy = 1e8
  return rp
end

-- A chest next to (x, y) holding the given items ({{name=, count=, quality=}, ...}).
function scenes.chest(s, f, x, y, items, name)
  local chest = s.create_entity{name = name or "storage-chest", position = {x, y}, force = f}
  for _, it in pairs(items or {}) do chest.insert(it) end
  return chest
end

-- A small base like qa.lua's: ground 80 x 80 around (cx, cy), a roboport with robots, and a chest beside it.
-- opts.chest = "passive-provider-chest" etc. to use another chest; opts.robots defaults to 50.
function scenes.base(s, f, cx, cy, items, opts)
  opts = opts or {}
  scenes.ground(s, cx - 40, cy - 40, cx + 40, cy + 40)
  scenes.roboport(s, f, cx, cy, opts.robots or 50)
  return scenes.chest(s, f, cx + 3, cy - 3, items, opts.chest)
end

-- A long, thin network: roboports every 48 tiles from cx to cx + 48 * hops, the robots and the chest at the first
-- one. Something placed near the last roboport is about 48 * hops tiles from the ammo, so (with slow robots) a
-- request there stays open for a long time even though robots are flying it. Returns the chest and the x of the
-- last roboport.
function scenes.long_network(s, f, cx, cy, hops, robots, items)
  scenes.ground(s, cx - 10, cy - 10, cx + 48 * hops + 54, cy + 22) -- (to the edge of the last one's construction area)
  for i = 0, hops do scenes.roboport(s, f, cx + 48 * i, cy, i == 0 and robots or 0) end
  return scenes.chest(s, f, cx + 3, cy - 3, items), cx + 48 * hops
end

-- A force with no research at all (slow construction robots that carry one item per trip, as in the early game).
-- It is at peace with the player's force, and shares nothing with it.
function scenes.slow_force()
  local slow = game.forces["sta-qa-slow"] or game.create_force("sta-qa-slow")
  local player = game.forces.player
  slow.set_cease_fire(player, true)
  player.set_cease_fire(slow, true)
  slow.set_cease_fire("enemy", true)
  game.forces.enemy.set_cease_fire(slow, true)
  return slow
end

-- A turret (gun turret unless named), optionally loaded, that the mod is told about like a build would.
-- quiet = true: no build event (as when another mod's script places it).
function scenes.turret(s, f, x, y, load, name, quiet)
  local t = s.create_entity{name = name or "gun-turret", position = {x, y}, force = f}
  if load then t.insert(load) end
  if not quiet then script.raise_script_built{entity = t} end
  return t
end

return scenes
