class_name Wander
extends RefCounted
## The Wander — the spellbook every Gifted character carries.
##
## Owns the spell catalogue, what a character has learned, the five equipped
## spell slots and their independent cooldowns. Pure data + timers: casting is
## performed by player.gd, and the UI (scripts/spell_wheel.gd) only reads and
## mutates slots through here.
##
## Design notes (from the LastStar brief): a player starts with 3-4 basic
## spells, learns more by exploring/fighting/quests, and every spell levels up
## through repeated use. Light is the casting resource (Game.energy).

signal slots_changed()
signal progress_changed()
signal spell_levelled(id: String, level: int)
signal spell_cast(id: String)

const MAX_SLOTS := 5
const MAX_SPELL_LEVEL := 30

## Element ids match Game.PARTY[x]["element_id"].

## The starter codex. `cost` is Light, `power` multiplies the character's attack,
## `radius` is the effect area in metres (0 = single target / projectile).
const CATALOGUE := {
	"ember_shot": {
		"name": "Ember Shot",
		"category": "Elemental",
		"element": 1,
		"color": Color(1.0, 0.55, 0.25),
		"icon": "ember",
		"cost": 12.0,
		"cooldown": 1.6,
		"power": 1.5,
		"radius": 0.0,
		"range": 26.0,
		"desc": "A focused burst of fire in front of you.",
		"starter": true,
	},
	"gale_palm": {
		"name": "Gale Palm",
		"category": "Elemental",
		"element": 0,
		"color": Color(0.45, 0.95, 0.8),
		"icon": "aqua",
		"cost": 14.0,
		"cooldown": 2.4,
		"power": 1.8,
		"radius": 4.5,
		"range": 6.0,
		"desc": "A shove of compressed air in front of you.",
		"starter": true,
	},
	"frost_shard": {
		"name": "Frost Shard",
		"category": "Elemental",
		"element": 4,
		"color": Color(0.55, 0.85, 1.0),
		"icon": "aqua",
		"cost": 16.0,
		"cooldown": 3.0,
		"power": 2.0,
		"radius": 0.0,
		"range": 30.0,
		"desc": "A focused burst of ice in front of you.",
		"starter": true,
	},
	"stone_bulwark": {
		"name": "Stone Bulwark",
		"category": "Defensive",
		"element": 5,
		"color": Color(0.85, 0.72, 0.45),
		"icon": "verdant",
		"cost": 20.0,
		"cooldown": 8.0,
		"power": 0.4,
		"radius": 3.0,
		"range": 0.0,
		"desc": "Wraps the party in a damage-absorbing stone shield.",
		"starter": false,
	},
	"arc_lance": {
		"name": "Arc Lance",
		"category": "Arcane",
		"element": 2,
		"color": Color(0.72, 0.6, 1.0),
		"icon": "arcane",
		"cost": 24.0,
		"cooldown": 5.0,
		"power": 2.6,
		"radius": 2.2,
		"range": 34.0,
		"desc": "A powerful arcane strike against foes ahead.",
		"starter": false,
	},
	"sun_spear": {
		"name": "Sun Spear",
		"category": "Elemental",
		"element": 1,
		"color": Color(1.0, 0.86, 0.4),
		"icon": "radiant",
		"cost": 26.0,
		"cooldown": 4.2,
		"power": 2.8,
		"radius": 1.6,
		"range": 40.0,
		"desc": "Hurls a lance of concentrated daylight.",
		"starter": false,
	},
	"tide_step": {
		"name": "Tide Step",
		"category": "Spatial",
		"element": 3,
		"color": Color(0.4, 0.75, 1.0),
		"icon": "aqua",
		"cost": 18.0,
		"cooldown": 6.0,
		"power": 0.6,
		"radius": 1.0,
		"range": 14.0,
		"desc": "Slips forward through a ripple of water.",
		"starter": false,
	},
	"verdant_bloom": {
		"name": "Verdant Bloom",
		"category": "Summoning",
		"element": 0,
		"color": Color(0.5, 0.9, 0.55),
		"icon": "verdant",
		"cost": 22.0,
		"cooldown": 7.5,
		"power": 1.2,
		"radius": 5.5,
		"range": 0.0,
		"desc": "Brambles erupt and hold the ground.",
		"starter": false,
	},
}

