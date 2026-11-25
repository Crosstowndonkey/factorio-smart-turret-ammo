-- The settings suite changes Smart Turret Ammo's map-setting defaults here (scripts can't change another mod's
-- settings): "Use ammo from other mods" off, for R11. Other suites leave every setting at its default.
if require("suite") == "settings" then
  data.raw["bool-setting"]["sta-use-modded-ammo"].default_value = false
end
