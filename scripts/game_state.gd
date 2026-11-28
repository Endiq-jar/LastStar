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
var last_waypoint_name: String = "Ashvale"
var checkpoint: Vector3 = Vector3.ZERO
var has_checkpoint: bool = false

var is_paused: bool = false
var has_won: bool = false
var quest_text: String = ""

## 0 = Balanced, 1 = Performance, 2 = High. Applied by the world when it loads.
var quality_tier: int = 2
## Set by Game.start_game(); the world consumes it and unpauses the tree on
## its first frame (queued scene changes can otherwise keep the menu pause).
var pending_unpause: bool = false
## False until the world has booted at least once this session.
var booted: bool = false
const QUALITY_NAMES := ["Ultra Low", "Low", "Medium", "High", "Ultra"]

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
const SETTLEMENT_SHOPS := preload("res://scripts/settlement_shops.gd")
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
var settlement_quests: Dictionary = {}
var ashvale_hollow_cleared := false
var dungeon_clears: Dictionary = {}
# Runtime-only flag: the underground finale uses its own floors and cleanup.
var in_final_dungeon := false
# Runtime only: the reward for clearing each fixed tier applies exclusively
# within an appropriate Hollow, never in the open world or ordinary encounters.
var hollow_resonance := 1.0
var resonance_source := ""
# Story memories are derived from unique dungeon clears, so old saves receive
# them automatically and repeat victories can never duplicate an item.
const STORY_DUNGEONS := preload("res://scripts/story_dungeons.gd")
const STORY_CHRONICLE := preload("res://scripts/story_chronicle.gd")
const STORY_JOURNEY := preload("res://scripts/story_journey.gd")
const REGIONAL_SIDE_STORIES := preload("res://scripts/regional_side_stories.gd")
const OPTIONAL_DUNGEONS := preload("res://scripts/optional_dungeons.gd")
const STORY_MEMORY_GOAL := 25
const MEMORY_SPELLS := {"memory_10": "tide_remedy", "memory_15": "winter_resolve", "memory_22": "dusk_seal"}
const STORY_MEMORIES := [
	{"id": "ashvale", "name": "The First Lamp", "lore": "When the Silence fell, Ashvale sheltered its neighbours beneath a shared light."},
	{"id": "memory_vault", "name": "The Sealed Record", "lore": "The Vault remembers seven seals, raised not to imprison the world but to protect its people."},
	{"id": "suncrest_roost", "name": "The Scorched Promise", "lore": "A dragon guarded the last caravan carrying a fragment of the old world's knowledge."},
]


func story_memory_owned(id: String) -> bool:
	return ashvale_hollow_cleared if id == "ashvale" else bool(dungeon_clears.get(id, false))


# Stories are derived from clear flags, including saves made before the
# chronicle was added. Unrecovered memories never leak their revelations.
func story_account(id: String) -> String:
	if not story_memory_owned(id): return ""
	return STORY_CHRONICLE.account(id)


func story_connections() -> Array:
	var found: Array = []
	for connection in STORY_CHRONICLE.CONNECTIONS:
		var ids: Array = connection["ids"]
		if story_memory_owned(str(ids[0])) and story_memory_owned(str(ids[1])):
			found.append(connection)
	return found


# Act order is journal guidance only. Existing clear flags are authoritative,
# so old saves and memories recovered out of order are credited automatically.
func journey_acts() -> Array:
	var result: Array = []
	var unlocked := true
	for definition in STORY_JOURNEY.ACTS:
		var total := 0
		for quest in definition["quests"]:
			if story_memory_owned(str(quest["id"])): total += 1
		result.append({"definition": definition, "unlocked": unlocked, "done": total, "total": definition["quests"].size()})
		unlocked = unlocked and total == definition["quests"].size()
	return result


func journey_next_quest() -> Dictionary:
	for act in journey_acts():
		if not bool(act["unlocked"]): break
		for quest in act["definition"]["quests"]:
			if not story_memory_owned(str(quest["id"])): return quest
	return {}


func story_ending() -> String:
	if not bool(guard_story.get("keeper_defeated", false)): return ""
	var conclusion: String = STORY_CHRONICLE.ending(str(guard_story.get("memory_choice", "")), str(guard_story.get("keeper_resolution", "")))
	if int(guard_story.get("ilyra_arc_stage", 0)) == 4:
		if str(guard_story.get("ilyra_arc_choice", "")) == "names":
			conclusion += " Ilyra keeps the patrol's names at the memorial, with room for their families to correct the record."
		else:
			conclusion += " Ilyra delivers the patrol's letters to their families, who decide what to share."
	if int(guard_story.get("harbor_stage", 0)) == 3:
		match str(guard_story.get("harbor_choice", "")):
			"shared": conclusion += " Neri's crews pass warnings from boat to boat, giving every vessel a voice in the alarm."
			"station": conclusion += " Neri's harbour station keeps an open warning log, checked by two watches and accountable to the crews."
	if int(guard_story.get("wander_story_stage", 0)) == 4:
		if str(guard_story.get("wander_story_choice", "")) == "public":
			conclusion += " Veya preserves the Wander's message in a public archive, with the families' names withheld until they consent."
		else:
			conclusion += " Veya brings the Wander's message to the families first, leaving publication to them."
	if int(guard_story.get("caravan_stage", 0)) == 4:
		match str(guard_story.get("caravan_choice", "")):
			"shelters": conclusion += " Zara's caravan network keeps shared shelters stocked along the pass, open to travellers whether or not they can pay."
			"guides": conclusion += " Zara and Bryn arrange paired guides between settlements, with a place in each caravan for travellers who cannot pay."
	if int(guard_story.get("orchard_story_stage", 0)) == 4:
		match str(guard_story.get("orchard_story_choice", "")):
			"share": conclusion += " Orin shares Orchard cuttings with Glassheaven, along with the knowledge to tend them without damaging the old roots."
			"shelter": conclusion += " Orin shelters a young cutting in the Orchard, where visitors help care for it and learn its history."
	if int(guard_story.get("watch_stage", 0)) == 3:
		if str(guard_story.get("watch_choice", "")) == "patrol":
			conclusion += " Frostmere's watch shares patrols across the pass, so no guide is left alone."
		else:
			conclusion += " Frostmere's families practise evacuation together, with a guide assigned to every group."
	if renewal_count() == STORY_CHRONICLE.RENEWAL_VOICES.size():
		conclusion += " At the heart of the Seal, seven witnesses offer their light freely; the promise is renewed together."
	if bool(guard_story.get("homecoming_done", false)):
		if str(guard_story.get("answer", "")) == "duty":
			conclusion += " Back in Ashvale, Ilyra remembers your promise to protect the valley. The people now share that watch with you."
		else:
			conclusion += " Back in Ashvale, Ilyra remembers your search for answers. The people now keep the questions open together."
	return conclusion


