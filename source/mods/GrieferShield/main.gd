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
# The decompression bomb (a tiny packet that unpacks to gigabytes and crashes the game while it is being read, before any
# script sees it) is stopped by the C# part of this mod (GrieferShield.dll), which puts a size limit on the game's unpacking.
# A server running Packet Guard also bans whoever sends one.

const VERSION = "1.5.0"
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

# the black box: every packet received is written to a file as it arrives (see "the black box" below)
const BB_FILE = "user://griefershield_blackbox.log"
const BB_OLD = "user://griefershield_blackbox_old.log"
const BB_SUSPECTS = "user://griefershield_suspects.log"
const BB_MAX = 3 * 1024 * 1024        # the black box is cut at this size (the old half is kept): the last few minutes
const BB_SUSPECTS_MAX = 256 * 1024
const BB_CRASHES_KEPT = 3
const BB_LINE_MAX = 600
const BB_KNOWN_TYPES = ["handshake", "handshake_request", "server_close", "peer_was_kicked", "client_was_kicked", "peer_was_banned",
	"client_was_banned", "request_actors", "actor_request_send", "instance_actor", "actor_update", "actor_animation_update",
	"actor_action", "message", "letter_recieved", "letter_was_accepted", "letter_was_denied", "chalk_packet", "new_player_join",
	"player_punch", "user_joined_weblobby", "user_left_weblobby", "receive_weblobby", "request_ping", "arena_join"]
const BB_BIG_TYPES = ["chalk_packet", "actor_request_send", "receive_weblobby", "request_actors"]

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
var bb = null            # the black box file, open for the whole session
var bb_bytes = 0
var bb_size = 0          # compressed size of the packet being read
var bb_claimed = -1
var bb_sender = 0
var bb_members = {}      # steam id -> name, for the join/leave lines
var bb_closed = false
var bb_open = false      # a packet was started but not finished (the game stopped, or refused it, while unpacking)


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
	_bb_start()


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
		_bb_watch_members()


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


# --- the black box ---
# The game reads and unpacks each packet in one go, so if a packet kills the game there is nothing left to show which one.
# The C# part of this mod (GrieferShield.dll) makes the game call blackbox() just before it unpacks a packet and
# blackbox_packet() right after, and every packet is written to user://griefershield_blackbox.log as it arrives (the file is
# flushed each time, so it survives a crash). The line is started before the packet is unpacked and finished after, so if
# the game dies while unpacking, the last line of the file is the unfinished one and names the sender.
#   <ms> <sender> <packed bytes> <size the packet claims to unpack to> | <type> <key>=<value>...  [!flag ...]
# Values: s<length>:"text" i<number> f<number> b<0/1> v2/v3 a<count>[...] d<count>{...} NODEPATH! OBJECT!
# At the next start, if the file doesn't end with EXIT the game did not close normally: the file is copied to
# griefershield_crash_<time>.log, you get a notification, and if the game died while unpacking a packet its sender is hidden.
# Packets that look wrong (not packed, absurd size, a type the game doesn't have, text over 1000 chars, node paths) are also
# written to griefershield_suspects.log, which is kept.

func _bb_start():
	_bb_check_last_session()
	var dir = Directory.new()
	if dir.file_exists(BB_FILE):
		dir.rename(BB_FILE, BB_OLD) if not dir.file_exists(BB_OLD) else dir.copy(BB_FILE, BB_OLD)
	bb = File.new()
	if bb.open(BB_FILE, File.WRITE) != OK:
		bb = null
		return
	bb_bytes = 0
	_bb_line("START " + VERSION + " " + str(OS.get_unix_time()))


func _bb_put(text):
	if bb == null:
		return
	bb.store_string(text)
	bb.flush()
	bb_bytes += text.length()


func _bb_line(text):
	_bb_put(text + "\n")
	if bb_bytes > BB_MAX:
		_bb_rotate()


func _bb_rotate():
	if bb == null:
		return
	bb.close()
	var dir = Directory.new()
	if dir.file_exists(BB_OLD):
		dir.remove(BB_OLD)
	dir.rename(BB_FILE, BB_OLD)
	bb = File.new()
	if bb.open(BB_FILE, File.WRITE) != OK:
		bb = null
		return
	bb_bytes = 0


