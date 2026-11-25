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
-- turrets don't all ask for the same thirty magazines. A request that has stalled (nothing delivered for
-- 20 seconds, and its ammo gone with no robot carrying it, or a swap whose old ammo has nowhere to go) is
-- cancelled, so the turret can be filled with whatever there is instead.
--
-- Which ammo is "best" comes from data-final-fixes.lua: while the game loads it adds up every ammo's
-- damage (any mod's) and flags dangerous ammo (nukes, unit spawners, huge blasts), which is never used.

-- The mods whose ammo counts as the game's own, for the "Use ammo from other mods" setting: the base game
-- and Factorio's official expansion mods. (Decided by which mod created the item, not by a list of names, so
-- cannon shells, shotgun shells, tesla ammo and anything those mods add later are all included.)
local VANILLA_MODS = {["base"] = true, ["space-age"] = true, ["quality"] = true, ["elevated-rails"] = true}

-- Entity types the mod looks after, and the inventory their ammo goes into.
local AMMO_INVENTORY = {
  ["ammo-turret"] = defines.inventory.turret_ammo,
  ["artillery-turret"] = defines.inventory.artillery_turret_ammo,
  ["artillery-wagon"] = defines.inventory.artillery_wagon_ammo,
}
local TURRET_TYPES = {"ammo-turret", "artillery-turret", "artillery-wagon"}

local CHECK_INTERVAL = 60 -- each turret is checked at most once per this many ticks
local INSERTER_CACHE_TICKS = 600 -- how long "is this turret fed by an inserter?" is remembered
local STALE_TICKS = 1200 -- an open request that gets nowhere for this long is cancelled (see check_open_request)
local MAX_WAIT_TICKS = 5 * 3600 -- ...and one with nothing delivered for this long, even if robots seem to be coming
local SWAP_BACKOFF_TICKS = 5 * 3600 -- after a swap is given up, that turret doesn't try another for this long
local UPGRADE_RECHECK_TICKS = 600 -- a turret that found no better ammo looks again after this long

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

-- Was this ammo item created by the base game or one of Factorio's own expansion mods? (Remembered per name:
-- prototypes never change while the game runs.)
local vanilla_cache = {}
local function is_vanilla(name)
  local vanilla = vanilla_cache[name]
  if vanilla == nil then
    -- get_history needs the item's real prototype type ("ammo"); it raises an error for a name it doesn't know
    local ok, history = pcall(prototypes.get_history, "ammo", name)
    vanilla = ok and history ~= nil and VANILLA_MODS[history.created] == true
    vanilla_cache[name] = vanilla
  end
  return vanilla
end

-- How good this ammo is (a damage number, before quality), or nil if the mod must not use it.
local function ammo_score(name)
  if cfg.blocked[name] then return nil end
  local override = storage.overrides and storage.overrides[name]
  if override == false then return nil end
  if type(override) == "number" then return override end
  local info = load_scores()[name]
  if not info or info.danger then return nil end
  if not cfg.use_modded and not is_vanilla(name) then return nil end
  return info.score
end

-- A quality can be used if the game has it and it isn't hidden ("quality-unknown" is hidden). "normal" is
-- always usable: without the Quality mod it is hidden too, but it is the only quality there is.
local function usable_quality(name)
  local q = prototypes.quality[name]
  return q ~= nil and (name == "normal" or not q.hidden)
end

-- A quality name from a pick (the panel, a blueprint, another mod) made safe to use: a blueprint from a game
-- with other quality mods can name a quality this game doesn't have, and asking for it would be an error.
-- Anything unknown becomes "normal".
local function valid_quality(name)
  if type(name) == "string" and usable_quality(name) then return name end
  return "normal"
end

