extends Node
## LastStar — global game state (autoload "Game").
##
## Owns the party, elemental energy, story progress and the signals the HUD
## listens to. Everything else in the game reads/writes through here so the
## UI never has to dig through the scene tree.

signal sigils_changed(collected: int, total: int)
signal character_changed(index: int)
signal quality_changed(tier: int)
signal stats_changed()
signal quest_changed(text: String)
signal toast(text: String)
signal waypoint_changed(name: String)
signal game_won()
signal respawned()
## Emitted when the player casts a Wander spell. player.gd performs the effect.
signal spell_cast(id: String, data: Dictionary)

const TOTAL_SIGILS := 12
const MAX_STAMINA := 100.0
const MAX_ENERGY := 100.0
const WORLD_PATH := "res://scenes/world.tscn"
const MENU_PATH := "res://scenes/main_menu.tscn"

## The travelling party. Original characters — no Genshin assets are used.
const PARTY := [
	{
		"name": "Sora",
		"title": "Wandering Gale",
		"element": "Anemo",
		"element_id": 0,
		"color": Color(0.92, 0.26, 0.24),
		# Black and red, per the brief. The previous values (0.62-0.87 near-white
		# blues) were an over-correction for clipping: I had chased the white-blob
		# artefact by lifting every albedo toward 1.0, which is exactly backwards.
		# A character reads as black-and-red because its albedos ARE dark, and the
		# toon ramp supplies the separation between the lit and shadowed halves.
		"hair": Color(0.13, 0.12, 0.16),
		"hair_tip": Color(0.72, 0.15, 0.18),
		"outfit": Color(0.14, 0.13, 0.17),
		"outfit_accent": Color(0.66, 0.13, 0.16),
		"skin": Color(0.88, 0.74, 0.66),
		"eye": Color(0.95, 0.28, 0.24),
		"cape": Color(0.52, 0.08, 0.12),
		"weapon": "sword",
		"max_hp": 1100.0,
		"attack": 42.0,
		"skill_name": "Gale Palm",
		"burst_name": "Tempest Bloom",
		"skill_cd": 4.5,
		"burst_cost": 55.0,
	},
	{
		"name": "Ember",
		"title": "Cinder of Dawn",
		"element": "Pyro",
		"element_id": 1,
		"color": Color(1.0, 0.55, 0.32),
		"hair": Color(0.55, 0.16, 0.12),
		"hair_tip": Color(1.0, 0.62, 0.24),
		"outfit": Color(0.30, 0.20, 0.18),
		"outfit_accent": Color(0.86, 0.30, 0.16),
		"skin": Color(0.88, 0.71, 0.62),
		"eye": Color(1.0, 0.62, 0.22),
		"cape": Color(1.0, 0.46, 0.26),
		"weapon": "catalyst",
		"max_hp": 940.0,
		"attack": 48.0,
		"skill_name": "Ember Ring",
		"burst_name": "Solar Flare",
		"skill_cd": 5.5,
		"burst_cost": 60.0,
	},
	{
		"name": "Volt",
		"title": "Storm Arrow",
		"element": "Electro",
		"element_id": 2,
		"color": Color(0.75, 0.56, 1.0),
		"hair": Color(0.29, 0.22, 0.42),
		"hair_tip": Color(0.78, 0.56, 1.0),
		"outfit": Color(0.20, 0.18, 0.28),
		"outfit_accent": Color(0.44, 0.28, 0.72),
		"skin": Color(0.84, 0.70, 0.63),
		"eye": Color(0.66, 0.44, 1.0),
		"cape": Color(0.66, 0.48, 1.0),
		"weapon": "bow",
		"max_hp": 1000.0,
		"attack": 45.0,
		"skill_name": "Static Snare",
		"burst_name": "Thunderfall",
		"skill_cd": 5.0,
		"burst_cost": 58.0,
	},
]

var party_index: int = 0
var health: Array[float] = []
var energy: float = 0.0
var stamina: float = MAX_STAMINA

