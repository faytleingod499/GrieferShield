extends Node

# Griefer Shield
# Protects you from the packets griefers send to attack other players, on any server:
#  - the sound exploit: "_play_sfx" with a node path for a sound name, which moves things in your game (the map
#    vanishes, the screen goes white) and writes errors into your log
#  - the log flood: actions full of huge text, which the game prints into godot.log until the disk is full (and a full
#    disk wipes the save the game is writing)
#  - the action queue flood: actions for characters that aren't there, which pile up until the game dumps the whole pile
#    into the log for every new packet
# Whoever sends one is put on the game's own "hidden" list, which drops everything they send before the game reads it
# (you can unhide them in the game's player list). Every action is checked after the game receives it and before your
# game acts on it.
# It also keeps its own copies of your save slots and puts a broken save back when the game starts, and deletes
# oversized old log files, so an attack can't cost you your save or your disk space.
# What it can't stop: a "decompression bomb" crashes the game while it unpacks the packet, before any mod sees it.
# A server running Packet Guard bans whoever sends one.

const VERSION = "1.3.2"
const MAX_TEXT = 4096              # the longest text the real game ever sends in an action is a chat bubble (~512)
const MAX_ACTION_NAME = 256
const KEEP_FOR_MISSING = 32        # actions kept for a character that isn't here (yet): the game dumps the pile past 128
const MISSING_LIMIT = 100          # more dropped than this in a minute from one player is an attack
const BACKUP_DIR = "user://griefershield_backups/"
const BACKUPS_KEPT = 5             # per save slot
const BACKUP_EVERY = 120.0         # seconds; only when the save changed
const SLOTS = 4
const BIG_LOG = 50 * 1024 * 1024   # old log files bigger than this are deleted at start
const LOG_CHECK_EVERY = 2.0        # seconds
const LOG_ALARM = 6 * 1024 * 1024  # the log growing faster than this in one check is an attack (a normal session writes a few KB)

var safe_sound = RegEx.new()
var blocked = {}        # steam id -> why, this session
var missing_drops = {}  # steam id -> [minute start, count]
var backup_timer = 0.0
var backup_seen = {}    # slot -> modified time of the save last backed up
var pending_notes = []  # shown once the game can show notifications
var clock = 0.0
var log_timer = 0.0
var log_size_before = -1
var log_noted = false


func _ready():
	# modded species name their sounds after the species ("bark_Awesome Possum_species_possum"), so spaces and accents are normal;
	# what a node path needs is / . : @ or %, and those (and control characters) are what gets refused
	safe_sound.compile("^[^/\\\\.:@%\"\\x00-\\x1f]{1,96}$")
	# Run after the game reads its packets and before any character acts on them: the network reads first, then this,
	# then everything else.
	var net = get_node_or_null("/root/Network")
	if net != null:
		net.process_priority = -100
	process_priority = -50
	_clean_logs()
	_restore_broken_saves()
	_backup_saves()


func _process(delta):
	clock += delta
	_scan_actions()
	backup_timer += delta
	if backup_timer >= BACKUP_EVERY:
		backup_timer = 0.0
		_backup_saves()
	_show_notes()
	log_timer += delta
	if log_timer >= LOG_CHECK_EVERY:
		log_timer = 0.0
		_watch_log()


# --- the log filling up ---
# The game prints whole packets into godot.log when it thinks they're malformed, and those never reach the action queue
# above. When the log suddenly grows, whoever is sending the most packets is the likely source and gets blocked.

func _current_log():
	var log_path = str(ProjectSettings.get_setting("logging/file_logging/log_path"))
	if log_path == "" or log_path == "Null":
		log_path = "user://logs/godot.log"
	return log_path