-- Quality levels, best first, each with its damage multiplier (hidden ones like "quality-unknown" left out).
local quality_cache
local multiplier_cache = {}
local function qualities()
  if not quality_cache then
    quality_cache = {}
    for name, q in pairs(prototypes.quality) do
      if usable_quality(name) then table.insert(quality_cache, {name = name, level = q.level, mult = q.default_multiplier}) end
    end
    table.sort(quality_cache, function(a, b) return a.level > b.level end)
  end
  return quality_cache
end

-- How much more damage ammo of this quality does (normal 1, then +30% a level: legendary 2.5).
local function quality_multiplier(name)
  local mult = multiplier_cache[name]
  if not mult then
    local q = prototypes.quality[name]
    mult = q and q.default_multiplier or 1
    multiplier_cache[name] = mult
  end
  return mult
end

-- Is ammo a better than ammo b? The scores are damage x quality multiplier (so legendary yellow, 12.5 a shot,
-- beats normal red, 8); on a tie the higher quality wins.
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

-- For each turret prototype: every allowed ammo it can fire, best first, as {name, quality, score, level}
-- (score = damage x quality multiplier), and the set of those names. Built from prototypes and settings only,
-- so it is the same on every machine in multiplayer.
local candidate_cache = {}
local allowed_cache = {}
local function candidates_for(turret)
  local proto = turret.prototype
  local list = candidate_cache[proto.name]
  if list then return list, allowed_cache[proto.name] end
  list = {}
  local allowed = {}
  local cats = ammo_categories(proto)
  for name, item in pairs(prototypes.get_item_filtered{{filter = "type", type = "ammo"}}) do
    local s = ammo_score(name)
    if s and item.ammo_category and cats[item.ammo_category.name] then
      allowed[name] = true
      for _, q in pairs(qualities()) do
        table.insert(list, {name = name, quality = q.name, score = s * q.mult, level = q.level})
      end
    end
  end
  table.sort(list, function(a, b) return better(a.score, a.level, b.score, b.level) end)
  candidate_cache[proto.name] = list
  allowed_cache[proto.name] = allowed
  return list, allowed
end

local keep_cache -- (declared with amount_to_keep, below)
local function reset_caches()
  candidate_cache = {}
  allowed_cache = {}
  quality_cache = nil
  multiplier_cache = {}
  keep_cache = {}
end

-- Ammo items no score was worked out for while the game loaded: another mod added (or replaced) them in its own
-- data-final-fixes, after this mod's. They are never loaded automatically (their danger can't be checked);
-- the names go into the log once, so a player or mod author can see why (set_ammo_score can allow them).
local function log_unscored()
  local scores, missing = load_scores(), {}
  for name in pairs(prototypes.get_item_filtered{{filter = "type", type = "ammo"}}) do
    if not scores[name] then table.insert(missing, name) end
  end
  if #missing == 0 then return end
  table.sort(missing)
  log("Smart Turret Ammo: these ammo items were added after the mod scored ammo (by another mod's data-final-fixes), "
    .. "so they are never loaded automatically: " .. table.concat(missing, ", "))
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
-- A network without construction robots doesn't count either (a roboport whose robots haven't arrived yet,
-- or another mod's roboport-like building such as a repair turret): nothing could ever bring its ammo.
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
    if net.valid and net.all_construction_robots > 0 and (cfg.use_personal or not is_mobile(net)) then
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
--   storage.pending[turret unit_number] = {proxy, name, quality, key, supply, remaining, progress_tick,
--     delivered_tick, swap}
--   storage.reserved[source id][item key] = how many items open requests from that source still need
-- Each request's "remaining" is part of the reserved total: every change to it goes through reserve(), so the
-- total stays exact without re-counting every request at once (which cost ~4 ms a second with 1200 open).
---------------------------------------------------------------------------------------------------------

local function reserve(supply, key, count)
  if count == 0 then return end
  local by_source = storage.reserved[supply]
  if not by_source then
    by_source = {}
    storage.reserved[supply] = by_source
  end
  local total = (by_source[key] or 0) + count
  by_source[key] = total > 0 and total or nil
  if next(by_source) == nil then storage.reserved[supply] = nil end
