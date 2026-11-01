-- Runs once while the game loads, after every mod has added its prototypes.
-- For every ammo item from every mod: add up how much damage it does (following projectiles, streams,
-- artillery shells, clusters and nested effects; area damage counts extra, weighted by its radius), and flag ammo that must never be loaded automatically
-- (nukes, anything that spawns units, huge blasts). The results go into a "mod-data" prototype, which
-- control.lua reads in the running game as prototypes.mod_data["smart-turret-ammo-scores"].data.

local DANGER_RADIUS = 10 -- an area effect bigger than this is a weapon of mass destruction, not turret ammo
local DANGER_ENTITY_TYPES = {
  ["unit"] = true, ["unit-spawner"] = true, ["spider-unit"] = true, ["segmented-unit"] = true,
  ["capture-robot"] = true, ["combat-robot"] = true, ["character"] = true, ["land-mine"] = true,
  ["turret"] = true, ["ammo-turret"] = true,
}

local function as_list(x)
  if x == nil then return {} end
  if x[1] ~= nil or next(x) == nil then return x end
  return {x}
end

-- Finds the prototype for an entity name in any entity category.
local entity_types
local function find_entity(name)
  if not entity_types then
    entity_types = {}
    for type_name in pairs(defines.prototypes.entity) do table.insert(entity_types, type_name) end
  end
  for _, t in pairs(entity_types) do
    local group = data.raw[t]
    if group and group[name] then return group[name], t end
  end
end

local walk_trigger -- defined below; the functions call each other

local function walk_effects(effects, result, depth)
  for _, eff in pairs(as_list(effects)) do
    local repeat_count = eff.repeat_count or 1
    if eff.type == "damage" and eff.damage then
      result.damage = result.damage + (eff.damage.amount or 0) * repeat_count
    elseif eff.type == "nested-result" then
      walk_trigger(eff.action, result, depth + 1)
    elseif eff.type == "create-entity" or eff.type == "create-explosion" then
      local name = eff.entity_name or ""
      if name:find("nuke") or name:find("atomic") then result.danger = "creates " .. name end
      local proto, proto_type = find_entity(name)
      if proto_type and DANGER_ENTITY_TYPES[proto_type] then result.danger = "spawns a " .. proto_type end
    end
  end
end

local function walk_delivery(delivery, result, depth, seen)
  for _, d in pairs(as_list(delivery)) do
    walk_effects(d.target_effects, result, depth)
    -- deliveries that fly a separate entity (projectile, artillery shell, stream, beam) carry its effects
    local entity_name = d.projectile or d.stream or d.beam
    if entity_name and not seen[entity_name] then
      seen[entity_name] = true
      local proto = find_entity(entity_name)
      if proto then
        walk_trigger(proto.action, result, depth + 1, seen)
        walk_trigger(proto.final_action, result, depth + 1, seen)
        walk_trigger(proto.initial_action, result, depth + 1, seen)
      end
    end
  end
end

walk_trigger = function(trigger, result, depth, seen)
  if depth > 12 then return end -- guards against prototypes that refer to each other in a loop
  seen = seen or {}
  for _, item in pairs(as_list(trigger)) do
    if item.type == "area" and (item.radius or 0) > DANGER_RADIUS then
      result.danger = "blast radius " .. item.radius
    end
    local before = result.damage
    walk_delivery(item.action_delivery, result, depth, seen)
    local repeats = (item.repeat_count or 1) * ((item.type == "cluster" and item.cluster_count) or 1)
    -- an area effect hits a group, not one enemy: weight it by its radius (a rough "how many targets")
    if item.type == "area" then repeats = repeats * math.max(1, item.radius or 1) end
    result.damage = before + (result.damage - before) * repeats
  end
end

local scores = {}
for name, ammo in pairs(data.raw["ammo"] or {}) do
  local result = {damage = 0, danger = nil}
  for _, ammo_type in pairs(as_list(ammo.ammo_type)) do
    walk_trigger(ammo_type.action, result, 0)
  end
  if name:find("atomic") or name:find("nuke") then result.danger = result.danger or "named like a nuke" end
  scores[name] = {
    score = result.damage,
    danger = result.danger,
    category = ammo.ammo_category,
  }
end

data:extend({{
  type = "mod-data",
  name = "smart-turret-ammo-scores",
  data = scores,
}})
