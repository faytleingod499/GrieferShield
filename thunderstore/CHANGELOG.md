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
