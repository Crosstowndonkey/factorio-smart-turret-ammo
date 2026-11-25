-- A pretend "other mod" for the tests: a new turret that fires a new kind of ammo, two safe ammo items
-- and two dangerous ones. Smart Turret Ammo must pick the laser round and never touch the dangerous ones.
local function ammo(name, action, order)
  return {
    type = "ammo",
    name = name,
    icon = "__base__/graphics/icons/firearm-magazine.png",
    ammo_category = "sta-laser",
    ammo_type = {target_type = "entity", action = action},
    magazine_size = 10,
    subgroup = "ammo",
    order = "z[sta]-" .. order,
    stack_size = 200,
  }
end
local function hit(amount)
  return {type = "direct", action_delivery = {type = "instant",
    target_effects = {{type = "damage", damage = {amount = amount, type = "physical"}}}}}
end

local turret = table.deepcopy(data.raw["ammo-turret"]["gun-turret"])
turret.name = "sta-laser-turret"
turret.attack_parameters.ammo_category = nil
turret.attack_parameters.ammo_categories = {"sta-laser"}

data:extend({
  {type = "ammo-category", name = "sta-laser"},
  ammo("sta-laser-round", hit(50), "a"),
  ammo("sta-weak-laser", hit(2), "b"),
  ammo("sta-mega-nuke", {type = "area", radius = 40, action_delivery = {type = "instant",
    target_effects = {{type = "damage", damage = {amount = 5000, type = "explosion"}}}}}, "c"),
  ammo("sta-spawner-round", {type = "direct", action_delivery = {type = "instant",
    target_effects = {{type = "create-entity", entity_name = "small-biter"}}}}, "d"),
  turret,
})

-- QA pass 2026-11-25 additions (each one is used by a scenario in tests/sta-tests/qa2.lua or another suite).

-- C2: an artillery shell shaped like Cerys' neutron bomb. The shell itself only does a small blast (radius 4, more
-- damage than a normal shell, so it would be ranked first), but its projectile creates an explosion whose
-- created_effect carries the real weapon in source_effects: 175 projectiles over radius 12 and an area of radius 200.
-- Smart Turret Ammo must see through that and flag it dangerous. (Names avoid "nuke"/"atomic" on purpose.)
local neutron = table.deepcopy(data.raw.projectile["rocket"])
neutron.name = "sta-neutron"
neutron.action = hit(70)
neutron.final_action = nil
local explosion = table.deepcopy(data.raw.explosion["big-explosion"])
explosion.name = "sta-neutron-explosion"
explosion.created_effect = {type = "direct", action_delivery = {type = "instant", source_effects = {
  {type = "nested-result", repeat_count = 175, action = {type = "area", radius = 12, target_entities = false,
    trigger_from_target = true, action_delivery = {type = "projectile", projectile = "sta-neutron", starting_speed = 1}}},
  {type = "nested-result", action = {type = "area", radius = 200, target_entities = false,
    trigger_from_target = true, action_delivery = {type = "projectile", projectile = "sta-neutron", starting_speed = 1}}},
}}}
local shell_projectile = table.deepcopy(data.raw["artillery-projectile"]["artillery-projectile"])
shell_projectile.name = "sta-neutron-shell-projectile"
shell_projectile.action = {type = "direct", action_delivery = {type = "instant", target_effects = {
  {type = "nested-result", action = {type = "area", radius = 4, action_delivery = {type = "instant", target_effects = {
    {type = "damage", damage = {amount = 1500, type = "physical"}},
    {type = "damage", damage = {amount = 1500, type = "explosion"}}}}}},
  {type = "create-entity", entity_name = "sta-neutron-explosion"},
}}}
shell_projectile.final_action = nil
local neutron_shell = table.deepcopy(data.raw.ammo["artillery-shell"])
neutron_shell.name = "sta-neutron-shell"
neutron_shell.order = "z[sta]-e"
neutron_shell.ammo_type.action.action_delivery.projectile = "sta-neutron-shell-projectile"

-- C2 (the simpler half): a round whose blast sits in its delivery's source_effects instead of target_effects.
local backblast = ammo("sta-backblast-round", {type = "direct", action_delivery = {type = "instant",
  target_effects = {{type = "damage", damage = {amount = 10, type = "physical"}}},
  source_effects = {{type = "nested-result", action = {type = "area", radius = 40, action_delivery = {type = "instant",
    target_effects = {{type = "damage", damage = {amount = 5000, type = "explosion"}}}}}}}}}, "f")

-- R11: a turret that fires the base game's own cannon shells (as a cannon-turret mod would add).
local cannon_turret = table.deepcopy(data.raw["ammo-turret"]["gun-turret"])
cannon_turret.name = "sta-cannon-turret"
cannon_turret.attack_parameters.ammo_category = nil
cannon_turret.attack_parameters.ammo_categories = {"cannon-shell"}

-- R17: a hidden, non-selectable ammo turret, the kind another mod uses as an internal part (a vehicle's gun).
local hidden_turret = table.deepcopy(data.raw["ammo-turret"]["gun-turret"])
hidden_turret.name = "sta-hidden-turret"
hidden_turret.hidden = true
hidden_turret.selectable_in_game = false

data:extend({explosion, neutron, shell_projectile, neutron_shell, backblast, cannon_turret, hidden_turret})

-- C6: Space Exploration's plague bomb does its harm by script, which no prototype walk can see. A stand-in with the
-- same name (a plain rocket) checks that the built-in "never automatic" list knows it. Skipped when the real SE is
-- loaded alongside (the compat runner may do that).
if not data.raw.ammo["se-plague-bomb"] then
  local plague = table.deepcopy(data.raw.ammo["rocket"])
  plague.name = "se-plague-bomb"
  plague.order = "z[sta]-g"
  data:extend({plague})
end