# Optional, replay-safe epilogue interaction. Existing Keeper victories can
# return to the arena; it neither gates the ending nor changes prior rewards.
func renewal_mask() -> int:
	return int(guard_story.get("renewal_mask", 0)) & 127


func offer_renewal_light(index: int) -> bool:
	if not bool(guard_story.get("keeper_defeated", false)) or index < 0 or index >= STORY_CHRONICLE.RENEWAL_VOICES.size(): return false
	var bit := 1 << index
	var mask := renewal_mask()
	if (mask & bit) != 0: return false
	guard_story["renewal_mask"] = mask | bit
	save_collection()
	collection_changed.emit()
	return true


func renewal_count() -> int:
	var total := 0
	for index in range(STORY_CHRONICLE.RENEWAL_VOICES.size()):
		if (renewal_mask() & (1 << index)) != 0: total += 1
	return total


func homecoming_objective() -> String:
	if not bool(guard_story.get("keeper_defeated", false)): return ""
	if bool(guard_story.get("homecoming_done", false)): return "Completed · the promise carried home."
	if str(guard_story.get("keeper_resolution", "")).is_empty(): return "Return to the Last Seal and decide what to do with the Keeper's memory."
	if renewal_count() < STORY_CHRONICLE.RENEWAL_VOICES.size(): return "Hear the seven witnesses at the Last Seal (%d / 7)." % renewal_count()
	return "Return to Ashvale and speak to Ilyra to carry the promise home."


func homecoming_in_ashvale() -> bool:
	var actor := get_tree().get_first_node_in_group("player") as Node3D
	if actor == null or in_final_dungeon: return false
	var world := actor.get_parent()
	var manager: Node = world.get_node_or_null("Settlements") if world != null else null
	if manager == null: return false
	var sites: Array = manager.get("_sites")
	if sites.is_empty(): return false
	var center: Vector2 = sites[0]["resolved"]
	var point := Vector2(actor.global_position.x, actor.global_position.z)
	var ground := float(world.call("_height", point.x, point.y))
	return point.distance_to(center) <= SETTLEMENT_DATA.PAVING_HALF_SIZE and absf(actor.global_position.y - ground) < 8.0


func finish_homecoming() -> bool:
	if not bool(guard_story.get("keeper_defeated", false)) or str(guard_story.get("keeper_resolution", "")).is_empty() or renewal_count() != STORY_CHRONICLE.RENEWAL_VOICES.size() or bool(guard_story.get("homecoming_done", false)) or not homecoming_in_ashvale(): return false
	guard_story["homecoming_done"] = true
	starlight += 150
	save_collection()
	collection_changed.emit()
	return true


func resolve_keeper_memory(choice: String) -> bool:
	if not bool(guard_story.get("keeper_defeated", false)) or not ["witness", "private"].has(choice) or not str(guard_story.get("keeper_resolution", "")).is_empty():
		return false
	guard_story["keeper_resolution"] = choice
	save_collection()
	collection_changed.emit()
	return true


func all_story_memories() -> Array:
	return STORY_MEMORIES + STORY_DUNGEONS.ENTRIES


func story_memory_count() -> int:
	var count := 0
	for memory in all_story_memories():
		if story_memory_owned(str(memory["id"])): count += 1
	return count


func optional_dungeon_count() -> int:
	return OPTIONAL_DUNGEONS.count_cleared(dungeon_clears)


func dungeon_count() -> int:
	return story_memory_count() + optional_dungeon_count()


func region_chart_unlocked(site_id: String) -> bool:
	# A written guide rather than a graphical map. Existing completed quests
	# automatically unlock their chart without altering the save format.
	return settlement_quest_status(site_id, "main", 0) == "done"


func first_tier_clear_count() -> int:
	var count := 0
	for number in range(4, 24):
		if bool(dungeon_clears.get("memory_%02d" % number, false)): count += 1
	return count


func second_tier_clear_count() -> int:
	var count := 0
	for number in range(20):
		if bool(dungeon_clears.get("optional_%03d" % number, false)): count += 1
	return count


func third_tier_clear_count() -> int:
	var count := 0
	for number in range(20, 40):
		if bool(dungeon_clears.get("optional_%03d" % number, false)): count += 1
	return count


func fourth_tier_clear_count() -> int:
	var count := 0
	for number in range(40, 60):
		if bool(dungeon_clears.get("optional_%03d" % number, false)): count += 1
	return count


func original_hollow_clear_count() -> int:
	var count := story_memory_count()
	for number in range(OPTIONAL_DUNGEONS.ORIGINAL_COUNT):
		if bool(dungeon_clears.get("optional_%03d" % number, false)): count += 1
	return count