func _watch_log():
	var file = File.new()
	var path = _current_log()
	if not file.file_exists(path) or file.open(path, File.READ) != OK:
		return
	var size = file.get_len()
	file.close()
	var grew = size - log_size_before if log_size_before >= 0 else 0
	log_size_before = size
	if grew < LOG_ALARM:
		return
	var net = get_node_or_null("/root/Network")
	if net == null or typeof(net.get("FLUSH_PACKET_INFORMATION")) != TYPE_DICTIONARY:
		return
	var owner_id = 0
	if Engine.has_singleton("Steam") and int(net.get("STEAM_LOBBY_ID")) > 0:
		var steam = Engine.get_singleton("Steam")
		if steam.has_method("getLobbyOwner"):
			owner_id = int(steam.getLobbyOwner(net.STEAM_LOBBY_ID))
	var best = 0
	var best_count = 0
	for sender in net.FLUSH_PACKET_INFORMATION.keys():
		var id = int(sender)
		if id == int(net.STEAM_ID) or id == owner_id or blocked.has(id):
			continue
		var count = int(net.FLUSH_PACKET_INFORMATION[sender])
		if count > best_count:
			best = id
			best_count = count
	if best != 0 and best_count >= 20:
		_block(best, "the log flood (godot.log grew " + str(grew / (1024 * 1024)) + " MB in a few seconds while they were sending " + str(best_count) + " packets)")
	elif not log_noted:
		log_noted = true
		pending_notes.append("Your godot.log is growing very fast (" + str(grew / (1024 * 1024)) + " MB in a few seconds) and Griefer Shield could not tell who is doing it. Leave the game and free some disk space if it keeps going.")


# --- checking every action before the game runs it ---

func _scan_actions():
	var net = get_node_or_null("/root/Network")
	if net == null:
		return
	var queues = net.get("ACTOR_ACTIONS")
	if typeof(queues) != TYPE_DICTIONARY or queues.empty():
		return
	var here = {}
	for actor in get_tree().get_nodes_in_group("actor"):
		here[actor.get("actor_id")] = actor
	for actor_id in queues.keys():
		var queue = queues[actor_id]
		if typeof(queue) != TYPE_ARRAY or queue.empty():
			continue
		var keep = []
		for entry in queue:
			if typeof(entry) != TYPE_ARRAY or entry.size() < 3:
				continue
			var sender = int(entry[2])
			if blocked.has(sender):
				continue
			var why = _attack_in(entry, here)
			if why != "":
				_block(sender, why)
				continue
			keep.append(entry)
		# a character that isn't here: keep only the newest few, the rest would pile up and be dumped into the log
		if not here.has(actor_id) and keep.size() > KEEP_FOR_MISSING:
			var dropped = keep.size() - KEEP_FOR_MISSING
			for i in range(dropped):
				_count_missing(int(keep[i][2]))
			keep = keep.slice(dropped, keep.size() - 1)
		if keep.size() != queue.size():
			queues[actor_id] = keep


# what's wrong with one action, or "" when it's fine
func _attack_in(entry, here = {}):
	var action = entry[0]
	if typeof(action) != TYPE_STRING:
		return ""
	if action.length() > MAX_ACTION_NAME:
		return "an action with a " + str(action.length()) + " character name"
	var params = entry[1]
	# a node path (or an object) anywhere: the game never sends one, and as a sound name it moves any node in your game
	if _has_forbidden(params, 0):
		return "the sound exploit (a node path sent as a value in " + action.left(40) + ")"
	if action == "_wipe_actor":
		var why = _bad_wipe(params, here)
		if why != "":
			return why
	if action == "_play_sfx":
		var sound = null
		if typeof(params) == TYPE_ARRAY and params.size() > 0:
			sound = params[0]
		if sound != null and typeof(sound) != TYPE_STRING:
			return "the sound exploit (a sound name that is not text)"
		if typeof(sound) == TYPE_STRING and safe_sound.search(sound) == null:
			return "the sound exploit (a sound named \"" + sound.left(40) + "\")"
	# names looked up in the game's lists and nodes must be text
	if action in ["_play_particle", "_face_emote", "_talk", "_sync_create_bubble", "_sync_level_bubble"]:
		# the game sends the level-up bubble with no values at all, so that one may be empty
		var may_be_empty = action == "_sync_level_bubble"
		if typeof(params) != TYPE_ARRAY:
			return "the wrong kind of value in " + action.left(40)
		if params.size() == 0:
			if not may_be_empty:
				return "the wrong kind of value in " + action.left(40)
		elif typeof(params[0]) != TYPE_STRING:
			return "the wrong kind of value in " + action.left(40)
	var longest = _longest_text(params, 0)
	if longest > MAX_TEXT:
		return "the log flood (" + str(longest) + " characters of text in " + action.left(40) + ")"
	return ""


