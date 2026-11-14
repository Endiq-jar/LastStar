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
signal collection_changed()

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
var shield_points: float = 0.0

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
## Metres across the whole world. The terrain publishes this at startup so the
## map, the water surface and the compass agree on where the edge is.
var world_size: float = 10000.0
var lake_center: Vector2 = Vector2(48.0, 52.0)
var lake_radius: float = 92.0

## The player's spellbook (scripts/wander.gd), set once the player spawns so the
## HUD can read slots and cooldowns without reaching into the scene tree.
var wander: Wander

## Touch joystick vector, written by the mobile HUD each frame.
var touch_move: Vector2 = Vector2.ZERO
var touch_active: bool = false

## Offline collection persists independently of a single expedition.
const COLLECTION_FILE := "user://collection.cfg"
const WISH_ITEMS := ["Moonstone", "Starflower", "Sunshard", "Stormglass"]
var coins := 150
var starlight := 30
var potions := 2
var character_levels: Array[int] = [1, 1, 1]
var collectibles: Dictionary = {}
var wish_count := 0
var sigils_seen: Dictionary = {}
var story_complete := false
# First playable story slice, independent from the older sigil victory.
var guard_story: Dictionary = {}
var wander_levels: Dictionary = {}
var wander_slots: Array = []
var outfit_style := 0
var camera_sensitivity := 1.0
const REBIND_ACTIONS := ["move_forward", "move_back", "move_left", "move_right", "jump", "sprint", "skill", "burst", "party_next"]
var _default_keys: Dictionary = {}
var dropped_items: Dictionary = {}
var next_drop_id := 1
const BACKPACK_NAMES := ["No backpack", "Trail backpack", "Explorer backpack"]
const BACKPACK_BONUS := [0, 5, 10]
const BACKPACK_PRICES := [0, 100, 250]
var owned_backpacks: Array[int] = [0]
var equipped_backpack := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_quality()
	_setup_settings()
	reset_run()
	load_collection()


func reset_run() -> void:
	party_index = 0
	health.clear()
	for c in PARTY:
		health.append(float(c["max_hp"]))
	energy = 25.0
	stamina = MAX_STAMINA
	shield_points = 0.0
	sigils_collected = 0
	slimes_defeated = 0
	waypoints_activated = 0
	waypoints_seen.clear()
	sigils_seen.clear()
	story_complete = false
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
	var remaining := maxf(0.0, amount)
	if shield_points > 0.0:
		var absorbed := minf(shield_points, remaining)
		shield_points -= absorbed
		remaining -= absorbed
		if absorbed > 0.0:
			toast.emit("Bulwark absorbed %.0f damage" % absorbed)
	set_hp(current_hp() - remaining)


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
	return float(character()["attack"]) * (1.0 + 0.12 * float(character_levels[party_index] - 1))


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
	toast.emit("%s is down — waking at %s." % [character()["name"], last_waypoint_name])
	# Revive the whole party at half health, like a Genshin statue heal.
	for i in range(health.size()):
		health[i] = float(PARTY[i]["max_hp"]) * 0.5
	stamina = MAX_STAMINA
	energy = maxf(energy, 20.0)
	respawned.emit()
	emit_signal("stats_changed")


func collect_sigil(sigil_id: String = "") -> void:
	if has_won or (sigil_id != "" and sigils_seen.has(sigil_id)):
		return
	if sigil_id != "":
		sigils_seen[sigil_id] = true
	sigils_collected = mini(TOTAL_SIGILS, sigils_collected + 1)
	coins += 20
	starlight += 5
	if sigils_collected >= TOTAL_SIGILS:
		story_complete = true
	save_collection()
	collection_changed.emit()
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
	coins += 5
	save_collection()
	collection_changed.emit()
	add_energy(6.0)
	_refresh_quest()


func activate_waypoint(statue_name: String, pos: Vector3) -> void:
	if not waypoints_seen.has(statue_name):
		waypoints_seen[statue_name] = true
		waypoints_activated += 1
		coins += 15
		collection_changed.emit()
	last_waypoint_name = statue_name
	checkpoint = pos
	has_checkpoint = true
	save_collection()
	for i in range(health.size()):
		health[i] = float(PARTY[i]["max_hp"])
	stamina = MAX_STAMINA
	waypoint_changed.emit(statue_name)
	toast.emit("Waypoint: %s — party healed" % statue_name)
	emit_signal("stats_changed")
	_refresh_quest()