var sigils_collected: int = 0
var slimes_defeated: int = 0
var waypoints_activated: int = 0
## Names of every waypoint already lit, so re-touching one doesn't inflate the count.
var waypoints_seen: Dictionary = {}
var last_waypoint_name: String = "Starlit Shore"
var checkpoint: Vector3 = Vector3.ZERO
var has_checkpoint: bool = false

var is_paused: bool = false
var has_won: bool = false
var quest_text: String = ""

## 0 = Balanced, 1 = Performance, 2 = High. Applied by the world when it loads.
var quality_tier: int = 0
## Set by Game.start_game(); the world consumes it and unpauses the tree on
## its first frame (queued scene changes can otherwise keep the menu pause).
var pending_unpause: bool = false
## False until the world has booted at least once this session.
var booted: bool = false
const QUALITY_NAMES := ["Balanced", "Performance", "High"]

## Shared world facts used by water, enemies and weather systems.
var water_level: float = 1.2
var lake_center: Vector2 = Vector2(48.0, 52.0)
var lake_radius: float = 92.0

## The player's spellbook (scripts/wander.gd), set once the player spawns so the
## HUD can read slots and cooldowns without reaching into the scene tree.
var wander: Wander

## Touch joystick vector, written by the mobile HUD each frame.
var touch_move: Vector2 = Vector2.ZERO
var touch_active: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_quality()
	reset_run()


func reset_run() -> void:
	party_index = 0
	health.clear()
	for c in PARTY:
		health.append(float(c["max_hp"]))
	energy = 25.0
	stamina = MAX_STAMINA
	sigils_collected = 0
	slimes_defeated = 0
	waypoints_activated = 0
	waypoints_seen.clear()
	last_waypoint_name = "Starlit Shore"
	has_checkpoint = false
	checkpoint = Vector3.ZERO
	has_won = false
	is_paused = false
	get_tree().paused = false
	quest_text = ""
	_refresh_quest()
	emit_signal("stats_changed")
	emit_signal("sigils_changed", sigils_collected, TOTAL_SIGILS)
	emit_signal("character_changed", party_index)


func character() -> Dictionary:
	return PARTY[party_index]


func character_at(i: int) -> Dictionary:
	return PARTY[clampi(i, 0, PARTY.size() - 1)]


func max_hp() -> float:
	return float(character()["max_hp"])


func _ensure_health() -> void:
	if health.size() != PARTY.size():
		health.clear()
		for c in PARTY:
			health.append(float(c["max_hp"]))


func current_hp() -> float:
	_ensure_health()
	return health[party_index]


func set_hp(value: float) -> void:
	_ensure_health()
	var m := max_hp()
	health[party_index] = clampf(value, 0.0, m)
	emit_signal("stats_changed")
	if health[party_index] <= 0.0:
		_on_party_down()


func heal(amount: float) -> void:
	set_hp(current_hp() + amount)


func damage(amount: float) -> void:
	set_hp(current_hp() - amount)


func add_stamina(amount: float) -> void:
	stamina = clampf(stamina + amount, 0.0, MAX_STAMINA)
	emit_signal("stats_changed")


func drain_stamina(amount: float) -> void:
	stamina = clampf(stamina - amount, 0.0, MAX_STAMINA)
	emit_signal("stats_changed")


func add_energy(amount: float) -> void:
	energy = clampf(energy + amount, 0.0, MAX_ENERGY)
	emit_signal("stats_changed")


func spend_energy(amount: float) -> bool:
	if energy + 0.001 < amount:
		return false
	energy = clampf(energy - amount, 0.0, MAX_ENERGY)
	emit_signal("stats_changed")
	return true


func attack_power() -> float:
	return float(character()["attack"])


func switch_character(index: int) -> void:
	if index == party_index or index < 0 or index >= PARTY.size():
		return
	party_index = index
	var amb := get_tree().get_first_node_in_group("ambience")
	if amb and amb.has_method("play_switch"):
		amb.play_switch()
	emit_signal("character_changed", party_index)
	emit_signal("stats_changed")
	emit_signal("toast", "%s — %s" % [character()["name"], character()["element"]])