# called by the game's packet reader just before it unpacks a packet
func blackbox(sender, payload):
	if bb == null or typeof(payload) != TYPE_RAW_ARRAY:
		return
	var n = payload.size()
	var claimed = -1
	if n >= 4:
		# the last four bytes of a gzip stream say how big it unpacks to (a liar can write anything, but it's a hint)
		claimed = payload[n - 4] | (payload[n - 3] << 8) | (payload[n - 2] << 16) | (payload[n - 1] << 24)
	if bb_open:
		_bb_line(" | UNFINISHED (the game stopped reading that packet)")
	bb_open = true
	bb_sender = int(sender)
	bb_size = n
	bb_claimed = claimed
	var text = str(OS.get_system_time_msecs()) + " " + str(bb_sender) + " " + str(n) + " " + str(claimed)
	if n < 18 or payload[0] != 0x1f or payload[1] != 0x8b:
		text += " NOTGZIP"
	_bb_put(text)


# called right after the packet is unpacked and read
func blackbox_packet(sender, data):
	if bb == null:
		return
	bb_open = false
	var flags = []
	var summary = _bb_summary(data, flags)
	if bb_size > 20000:
		flags.append("!bigpacket")
	if bb_claimed > 262144 and not (typeof(data) == TYPE_DICTIONARY and str(data.get("type", "")) in BB_BIG_TYPES):
		flags.append("!bigclaim")
	var line = " | " + summary
	if not flags.empty():
		line += "  " + " ".join(flags)
	_bb_line(line)
	if not flags.empty():
		_bb_suspect(str(OS.get_system_time_msecs()) + " " + str(bb_sender) + " " + str(bb_size) + " " + str(bb_claimed) + line)


func _bb_suspect(text):
	var file = File.new()
	var dir = Directory.new()
	if file.file_exists(BB_SUSPECTS) and file.open(BB_SUSPECTS, File.READ) == OK:
		var size = file.get_len()
		file.close()
		if size > BB_SUSPECTS_MAX:
			dir.remove(BB_SUSPECTS)
	var mode = File.READ_WRITE if file.file_exists(BB_SUSPECTS) else File.WRITE
	if file.open(BB_SUSPECTS, mode) != OK:
		return
	file.seek_end()
	file.store_line(text.left(BB_LINE_MAX * 2))
	file.close()


func _bb_safe(text, max_len):
	var out = ""
	var shown = text.left(max_len)
	for i in range(shown.length()):
		var code = shown.ord_at(i)
		out += "?" if code < 32 or code == 127 or code == 124 else shown[i]
	if text.length() > max_len:
		out += "..."
	return out


func _bb_summary(data, flags):
	if typeof(data) != TYPE_DICTIONARY:
		flags.append("!notdict")
		return "NOTDICT t" + str(typeof(data))
	var kind = data.get("type", null)
	var out = ""
	if typeof(kind) != TYPE_STRING:
		flags.append("!notype")
		out = "NOTYPE"
	else:
		out = _bb_safe(kind, 40)
		if not kind in BB_KNOWN_TYPES:
			flags.append("!unknowntype")
	var keys = data.keys()
	var shown = 0
	for k in keys:
		if typeof(k) == TYPE_STRING and k == "type":
			continue
		shown += 1
		if shown > 14:
			out += " ...+" + str(keys.size() - 14)
			break
		out += " " + _bb_safe(str(k), 24) + "=" + _bb_describe(data[k], 0, flags)
		if out.length() > BB_LINE_MAX:
			out = out.left(BB_LINE_MAX) + "..."
			break
	return out


func _bb_describe(value, depth, flags):
	match typeof(value):
		TYPE_NIL:
			return "nil"
		TYPE_BOOL:
			return "b" + ("1" if value else "0")
		TYPE_INT:
			return "i" + str(value)
		TYPE_REAL:
			return "f" + str(stepify(value, 0.01))
		TYPE_STRING:
			if value.length() > 1000 and not flags.has("!longtext"):
				flags.append("!longtext")
			return "s" + str(value.length()) + ':"' + _bb_safe(value, 40) + '"'
		TYPE_VECTOR2:
			return "v2"
		TYPE_VECTOR3:
			return "v3"
		TYPE_NODE_PATH:
			if not flags.has("!nodepath"):
				flags.append("!nodepath")
			return "NODEPATH!"
		TYPE_OBJECT, TYPE_RID:
			if not flags.has("!object"):
				flags.append("!object")
			return "OBJECT!"
		TYPE_ARRAY:
			var out = "a" + str(value.size())
			if depth < 2 and value.size() > 0:
				var parts = []
				var count = 0
				for item in value:
					count += 1
					if count > 4:
						parts.append("...")
						break
					parts.append(_bb_describe(item, depth + 1, flags))
				out += "[" + ",".join(parts) + "]"
			return out
		TYPE_DICTIONARY:
			var out = "d" + str(value.size())
			if depth < 2 and value.size() > 0:
				var parts = []
				var count = 0
				for k in value.keys():
					count += 1
					if count > 4:
						parts.append("...")
						break
					parts.append(_bb_safe(str(k), 16) + ":" + _bb_describe(value[k], depth + 1, flags))
				out += "{" + ",".join(parts) + "}"
			return out
	return "t" + str(typeof(value))