func _refresh_quest() -> void:
	if story_complete:
		quest_text = "Every star sigil is home. The valley remembers your name."
		quest_changed.emit(quest_text)
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
	load_collection()
	pending_unpause = true
	get_tree().change_scene_to_file(WORLD_PATH)


func quit_to_menu() -> void:
	get_tree().paused = false
	is_paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(MENU_PATH)


func save_collection() -> bool:
	var cfg := ConfigFile.new()
	cfg.set_value("collection", "coins", coins)
	cfg.set_value("collection", "starlight", starlight)
	cfg.set_value("collection", "potions", potions)
	cfg.set_value("collection", "levels", character_levels)
	cfg.set_value("collection", "items", collectibles)
	cfg.set_value("collection", "wishes", wish_count)
	cfg.set_value("collection", "owned_backpacks", owned_backpacks)
	cfg.set_value("collection", "equipped_backpack", equipped_backpack)
	cfg.set_value("collection", "outfit_style", outfit_style)
	cfg.set_value("story", "sigils_seen", sigils_seen)
	cfg.set_value("story", "sigils_collected", sigils_collected)
	cfg.set_value("story", "slimes_defeated", slimes_defeated)
	cfg.set_value("story", "waypoints_seen", waypoints_seen)
	cfg.set_value("story", "last_waypoint", last_waypoint_name)
	cfg.set_value("story", "has_checkpoint", has_checkpoint)
	cfg.set_value("story", "checkpoint", checkpoint)
	cfg.set_value("story", "complete", story_complete)
	cfg.set_value("story", "guard_story", guard_story)
	cfg.set_value("wander", "levels", wander_levels)
	cfg.set_value("wander", "slots", wander_slots)
	cfg.set_value("story", "dropped_items", dropped_items)
	cfg.set_value("story", "next_drop_id", next_drop_id)
	var err := cfg.save(COLLECTION_FILE)
	if err != OK:
		push_warning("LastStar: could not save the offline collection (%d)" % err)
	return err == OK


func load_collection() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(COLLECTION_FILE) != OK:
		return
	var saved_sigils = cfg.get_value("story", "sigils_seen", {})
	sigils_seen = saved_sigils if saved_sigils is Dictionary else {}
	sigils_collected = clampi(int(cfg.get_value("story", "sigils_collected", 0)), 0, TOTAL_SIGILS)
	slimes_defeated = maxi(0, int(cfg.get_value("story", "slimes_defeated", 0)))
	var saved_waypoints = cfg.get_value("story", "waypoints_seen", {})
	waypoints_seen = saved_waypoints if saved_waypoints is Dictionary else {}
	waypoints_activated = waypoints_seen.size()
	last_waypoint_name = str(cfg.get_value("story", "last_waypoint", "Starlit Shore"))
	var saved_checkpoint = cfg.get_value("story", "checkpoint", Vector3.ZERO)
	checkpoint = saved_checkpoint if saved_checkpoint is Vector3 else Vector3.ZERO
	has_checkpoint = bool(cfg.get_value("story", "has_checkpoint", false)) and saved_checkpoint is Vector3
	story_complete = bool(cfg.get_value("story", "complete", false))
	var story_data = cfg.get_value("story", "guard_story", {})
	guard_story = story_data if story_data is Dictionary else {}
	var levels_data = cfg.get_value("wander", "levels", {})
	wander_levels = levels_data if levels_data is Dictionary else {}
	var slots_data = cfg.get_value("wander", "slots", [])
	wander_slots = slots_data if slots_data is Array else []
	var saved_drops = cfg.get_value("story", "dropped_items", {})
	dropped_items = saved_drops if saved_drops is Dictionary else {}
	next_drop_id = maxi(1, int(cfg.get_value("story", "next_drop_id", 1)))
	_refresh_quest()
	sigils_changed.emit(sigils_collected, TOTAL_SIGILS)
	coins = maxi(0, int(cfg.get_value("collection", "coins", 150)))
	starlight = maxi(0, int(cfg.get_value("collection", "starlight", 30)))
	potions = maxi(0, int(cfg.get_value("collection", "potions", 2)))
	wish_count = maxi(0, int(cfg.get_value("collection", "wishes", 0)))
	outfit_style = clampi(int(cfg.get_value("collection", "outfit_style", 0)), 0, 2)
	owned_backpacks = [0]
	var saved_packs = cfg.get_value("collection", "owned_backpacks", [0])
	if saved_packs is Array:
		for pack in saved_packs:
			var index := int(pack)
			if index > 0 and index < BACKPACK_NAMES.size() and not owned_backpacks.has(index):
				owned_backpacks.append(index)
	equipped_backpack = int(cfg.get_value("collection", "equipped_backpack", 0))
	if not owned_backpacks.has(equipped_backpack):
		equipped_backpack = 0
	var levels = cfg.get_value("collection", "levels", [1, 1, 1])
	if levels is Array and levels.size() == PARTY.size():
		for i in range(PARTY.size()):
			character_levels[i] = clampi(int(levels[i]), 1, 10)
	var saved_items = cfg.get_value("collection", "items", {})
	if saved_items is Dictionary:
		collectibles = saved_items
	collection_changed.emit()