func hollow_tier(id: String) -> int:
	if OPTIONAL_DUNGEONS.DESIGNS.get_design(id).is_empty(): return 1
	var number := int(id.substr(9))
	if number < 20: return 2
	if number < 40: return 3
	return 4 if number < 60 else 5


func hollow_power_multiplier(id: String) -> float:
	match hollow_tier(id):
		2: return 20.0
		3: return 500.0
		4: return 7500.0
		5: return 15000.0
	return 1.0


# Earned offensive attunement addresses the extreme HP of the fixed tiers.
# Enemy health/damage and the required clear counts remain unchanged. Cache it
# on entry, not on every hit, and do not persist this transient combat context.
func earned_hollow_resonance(id: String) -> float:
	var tier := 5 if id == "last_seal" else hollow_tier(id)
	if tier >= 5 and fourth_tier_clear_count() >= 20: return 3000.0
	if tier >= 4 and third_tier_clear_count() >= 20: return 2000.0
	if tier >= 3 and second_tier_clear_count() >= 20: return 200.0
	if tier >= 2 and first_tier_clear_count() >= 20: return 10.0
	return 1.0


func enter_hollow_resonance(id: String) -> void:
	resonance_source = id
	hollow_resonance = earned_hollow_resonance(id)


func leave_hollow_resonance(id: String) -> void:
	if resonance_source != id: return
	resonance_source = ""
	hollow_resonance = 1.0


func can_enter_hollow(id: String, site_id: String, cleared: bool) -> bool:
	# Previously cleared dungeons remain revisit-able on older saves.
	if cleared: return true
	if id == "ashvale": return bool(guard_story.get("memory_accepted", false))
	var tier := hollow_tier(id)
	if tier >= 2 and first_tier_clear_count() < 20: return false
	if tier >= 3 and second_tier_clear_count() < 20: return false
	if tier >= 4 and third_tier_clear_count() < 20: return false
	if tier >= 5 and fourth_tier_clear_count() < 20: return false
	return bool(guard_story.get("memory_done", false)) and region_chart_unlocked(site_id)


func can_enter_finale() -> bool:
	# A completed ending remains revisit-able after updating an old save.
	return bool(guard_story.get("keeper_defeated", false)) or (bool(guard_story.get("memory_done", false)) and original_hollow_clear_count() == STORY_MEMORY_GOAL + OPTIONAL_DUNGEONS.ORIGINAL_COUNT)

const SETTLEMENT_DATA := preload("res://scripts/settlement_data.gd")
var wander_levels: Dictionary = {}
var wander_slots: Array = []
# Coins in older saves are displayed as Ane; retain the save key for migration.
var outfit_style := 0
var owned_outfits: Array = [0, 1, 2]
var owned_weapons: Array = []
var equipped_weapon := ""
var owned_wayfarer_armor := false
var equipped_wayfarer_armor := false
var owned_cosmetics: Array = []
var equipped_cosmetic := ""
var owned_blueprints: Array = []
const WEAPONS := preload("res://scripts/weapon_catalog.gd")
const COSMETIC_NAMES := {"star_pin": "Star hairpin", "moon_pin": "Moon hairpin", "caravan_pin": "Caravan hairpin"}
const BLUEPRINT_ID := "research_0_1_0_0_0"
const OUTFIT_NAMES := ["Original", "Moonlit blue", "Rose dusk", "Forest traveller", "Sunrise traveller"]
var camera_sensitivity := 1.0
const REBIND_ACTIONS := ["move_forward", "move_back", "move_left", "move_right", "jump", "sprint", "skill", "burst", "party_next", "dodge", "heavy_attack"]
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
	_setup_game_controls()
	_setup_settings()
	reset_run()
	load_collection()


