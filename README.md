# Smart Turret Ammo (Factorio 2.1 mod)

Gun, rocket, railgun and artillery turrets (and artillery wagons) keep themselves stocked with the best ammo in
reach - no extra entities, no inserters, no interfaces. Works with other mods' turrets and ammo.

- **On planets** construction robots bring ammo from the logistic network.
- **On space platforms** the hub throws it across from its inventory.
- **Upgrades itself:** when the network has a full load of better ammo, the old ammo goes back to storage and the
  better ammo goes in. Better = more damage (yellow < red < uranium, rocket < explosive rocket), then higher quality.
- **Modded turrets and ammo just work:** any turret the game calls an ammo turret or artillery is handled, and every
  ammo item from every mod is scored by its damage while the game loads (`data-final-fixes.lua`, following
  projectiles, artillery shells, clusters and nested effects; area damage is weighted by its radius).
- **Pick the ammo yourself:** open a turret and use the **Auto-load ammo** panel beside its window - an ammo picker
  (only ammo that turret can fire, with quality) and an **Auto (best)** button. A picked ammo is the only one loaded;
  anything else is swapped out. Copy / paste settings copies the choice, and blueprints remember it.
- **Safe:** ammo that makes a nuclear explosion, spawns units (capture robot rockets, biter-spawning rounds) or has a
  blast wider than 10 tiles is never used - from any mod. Ammo loaded by hand that the mod won't use is left alone.

## How it works
Turrets are checked in rotation (at most once a second each, and at most N per tick). For a turret that is empty,
low, or holding worse ammo than is available, the mod creates an *item request proxy* - the same request a
blueprint makes for modules - and the game's own robots / platform hub deliver it.

## Settings (map settings)
| Setting | Default |
|---|---|
| Ammo to keep in each turret (capped at one stack) | 50 |
| Refill when below (% of the amount kept) | 40 |
| Swap worse ammo for better ammo | on |
| Pause requests while a turret is shooting | off |
| Skip turrets fed by inserters | on |
| Turrets checked per tick | 20 |
| Use ammo from other mods | on |
| Never use these ammo items (comma-separated names) | (empty) |

## For other mods
```lua
remote.call("smart-turret-ammo", "set_ammo_score", "my-ammo", 30)    -- use it, as if it did 30 damage
remote.call("smart-turret-ammo", "set_ammo_score", "my-ammo", false) -- never use it
remote.call("smart-turret-ammo", "set_ammo_score", "my-ammo", nil)   -- back to the automatic score
remote.call("smart-turret-ammo", "get_ammo_info", "my-ammo")         -- {score, danger, allowed}
remote.call("smart-turret-ammo", "set_turret_ammo", turret, "piercing-rounds-magazine", "normal") -- lock one turret
remote.call("smart-turret-ammo", "set_turret_ammo", turret, nil)     -- back to automatic
```

## Development
- `tools/run_tests.sh` - runs the test harness (`tests/sta-tests`, 29 checks) headless in a throwaway folder on a
  fixed, enemy-free map, and prints PASS / FAIL for each behaviour. `tests/sta-fake-content` is a pretend other mod
  (a laser turret, laser rounds, a "mega nuke" and a biter-spawning round). It never touches `~/.factorio`.
- `tools/package.sh` - builds `dist/smart-turret-ammo_<version>.zip` for the mod portal.
