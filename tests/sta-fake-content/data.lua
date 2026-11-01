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