func reset_run() -> void:
	resonance_source = ""
	hollow_resonance = 1.0
	in_final_dungeon = false
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
	last_waypoint_name = "Ashvale"
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
	var remaining := maxf(0.0, amount) * (0.9 if equipped_wayfarer_armor else 1.0)
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
	return float(character()["attack"]) * (1.0 + 0.12 * float(character_levels[party_index] - 1)) * (1.0 + WEAPONS.bonus(equipped_weapon) if character()["weapon"] == "sword" else 1.0)


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
		toast.emit("All star sigils recovered. The journey continues.")


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
	cfg.set_value("collection", "owned_outfits", owned_outfits)
	cfg.set_value("collection", "owned_weapons", owned_weapons)
	cfg.set_value("collection", "equipped_weapon", equipped_weapon)
	cfg.set_value("collection", "owned_wayfarer_armor", owned_wayfarer_armor)
	cfg.set_value("collection", "equipped_wayfarer_armor", equipped_wayfarer_armor)
	cfg.set_value("collection", "owned_cosmetics", owned_cosmetics)
	cfg.set_value("collection", "equipped_cosmetic", equipped_cosmetic)
	cfg.set_value("collection", "owned_blueprints", owned_blueprints)
	cfg.set_value("story", "sigils_seen", sigils_seen)
	cfg.set_value("story", "sigils_collected", sigils_collected)
	cfg.set_value("story", "slimes_defeated", slimes_defeated)
	cfg.set_value("story", "waypoints_seen", waypoints_seen)
	cfg.set_value("story", "last_waypoint", last_waypoint_name)
	cfg.set_value("story", "has_checkpoint", has_checkpoint)
	cfg.set_value("story", "checkpoint", checkpoint)
	cfg.set_value("story", "complete", story_complete)
	cfg.set_value("story", "guard_story", guard_story)
	cfg.set_value("story", "settlement_quests", settlement_quests)
	cfg.set_value("story", "ashvale_hollow_cleared", ashvale_hollow_cleared)
	cfg.set_value("story", "dungeon_clears", dungeon_clears)
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
	last_waypoint_name = str(cfg.get_value("story", "last_waypoint", "Ashvale"))
	var saved_checkpoint = cfg.get_value("story", "checkpoint", Vector3.ZERO)
	checkpoint = saved_checkpoint if saved_checkpoint is Vector3 else Vector3.ZERO
	has_checkpoint = bool(cfg.get_value("story", "has_checkpoint", false)) and saved_checkpoint is Vector3
	story_complete = bool(cfg.get_value("story", "complete", false))
	var story_data = cfg.get_value("story", "guard_story", {})
	guard_story = story_data if story_data is Dictionary else {}
	var settlement_data = cfg.get_value("story", "settlement_quests", {})
	settlement_quests = settlement_data if settlement_data is Dictionary else {}
	ashvale_hollow_cleared = bool(cfg.get_value("story", "ashvale_hollow_cleared", false))
	var saved_dungeon_clears = cfg.get_value("story", "dungeon_clears", {})
	dungeon_clears = saved_dungeon_clears if saved_dungeon_clears is Dictionary else {}
	var levels_data = cfg.get_value("wander", "levels", {})
	wander_levels = levels_data if levels_data is Dictionary else {}
	# Existing clears earn these discoveries too, without resetting mastery.
	for memory_id in MEMORY_SPELLS:
		if bool(dungeon_clears.get(memory_id, false)):
			var spell_id: String = MEMORY_SPELLS[memory_id]
			if not wander_levels.has(spell_id): wander_levels[spell_id] = 1
			if wander != null and not wander.known(spell_id): wander.levels[spell_id] = 1
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
	owned_outfits = [0, 1, 2]
	var outfits = cfg.get_value("collection", "owned_outfits", [])
	if outfits is Array:
		for i in outfits:
			if int(i) >= 0 and int(i) < OUTFIT_NAMES.size() and not owned_outfits.has(int(i)):
				owned_outfits.append(int(i))
	outfit_style = int(cfg.get_value("collection", "outfit_style", 0))
	if not owned_outfits.has(outfit_style):
		outfit_style = 0
	var weapons = cfg.get_value("collection", "owned_weapons", [])
	owned_weapons = weapons if weapons is Array else []
	equipped_weapon = str(cfg.get_value("collection", "equipped_weapon", ""))
	if not owned_weapons.has(equipped_weapon) or WEAPONS.index_for_id(equipped_weapon) < 0:
		equipped_weapon = ""
	owned_wayfarer_armor = bool(cfg.get_value("collection", "owned_wayfarer_armor", false))
	equipped_wayfarer_armor = owned_wayfarer_armor and bool(cfg.get_value("collection", "equipped_wayfarer_armor", false))
	var cosmetics = cfg.get_value("collection", "owned_cosmetics", [])
	owned_cosmetics = cosmetics if cosmetics is Array else []
	equipped_cosmetic = str(cfg.get_value("collection", "equipped_cosmetic", ""))
	if not owned_cosmetics.has(equipped_cosmetic) or not COSMETIC_NAMES.has(equipped_cosmetic):
		equipped_cosmetic = ""
	var blueprints = cfg.get_value("collection", "owned_blueprints", [])
	owned_blueprints = blueprints if blueprints is Array else []
	# Grant unique rewards for quests completed before the rewards update.
	for site in SETTLEMENT_DATA.SITES:
		for index in range(SETTLEMENT_DATA.RESIDENT_COUNT):
			if settlement_quest_status(site["id"], "main", index) == "done":
				_grant_quest_weapon(site["id"], index)
			if settlement_quest_status(site["id"], "side", index) == "done":
				_grant_quest_weapon(site["id"], index)
				if index % 6 == 3: owned_wayfarer_armor = true
			if settlement_quest_status(site["id"], "main", index) == "done" or settlement_quest_status(site["id"], "side", index) == "done":
				_grant_resident_reward(index)
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


func grant_memory_spell(memory_id: String) -> String:
	var id := str(MEMORY_SPELLS.get(memory_id, ""))
	if id.is_empty(): return ""
	if not wander_levels.has(id): wander_levels[id] = 1
	if wander != null and not wander.known(id): wander.learn(id)
	return id


func save_wander() -> void:
	if wander == null:
		return
	wander_levels = wander.levels.duplicate(true)
	wander_slots = wander.slots.duplicate()
	save_collection()


func research_element_unlocked(index: int) -> bool:
	if index >= 0 and index <= 2: return true
	match index:
		3: return story_memory_owned("memory_10")
		4: return story_memory_owned("memory_15")
		5: return story_memory_owned("memory_24")
	return false


func research_spell(first: int, second: int, shape: int, reach: int, intensity: int) -> String:
	if wander == null or not bool(guard_story.get("seal_done", false)) or starlight < 10 or not research_element_unlocked(first) or not research_element_unlocked(second):
		return ""
	var id := Wander.research_id(first, second, shape, reach, intensity)
	if id == "" or wander.known(id):
		return ""
	starlight -= 10
	# learn() emits progress_changed, saving currency and the new spell together.
	wander.learn(id)
	collection_changed.emit()
	return id


func _settlement_quest_key(site_id: String, kind: String, resident_index: int) -> String:
	# Keep the original resident's key unchanged so existing saves migrate
	# without resetting their quests.
	return site_id + ":" + kind if resident_index == 0 else "%s:%d:%s" % [site_id, resident_index, kind]


func settlement_quest_status(site_id: String, kind: String, resident_index: int = 0) -> String:
	if SETTLEMENT_DATA.resident(site_id, resident_index).is_empty() or not ["main", "side"].has(kind):
		return "invalid"
	return str(settlement_quests.get(_settlement_quest_key(site_id, kind, resident_index), "available"))


