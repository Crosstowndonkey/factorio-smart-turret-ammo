#!/bin/bash
# Runs the test suites headless in a throwaway folder (never touches ~/.factorio).
# Usage: tools/run_tests.sh [suite ...]        (default: all of them, in this order)
#   main      the original checks (tests/sta-tests/control.lua) and the QA scenarios (qa.lua, qa2.lua), Space Age
#   baseonly  the base game alone: no Space Age, no Quality mod (tests/sta-suites, QA 2026-11-25 C1)
#   settings  map settings changed from their defaults by tests/sta-suites/settings-updates.lua (R11, R8)
#   badpicks  picks with a quality the game doesn't have (R1) - kept apart: a crash ends only this suite
#   removed   a save with a turret picked to an ammo mod's ammo, loaded again without that mod (R2): two phases
#   upgrade   a save made by release 0.1.1 (git a87763d) in the middle of the action - open requests, half-done swaps,
#             scarce ammo, picks (one a quality pick), robots in the air - on a headless server, then loaded with the
#             current code: no errors, picks kept, everything filled and no request stuck within 90 s, reservations
#             sane. (Needs git: the old version is taken from the repo with `git archive`.)
#   upgrade010  the same from release 0.1.0 (git 299c5af)
# (The old way, tools/run_tests.sh /path/to/factorio, still works: an argument that is a file is the game binary.)
#
# Environment (all optional):
#   FACTORIO=<binary>                 the game (default: the Steam install)
#   EXTRA_MODS="<zip or folder> ..."  also load these mods in every suite - e.g. a player's own mod set, to check the
#                                     mod alongside it. They are linked, never changed. (A mod that needs Space Age
#                                     can't load in baseonly: run the other suites by name then.)
#   EXTRA_MODS_FILE=<file>            the same, one path per line (for paths with spaces)
#   STA_SRC=<folder or zip>           the Smart Turret Ammo to test (default: smart-turret-ammo/ in this repo) - e.g.
#                                     dist/smart-turret-ammo_0.1.1.zip, or a folder from `git archive <commit>`
#   UPGRADE_FROM=<folder or zip>      the old version the upgrade suite starts from (default: 0.1.1 from git)
#   KEEP=1                            keep the throwaway folder (its path is printed)
# Exit status 0 only when every suite printed "STA DONE failures=0".
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FACTORIO="${FACTORIO:-/mnt/GamingSSD/SteamLibrary/steamapps/common/Factorio/bin/x64/factorio}"
SUITES=()
for a in "$@"; do if [ -f "$a" ]; then FACTORIO="$a"; else SUITES+=("$a"); fi; done
[ ${#SUITES[@]} -eq 0 ] && SUITES=(main baseonly settings badpicks removed upgrade upgrade010)
STA_SRC="${STA_SRC:-$ROOT/smart-turret-ammo}"

WORK="$(mktemp -d)"
if [ -n "$KEEP" ]; then echo "(work folder: $WORK)"; else trap 'rm -rf "$WORK"' EXIT; fi
mkdir -p "$WORK/mods" "$WORK/write"
link() { ln -s "$1" "$WORK/mods/$(basename "$1")"; }
if [[ "$STA_SRC" == *.zip ]]; then link "$STA_SRC"; else ln -s "$STA_SRC" "$WORK/mods/smart-turret-ammo"; fi
ln -s "$ROOT/tests/sta-tests" "$WORK/mods/sta-tests"
ln -s "$ROOT/tests/sta-fake-content" "$WORK/mods/sta-fake-content"
ln -s "$ROOT/tests/sta-removed-ammo" "$WORK/mods/sta-removed-ammo"
# sta-suites is copied, not linked: suite.lua is written into it for each suite
mkdir -p "$WORK/mods/sta-suites"
\cp -f "$ROOT/tests/sta-suites/"* "$WORK/mods/sta-suites/"
EXTRA=()
for m in $EXTRA_MODS; do EXTRA+=("$m"); done
if [ -n "$EXTRA_MODS_FILE" ]; then while IFS= read -r m; do [ -n "$m" ] && EXTRA+=("$m"); done < "$EXTRA_MODS_FILE"; fi
: > "$WORK/extra-files"
for m in "${EXTRA[@]}"; do link "$m"; basename "$m" >> "$WORK/extra-files"; done

# mod_list <mod names to enable...>: writes mod-list.json naming EVERY mod (Factorio enables any mod in the folder
# that the list leaves out); the extra mods (the files named in $WORK/extra-files) are always enabled.
# (MODS=<folder> writes the list of another mods folder: the upgrade suite's old-version one.)
mod_list() {
  python3 -I - "${MODS:-$WORK/mods}" "$WORK/extra-files" "$@" <<'PY'
import json, os, sys, zipfile
d, want = sys.argv[1], set(sys.argv[3:])
extra_files = set(open(sys.argv[2]).read().split("\n")) - {""}
names = ["base", "space-age", "quality", "elevated-rails", "recycler"]
extra = set()
for f in sorted(os.listdir(d)):
    p = os.path.join(d, f)
    try:
        if f.endswith(".zip"):
            with zipfile.ZipFile(p) as z:
                info = [n for n in z.namelist() if n.count("/") == 1 and n.endswith("/info.json")][0]
                name = json.loads(z.read(info))["name"]
        elif os.path.isdir(p):
            name = json.load(open(os.path.join(p, "info.json")))["name"]
        else:
            continue
    except Exception as e:
        sys.exit("can't read the mod name of %s: %s" % (p, e))
    if name not in names:
        names.append(name)
    if f in extra_files:
        extra.add(name)
mods = [{"name": n, "enabled": n in want or n in extra} for n in names]
json.dump({"mods": mods}, open(os.path.join(d, "mod-list.json"), "w"), indent=1)
PY
}
[ ${#EXTRA[@]} -gt 0 ] && echo "(with extra mods: ${EXTRA[*]})"
SA="base space-age quality elevated-rails recycler"
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$WORK/write" > "$WORK/config.ini"
# mod-settings.dat keeps setting values between runs; removed before each run so every suite starts from the defaults
run() { \rm -f "$WORK/mods/mod-settings.dat"; "$FACTORIO" -c "$WORK/config.ini" --mod-directory "$WORK/mods" "$@"; }
report() {  # report <log>...: the STA (and PROBE) lines, and any error
  grep -h -E "^(STA|PROBE)" "$@" || true  # (PROBE: lines from probe mods loaded with EXTRA_MODS)
  if grep -qE "Error|non-recoverable" "$@"; then grep -h -E -A12 "Error|non-recoverable" "$@" | head -40; fi
}

# upgrade_save <suite> <old Smart Turret Ammo: folder or zip>: makes $WORK/write/saves/sta-midaction.zip - the
# scene built (--create) and run on a headless server with the OLD version until the scene saves at tick 900
# (game.server_save), then the server is stopped (by its PID).
upgrade_save() {
  local suite="$1" old="$2" om="$WORK/old-mods-$1"
  rm -rf "$om"; mkdir -p "$om"
  if [[ "$old" == *.zip ]]; then ln -s "$old" "$om/$(basename "$old")"; else ln -s "$old" "$om/smart-turret-ammo"; fi
  ln -s "$WORK/mods/sta-suites" "$om/sta-suites"
  for m in "${EXTRA[@]}"; do ln -s "$m" "$om/$(basename "$m")"; done
  MODS="$om" mod_list $SA smart-turret-ammo sta-suites
  \rm -f "$om/mod-settings.dat" "$WORK/write/saves/sta-midaction.zip"
  mkdir -p "$WORK/write/saves" # (server_save fails if the folder is missing)
  "$FACTORIO" -c "$WORK/config.ini" --mod-directory "$om" --create "$WORK/$suite-old.zip" \
    --map-gen-settings "$ROOT/tests/map-gen-settings.json" > "$WORK/$suite-create.log" 2>&1 || return 1
  printf '{"name":"sta-upgrade","description":"","tags":[],"max_players":0,"visibility":{"public":false,"lan":false},"require_user_verification":false,"auto_pause":false,"autosave_interval":0,"non_blocking_saving":false,"game_password":""}' > "$WORK/server.json"
  "$FACTORIO" -c "$WORK/config.ini" --mod-directory "$om" --start-server "$WORK/$suite-old.zip" \
    --server-settings "$WORK/server.json" --port 34297 < /dev/null > "$WORK/$suite-server.log" 2>&1 &
  local pid=$! waited=0
  # the server runs in real time: tick 900 is ~15 s after it starts; give it 120 s
  while [ $waited -lt 120 ] && kill -0 $pid 2>/dev/null; do
    grep -q "STA fact: saved at tick" "$WORK/$suite-server.log" && grep -q "Saving finished" "$WORK/$suite-server.log" && break
    sleep 1; waited=$((waited + 1))
  done
  kill -INT $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  [ -f "$WORK/write/saves/sta-midaction.zip" ]
}

FAILED=0; PASSES=0; FAILS=0
for suite in "${SUITES[@]}"; do
  echo "=== $suite"
  printf -- '-- written by tools/run_tests.sh\nreturn "%s"\n' "$suite" > "$WORK/mods/sta-suites/suite.lua"
  ticks=2000
  case $suite in
    main) mod_list $SA smart-turret-ammo sta-fake-content sta-suites sta-tests; ticks=6100 ;;
    baseonly) mod_list base smart-turret-ammo sta-suites ;;
    settings) mod_list $SA smart-turret-ammo sta-fake-content sta-suites ;;
    badpicks) mod_list $SA smart-turret-ammo sta-suites ;;
    removed) mod_list $SA smart-turret-ammo sta-removed-ammo sta-suites; ticks=700 ;;
    upgrade|upgrade010)
      if [ $suite = upgrade ]; then commit=a87763d; else commit=299c5af; fi
      old="$WORK/old-$suite/smart-turret-ammo"
      if [ $suite = upgrade ] && [ -n "$UPGRADE_FROM" ]; then old="$UPGRADE_FROM"
      else mkdir -p "$WORK/old-$suite"; git -C "$ROOT" archive "$commit" smart-turret-ammo | tar -x -C "$WORK/old-$suite"; fi
      if ! upgrade_save $suite "$old"; then
        report "$WORK/$suite-create.log" "$WORK/$suite-server.log" 2>/dev/null; tail -20 "$WORK/$suite-server.log" 2>/dev/null
        echo "STA FAIL $suite: the old version's save could not be made"; FAILED=1; FAILS=$((FAILS + 1)); continue
      fi
      grep -h "^STA" "$WORK/$suite-server.log" || true
      grep -v "Got EOF on stdin" "$WORK/$suite-server.log" | grep -E -A12 "Error|non-recoverable" | head -30 || true
      \cp -f "$WORK/write/saves/sta-midaction.zip" "$WORK/$suite.zip"
      mod_list $SA smart-turret-ammo sta-suites
      run --benchmark "$WORK/$suite.zip" --benchmark-ticks 5600 --benchmark-runs 1 > "$WORK/$suite.log" 2>&1 || true
      log="$WORK/$suite.log"; report "$log"
      PASSES=$((PASSES + $(grep -c "^STA PASS" "$log" || true))); FAILS=$((FAILS + $(grep -c "^STA FAIL" "$log" || true)))
      if ! grep -q "^STA DONE failures=0" "$log"; then
        FAILED=1
        grep -q "^STA DONE" "$log" || { echo "STA FAIL $suite: the run ended before its checks (a crash? see the error above)"; FAILS=$((FAILS + 1)); }
      fi
      continue ;;
    *) echo "STA FAIL unknown suite '$suite' (main baseonly settings badpicks removed upgrade upgrade010)"; FAILED=1; FAILS=$((FAILS + 1)); continue ;;
  esac
  log="$WORK/$suite.log"
  if ! run --create "$WORK/$suite.zip" --map-gen-settings "$ROOT/tests/map-gen-settings.json" > "$WORK/$suite-create.log" 2>&1; then
    tail -30 "$WORK/$suite-create.log"; echo "STA FAIL $suite: the map could not be created"
    FAILED=1; FAILS=$((FAILS + 1)); continue
  fi
  # removed, phase 2: the same save, with the ammo mod gone
  [ "$suite" = removed ] && mod_list $SA smart-turret-ammo sta-suites
  run --benchmark "$WORK/$suite.zip" --benchmark-ticks $ticks --benchmark-runs 1 > "$log" 2>&1 || true
  report "$WORK/$suite-create.log" "$log"
  PASSES=$((PASSES + $(grep -c "^STA PASS" "$log" || true)))
  FAILS=$((FAILS + $(grep -c "^STA FAIL" "$log" || true)))
  if ! grep -q "^STA DONE failures=0" "$log"; then
    FAILED=1
    if ! grep -q "^STA DONE" "$log"; then
      echo "STA FAIL $suite: the run ended before its checks (a crash? see the error above)"; FAILS=$((FAILS + 1))
    fi
  fi
done
echo "=== $PASSES passed, $FAILS failed"
[ $FAILED = 0 ] && echo "=== ALL PASSED" || { echo "=== SOME FAILED"; exit 1; }