# "_wipe_actor" deletes an actor in the game of whoever owns it. The real game uses it on a fish spot, a mound, a bug or a
# prop it placed itself, never on a player. A griefer sends it for another player's character or their props.
func _bad_wipe(params, here):
	if typeof(params) != TYPE_ARRAY or params.size() != 1 or typeof(params[0]) != TYPE_INT:
		return "the wipe exploit (a wipe without a plain actor number)"
	var target = here.get(params[0], null)
	if target == null or not is_instance_valid(target):
		return ""
	if not target.get("controlled"):
		return "" # not ours, the game ignores it anyway
	var kind = str(target.get("actor_type"))
	if kind == "player":
		return "the wipe exploit (tried to delete your character)"
	var world = target.get("world")
	if world != null and typeof(world.get("ACTOR_BANK")) == TYPE_DICTIONARY:
		var bank = world.ACTOR_BANK.get(kind, null)
		if bank != null and bank.size() > 1 and bank[1]:
			return "" # a fish spot, a metal spot...: only the host has them, and players do wipe those
	return "the wipe exploit (tried to delete your " + kind.left(30) + ")"


func _has_forbidden(value, depth):
	if depth > 16:
		return false
	match typeof(value):
		TYPE_NODE_PATH, TYPE_OBJECT, TYPE_RID:
			return true
		TYPE_ARRAY:
			for item in value:
				if _has_forbidden(item, depth + 1):
					return true
		TYPE_DICTIONARY:
			for key in value.keys():
				if _has_forbidden(key, depth + 1) or _has_forbidden(value[key], depth + 1):
					return true
	return false


func _longest_text(value, depth):
	if depth > 16:
		return 0
	match typeof(value):
		TYPE_STRING:
			return value.length()
		TYPE_ARRAY:
			var longest = 0
			for item in value:
				longest = max(longest, _longest_text(item, depth + 1))
			return longest
		TYPE_DICTIONARY:
			var longest = 0
			for key in value.keys():
				longest = max(longest, max(_longest_text(key, depth + 1), _longest_text(value[key], depth + 1)))
			return longest
		TYPE_STRING_ARRAY:
			var longest = 0
			for item in value:
				longest = max(longest, item.length())
			return longest
	return 0


func _count_missing(sender):
	var entry = missing_drops.get(sender, [clock, 0])
	if clock - entry[0] > 60.0:
		entry = [clock, 0]
	entry[1] += 1
	missing_drops[sender] = entry
	if entry[1] > MISSING_LIMIT:
		_block(sender, "the action queue flood (actions for characters that aren't there)")


# onto the game's hidden list: the game drops everything they send before reading it
func _block(sender, why):
	var net = get_node_or_null("/root/Network")
	var data = get_node_or_null("/root/PlayerData")
	if sender <= 0 or (net != null and sender == int(net.STEAM_ID)) or blocked.has(sender):
		return
	blocked[sender] = why
	if data != null and typeof(data.get("players_hidden")) == TYPE_ARRAY and not data.players_hidden.has(sender):
		data.players_hidden.append(sender)
	var name = _name_of(sender)
	print("[GrieferShield] blocked ", name, " (", sender, "): ", why)
	pending_notes.append("Griefer Shield blocked " + name + ": " + why)


func _name_of(id):
	var net = get_node_or_null("/root/Network")
	if net != null and typeof(net.get("LOBBY_MEMBERS")) == TYPE_ARRAY:
		for member in net.LOBBY_MEMBERS:
			if int(member.get("steam_id", 0)) == id:
				return str(member.get("steam_name", id))
	if Engine.has_singleton("Steam"):
		var steam = Engine.get_singleton("Steam")
		if steam.has_method("getFriendPersonaName"):
			var name = str(steam.getFriendPersonaName(id))
			if name != "" and name != "[unknown]":
				return name
	return str(id)


func _show_notes():
	if pending_notes.empty():
		return
	var data = get_node_or_null("/root/PlayerData")
	if data == null or not data.has_method("_send_notification") or get_tree().get_nodes_in_group("controlled_player").empty():
		return # in the menus: shown once the game is on
	for note in pending_notes:
		data._send_notification(note, 1)
	pending_notes = []


# --- saves ---

func _slot_path(slot):
	return "user://webfishing_save_slot_" + str(slot) + ".sav"