func accept_settlement_quest(site_id: String, kind: String, resident_index: int = 0) -> bool:
	if settlement_quest_status(site_id, kind, resident_index) != "available":
		return false
	settlement_quests[_settlement_quest_key(site_id, kind, resident_index)] = "active"
	save_collection()
	collection_changed.emit()
	return true


func collect_settlement_item(site_id: String, kind: String, resident_index: int = 0) -> bool:
	if settlement_quest_status(site_id, kind, resident_index) != "active":
		return false
	settlement_quests[_settlement_quest_key(site_id, kind, resident_index)] = "found"
	save_collection()
	collection_changed.emit()
	return true


func complete_settlement_quest(site_id: String, kind: String, resident_index: int = 0) -> bool:
	if settlement_quest_status(site_id, kind, resident_index) != "found":
		return false
	settlement_quests[_settlement_quest_key(site_id, kind, resident_index)] = "done"
	if kind == "main":
		coins += 25
		_grant_quest_weapon(site_id, resident_index)
	else:
		starlight += 10
		potions += 1 # Quest rewards are never lost even when the backpack is full.
		_grant_quest_weapon(site_id, resident_index)
		if resident_index % 6 == 3: owned_wayfarer_armor = true
	_grant_resident_reward(resident_index)
	save_collection()
	collection_changed.emit()
	return true


func _grant_quest_weapon(site_id: String, index: int) -> void:
	var id := WEAPONS.quest_weapon(site_id, index)
	if id != "" and not owned_weapons.has(id):
		owned_weapons.append(id)


func _grant_resident_reward(index: int) -> void:
	match index % 6:
		0:
			if not owned_weapons.has("trail_blade"): owned_weapons.append("trail_blade")
		1:
			if not owned_blueprints.has(BLUEPRINT_ID): owned_blueprints.append(BLUEPRINT_ID)
		2:
			if not owned_cosmetics.has("star_pin"): owned_cosmetics.append("star_pin")
		3:
			if not owned_outfits.has(3): owned_outfits.append(3)
		4:
			if not owned_weapons.has("leaf_blade"): owned_weapons.append("leaf_blade")

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


# The Memory Vault story thread builds on the existing Ilyra save dictionary.
# These keys default safely for players with saves from before this chapter.
func accept_hollow_memory() -> bool:
	if not bool(guard_story.get("seal_done", false)) or bool(guard_story.get("memory_accepted", false)):
		return false
	guard_story["memory_accepted"] = true
	save_collection()
	collection_changed.emit()
	return true


func collect_hollow_memory() -> bool:
	if not ashvale_hollow_cleared or bool(guard_story.get("memory_found", false)):
		return false
	guard_story["memory_found"] = true
	save_collection()
	collection_changed.emit()
	toast.emit("Memory fragment recovered. Bring it to Ilyra.")
	return true


func resolve_hollow_memory(choice: String) -> bool:
	if not ["share", "study"].has(choice) or not bool(guard_story.get("memory_accepted", false)) or not bool(guard_story.get("memory_found", false)) or bool(guard_story.get("memory_done", false)) or wander == null:
		return false
	# Persist the decision before learning emits a save signal.
	guard_story["memory_done"] = true
	guard_story["memory_choice"] = choice
	guard_story["ilyra_bond"] = 2 if choice == "share" else 1
	var spell := "sun_spear" if choice == "share" else "tide_step"
	wander.learn(spell)
	save_wander()
	collection_changed.emit()
	toast.emit("Memory understood: %s learned." % wander.spell(spell)["name"])
	return true


# Optional personal quest. Stages are persisted in the existing guard_story
# dictionary and never gate the main Hollows or the Last Seal.
func begin_ilyra_arc() -> bool:
	if not bool(guard_story.get("memory_done", false)) or int(guard_story.get("ilyra_arc_stage", 0)) != 0: return false
	guard_story["ilyra_arc_stage"] = 1
	save_collection()
	collection_changed.emit()
	return true


func read_ilyra_memorial() -> bool:
	if int(guard_story.get("ilyra_arc_stage", 0)) != 1: return false
	guard_story["ilyra_arc_stage"] = 2
	save_collection()
	collection_changed.emit()
	return true


func hear_ilyra_guard_record() -> bool:
	if int(guard_story.get("ilyra_arc_stage", 0)) != 2 or not region_chart_unlocked("capital"): return false
	guard_story["ilyra_arc_stage"] = 3
	save_collection()
	collection_changed.emit()
	return true


func finish_ilyra_arc(choice: String) -> bool:
	if int(guard_story.get("ilyra_arc_stage", 0)) != 3 or not story_memory_owned("memory_vault") or not ["names", "letters"].has(choice): return false
	guard_story["ilyra_arc_stage"] = 5 if choice == "names" else 6
	guard_story["ilyra_arc_choice"] = choice
	save_collection()
	collection_changed.emit()
	return true


func complete_ilyra_arc() -> bool:
	var stage := int(guard_story.get("ilyra_arc_stage", 0))
	if stage != 5 and stage != 6: return false
	guard_story["ilyra_arc_stage"] = 4
	guard_story["ilyra_bond"] = maxi(3, int(guard_story.get("ilyra_bond", 0)))
	starlight += 60
	save_collection()
	collection_changed.emit()
	return true


func ilyra_arc_objective() -> String:
	match int(guard_story.get("ilyra_arc_stage", 0)):
		1: return "Read the patrol memorial west of Ashvale's center."
		2: return "Complete Captain Ren's main quest in Elaris Capital, then ask him about the sealed order."
		3: return "Clear the Memory Vault near Lunareth and speak to Ilyra."
		4: return "Completed · Ilyra's Gift is strengthened; 60 starlight received."
		5: return "Return to the patrol memorial west of Ashvale's center and read the names."
		6: return "Speak to Mira in Ashvale about delivering the families' letters."
	return ""


