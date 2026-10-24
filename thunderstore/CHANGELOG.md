## 1.3.2
- Fixed: players using modded species (for example "Awesome Possum") were treated as attackers because their species' sound names have spaces. Only sound names that can reach another node (containing / . : @ %) are refused now.

## 1.3.1
- Fixes a false positive: the game sends the level-up bubble with no values, and 1.3.0 treated that as an attack and blocked the player who levelled up. Empty level-up bubbles are now allowed.

## 1.3.0
- Log flood fallback: the game writes whole malformed packets into godot.log, which a griefer can use to fill your disk
  without sending anything this mod could inspect. If godot.log suddenly grows by several MB, the player sending the
  most packets is blocked (you can unhide them in the game's player list). If it can't tell who, you get a warning.

## 1.2.0
- Blocks the wipe exploit: a griefer could tell your game to delete your own character or the props you placed. Wipes
  aimed at your character or your props now get the sender blocked. Normal wipes (fish spots and the like) still work.

## 1.1.0
- Closes a gap in the sound attack: the sound name can be sent as a node path instead of text, which skipped the old check
  and still moved things in your game (the map vanishing). Node paths and objects are now blocked anywhere in an action,
  and sound/particle/emote/talk/bubble actions must carry text where text is expected.

## 1.0.0
- First release.
