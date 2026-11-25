-- An "other mod's" bullet ammo (a copy of red). The removed suite makes a save with a turret picked to it, then
-- loads that save without this mod - as a player does who removes an ammo mod.
local round = table.deepcopy(data.raw.ammo["piercing-rounds-magazine"])
round.name = "sta-removed-round"
round.order = "z[sta]-removed"
data:extend({round})