# A cross-region side story, stored alongside the existing story choices. The
# memory prerequisites count earlier victories and do not change Hollow gates.
func begin_harbor_story() -> bool:
	if int(guard_story.get("harbor_stage", 0)) != 0 or not region_chart_unlocked("tidefall"): return false
	guard_story["harbor_stage"] = 1
	save_collection()
	collection_changed.emit()
	return true


func choose_harbor_story(choice: String) -> bool:
	if int(guard_story.get("harbor_stage", 0)) != 1 or not ["shared", "station"].has(choice): return false
	if not story_memory_owned("memory_11") or not story_memory_owned("memory_12") or not region_chart_unlocked("glassheaven"): return false
	guard_story["harbor_stage"] = 2
	guard_story["harbor_choice"] = choice
	save_collection()
	collection_changed.emit()
	return true


func finish_harbor_story() -> bool:
	if int(guard_story.get("harbor_stage", 0)) != 2 or wander == null: return false
	guard_story["harbor_stage"] = 3
	wander.learn("harbor_light")
	save_wander()
	collection_changed.emit()
	return true


func harbor_story_objective() -> String:
	match int(guard_story.get("harbor_stage", 0)):
		1: return "Recover The Drowned Bell near Tidefall and A Prism of Voices near Glassheaven, then complete Prism's main quest and speak to Prism."
		2: return "Return to Neri in Tidefall with the warning plan."
		3: return "Completed · Harbor Light learned."
	return ""


# A lost Wander investigation. Existing leader and memory clears are honored;
# the story does not add a new gate to the main progression.
func begin_wander_story() -> bool:
	if int(guard_story.get("wander_story_stage", 0)) != 0 or not region_chart_unlocked("lunareth"): return false
	guard_story["wander_story_stage"] = 1
	save_collection()
	collection_changed.emit()
	return true


func trace_lost_wander() -> bool:
	if int(guard_story.get("wander_story_stage", 0)) != 1 or not region_chart_unlocked("evergloom") or not story_memory_owned("memory_09") or not story_memory_owned("memory_22"): return false
	guard_story["wander_story_stage"] = 2
	save_collection()
	collection_changed.emit()
	return true


func recover_lost_wander() -> bool:
	if int(guard_story.get("wander_story_stage", 0)) != 2: return false
	guard_story["wander_story_stage"] = 3
	save_collection()
	collection_changed.emit()
	return true


func finish_wander_story(choice: String) -> bool:
	if int(guard_story.get("wander_story_stage", 0)) != 3 or not ["public", "families"].has(choice) or wander == null: return false
	guard_story["wander_story_stage"] = 4
	guard_story["wander_story_choice"] = choice
	wander.learn("echo_resonance")
	save_wander()
	collection_changed.emit()
	return true


func wander_story_objective() -> String:
	match int(guard_story.get("wander_story_stage", 0)):
		1: return "Recover The Wander's Mark near Lunareth and The Twilight Witness near Duskhaven. Complete Rook's main quest and speak to Rook in Evergloom."
		2: return "Examine the lost Wander east of Evergloom's center."
		3: return "Bring the lost Wander to Veya in Lunareth."
		4: return "Completed · Echo Resonance learned."
	return ""


# The Orchard witnesses can be heard in any order, including across reloads.
# The investigation has no effect on the original memory or Hollow gates.
func begin_orchard_story() -> bool:
	if int(guard_story.get("orchard_story_stage", 0)) != 0 or not region_chart_unlocked("orchard"): return false
	guard_story["orchard_story_stage"] = 1
	guard_story["orchard_echoes"] = 0
	save_collection()
	collection_changed.emit()
	return true


func hear_orchard_echo(index: int) -> bool:
	if int(guard_story.get("orchard_story_stage", 0)) != 1 or index < 0 or index > 2: return false
	var mask := int(guard_story.get("orchard_echoes", 0)) & 7
	var bit := 1 << index
	if (mask & bit) != 0: return false
	mask |= bit
	guard_story["orchard_echoes"] = mask
	if mask == 7: guard_story["orchard_story_stage"] = 2
	save_collection()
	collection_changed.emit()
	return true


func interpret_orchard_story() -> bool:
	if int(guard_story.get("orchard_story_stage", 0)) != 2 or not region_chart_unlocked("glassheaven") or not story_memory_owned("memory_18") or not story_memory_owned("memory_19"): return false
	guard_story["orchard_story_stage"] = 3
	save_collection()
	collection_changed.emit()
	return true


func finish_orchard_story(choice: String) -> bool:
	if int(guard_story.get("orchard_story_stage", 0)) != 3 or not ["share", "shelter"].has(choice) or wander == null: return false
	guard_story["orchard_story_stage"] = 4
	guard_story["orchard_story_choice"] = choice
	wander.learn("rootward")
	save_wander()
	collection_changed.emit()
	return true


func orchard_story_objective() -> String:
	match int(guard_story.get("orchard_story_stage", 0)):
		1:
			var mask := int(guard_story.get("orchard_echoes", 0)) & 7
			var count := 0
			for index in range(3):
				if (mask & (1 << index)) != 0: count += 1
			return "Hear the three root marks around the Orchard settlement (%d / 3)." % count
		2: return "Recover The Orchard's Roots and The Seed of Light, complete Prism's Glassheaven main quest, and ask Prism to interpret the marks."
		3: return "Return to Orin in the Orchard and choose how to protect the young cutting."
		4: return "Completed · Rootward learned."
	return ""