end

-- Re-count what one open request still needs (it shrinks as robots deliver) and note any delivery as progress.
-- Done whenever its turret is checked, so the work is spread over the second like the checks themselves.
local function update_request(p)
  local left = 0
  for _, r in pairs(p.proxy.item_requests) do
    if r.name == p.name and (r.quality or "normal") == p.quality then left = left + r.count end
  end
  if left < p.remaining then
    p.progress_tick = game.tick
    p.delivered_tick = game.tick
  end
  reserve(p.supply, p.key, left - p.remaining)
  p.remaining = left
end

-- Forget this turret's request (it was finished or replaced) and give back what it had reserved.
local function forget_request(unit)
  local p = storage.pending[unit]
  if not p then return end
  storage.pending[unit] = nil
  reserve(p.supply, p.key, -p.remaining)
end

-- Withdraw this turret's open request (robots already carrying items take them back to storage).
local function cancel_request(unit)
  local p = storage.pending[unit]
  if not p then return end
  forget_request(unit)
  if p.proxy.valid then p.proxy.destroy() end
end

-- Re-count every open request from scratch and rebuild the reserved totals (after a mod update or change).
local function rebuild_reserved()
  storage.reserved = {}
  for unit, p in pairs(storage.pending) do
    if p.proxy.valid and prototypes.item[p.name] then
      p.remaining = 0
      update_request(p)
    else
      storage.pending[unit] = nil
    end
  end
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
-- (artillery slots hold more shells than a shell's stack size). Remembered per turret type and ammo, as it
-- depends only on prototypes and the setting (keep_cache is emptied with the other caches).
keep_cache = {}
local function amount_to_keep(turret, name)
  local proto_name = turret.name
  local by_turret = keep_cache[proto_name]
  if not by_turret then
    by_turret = {}
    keep_cache[proto_name] = by_turret
  end
  local keep = by_turret[name]
  if not keep then
    local limit = turret.prototype.ammo_stack_limit
    if not limit or limit == 0 then limit = prototypes.item[name].stack_size end
    keep = math.min(cfg.keep, limit)
    by_turret[name] = keep
  end
  return keep
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
      supply = supply, remaining = count, progress_tick = game.tick, delivered_tick = game.tick, swap = removal ~= nil}
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

-- Take over an open request on this turret that the mod has no record of, if it asks only for ammo: one copied
-- along with a cloned turret (a spaceship or "move base" mod), one from a 0.1.0 save, a blueprint's or another
-- mod's. From then on it is looked after like the mod's own (and cancelled if it gets nowhere).
-- progress_tick: when it last counts as having moved (now, or long ago to check it at once).
local function adopt(turret, proxy, progress_tick)
  local reqs = proxy.item_requests
  local first = reqs[1]
  if not first then return nil end
  for _, r in pairs(reqs) do
    local item = prototypes.item[r.name]
    if not (item and item.type == "ammo") then return nil end
  end
  local quality = first.quality or "normal"
  local sources = supply_sources(turret)
  local p = {proxy = proxy, name = first.name, quality = quality, key = item_key(first.name, quality),
    supply = sources and sources[1].id or "none", remaining = 0, progress_tick = progress_tick,
    delivered_tick = progress_tick, swap = proxy.removal_plan[1] ~= nil}
  storage.pending[turret.unit_number] = p
  update_request(p) -- counts what it still needs, and reserves that
  return p
end

