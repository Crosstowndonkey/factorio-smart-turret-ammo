Gun, rocket, railgun and artillery turrets - and artillery wagons - keep themselves stocked with the **best ammo in reach**. No interfaces, no extra buildings, no inserter spaghetti.

- **On planets**, construction robots bring ammo from your logistic network.
- **On space platforms**, the hub throws it across from its inventory.
- **Upgrades itself:** when your network has a full load of better ammo, the old ammo goes back to storage and the better ammo goes in. Yellow < red < uranium, rocket < explosive rocket, then higher quality.
- **Pick the ammo yourself:** open a turret and use the **Auto-load ammo** panel beside its window. The picker only shows ammo that turret can fire (with quality). **Auto (best)** goes back to automatic. Copy / paste settings copies the choice, and blueprints remember it.

## Works with other mods
- Any modded ammo turret or artillery is handled automatically.
- Every ammo item from every mod is scored by its damage while the game loads (following projectiles, artillery shells, clusters and nested effects; area damage counts for more).
- **Never uses dangerous ammo:** anything that makes a nuclear explosion, spawns units (like the capture robot rocket) or has a blast wider than 10 tiles - from any mod. Ammo you load by hand is left alone.

## Settings (Settings > Mod settings > Map)
| Setting | Default |
|---|---|
| Ammo to keep in each turret (capped at one stack) | 50 |
| Refill when below (% of the amount kept) | 40 |
| Swap worse ammo for better ammo | on |
| Pause requests while a turret is shooting | off |
| Skip turrets fed by inserters | on |
| Turrets checked per tick | 20 |
| Use ammo from other mods | on |
| Never use these ammo items (comma-separated names) | empty |

## Good to know
- Turrets are checked in rotation, at most once a second each, so big bases stay cheap.
- Artillery wagons are only loaded while their train is standing still.
- A turret down to its last few rounds of an ammo that has run out finishes them before switching, so it never swaps back and forth.

## For mod authors
```lua
remote.call("smart-turret-ammo", "set_ammo_score", "my-ammo", 30)    -- use it, as if it did 30 damage
remote.call("smart-turret-ammo", "set_ammo_score", "my-ammo", false) -- never use it
remote.call("smart-turret-ammo", "set_turret_ammo", turret, "piercing-rounds-magazine", "normal") -- lock one turret
```

Source code and tests: [GitHub](https://github.com/Crosstowndonkey/factorio-smart-turret-ammo) (MIT).