## Equipped slot ids, length MAX_SLOTS. Empty string means an empty slot.
var slots: Array[String] = ["ember_shot", "gale_palm", "", "", ""]
## id -> mastery level
var levels: Dictionary = {}
## id -> seconds remaining on cooldown (0 = ready)
var cooldowns: Dictionary = {}


func _init() -> void:
	for id in CATALOGUE:
		if bool(CATALOGUE[id].get("starter", false)):
			levels[id] = 1


func learn(id: String) -> bool:
	if not CATALOGUE.has(id) or known(id):
		return false
	levels[id] = 1
	progress_changed.emit()
	slots_changed.emit()
	return true


func restore(saved_levels: Dictionary, saved_slots: Array) -> void:
	# Ignore unrecognised data; starter spells are always available.
	for id in CATALOGUE:
		if saved_levels.has(id):
			levels[id] = clampi(int(saved_levels[id]), 1, MAX_SPELL_LEVEL)
			levels[id + "_xp"] = clampi(int(saved_levels.get(id + "_xp", 0)), 0, 180)
	if saved_slots.size() == MAX_SLOTS:
		var used: Array[String] = []
		for i in range(MAX_SLOTS):
			var id := str(saved_slots[i])
			if id == "" or (known(id) and not used.has(id)):
				slots[i] = id
				if id != "":
					used.append(id)
			else:
				slots[i] = ""


func spell(id: String) -> Dictionary:
	return CATALOGUE.get(id, {})


func known(id: String) -> bool:
	return id != "" and levels.has(id) and CATALOGUE.has(id)


func level_of(id: String) -> int:
	return int(levels.get(id, 0))


func equipped_at(i: int) -> String:
	if i < 0 or i >= slots.size():
		return ""
	return slots[i]


func set_slot(i: int, id: String) -> bool:
	if i < 0 or i >= MAX_SLOTS:
		return false
	if id != "" and not known(id):
		return false
	# A spell may only occupy one slot at a time.
	for j in range(MAX_SLOTS):
		if j != i and slots[j] == id:
			slots[j] = ""
	slots[i] = id
	slots_changed.emit()
	progress_changed.emit()
	return true


func cooldown_left(id: String) -> float:
	return maxf(0.0, float(cooldowns.get(id, 0.0)))


func cooldown_ratio(id: String) -> float:
	## 0 = just fired, 1 = ready. Drives the sweep on the spell button.
	var data := spell(id)
	if data.is_empty():
		return 1.0
	var total: float = maxf(0.01, float(data["cooldown"]))
	return 1.0 - clampf(cooldown_left(id) / total, 0.0, 1.0)


func can_cast(id: String, light: float) -> bool:
	if not known(id):
		return false
	if cooldown_left(id) > 0.0:
		return false
	return light >= float(spell(id)["cost"])


## Start a cooldown and record mastery progress. Returns the spell data.
## True when the spell is known and off cooldown. The HUD had this same
## expression inlined; one predicate means "ready" cannot drift from
## "castable" the way it did for the Light/cooldown ordering bug.
func is_ready(id: String) -> bool:
	return known(id) and cooldown_left(id) <= 0.0


func begin_cast(id: String) -> Dictionary:
	var data := spell(id)
	if data.is_empty():
		return {}
	cooldowns[id] = float(data["cooldown"])
	spell_cast.emit(id)
	_add_mastery(id)
	progress_changed.emit()
	return data


func _add_mastery(id: String) -> void:
	# Mastery is deliberately slow: casting a spell is practice, not a switch.
	var lvl := level_of(id)
	if lvl >= MAX_SPELL_LEVEL:
		return
	var xp: int = int(levels.get(id + "_xp", 0)) + 1
	levels[id + "_xp"] = xp
	if xp >= lvl * 6:
		levels[id] = lvl + 1
		levels[id + "_xp"] = 0
		spell_levelled.emit(id, lvl + 1)


func tick(delta: float) -> void:
	var changed := false
	for id in cooldowns.keys():
		var v := float(cooldowns[id])
		if v > 0.0:
			cooldowns[id] = maxf(0.0, v - delta)
			changed = true
	if changed:
		slots_changed.emit()