# Cross-region caravan rescue. New keys coexist with older saves and do not
# alter the original settlement quest states or Hollow progression.
func begin_caravan_story() -> bool:
	if int(guard_story.get("caravan_stage", 0)) != 0 or not region_chart_unlocked("suncrest"): return false
	guard_story["caravan_stage"] = 1
	save_collection()
	collection_changed.emit()
	return true


func trace_caravan() -> bool:
	if int(guard_story.get("caravan_stage", 0)) != 1 or not region_chart_unlocked("frostmere"): return false
	guard_story["caravan_stage"] = 2
	save_collection()
	collection_changed.emit()
	return true


func rescue_caravan() -> bool:
	if int(guard_story.get("caravan_stage", 0)) != 2: return false
	guard_story["caravan_stage"] = 3
	save_collection()
	collection_changed.emit()
	return true


func hear_caravan_survivor(index: int) -> bool:
	if int(guard_story.get("caravan_stage", 0)) != 3 or index < 0 or index > 1: return false
	var previous := int(guard_story.get("caravan_witnesses", 0)) & 3
	var next := previous | (1 << index)
	if next == previous: return false
	guard_story["caravan_witnesses"] = next
	save_collection()
	collection_changed.emit()
	return true


func finish_caravan_story(choice: String) -> bool:
	if int(guard_story.get("caravan_stage", 0)) != 3 or not ["shelters", "guides"].has(choice): return false
	guard_story["caravan_stage"] = 4
	guard_story["caravan_choice"] = choice
	if not owned_cosmetics.has("caravan_pin"): owned_cosmetics.append("caravan_pin")
	save_collection()
	collection_changed.emit()
	return true


func caravan_story_objective() -> String:
	match int(guard_story.get("caravan_stage", 0)):
		1: return "Complete Bryn's main quest in Frostmere and ask about the missing caravan."
		2: return "Search the caravan packs east of Frostmere's center and defeat the attackers. If interrupted, return to try again."
		3: return "Return to Zara in Suncrest and choose how to protect future travellers."
		4: return "Completed · Caravan hairpin added to Wardrobe."
	return ""


# Frostmere's optional defense is independent of the 105 Hollow clear flags.
func begin_watch_story() -> bool:
	if int(guard_story.get("watch_stage", 0)) != 0 or not region_chart_unlocked("frostmere"): return false
	guard_story["watch_stage"] = 1
	save_collection()
	collection_changed.emit()
	return true


func complete_watch_defense() -> bool:
	if int(guard_story.get("watch_stage", 0)) != 1: return false
	guard_story["watch_stage"] = 2
	save_collection()
	collection_changed.emit()
	return true


func finish_watch_story(choice: String) -> bool:
	if int(guard_story.get("watch_stage", 0)) != 2 or not ["patrol", "evacuation"].has(choice) or wander == null: return false
	guard_story["watch_stage"] = 3
	guard_story["watch_choice"] = choice
	wander.learn("watchfire")
	save_wander()
	collection_changed.emit()
	return true


func watch_story_objective() -> String:
	match int(guard_story.get("watch_stage", 0)):
		1: return "Signal the watch north of Frostmere's center and defeat both attackers. If interrupted, signal it again."
		2: return "Return to Bryn in Frostmere."
		3: return "Completed · Watchfire learned."
	return ""


func set_veya_following(following: bool) -> bool:
	if int(guard_story.get("wander_story_stage", 0)) != 4: return false
	guard_story["veya_following"] = following
	save_collection()
	collection_changed.emit()
	return true


func set_neri_following(following: bool) -> bool:
	if int(guard_story.get("harbor_stage", 0)) != 3: return false
	guard_story["neri_following"] = following
	save_collection()
	collection_changed.emit()
	return true


func set_ilyra_following(following: bool) -> bool:
	if not bool(guard_story.get("seal_done", false)):
		return false
	guard_story["ilyra_following"] = following
	save_collection()
	collection_changed.emit()
	return true


func inventory_capacity() -> int:
	return 10 + int(BACKPACK_BONUS[equipped_backpack])


func inventory_used() -> int:
	var total := potions
	for item in WISH_ITEMS:
		total += maxi(0, int(collectibles.get(item, 0)))
	return total


func set_outfit_style(index: int) -> void:
	if not owned_outfits.has(index):
		return
	outfit_style = index
	save_collection()
	collection_changed.emit()
	character_changed.emit(party_index)


func settlement_quest_title(site_id: String, kind: String, index: int) -> String:
	if kind == "side" and index == 0:
		var story: Dictionary = REGIONAL_SIDE_STORIES.STORIES.get(site_id, {})
		if not story.is_empty(): return str(story["title"])
	var resident: Dictionary = SETTLEMENT_DATA.resident(site_id, index)
	return str(resident.get(kind, "Quest"))


func settlement_reward_text(kind: String, index: int, site_id: String) -> String:
	var base := "25 Ane" if kind == "main" else "10 starlight + 1 potion"
	var extras := ["Trail Blade", "Wind / Fire spell blueprint", "Star hairpin", "Forest traveller outfit", "Leaf Blade", ""]
	var extra: String = extras[index % 6]
	var weapon := WEAPONS.name_for_id(WEAPONS.quest_weapon(site_id, index))
	if weapon != "":
		base += " + " + weapon + " (unique)"
	if extra != "" and extra != weapon:
		base += " + " + extra + " (unique)"
	if kind == "side" and index % 6 == 3: base += " + Wayfarer armor (10% damage reduction)"
	if kind == "main" and index == 0: base += " + regional dungeon guide"
	return base