func next_character() -> void:
	switch_character((party_index + 1) % PARTY.size())


func _on_party_down() -> void:
	toast.emit("%s is down — returning to the last waypoint." % character()["name"])
	# Revive the whole party at half health, like a Genshin statue heal.
	for i in range(health.size()):
		health[i] = float(PARTY[i]["max_hp"]) * 0.5
	stamina = MAX_STAMINA
	energy = maxf(energy, 20.0)
	respawned.emit()
	emit_signal("stats_changed")


func collect_sigil() -> void:
	if has_won:
		return
	sigils_collected += 1
	add_energy(14.0)
	sigils_changed.emit(sigils_collected, TOTAL_SIGILS)
	_refresh_quest()
	if sigils_collected >= TOTAL_SIGILS:
		has_won = true
		quest_text = "Every star sigil is home. The valley remembers your name."
		quest_changed.emit(quest_text)
		game_won.emit()


func register_slime() -> void:
	slimes_defeated += 1
	add_energy(6.0)
	_refresh_quest()


func activate_waypoint(statue_name: String, pos: Vector3) -> void:
	if not waypoints_seen.has(statue_name):
		waypoints_seen[statue_name] = true
		waypoints_activated += 1
	last_waypoint_name = statue_name
	checkpoint = pos
	has_checkpoint = true
	for i in range(health.size()):
		health[i] = float(PARTY[i]["max_hp"])
	stamina = MAX_STAMINA
	waypoint_changed.emit(statue_name)
	toast.emit("Waypoint: %s — party healed" % statue_name)
	emit_signal("stats_changed")
	_refresh_quest()


func _refresh_quest() -> void:
	if has_won:
		return
	var parts: PackedStringArray = PackedStringArray()
	var left := TOTAL_SIGILS - sigils_collected
	if left > 0:
		parts.append("Recover %d more star sigils" % left)
	else:
		parts.append("All sigils recovered")
	if waypoints_activated <= 0:
		parts.append("Touch a waypoint statue to rest")
	if slimes_defeated < 6:
		parts.append("Clear the wandering slimes (%d/6)" % slimes_defeated)
	quest_text = " · ".join(parts)
	quest_changed.emit(quest_text)


func set_paused(paused: bool) -> void:
	is_paused = paused
	get_tree().paused = paused
	if paused:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func start_game() -> void:
	reset_run()
	pending_unpause = true
	get_tree().change_scene_to_file(WORLD_PATH)


func quit_to_menu() -> void:
	get_tree().paused = false
	is_paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(MENU_PATH)


func quality_name() -> String:
	return QUALITY_NAMES[clampi(quality_tier, 0, QUALITY_NAMES.size() - 1)]


func set_quality_tier(tier: int) -> void:
	## Public setter used by the automatic performance tuner.
	quality_tier = clampi(tier, 0, QUALITY_NAMES.size() - 1)
	_save_quality()
	quality_changed.emit(quality_tier)


func cycle_quality() -> void:
	quality_tier = (quality_tier + 1) % QUALITY_NAMES.size()
	_save_quality()
	quality_changed.emit(quality_tier)
	toast.emit("Quality: %s" % quality_name())


func _save_quality() -> void:
	## Remember the choice: a phone that had to drop to Performance should not
	## silently go back to the heaviest preset on the next launch.
	var cfg := ConfigFile.new()
	cfg.set_value("video", "quality_tier", quality_tier)
	cfg.save("user://video.cfg")


func load_quality() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://video.cfg") == OK:
		quality_tier = clampi(int(cfg.get_value("video", "quality_tier", 0)), 0, QUALITY_NAMES.size() - 1)


func boot_direct() -> void:
	## Called by the world when it is the very first scene (the Android app
	## opens straight into gameplay, no title screen).
	reset_run()
	pending_unpause = true


func is_mobile() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")