-- Has robots' work on this open request stalled for good? Asked once nothing has been delivered for 20 s.
--  * A swap whose old ammo is still in the turret: stalled if no network in reach has room in storage for it
--    (say there is no storage chest) - robots never take it out, so the new ammo never comes, whatever is in
--    stock. With room, the robots are just busy.
--  * Otherwise (a refill, or a swap whose old ammo is out): not while its ammo is still in stock for it (the
--    robots are just busy), nor while robots have set off with everything it still needs (the request is no
--    longer waiting in the robots' queue) - a far turret early in the game can wait a minute while slow
--    robots fly, and as robots set off within a tick of the request, the network's count drops at once, so
--    "none in stock" alone can't tell flying ammo from ammo that vanished or was taken by someone else.
local function stalled(turret, p, proxy)
  local sources = supply_sources(turret)
  if not sources then return true end -- nothing in reach can bring it any more (a wagon that drove off)
  local on_planet = not turret.surface.platform
  local removal = proxy.removal_plan[1]
  if on_planet and removal then
    local stack = {name = removal.id.name, quality = removal.id.quality or "normal", count = 1}
    for _, src in pairs(sources) do
      if src.net and src.net.select_drop_point{stack = stack, members = "storage"} then return false end
    end
    return true
  end
  if free_count(sources, p.name, p.quality, p) > 0 then return false end
  return not (on_planet and not proxy.is_registered_for_construction())
end

-- A request is already open for this turret. It is cancelled if the turret is about to be removed, or if it
-- has stalled (see above) - then the next check fills the turret with what there is. A swap given up that way
-- isn't tried again on that turret for 5 minutes (it would only stall again); an empty or low turret is still
-- filled. Whatever the case, a request with nothing delivered for 5 minutes (MAX_WAIT_TICKS) is given up.
local function check_open_request(turret, proxy)
  local unit = turret.unit_number
  local p = storage.pending[unit]
  if p and not p.proxy.valid then
    forget_request(unit) -- ours is finished or gone; this is a different request
    p = nil
  end
  if p then
    proxy = p.proxy -- (if the turret has another request too, say a blueprint's, ours is the one looked at)
  else
    p = adopt(turret, proxy, game.tick)
    if not p then return end -- (asks for something besides ammo: not ours to manage)
  end
  update_request(p)
  if turret.to_be_deconstructed() or turret.to_be_upgraded() then
    cancel_request(unit)
    return
  end
  if game.tick - p.progress_tick < STALE_TICKS then return end
  local waited = game.tick - (p.delivered_tick or p.progress_tick) -- (requests from 0.1.1 saves have no delivered_tick)
  if waited < MAX_WAIT_TICKS and not stalled(turret, p, proxy) then
    p.progress_tick = game.tick -- (still on its way: asked again in 20 seconds, not at every check)
    return
  end
  if p.swap then storage.swap_backoff[unit] = game.tick + SWAP_BACKOFF_TICKS end
  cancel_request(unit)
end

-- Decide what (if anything) this turret should ask for.
local function service(turret)
  local proxy = turret.item_request_proxy
  if proxy then return check_open_request(turret, proxy) end
  local unit = turret.unit_number
  forget_request(unit) -- (a finished request)
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
  local candidates, allowed = candidates_for(turret)
  if #candidates == 0 then return end
  local sources = supply_sources(turret)
  if not sources then return end -- no robots in reach (the early game): nothing to do
  if cfg.skip_inserter_fed and fed_by_inserter(turret) then return end

  local loaded = loaded_ammo(inv)

  -- After a swap that got nowhere (see check_open_request), no new swap for a while; filling still goes on.
  local backoff = storage.swap_backoff[unit]
  if backoff and game.tick >= backoff then
    storage.swap_backoff[unit] = nil
    backoff = nil
  end
  local may_swap = not hold_swaps and not backoff

  -- The player picked an ammo for this turret: use only that, never "upgrade" past it.
  local choice = storage.choices[unit]
  if choice and not prototypes.item[choice.name] then
    storage.choices[unit] = nil -- (its mod was removed; on_configuration_changed normally drops these first)
    choice = nil
  end
  -- A pick the mod may not use right now (blocked by a setting or another mod, or ammo this turret can't
  -- fire) is ignored: the turret is looked after automatically. The pick is kept, so it comes back when
  -- the ammo is allowed again.
  if choice and allowed[choice.name] then
    local keep = amount_to_keep(turret, choice.name)
    local have, supply = free_count(sources, choice.name, choice.quality)
    if loaded and loaded.name == choice.name and loaded.quality == choice.quality then
      if loaded.count < refill_below(keep) and have > 0 then
        request(turret, inventory_id, choice.name, choice.quality, math.min(keep - loaded.count, have), loaded.index, nil, supply)
      end
    elseif not loaded then
      -- empty: any amount of the pick will do
      if have > 0 then request(turret, inventory_id, choice.name, choice.quality, math.min(keep, have), 0, nil, supply) end
    elseif have >= keep and may_swap then
      -- holding other ammo: swap only for a full load of the pick, so a wall of turrets picked to new ammo
      -- doesn't throw out full loads for a handful each while that ammo is still being made
      request(turret, inventory_id, choice.name, choice.quality, keep, loaded.index, removal_of(loaded, inventory_id), supply)
    end
    return
  end

  -- Empty: fill it with the best ammo there is a refill's worth of (so 2 rare magazines don't leave a turret
  -- nearly empty while 200 normal ones sit in storage), or else the best there is any of.
  if not loaded then
    local fallback
    for _, c in ipairs(candidates) do
      local have, supply = free_count(sources, c.name, c.quality)
      if have > 0 then
        local keep = amount_to_keep(turret, c.name)
        if have >= refill_below(keep) then
          request(turret, inventory_id, c.name, c.quality, math.min(keep, have), 0, nil, supply)
          return
        end
        if not fallback then fallback = {c = c, keep = keep, have = have, supply = supply} end
      end
    end
    if fallback then
      local f = fallback
      request(turret, inventory_id, f.c.name, f.c.quality, math.min(f.keep, f.have), 0, nil, f.supply)
    end
    return
  end

  -- Loaded with something the mod won't use (a nuke put in by hand, blocked ammo): leave it alone.
  local loaded_score = ammo_score(loaded.name)
  if not loaded_score then return end
  loaded_score = loaded_score * quality_multiplier(loaded.quality)

  -- Better ammo available? Only swap for a full load nobody else has asked for, so a handful of rounds can't
  -- cause swapping back and forth, and a turret is never emptied for ammo that then doesn't come.
  -- (A turret that found nothing better looks again after UPGRADE_RECHECK_TICKS, not every second: in a big
  -- base most turrets are full and idle, and this search is most of what checking them costs.)
  local next_look = storage.next_upgrade[unit]
  if cfg.upgrade and may_swap and not (next_look and game.tick < next_look) then
    for _, c in ipairs(candidates) do
      if not better(c.score, c.level, loaded_score, loaded.level) then break end
      local keep = amount_to_keep(turret, c.name)
      local have, supply = free_count(sources, c.name, c.quality)
      if have >= keep then
        request(turret, inventory_id, c.name, c.quality, keep, loaded.index, removal_of(loaded, inventory_id), supply)
        return
      end
    end
    storage.next_upgrade[unit] = game.tick + UPGRADE_RECHECK_TICKS
  end

  -- Running low? Top up with the same ammo. If none of that is left (common with quality ammo), swap to the
  -- best ammo that has a full load to spare, even if it is worse - better than running dry in the next
  -- fight. (A full load, so it can't swap back and forth; and like any swap, not while a planet turret shoots.)
  local keep = amount_to_keep(turret, loaded.name)
  if loaded.count < refill_below(keep) then
    local have, supply = free_count(sources, loaded.name, loaded.quality)
    if have > 0 then
      request(turret, inventory_id, loaded.name, loaded.quality, math.min(keep - loaded.count, have), loaded.index, nil, supply)
    elseif may_swap then
      for _, c in ipairs(candidates) do
        local c_have, c_supply = free_count(sources, c.name, c.quality)
        local c_keep = c_have > 0 and amount_to_keep(turret, c.name)
        if c_keep and c_have >= c_keep then
          request(turret, inventory_id, c.name, c.quality, c_keep, loaded.index, removal_of(loaded, inventory_id), c_supply)
          return
        end
      end
    end
  end
end

---------------------------------------------------------------------------------------------------------
-- Keeping the list of turrets
---------------------------------------------------------------------------------------------------------

-- Is this a turret the mod looks after? Hidden turrets that players can't select are another mod's internal
-- parts (a vehicle's gun, a scripted emplacement): robots filling them would surprise that mod, so they are left out.
local function is_managed(entity)
  if not AMMO_INVENTORY[entity.type] then return false end
  local proto = entity.prototype
  return not proto.hidden and proto.selectable_in_game
end

local function add_turret(entity)
  if not (entity and entity.valid and entity.unit_number) then return end
  if not is_managed(entity) then return end
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
  storage.swap_backoff = storage.swap_backoff or {} -- unit_number -> tick until which that turret tries no swap
  storage.next_upgrade = storage.next_upgrade or {} -- unit_number -> tick it next looks for better ammo
end

-- Saves from 0.1.0 have no record of the requests that version made, and some may be stuck. Adopt every open
-- request on a turret that asks only for ammo, so a stuck one is cancelled like any other. They are checked
-- straight away (an old progress tick): one that gets nowhere is cancelled at the turret's next check.
local function adopt_open_requests()
  for unit, turret in pairs(storage.turrets) do
    local proxy = turret.valid and not storage.pending[unit] and turret.item_request_proxy
    if proxy then adopt(turret, proxy, game.tick - STALE_TICKS) end
  end
end

-- After a mod update or a change to the mod list: clean up what the old state refers to.
local function migrate()
  -- Picks for ammo whose mod was removed would be an error at the turret's next check: drop them (the turret
  -- goes back to automatic). A pick whose quality is gone (the Quality mod removed) keeps its ammo, at normal.
  for unit, c in pairs(storage.choices) do
    local item = type(c) == "table" and type(c.name) == "string" and prototypes.item[c.name]
    if item and item.type == "ammo" then
      c.quality = valid_quality(c.quality)
    else
      storage.choices[unit] = nil
    end
  end
  -- Turrets the mod no longer looks after (hidden ones, see is_managed): dropped from the list; the next pass
  -- of the rotation forgets them and cancels any request the mod made for them.
  for unit, turret in pairs(storage.turrets) do
    if turret.valid and not is_managed(turret) then storage.turrets[unit] = nil end
  end
  -- Requests for ammo that no longer exists are withdrawn; the rest are re-counted (0.1.1 saves keep their
  -- reserved totals differently).
  for unit, p in pairs(storage.pending) do
    if not prototypes.item[p.name] then
      storage.pending[unit] = nil
      if p.proxy.valid then p.proxy.destroy() end
    end
  end
  rebuild_reserved()
end

script.on_init(function()
  init_storage()
  read_settings()
  scan_all()
  log_unscored()
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
  migrate()
  scan_all()
  adopt_open_requests()
  log_unscored()
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
  if type(tag) ~= "table" then tag = nil end -- (a blueprint from elsewhere could hold anything here)
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
-- (Each check also re-counts that turret's open request, so that work is spread over the ticks too.)
script.on_event(defines.events.on_tick, function()
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
      storage.swap_backoff[id] = nil
      storage.next_upgrade[id] = nil
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
  local _, allowed = candidates_for(turret)
  return allowed[name] == true
end

local refresh_panels_for -- defined below, with the panel

-- Pick the ammo for one turret (name nil = back to automatic). Used by the panel, copy / paste, blueprints,
-- rebuilds and the remote interface, so everything they hand over is checked: only ammo this turret may
-- fire, and a quality this game has (anything else, say a quality from another mod set's blueprint, is "normal").
set_choice = function(turret, name, quality)
  if not (turret and turret.valid and turret.unit_number and is_managed(turret)) then return end
  -- A turret another mod placed without telling anyone (no build event) is looked after from now on.
  add_turret(turret)
  local unit = turret.unit_number
  local old, new = storage.choices[unit], nil
  if type(name) == "string" and can_fire(turret, name) then new = {name = name, quality = valid_quality(quality)} end
  storage.choices[unit] = new
  -- a new pick takes effect at once: a request for the old one is withdrawn
  local function key(c) return c and item_key(c.name, c.quality) or "" end
  if key(old) ~= key(new) then
    cancel_request(unit)
    storage.next_upgrade[unit] = nil
    refresh_panels_for(turret)
  end
end

local PANEL = "sta_panel"
-- the window each turret type opens, for anchoring the panel next to it. (An artillery turret's window is a
-- container window like the wagon's, not a turret window: checked in the game by anchoring a frame to every
-- relative GUI type while one was open - only container_gui showed.)
local ANCHOR = {
  ["ammo-turret"] = defines.relative_gui_type.turret_gui,
  ["artillery-turret"] = defines.relative_gui_type.container_gui,
  ["artillery-wagon"] = defines.relative_gui_type.container_gui,
}

-- choice: the turret's pick (or nil); usable: whether the mod may load it right now (see service).
local function status_caption(choice, usable)
  if choice and not usable then return {"sta-gui.blocked", "[item=" .. choice.name .. "]"} end
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
  -- (a pick that is blocked right now isn't among the names the picker offers, so it isn't shown in it)
  local usable = choice ~= nil and can_fire(turret, choice.name)
  if usable then picker.elem_value = {name = choice.name, quality = choice.quality} end
  row.add{type = "button", name = "sta_auto", caption = {"sta-gui.auto-button"}, tooltip = {"sta-gui.auto-tooltip"}}
  local status = frame.add{type = "label", name = "sta_status", caption = status_caption(choice, usable)}
  status.style.single_line = false
  status.style.maximal_width = 220
  storage.open_turret[player.index] = turret
end

local function refresh_panel(player)
  local frame = player.gui.relative[PANEL]
  local turret = storage.open_turret[player.index]
  if not (frame and turret and turret.valid and frame.sta_status) then return end
  local choice = storage.choices[turret.unit_number]
  local usable = choice ~= nil and can_fire(turret, choice.name)
  local picker = frame.children[1].sta_pick
  picker.elem_value = usable and {name = choice.name, quality = choice.quality} or nil
  frame.sta_status.caption = status_caption(choice, usable)
end

-- Every player who has this turret's window open sees its new pick (in multiplayer that may be someone else).
refresh_panels_for = function(turret)
  for index, open in pairs(storage.open_turret) do
    if open.valid and open == turret then
      local player = game.get_player(index)
      if player then refresh_panel(player) end
    end
  end
end

-- Is this GUI event about one of this mod's own elements? (Another mod could use the same element names.)
local function ours(element)
  return element and element.valid and element.get_mod() == script.mod_name
end

script.on_event(defines.events.on_gui_opened, function(e)
  local player = game.get_player(e.player_index)
  local entity = e.entity
  if entity and entity.valid and entity.unit_number and is_managed(entity) then
    add_turret(entity) -- (one placed by another mod without a build event is looked after from now on)
    open_panel(player, entity)
  else
    close_panel(player)
  end
end)

script.on_event(defines.events.on_gui_closed, function(e)
  if e.entity then close_panel(game.get_player(e.player_index)) end
end)

script.on_event(defines.events.on_gui_elem_changed, function(e)
  if e.element.name ~= "sta_pick" or not ours(e.element) then return end
  local player = game.get_player(e.player_index)
  local turret = storage.open_turret[player.index]
  if not (turret and turret.valid) then return end
  local v = e.element.elem_value
  if v then set_choice(turret, v.name, v.quality) else set_choice(turret, nil) end
  refresh_panel(player)
end)

script.on_event(defines.events.on_gui_click, function(e)
  if e.element.name ~= "sta_auto" or not ours(e.element) then return end
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
