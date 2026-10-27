# Griefer Shield

Protects you from the packets griefers send to attack other players, on any server.

*This mod was created with the assistance of AI.*

## What it stops

- **The sound exploit.** A griefer sends a "sound" whose name is really a path into your game, which moves things
  around: the map vanishes or the whole screen goes white. Griefer Shield only lets real sound names through.
- **Log floods that fill your disk.** The game writes every sound it receives into its log file. Sounds and actions
  stuffed with huge amounts of text make that file grow until the disk is full, and a full disk wipes your save the
  next time the game saves. Griefer Shield drops anything with oversized text.
- **Action floods.** Actions aimed at characters that aren't there pile up, and once there are more than 128 the game
  dumps the whole pile into the log for every new packet. Griefer Shield never lets that pile grow.

Whoever sends one of these is put on the game's own **hidden** list, so your game ignores everything they send from
then on, and you get a notification saying who was blocked and why. You can unhide someone in the game's player list.

## Your saves

- It keeps its own copies of your save slots (the newest 5 of each, only when the save changed). If a save is ever
  broken, for example by a full disk, it puts the newest good copy back when the game starts and tells you so.
- At start it also deletes old log files bigger than 50 MB, so an attack can't keep your disk full.

- **Decompression bombs.** A tiny packet that unpacks to gigabytes crashes the game while it is being read, before any
  script mod can look at it. The game unpacks packets with no size limit; Griefer Shield (its GrieferShield.dll part)
  sets one, so such a packet is refused and the game carries on. Servers can also ban the sender: Ether's Wolf Park does.

## What it can't stop

Attacks that only look like normal packets, such as chat spam. Griefer Shield blocks the known tricks, not every
possible one.

## License

[MIT](LICENSE): you are free to copy, change and share your own versions.