# who is in the lobby (names go with the Steam ids in the file)
func _bb_watch_members():
	if bb == null:
		return
	var net = get_node_or_null("/root/Network")
	if net == null or typeof(net.get("LOBBY_MEMBERS")) != TYPE_ARRAY:
		return
	var now = {}
	for member in net.LOBBY_MEMBERS:
		if typeof(member) == TYPE_DICTIONARY:
			now[int(member.get("steam_id", 0))] = str(member.get("steam_name", ""))
	for id in now.keys():
		if not bb_members.has(id):
			_bb_line("JOIN " + str(OS.get_system_time_msecs()) + " " + str(id) + " " + _bb_safe(now[id], 40))
	for id in bb_members.keys():
		if not now.has(id):
			_bb_line("LEAVE " + str(OS.get_system_time_msecs()) + " " + str(id) + " " + _bb_safe(bb_members[id], 40))
	bb_members = now


func _bb_end():
	if bb != null and not bb_closed:
		bb_closed = true
		_bb_line("EXIT " + str(OS.get_unix_time()))
		bb.close()


func _notification(what):
	if what == NOTIFICATION_WM_QUIT_REQUEST or what == NOTIFICATION_PREDELETE:
		_bb_end()


func _exit_tree():
	_bb_end()


# At start: did the last game end without EXIT? Then keep its file and say what the last packet was.
func _bb_check_last_session():
	var file = File.new()
	if not file.file_exists(BB_FILE) or file.open(BB_FILE, File.READ) != OK:
		return
	var length = file.get_len()
	var start = max(0, length - 6000)
	file.seek(start)
	var tail = file.get_buffer(length - start).get_string_from_utf8()
	file.close()
	if length < 10 or tail.strip_edges().begins_with("EXIT") or tail.find("\nEXIT ") != -1:
		return
	var lines = tail.split("\n")
	var last = str(lines[lines.size() - 1])
	var finished = last == ""
	if finished and lines.size() > 1:
		last = str(lines[lines.size() - 2])
	var parts = last.split(" ")
	var text = "Your last game did not close normally."
	var culprit = 0
	if last.begins_with("EXIT") or last.begins_with("START"):
		return
	if not finished and parts.size() >= 4 and str(parts[1]).is_valid_integer():
		culprit = int(parts[1])
		text += " It stopped while unpacking a packet from " + str(culprit) + " (" + str(parts[2]) + " bytes, claims to unpack to " + str(parts[3]) + ")."
	elif parts.size() >= 4 and str(parts[1]).is_valid_integer():
		text += " The last packet it read was from " + str(parts[1]) + ": " + last.right(last.find("|") + 1).strip_edges().left(80)
	var dir = Directory.new()
	var copy = "user://griefershield_crash_" + str(OS.get_unix_time()) + ".log"
	if dir.copy(BB_FILE, copy) == OK:
		text += " Saved as " + copy.get_file() + "."
		_bb_prune_crashes()
	var data = get_node_or_null("/root/PlayerData")
	if culprit > 0 and data != null and typeof(data.get("players_hidden")) == TYPE_ARRAY and not data.players_hidden.has(culprit):
		data.players_hidden.append(culprit)
		text += " That player is now hidden (you can unhide them in the player list)."
	print("[GrieferShield] ", text)
	pending_notes.append(text)


func _bb_prune_crashes():
	var dir = Directory.new()
	if dir.open("user://") != OK:
		return
	var names = []
	dir.list_dir_begin(true, true)
	var name = dir.get_next()
	while name != "":
		if name.begins_with("griefershield_crash_") and name.ends_with(".log"):
			names.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	names.sort()
	while names.size() > BB_CRASHES_KEPT:
		dir.remove("user://" + names.pop_front())


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
