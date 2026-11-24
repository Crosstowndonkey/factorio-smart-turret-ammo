-- Smart Turret Ammo
-- Keeps ammo turrets (gun, rocket, railgun, modded) and artillery (turrets and wagons) stocked with the
-- best ammo in reach.
--
-- How it works: every turret is checked in rotation. If it is empty, low, or holds worse ammo than the
-- network has, the mod creates an "item request" for it - the same thing a blueprint makes when it asks
-- for modules. On planets, construction robots fulfil it from the logistic network; on space platforms,
-- the hub throws the items across. Swapped-out ammo goes back to storage the same way.
--
-- The mod keeps track of its own open requests: what they are still waiting for is "reserved", so twenty
-- turrets don't all ask for the same thirty magazines. A request that stops moving while its ammo is gone
-- is cancelled, so the turret can be filled with whatever there is instead.
--
-- Which ammo is "best" comes from data-final-fixes.lua: while the game loads it adds up every ammo's
-- damage (any mod's) and flags dangerous ammo (nukes, unit spawners, huge blasts), which is never used.

-- The base game and Space Age's own ammo, for the "only vanilla ammo" setting.
local VANILLA_AMMO = {
  ["firearm-magazine"] = true, ["piercing-rounds-magazine"] = true, ["uranium-rounds-magazine"] = true,
  ["rocket"] = true, ["explosive-rocket"] = true, ["atomic-bomb"] = true, ["capture-robot-rocket"] = true,
  ["railgun-ammo"] = true, ["artillery-shell"] = true,
}

-- Entity types the mod looks after, and the inventory their ammo goes into.
local AMMO_INVENTORY = {
  ["ammo-turret"] = defines.inventory.turret_ammo,
  ["artillery-turret"] = defines.inventory.artillery_turret_ammo,
  ["artillery-wagon"] = defines.inventory.artillery_wagon_ammo,
}
local TURRET_TYPES = {"ammo-turret", "artillery-turret", "artillery-wagon"}

local CHECK_INTERVAL = 60 -- each turret is checked at most once per this many ticks
local INSERTER_CACHE_TICKS = 600 -- how long "is this turret fed by an inserter?" is remembered
local STALE_TICKS = 1200 -- an open request with no delivery for this long, and no ammo left for it, is cancelled

-- Settings, read once and refreshed when the player changes them.
local cfg = {}
local function read_settings()
  local s = settings.global
  cfg.keep = s["sta-keep"].value
  cfg.refill_fraction = s["sta-refill-percent"].value / 100
  cfg.upgrade = s["sta-upgrade"].value
  cfg.pause_while_shooting = s["sta-pause-while-shooting"].value
  cfg.skip_inserter_fed = s["sta-skip-inserter-fed"].value
  cfg.per_tick = s["sta-turrets-per-tick"].value
  cfg.use_modded = s["sta-use-modded-ammo"].value
  cfg.use_personal = s["sta-use-personal-roboports"].value
  cfg.blocked = {}
  for name in string.gmatch(s["sta-blocked-ammo"].value, "[^%s,;]+") do cfg.blocked[name] = true end
end

---------------------------------------------------------------------------------------------------------
-- Ammo ranking
---------------------------------------------------------------------------------------------------------

local score_data
local function load_scores()
  if not score_data then
    local md = prototypes.mod_data["smart-turret-ammo-scores"]
    score_data = md and md.data or {}
  end
  return score_data
end

-- How good this ammo is (a damage number), or nil if the mod must not use it.
local function ammo_score(name)
  if cfg.blocked[name] then return nil end
  local override = storage.overrides and storage.overrides[name]
  if override == false then return nil end
  if type(override) == "number" then return override end
  local info = load_scores()[name]
  if not info or info.danger then return nil end
  if not cfg.use_modded and not VANILLA_AMMO[name] then return nil end
  return info.score
end

-- Quality levels, best first (hidden ones like "quality-unknown" left out).
local quality_cache
local function qualities()
  if not quality_cache then
    quality_cache = {}
    for name, q in pairs(prototypes.quality) do
      if not q.hidden then table.insert(quality_cache, {name = name, level = q.level}) end
    end
    table.sort(quality_cache, function(a, b) return a.level > b.level end)
  end
  return quality_cache
end

-- Is ammo a better than ammo b? Damage first, then quality.
local function better(a_score, a_level, b_score, b_level)
  if a_score ~= b_score then return a_score > b_score end
  return a_level > b_level
end

-- The ammo categories a turret (or artillery) can fire.
local function ammo_categories(proto)
  local cats = {}
  local params = proto.attack_parameters
  if params and params.ammo_categories then
    for _, c in pairs(params.ammo_categories) do cats[c] = true end
  end
  for _, gun in pairs(proto.indexed_guns or {}) do
    local gp = gun.attack_parameters
    for _, c in pairs(gp and gp.ammo_categories or {}) do cats[c] = true end
  end
  return cats
end

-- For each turret prototype: every allowed ammo it can fire, best first, as {name, quality, score, level}.
-- Built from prototypes and settings only, so it is the same on every machine in multiplayer.
local candidate_cache = {}
local function candidates_for(turret)
  local proto = turret.prototype
  local list = candidate_cache[proto.name]
  if list then return list end
  list = {}
  local cats = ammo_categories(proto)
  for name, item in pairs(prototypes.get_item_filtered{{filter = "type", type = "ammo"}}) do
    local s = ammo_score(name)
    if s and item.ammo_category and cats[item.ammo_category.name] then
      for _, q in pairs(qualities()) do
        table.insert(list, {name = name, quality = q.name, score = s, level = q.level})
      end
    end
  end
  table.sort(list, function(a, b) return better(a.score, a.level, b.score, b.level) end)
  candidate_cache[proto.name] = list
  return list
end

local function reset_caches()
  candidate_cache = {}
  quality_cache = nil
end

---------------------------------------------------------------------------------------------------------
-- Where the ammo comes from
---------------------------------------------------------------------------------------------------------

-- Is this a personal roboport's network (a player's armour, a spidertron, a tank)? Remembered per network,
-- since a network never changes between fixed and mobile. (Only a speed-up: every machine in a multiplayer
-- game works out the same answer, so it doesn't need to be saved.)
local mobile_cache = {}
local function is_mobile(net)
  local id = net.network_id
  local mobile = mobile_cache[id]
  if mobile == nil then
    local cell = net.cells[1]
    mobile = cell ~= nil and cell.mobile or false
    mobile_cache[id] = mobile
  end
  return mobile
end

-- Where this turret's ammo can come from: a list of {id, net} (logistic networks whose robots reach it) or
-- {id, inv} (a space platform's hub), or nil when nothing can deliver to it. Personal roboports only count
-- when the setting allows it, so the mod never hands out the ammo a player or spidertron is carrying.
local function supply_sources(turret)
  local platform = turret.surface.platform
  if platform then
    local hub = platform.hub
    if not (hub and hub.valid) then return nil end
    local inv = hub.get_inventory(defines.inventory.hub_main)
    if not inv then return nil end
    return {{id = "hub:" .. platform.index, inv = inv}}
  end
  local sources = {}
  for _, net in pairs(turret.surface.find_logistic_networks_by_construction_area(turret.position, turret.force)) do
    if net.valid and (cfg.use_personal or not is_mobile(net)) then
      table.insert(sources, {id = net.network_id, net = net})
    end
  end
  if #sources == 0 then return nil end
  return sources
end

local function item_key(name, quality) return name .. "/" .. quality end

-- How many of this item a turret may still ask for: what the best source holds, minus what this mod's other
-- open requests from that source are still waiting for. Returns the count and the id of that source.
-- (The game's own count already leaves out items robots are on their way to fetch; it doesn't know about
-- requests no robot has picked up yet - that is what the reservations are for.)
-- own: the turret's own open request, which doesn't count against itself.
local function free_count(sources, name, quality, own)
  local id_q = {name = name, quality = quality}
  local key = item_key(name, quality)
  local best, best_id = 0, nil
  for _, src in pairs(sources) do
    local n = src.inv and src.inv.get_item_count(id_q) or src.net.get_item_count(id_q)
    local by_source = storage.reserved[src.id]
    local r = by_source and by_source[key] or 0
    if own and own.supply == src.id and own.key == key then r = r - own.remaining end
    n = n - r
    if n > best then best, best_id = n, src.id end
  end
  return best, best_id
end

---------------------------------------------------------------------------------------------------------
-- The mod's open requests
--   storage.pending[turret unit_number] = {proxy, name, quality, key, supply, remaining, progress_tick}
--   storage.reserved[source id][item key] = how many items open requests from that source still need
---------------------------------------------------------------------------------------------------------

local function reserve(supply, key, count)
  local by_source = storage.reserved[supply]
  if not by_source then
    by_source = {}
    storage.reserved[supply] = by_source
  end
  by_source[key] = (by_source[key] or 0) + count
end

-- Once a second: re-count what every open request still needs (it shrinks as robots deliver), note which
-- ones made progress, and forget the finished ones. Rebuilding the totals from scratch keeps them exact.
local function refresh_pending()
  storage.reserved = {}
  for unit, p in pairs(storage.pending) do
    if p.proxy.valid then
      local left = 0
      for _, r in pairs(p.proxy.item_requests) do
        if r.name == p.name and (r.quality or "normal") == p.quality then left = left + r.count end
      end
      if left < p.remaining then p.progress_tick = game.tick end
      p.remaining = left
      if left > 0 then reserve(p.supply, p.key, left) end
    else
      storage.pending[unit] = nil
    end
  end
end

-- Withdraw this turret's open request (robots already carrying items take them back to storage).
local function cancel_request(unit)
  local p = storage.pending[unit]
  if not p then return end
  storage.pending[unit] = nil
  if p.proxy.valid then p.proxy.destroy() end
  local by_source = storage.reserved[p.supply]
  if by_source and by_source[p.key] then by_source[p.key] = math.max(0, by_source[p.key] - p.remaining) end
end

---------------------------------------------------------------------------------------------------------
-- Checks on a turret
---------------------------------------------------------------------------------------------------------

-- Does an inserter put items into this turret? (Loaders can't feed turrets.)
local function fed_by_inserter(turret)
  local cache = storage.inserter_cache
  local entry = cache[turret.unit_number]
  if entry and game.tick - entry.tick < INSERTER_CACHE_TICKS then return entry.fed end
  local box = turret.bounding_box
  local area = {{box.left_top.x - 3, box.left_top.y - 3}, {box.right_bottom.x + 3, box.right_bottom.y + 3}}
  local fed = false
  for _, ins in pairs(turret.surface.find_entities_filtered{area = area, type = "inserter", force = turret.force}) do
    if ins.drop_target == turret then fed = true break end
  end
  cache[turret.unit_number] = {tick = game.tick, fed = fed}
  return fed
end

-- The ammo currently loaded: {name, quality, level, count, index (0-based)} or nil when empty.
local function loaded_ammo(inv)
  for i = 1, #inv do
    local stack = inv[i]
    if stack.valid_for_read then
      return {name = stack.name, quality = stack.quality.name, level = stack.quality.level,
              count = stack.count, index = i - 1}
    end
  end
  return nil
end

-- How much of this ammo to keep in this turret: the setting, capped at what one slot holds
-- (artillery slots hold more shells than a shell's stack size).
local function amount_to_keep(turret, name)
  local limit = turret.prototype.ammo_stack_limit
  if not limit or limit == 0 then limit = prototypes.item[name].stack_size end
  return math.min(cfg.keep, limit)
end

local function refill_below(keep) return math.max(1, math.floor(keep * cfg.refill_fraction)) end

-- Ask for count of this ammo, from the given source, and remember the request (and reserve its items).
local function request(turret, inventory_id, name, quality, count, stack_index, removal, supply)
  local proxy = turret.surface.create_entity{
    name = "item-request-proxy",
    position = turret.position,
    force = turret.force,
    target = turret,
    modules = {{
      id = {name = name, quality = quality},
      items = {in_inventory = {{inventory = inventory_id, stack = stack_index, count = count}}},
    }},
    removal_plan = removal,
  }
  if proxy then
    local key = item_key(name, quality)
    storage.pending[turret.unit_number] = {proxy = proxy, name = name, quality = quality, key = key,
      supply = supply, remaining = count, progress_tick = game.tick}
    reserve(supply, key, count)
  end
end

-- "Take the loaded ammo out" (the first half of a swap).
local function removal_of(loaded, inventory_id)
  return {{
    id = {name = loaded.name, quality = loaded.quality},
    items = {in_inventory = {{inventory = inventory_id, stack = loaded.index, count = loaded.count}}},
  }}
end

-- A request is already open for this turret. Other people's requests (from a blueprint) are left alone.
-- One of ours is cancelled if the turret is about to be removed, or if nothing has been delivered for a
-- while and there is no ammo left for it - then the next check fills the turret with what there is.
local function check_open_request(turret, proxy)
  local unit = turret.unit_number
  local p = storage.pending[unit]
  if not (p and p.proxy.valid and p.proxy == proxy) then return end
  if turret.to_be_deconstructed() or turret.to_be_upgraded() then
    cancel_request(unit)
  elseif game.tick - p.progress_tick >= STALE_TICKS then
    local sources = supply_sources(turret)
    if not sources or free_count(sources, p.name, p.quality, p) <= 0 then cancel_request(unit) end
  end
end

-- Decide what (if anything) this turret should ask for.
local function service(turret)
  local proxy = turret.item_request_proxy
  if proxy then return check_open_request(turret, proxy) end
  storage.pending[turret.unit_number] = nil -- (a finished request; refresh_pending would forget it too)
  if turret.to_be_deconstructed() or turret.to_be_upgraded() then return end -- don't fill what's being removed

  -- Swaps (taking ammo out to put better in) wait until a planet turret stops shooting. On space platforms
  -- the hub throws ammo straight across, and turrets there are rarely idle, so they swap any time.
  local on_platform = turret.surface.platform ~= nil
  local hold_swaps = false
  if turret.type == "artillery-wagon" then
    local train = turret.train
    if train and train.speed ~= 0 then return end -- robots can't load a moving train
  elseif turret.type == "ammo-turret" and turret.shooting_target then
    -- (only ammo turrets can say what they're shooting at: asking an artillery turret is an error)
    -- (the pause setting keeps robots out of fights, so it doesn't apply on platforms either)
    if cfg.pause_while_shooting and not on_platform then return end
    hold_swaps = not on_platform
  end

  local inventory_id = AMMO_INVENTORY[turret.type]
  local inv = inventory_id and turret.get_inventory(inventory_id)
  if not inv or #inv == 0 then return end
  local candidates = candidates_for(turret)
  if #candidates == 0 then return end
  local sources = supply_sources(turret)
  if not sources then return end -- no robots in reach (the early game): nothing to do
  if cfg.skip_inserter_fed and fed_by_inserter(turret) then return end

  local loaded = loaded_ammo(inv)

  -- The player picked an ammo for this turret: use only that, never "upgrade" past it.
  local choice = storage.choices[turret.unit_number]
  if choice then
    local keep = amount_to_keep(turret, choice.name)
    local have, supply = free_count(sources, choice.name, choice.quality)
    if loaded and loaded.name == choice.name and loaded.quality == choice.quality then
      if loaded.count < refill_below(keep) and have > 0 then
        request(turret, inventory_id, choice.name, choice.quality, math.min(keep - loaded.count, have), loaded.index, nil, supply)
      end
    elseif have > 0 and not (loaded and hold_swaps) then
      request(turret, inventory_id, choice.name, choice.quality, math.min(keep, have), loaded and loaded.index or 0,
        loaded and removal_of(loaded, inventory_id), supply)
    end
    return
  end

  -- Empty: fill it with the best ammo there is any of.
  if not loaded then
    for _, c in ipairs(candidates) do
      local have, supply = free_count(sources, c.name, c.quality)
      if have > 0 then
        request(turret, inventory_id, c.name, c.quality, math.min(amount_to_keep(turret, c.name), have), 0, nil, supply)
        return
      end
    end
    return
  end

  -- Loaded with something the mod won't use (a nuke put in by hand, blocked ammo): leave it alone.
  local loaded_score = ammo_score(loaded.name)
  if not loaded_score then return end

  -- Better ammo available? Only swap for a full load nobody else has asked for, so a handful of rounds can't
  -- cause swapping back and forth, and a turret is never emptied for ammo that then doesn't come.
  if cfg.upgrade and not hold_swaps then
    for _, c in ipairs(candidates) do
      if not better(c.score, c.level, loaded_score, loaded.level) then break end
      local keep = amount_to_keep(turret, c.name)
      local have, supply = free_count(sources, c.name, c.quality)
      if have >= keep then
        request(turret, inventory_id, c.name, c.quality, keep, loaded.index, removal_of(loaded, inventory_id), supply)
        return
      end
    end
  end

  -- Running low? Top up with the same ammo. (If that ammo has run out, the turret uses up what it has
  -- and is then refilled with the best ammo left.)
  local keep = amount_to_keep(turret, loaded.name)
  if loaded.count < refill_below(keep) then
    local have, supply = free_count(sources, loaded.name, loaded.quality)
    if have > 0 then
      request(turret, inventory_id, loaded.name, loaded.quality, math.min(keep - loaded.count, have), loaded.index, nil, supply)
    end
  end
end

---------------------------------------------------------------------------------------------------------
-- Keeping the list of turrets
---------------------------------------------------------------------------------------------------------

local function add_turret(entity)
  if not (entity and entity.valid and entity.unit_number) then return end
  if not AMMO_INVENTORY[entity.type] then return end
  if storage.turrets[entity.unit_number] then return end
  storage.turrets[entity.unit_number] = entity
  table.insert(storage.queue, entity.unit_number)
end

local function scan_all()
  for _, surface in pairs(game.surfaces) do
    for _, e in pairs(surface.find_entities_filtered{type = TURRET_TYPES}) do add_turret(e) end
  end
end

local function init_storage()
  storage.turrets = storage.turrets or {}
  storage.queue = storage.queue or {}
  storage.cursor = storage.cursor or 1
  storage.inserter_cache = storage.inserter_cache or {}
  storage.overrides = storage.overrides or {}
  storage.choices = storage.choices or {} -- unit_number -> {name, quality}: ammo the player picked
  storage.open_turret = storage.open_turret or {} -- player index -> the turret whose window is open
  storage.pending = storage.pending or {} -- the mod's open requests (see "The mod's open requests")
  storage.reserved = storage.reserved or {}
  storage.mined = storage.mined or {} -- choices of turrets mined this tick, by spot (see on_mined)
  storage.mined_tick = storage.mined_tick or -1
end

-- Saves from 0.1.0 have no record of the requests that version made, and some may be stuck. Adopt every open
-- request on a turret that asks only for ammo, so a stuck one is cancelled like any other.
local function adopt_open_requests()
  for unit, turret in pairs(storage.turrets) do
    local proxy = turret.valid and not storage.pending[unit] and turret.item_request_proxy
    if proxy then
      local reqs = proxy.item_requests
      local only_ammo = reqs[1] ~= nil
      for _, r in pairs(reqs) do
        local item = prototypes.item[r.name]
        if not (item and item.type == "ammo") then only_ammo = false end
      end
      if only_ammo then
        -- Checked straight away: a hopeless one (none of its ammo left, or no source in reach - say it was a
        -- personal roboport's) is cancelled at the turret's next check.
        local sources = supply_sources(turret)
        local first = reqs[1]
        local quality = first.quality or "normal"
        local left = 0
        for _, r in pairs(reqs) do
          if r.name == first.name and (r.quality or "normal") == quality then left = left + r.count end
        end
        storage.pending[unit] = {proxy = proxy, name = first.name, quality = quality,
          key = item_key(first.name, quality), supply = sources and sources[1].id or "none", remaining = left,
          progress_tick = game.tick - STALE_TICKS}
      end
    end
  end
  refresh_pending()
end

script.on_init(function()
  init_storage()
  read_settings()
  scan_all()
end)

script.on_load(function()
  read_settings()
end)

script.on_configuration_changed(function()
  init_storage()
  read_settings()
  reset_caches()
  score_data = nil
  mobile_cache = {}
  scan_all()
  adopt_open_requests()
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(e)
  if e.setting:sub(1, 4) == "sta-" then
    read_settings()
    reset_caches()
  end
end)

local built_filter = {}
for _, t in pairs(TURRET_TYPES) do table.insert(built_filter, {filter = "type", type = t}) end
local set_choice -- defined below

local function spot_key(entity)
  local pos = entity.position
  return entity.surface.index .. ":" .. pos.x .. ":" .. pos.y
end

-- A turret with a picked ammo was mined. If a new turret is built on the same spot in the same tick, that was a
-- quality upgrade or a fast-replace, and the new turret keeps the pick (see on_built).
local function on_mined(e)
  local entity = e.entity
  local choice = entity and entity.valid and entity.unit_number and storage.choices[entity.unit_number]
  if not choice then return end
  if storage.mined_tick ~= game.tick then
    storage.mined = {}
    storage.mined_tick = game.tick
  end
  storage.mined[spot_key(entity)] = choice
end
for _, ev in pairs({defines.events.on_player_mined_entity, defines.events.on_robot_mined_entity,
                    defines.events.on_space_platform_mined_entity}) do
  script.on_event(ev, on_mined, built_filter)
end

local function on_built(e)
  local entity = e.entity
  add_turret(entity)
  if not (entity and entity.valid) then return end
  local tag = e.tags and e.tags.sta_ammo
  if not tag and storage.mined_tick == game.tick then tag = storage.mined[spot_key(entity)] end
  if tag then set_choice(entity, tag.name, tag.quality) end
end
for _, ev in pairs({defines.events.on_built_entity, defines.events.on_robot_built_entity,
                    defines.events.on_space_platform_built_entity, defines.events.script_raised_built,
                    defines.events.script_raised_revive}) do
  script.on_event(ev, on_built, built_filter)
end

-- A turret with a picked ammo was destroyed: its ghost remembers the pick, so the rebuilt turret gets it back.
script.on_event(defines.events.on_post_entity_died, function(e)
  local choice = e.unit_number and storage.choices[e.unit_number]
  local ghost = e.ghost
  if not (choice and ghost and ghost.valid) then return end
  local tags = ghost.tags or {}
  tags.sta_ammo = {name = choice.name, quality = choice.quality}
  ghost.tags = tags
end, built_filter)

-- Another mod copied a turret (e.g. a spaceship mod moving a ship): the copy is looked after too, with its pick.
script.on_event(defines.events.on_entity_cloned, function(e)
  add_turret(e.destination)
  local choice = e.source.valid and e.source.unit_number and storage.choices[e.source.unit_number]
  if choice and e.destination.valid then set_choice(e.destination, choice.name, choice.quality) end
end, built_filter)

-- Check a few turrets each tick, in rotation. Never more than the whole list once per CHECK_INTERVAL.
script.on_event(defines.events.on_tick, function(e)
  if e.tick % CHECK_INTERVAL == 0 then refresh_pending() end
  local queue = storage.queue
  local n = #queue
  if n == 0 then return end
  local count = math.min(cfg.per_tick, math.ceil(n / CHECK_INTERVAL))
  local i = storage.cursor
  while count > 0 and #queue > 0 do
    if i > #queue then i = 1 end
    local id = queue[i]
    local turret = storage.turrets[id]
    if turret and turret.valid then
      service(turret)
      i = i + 1
    else
      -- the turret is gone: drop it (swap the last entry into its place)
      storage.turrets[id] = nil
      storage.inserter_cache[id] = nil
      storage.choices[id] = nil
      cancel_request(id)
      queue[i] = queue[#queue]
      queue[#queue] = nil
    end
    count = count - 1
  end
  storage.cursor = i
end)

---------------------------------------------------------------------------------------------------------
-- Picking the ammo for one turret: a panel on the turret's window, copy / paste, and blueprints
---------------------------------------------------------------------------------------------------------

-- Names of the ammo this turret may be locked to (the same rules as automatic: never dangerous ammo).
local function pickable_names(turret)
  local names, seen = {}, {}
  for _, c in ipairs(candidates_for(turret)) do
    if not seen[c.name] then seen[c.name] = true table.insert(names, c.name) end
  end
  return names
end

local function can_fire(turret, name)
  for _, n in pairs(pickable_names(turret)) do if n == name then return true end end
  return false
end

set_choice = function(turret, name, quality)
  if not (turret and turret.valid and turret.unit_number and AMMO_INVENTORY[turret.type]) then return end
  local unit = turret.unit_number
  local old, new = storage.choices[unit], nil
  if name and can_fire(turret, name) then new = {name = name, quality = quality or "normal"} end
  storage.choices[unit] = new
  -- a new pick takes effect at once: a request for the old one is withdrawn
  local function key(c) return c and item_key(c.name, c.quality) or "" end
  if key(old) ~= key(new) then cancel_request(unit) end
end

local PANEL = "sta_panel"
-- the window each turret type opens, for anchoring the panel next to it
local ANCHOR = {
  ["ammo-turret"] = defines.relative_gui_type.turret_gui,
  ["artillery-turret"] = defines.relative_gui_type.turret_gui,
  ["artillery-wagon"] = defines.relative_gui_type.container_gui,
}

local function status_caption(choice)
  if choice then return {"sta-gui.locked"} end
  return {"sta-gui.auto"}
end

local function close_panel(player)
  local old = player.gui.relative[PANEL]
  if old then old.destroy() end
  storage.open_turret[player.index] = nil
end

local function open_panel(player, turret)
  close_panel(player)
  local frame = player.gui.relative.add{
    type = "frame", name = PANEL, direction = "vertical", caption = {"sta-gui.title"},
    anchor = {gui = ANCHOR[turret.type], position = defines.relative_gui_position.right},
  }
  local row = frame.add{type = "flow", direction = "horizontal"}
  row.style.vertical_align = "center"
  local choice = storage.choices[turret.unit_number]
  local names = pickable_names(turret)
  if #names == 0 then
    frame.add{type = "label", caption = {"sta-gui.nothing"}}
    storage.open_turret[player.index] = turret
    return
  end
  local picker = row.add{
    type = "choose-elem-button", name = "sta_pick", elem_type = "item-with-quality",
    elem_filters = {{filter = "name", name = names}},
    tooltip = {"sta-gui.pick-tooltip"},
  }
  if choice then picker.elem_value = {name = choice.name, quality = choice.quality} end
  row.add{type = "button", name = "sta_auto", caption = {"sta-gui.auto-button"}, tooltip = {"sta-gui.auto-tooltip"}}
  local status = frame.add{type = "label", name = "sta_status", caption = status_caption(choice)}
  status.style.single_line = false
  status.style.maximal_width = 220
  storage.open_turret[player.index] = turret
end

local function refresh_panel(player)
  local frame = player.gui.relative[PANEL]
  local turret = storage.open_turret[player.index]
  if not (frame and turret and turret.valid and frame.sta_status) then return end
  local choice = storage.choices[turret.unit_number]
  local picker = frame.children[1].sta_pick
  picker.elem_value = choice and {name = choice.name, quality = choice.quality} or nil
  frame.sta_status.caption = status_caption(choice)
end

script.on_event(defines.events.on_gui_opened, function(e)
  local player = game.get_player(e.player_index)
  if e.entity and e.entity.valid and AMMO_INVENTORY[e.entity.type] and e.entity.unit_number then
    open_panel(player, e.entity)
  else
    close_panel(player)
  end
end)

script.on_event(defines.events.on_gui_closed, function(e)
  if e.entity then close_panel(game.get_player(e.player_index)) end
end)

script.on_event(defines.events.on_gui_elem_changed, function(e)
  if e.element.name ~= "sta_pick" then return end
  local player = game.get_player(e.player_index)
  local turret = storage.open_turret[player.index]
  if not (turret and turret.valid) then return end
  local v = e.element.elem_value
  if v then set_choice(turret, v.name, v.quality) else set_choice(turret, nil) end
  refresh_panel(player)
end)

script.on_event(defines.events.on_gui_click, function(e)
  if e.element.name ~= "sta_auto" then return end
  local player = game.get_player(e.player_index)
  local turret = storage.open_turret[player.index]
  if turret and turret.valid then set_choice(turret, nil) end
  refresh_panel(player)
end)

-- Shift + right-click a turret, then Shift + left-click others: the ammo choice is copied too.
script.on_event(defines.events.on_entity_settings_pasted, function(e)
  local src, dst = e.source, e.destination
  if not (src.valid and dst.valid and AMMO_INVENTORY[src.type] and AMMO_INVENTORY[dst.type]) then return end
  local choice = storage.choices[src.unit_number]
  if choice then set_choice(dst, choice.name, choice.quality) else set_choice(dst, nil) end
end)

-- Blueprints remember each turret's choice (as a tag), and placing the blueprint brings it back (on_built).
script.on_event(defines.events.on_player_setup_blueprint, function(e)
  local player = game.get_player(e.player_index)
  -- the blueprint being made can be an item in hand, a blueprint library record, or the one being set up
  local function usable(x)
    if not x then return false end
    local ok, result = pcall(function()
      if x.object_name == "LuaRecord" then return x.valid and x.type == "blueprint" and x.is_blueprint_setup() end
      return x.valid_for_read and x.is_blueprint and x.is_blueprint_setup()
    end)
    return ok and result
  end
  local bp
  for _, candidate in pairs({e.stack, e.record, player.blueprint_to_setup, player.cursor_stack}) do
    if usable(candidate) then bp = candidate break end
  end
  if not bp then return end
  local mapping = e.mapping.get()
  for index, entity in pairs(mapping) do
    if entity.valid and entity.unit_number and storage.choices[entity.unit_number] then
      local c = storage.choices[entity.unit_number]
      bp.set_blueprint_entity_tag(index, "sta_ammo", {name = c.name, quality = c.quality})
    end
  end
end)

---------------------------------------------------------------------------------------------------------
-- For other mods
--   remote.call("smart-turret-ammo", "set_ammo_score", "my-ammo", 30) -- use it, as if it did 30 damage
--   remote.call("smart-turret-ammo", "set_ammo_score", "my-ammo", false) -- never use it
--   remote.call("smart-turret-ammo", "set_ammo_score", "my-ammo", nil) -- back to the automatic score
--   remote.call("smart-turret-ammo", "get_ammo_info", "my-ammo") -- {score, danger, allowed}
--   remote.call("smart-turret-ammo", "set_turret_ammo", turret, "piercing-rounds-magazine", "normal") -- lock one turret
--   remote.call("smart-turret-ammo", "set_turret_ammo", turret, nil) -- back to automatic
---------------------------------------------------------------------------------------------------------
remote.add_interface("smart-turret-ammo", {
  set_ammo_score = function(name, value)
    storage.overrides[name] = value
    reset_caches()
  end,
  -- pick the ammo for one turret (nil name = back to automatic)
  set_turret_ammo = function(entity, name, quality) set_choice(entity, name, quality) end,
  get_turret_ammo = function(entity)
    return entity and entity.valid and entity.unit_number and storage.choices[entity.unit_number] or nil
  end,
  get_ammo_info = function(name)
    local info = load_scores()[name] or {}
    return {score = info.score, danger = info.danger, allowed = ammo_score(name) ~= nil}
  end,
})