func equip_wayfarer_armor(equip: bool) -> bool:
	if equip and not owned_wayfarer_armor: return false
	equipped_wayfarer_armor = equip
	save_collection()
	collection_changed.emit()
	return true


func equip_reward_weapon(id: String) -> bool:
	if id != "" and (WEAPONS.index_for_id(id) < 0 or not owned_weapons.has(id)):
		return false
	equipped_weapon = id
	save_collection()
	collection_changed.emit()
	character_changed.emit(party_index)
	return true


func equip_reward_cosmetic(id: String) -> bool:
	if id != "" and (not COSMETIC_NAMES.has(id) or not owned_cosmetics.has(id)):
		return false
	equipped_cosmetic = id
	save_collection()
	collection_changed.emit()
	character_changed.emit(party_index)
	return true


func buy_reward_cosmetic(id: String) -> bool:
	if id != "moon_pin" or owned_cosmetics.has(id) or coins < 100:
		return false
	coins -= 100
	owned_cosmetics.append(id)
	save_collection()
	collection_changed.emit()
	return true


func buy_reward_outfit() -> bool:
	if owned_outfits.has(4) or coins < 150:
		return false
	coins -= 150
	owned_outfits.append(4)
	save_collection()
	collection_changed.emit()
	return true


func learn_reward_blueprint(id: String) -> bool:
	if id != BLUEPRINT_ID or not owned_blueprints.has(id) or wander == null or not wander.learn(id):
		return false
	save_wander()
	collection_changed.emit()
	return true


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


# These transactions operate on the original saved inventory and Ane balance.
# Sale price is below the purchase price, preventing currency duplication.
func buy_settlement_collectible(site_id: String) -> bool:
	var shop: Dictionary = SETTLEMENT_SHOPS.by_id(site_id)
	if shop.is_empty() or coins < SETTLEMENT_SHOPS.BUY_PRICE or inventory_used() >= inventory_capacity(): return false
	var item := str(shop.get("item", ""))
	if not WISH_ITEMS.has(item): return false
	coins -= SETTLEMENT_SHOPS.BUY_PRICE
	collectibles[item] = int(collectibles.get(item, 0)) + 1
	save_collection()
	collection_changed.emit()
	return true


func sell_settlement_collectible(site_id: String, item: String) -> bool:
	if SETTLEMENT_SHOPS.by_id(site_id).is_empty() or not WISH_ITEMS.has(item) or int(collectibles.get(item, 0)) <= 0: return false
	collectibles[item] = int(collectibles[item]) - 1
	if int(collectibles[item]) == 0: collectibles.erase(item)
	coins += SETTLEMENT_SHOPS.SELL_PRICE
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


func _setup_game_controls() -> void:
	# Add defaults without replacing keyboard/mouse bindings from the project.
	# Runtime setup works on desktop and Android Godot controller mappings.
	_add_key_default("dodge", KEY_C)
	_add_key_default("heavy_attack", KEY_R)
	_add_key_default("journal", KEY_J)
	for i in range(5):
		_add_key_default("spell_%d" % (i + 1), KEY_1 + i)
	var buttons := {
		"jump": JOY_BUTTON_A, "dodge": JOY_BUTTON_B,
		"attack": JOY_BUTTON_X, "skill": JOY_BUTTON_Y,
		"sprint": JOY_BUTTON_LEFT_SHOULDER, "burst": JOY_BUTTON_RIGHT_SHOULDER,
		"pause": JOY_BUTTON_START, "journal": JOY_BUTTON_BACK,
		"interact": JOY_BUTTON_DPAD_UP, "party_next": JOY_BUTTON_DPAD_RIGHT,
		"heavy_attack": JOY_BUTTON_DPAD_DOWN,
		"spell_1": JOY_BUTTON_DPAD_LEFT,
		"spell_4": JOY_BUTTON_RIGHT_STICK, "spell_5": JOY_BUTTON_LEFT_STICK,
	}
	for action in buttons:
		var button := InputEventJoypadButton.new()
		button.button_index = buttons[action]
		if not InputMap.action_has_event(action, button):
			InputMap.action_add_event(action, button)
	for binding in [["move_left", JOY_AXIS_LEFT_X, -1.0], ["move_right", JOY_AXIS_LEFT_X, 1.0], ["move_forward", JOY_AXIS_LEFT_Y, -1.0], ["move_back", JOY_AXIS_LEFT_Y, 1.0], ["spell_2", JOY_AXIS_TRIGGER_RIGHT, 1.0], ["spell_3", JOY_AXIS_TRIGGER_LEFT, 1.0]]:
		var axis := InputEventJoypadMotion.new()
		axis.axis = binding[1]
		axis.axis_value = binding[2]
		if not InputMap.action_has_event(binding[0], axis):
			InputMap.action_add_event(binding[0], axis)


func _add_key_default(action: String, key: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.25)
	var event := InputEventKey.new()
	event.physical_keycode = key as Key
	if not InputMap.action_has_event(action, event):
		InputMap.action_add_event(action, event)


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
	cfg.set_value("video", "quality_version", 2)
	cfg.save("user://video.cfg")


func _quality_from_config(cfg: ConfigFile) -> int:
	var value := int(cfg.get_value("video", "quality_tier", 0))
	if int(cfg.get_value("video", "quality_version", 1)) < 2:
		# Preserve old Balanced / Performance / High choices on upgrade.
		return [2, 1, 3][clampi(value, 0, 2)]
	return clampi(value, 0, QUALITY_NAMES.size() - 1)


func load_quality() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://video.cfg") == OK:
		quality_tier = _quality_from_config(cfg)


func boot_direct() -> void:
	## Called by the world when it is the very first scene (the Android app
	## opens straight into gameplay, no title screen).
	reset_run()
	load_collection()
	pending_unpause = true


func is_mobile() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")