func save_wander() -> void:
	if wander == null:
		return
	wander_levels = wander.levels.duplicate(true)
	wander_slots = wander.slots.duplicate()
	save_collection()


func guard_accept(quest: String, answer: String = "") -> bool:
	if not ["seal", "hollow"].has(quest) or bool(guard_story.get(quest + "_accepted", false)):
		return false
	guard_story[quest + "_accepted"] = true
	if quest == "seal" and ["duty", "curiosity"].has(answer):
		guard_story["answer"] = answer
	save_collection()
	quest_changed.emit(quest_text)
	collection_changed.emit()
	return true


func guard_can_complete(quest: String) -> bool:
	if not bool(guard_story.get(quest + "_accepted", false)) or bool(guard_story.get(quest + "_done", false)):
		return false
	return (quest == "seal" and sigils_collected >= 1) or (quest == "hollow" and slimes_defeated >= 3)


func guard_complete(quest: String) -> bool:
	if not guard_can_complete(quest) or wander == null:
		return false
	guard_story[quest + "_done"] = true
	var reward := "stone_bulwark" if quest == "seal" else "arc_lance"
	# Set completion before learn emits its save signal: the reward and quest
	# completion are then persisted together, with no repeatable reward window.
	wander.learn(reward)
	save_wander()
	collection_changed.emit()
	toast.emit("Wander discovery: %s" % wander.spell(reward)["name"])
	return true


func inventory_capacity() -> int:
	return 10 + int(BACKPACK_BONUS[equipped_backpack])


func inventory_used() -> int:
	var total := potions
	for item in WISH_ITEMS:
		total += maxi(0, int(collectibles.get(item, 0)))
	return total


func set_outfit_style(index: int) -> void:
	outfit_style = clampi(index, 0, 2)
	save_collection()
	collection_changed.emit()
	character_changed.emit(party_index)


func buy_backpack(index: int) -> bool:
	if index <= 0 or index >= BACKPACK_NAMES.size() or owned_backpacks.has(index) or coins < BACKPACK_PRICES[index]:
		return false
	coins -= int(BACKPACK_PRICES[index])
	owned_backpacks.append(index)
	save_collection()
	collection_changed.emit()
	return true


func equip_backpack(index: int) -> bool:
	if not owned_backpacks.has(index) or index < 0 or index >= BACKPACK_NAMES.size():
		return false
	if inventory_used() > 10 + int(BACKPACK_BONUS[index]):
		return false
	equipped_backpack = index
	save_collection()
	collection_changed.emit()
	return true


func drop_item(item: String, position: Vector3) -> String:
	if item == "Potion":
		if potions <= 0:
			return ""
		potions -= 1
	elif WISH_ITEMS.has(item) and int(collectibles.get(item, 0)) > 0:
		collectibles[item] = int(collectibles[item]) - 1
		if collectibles[item] <= 0:
			collectibles.erase(item)
	else:
		return ""
	var id := str(next_drop_id)
	next_drop_id += 1
	dropped_items[id] = {"item": item, "position": position}
	save_collection()
	collection_changed.emit()
	return id


