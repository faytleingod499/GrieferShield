# Griefer Shield

A client mod (for [GDWeave](https://thunderstore.io/c/webfishing/p/NotNet/GDWeave/)) that protects players from attack
packets. See `thunderstore/README.md` for what players see.

*This mod was created with the assistance of AI.*

## How it works
- Runs every frame after the game reads its packets and before any actor acts on them: it sets the `Network` autoload's
  `process_priority` to -100 and its own to -50 (actors are 0). It goes through `Network.ACTOR_ACTIONS` (actor id ->
  list of `[action, params, sender]`) and removes:
  - `_play_sfx` whose sound name isn't `^[A-Za-z0-9_-]{1,48}$` (the game uses it as a node path in `sound_manager`
    and moves the node: map vanishes, white screen),
  - any action with more than 4096 characters of text anywhere in its params, or a name over 256 characters
    (`_play_sfx` prints every received sound into godot.log),
  - for an actor id with no actor in group `actor`: everything but the newest 32 (the game dumps the whole queue into
    the log for every packet once it passes 128). More than 100 dropped from one player in a minute is an attack.
- An attacker is appended to `PlayerData.players_hidden`; `Network._read_P2P_Packet` drops everything from hidden players
  before reading it. The list is part of the save, so they stay blocked. Never the player's own id.
- Saves: every 2 minutes, a slot whose file changed and loads (`get_var` gives a dictionary with `inventory`) is copied to
  `user://griefershield_backups/slot<n>_<unix time>.sav`, newest 5 kept. At start, a slot whose save and the game's own
  `.backup` both fail to load gets the newest good copy written back to both (the game writes both at once, so a full
  disk breaks both).
- At start, `.log` files other than the current one in the log folder that are over 50 MB are deleted.
- Not covered: `decompress_dynamic(-1, ...)` in `_read_P2P_Packet` has no size limit, so a decompression bomb crashes
  the game before any mod runs. The server's Packet Guard (Cove fork) bans the sender.
- Test: `/home/claude/godot/pettest/e_shield.gd`.

## Building
```
PCK_OUT=$PWD/package/GrieferShield/GrieferShield.pck PCK_SRC_DIR=$PWD/source/mods/GrieferShield godot --path <any project> -s pack.gd
./build.sh
```

## License
[MIT](LICENSE)