func _game_backup_path(slot):
	return "user://webfishing_backup_save_slot_" + str(slot) + ".backup"


# a save the game can load: it reads back as a dictionary with an inventory
func _valid_save(path):
	var file = File.new()
	if not file.file_exists(path) or file.open(path, File.READ) != OK:
		return false
	if file.get_len() < 16:
		file.close()
		return false
	var data = file.get_var()
	file.close()
	return typeof(data) == TYPE_DICTIONARY and data.has("inventory")


func _copies_of(slot):
	var out = []
	var dir = Directory.new()
	if dir.open(BACKUP_DIR) != OK:
		return out
	dir.list_dir_begin(true, true)
	var name = dir.get_next()
	var prefix = "slot" + str(slot) + "_"
	while name != "":
		if name.begins_with(prefix) and name.ends_with(".sav"):
			out.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	out.sort() # the names carry the time, so this is oldest first
	return out


func _backup_saves():
	var dir = Directory.new()
	if dir.make_dir_recursive(BACKUP_DIR) != OK and not dir.dir_exists(BACKUP_DIR):
		return
	var file = File.new()
	for slot in range(SLOTS):
		var path = _slot_path(slot)
		if not file.file_exists(path):
			continue
		var changed = file.get_modified_time(path)
		if backup_seen.get(slot, -1) == changed:
			continue
		if not _valid_save(path):
			continue # never keep a broken one
		var target = BACKUP_DIR + "slot" + str(slot) + "_" + str(OS.get_unix_time()) + ".sav"
		if dir.copy(path, target) == OK and _valid_save(target):
			backup_seen[slot] = changed
			var copies = _copies_of(slot)
			while copies.size() > BACKUPS_KEPT:
				dir.remove(BACKUP_DIR + copies.pop_front())
		elif dir.file_exists(target):
			dir.remove(target) # a copy that came out broken (full disk) would only get in the way


# Both the save and the game's own backup are broken (the game writes both at once, so a full disk breaks both):
# put the newest good copy back before the game loads the slot.
func _restore_broken_saves():
	var dir = Directory.new()
	for slot in range(SLOTS):
		var path = _slot_path(slot)
		var game_backup = _game_backup_path(slot)
		if not dir.file_exists(path) and not dir.file_exists(game_backup):
			continue # an empty slot, nothing to mend
		if _valid_save(path) or _valid_save(game_backup):
			continue # the game can load it
		var copies = _copies_of(slot)
		while not copies.empty():
			var newest = BACKUP_DIR + copies.pop_back()
			if _valid_save(newest):
				if dir.copy(newest, path) == OK:
					dir.copy(newest, game_backup)
					var when = OS.get_datetime_from_unix_time(int(newest.get_file().get_basename().split("_")[1]))
					var text = "Griefer Shield restored your save slot %d from a copy made %04d-%02d-%02d %02d:%02d (UTC)" % [
						slot + 1, when["year"], when["month"], when["day"], when["hour"], when["minute"]]
					print("[GrieferShield] ", text)
					pending_notes.append(text)
				break


# --- the log ---

# Old logs filled by an attack would keep the disk full; the current one can't be removed while the game writes it.
func _clean_logs():
	var log_path = str(ProjectSettings.get_setting("logging/file_logging/log_path"))
	if log_path == "" or log_path == "Null":
		log_path = "user://logs/godot.log"
	var folder = log_path.get_base_dir()
	var current = log_path.get_file()
	var dir = Directory.new()
	if dir.open(folder) != OK:
		return
	var removed = 0
	var freed = 0
	dir.list_dir_begin(true, true)
	var name = dir.get_next()
	var big = []
	while name != "":
		if name != current and name.ends_with(".log"):
			var file = File.new()
			if file.open(folder + "/" + name, File.READ) == OK:
				var size = file.get_len()
				file.close()
				if size > BIG_LOG:
					big.append([name, size])
		name = dir.get_next()
	dir.list_dir_end()
	for entry in big:
		if dir.remove(folder + "/" + entry[0]) == OK:
			removed += 1
			freed += entry[1]
	if removed > 0:
		var text = "Griefer Shield deleted %d oversized old log file(s), freeing %d MB" % [removed, freed / (1024 * 1024)]
		print("[GrieferShield] ", text)
		pending_notes.append(text)