func recover_drop(id: String) -> bool:
	if not dropped_items.has(id) or inventory_used() >= inventory_capacity():
		return false
	var item := str(dropped_items[id].get("item", ""))
	if item == "Potion":
		potions += 1
	elif WISH_ITEMS.has(item):
		collectibles[item] = int(collectibles.get(item, 0)) + 1
	else:
		return false
	dropped_items.erase(id)
	save_collection()
	collection_changed.emit()
	return true


func buy_potion() -> bool:
	if coins < 25 or inventory_used() >= inventory_capacity():
		return false
	coins -= 25
	potions += 1
	save_collection()
	collection_changed.emit()
	return true


func use_potion() -> bool:
	if potions <= 0 or current_hp() >= max_hp():
		return false
	potions -= 1
	heal(300.0)
	save_collection()
	collection_changed.emit()
	return true


func upgrade_character(index: int) -> bool:
	if index < 0 or index >= PARTY.size() or character_levels[index] >= 10:
		return false
	var cost := character_levels[index] * 50
	if coins < cost:
		return false
	coins -= cost
	character_levels[index] += 1
	save_collection()
	collection_changed.emit()
	stats_changed.emit()
	return true


func make_wish() -> String:
	if starlight < 30 or inventory_used() >= inventory_capacity():
		return ""
	starlight -= 30
	var item: String = WISH_ITEMS[randi_range(0, WISH_ITEMS.size() - 1)]
	collectibles[item] = int(collectibles.get(item, 0)) + 1
	wish_count += 1
	save_collection()
	collection_changed.emit()
	return item


func _setup_settings() -> void:
	for bus in ["Ambience", "SFX"]:
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus)
			AudioServer.set_bus_send(AudioServer.bus_count - 1, "Master")
	for action in REBIND_ACTIONS:
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				_default_keys[action] = event.physical_keycode
				break
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") != OK:
		return
	for bus in ["Master", "Ambience", "SFX"]:
		set_bus_level(bus, float(cfg.get_value("audio", bus, 1.0)), false)
	camera_sensitivity = clampf(float(cfg.get_value("controls", "sensitivity", 1.0)), 0.25, 2.0)
	for action in REBIND_ACTIONS:
		var key := int(cfg.get_value("keys", action, 0))
		if key > 0:
			_apply_key(action, key)


func set_bus_level(bus: String, value: float, persist: bool = true) -> void:
	if not ["Master", "Ambience", "SFX"].has(bus):
		return
	var index := AudioServer.get_bus_index(bus)
	if index < 0:
		return
	AudioServer.set_bus_volume_db(index, linear_to_db(clampf(value, 0.0, 1.0)))
	AudioServer.set_bus_mute(index, value <= 0.001)
	if persist:
		save_settings()


func set_sensitivity(value: float) -> void:
	camera_sensitivity = clampf(value, 0.25, 2.0)
	save_settings()


func key_for_action(action: String) -> int:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			return int(event.physical_keycode)
	return 0


func rebind_action(action: String, key: int) -> bool:
	if not REBIND_ACTIONS.has(action) or key <= 0 or key in [KEY_ESCAPE, KEY_J, KEY_F3]:
		return false
	for other in REBIND_ACTIONS:
		if other != action and key_for_action(other) == key:
			return false
	_apply_key(action, key)
	save_settings()
	return true


func _apply_key(action: String, key: int) -> void:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			InputMap.action_erase_event(action, event)
	var binding := InputEventKey.new()
	binding.physical_keycode = key as Key
	InputMap.action_add_event(action, binding)


func reset_keys() -> void:
	for action in REBIND_ACTIONS:
		if _default_keys.has(action):
			_apply_key(action, int(_default_keys[action]))
	save_settings()


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for bus in ["Master", "Ambience", "SFX"]:
		var index := AudioServer.get_bus_index(bus)
		if index >= 0:
			cfg.set_value("audio", bus, 0.0 if AudioServer.is_bus_mute(index) else db_to_linear(AudioServer.get_bus_volume_db(index)))
	cfg.set_value("controls", "sensitivity", camera_sensitivity)
	for action in REBIND_ACTIONS:
		cfg.set_value("keys", action, key_for_action(action))
	if cfg.save("user://settings.cfg") != OK:
		push_warning("LastStar: could not save settings")


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
	load_collection()
	pending_unpause = true


func is_mobile() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")
