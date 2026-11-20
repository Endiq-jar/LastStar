extends RefCounted
## 100 persistent, deterministic melee weapons. The first two IDs predate the
## catalogue and must never change; all others are stable numeric IDs.
const COUNT := 100
const PREFIXES := ["Wayfarer", "Ashen", "Moonlit", "Tideborne", "Crystal", "Frostbound", "Suncrest", "Verdant", "Twilight", "Starfall"]
const TYPES := ["Sword", "Longsword", "Cleaver", "Rapier", "Dagger", "Axe", "Warhammer", "Spear", "Glaive", "Mace"]
const COLORS := [Color(0.72, 0.76, 0.83), Color(0.69, 0.43, 0.32), Color(0.58, 0.67, 0.88), Color(0.31, 0.68, 0.75), Color(0.69, 0.52, 0.83), Color(0.60, 0.81, 0.91), Color(0.92, 0.68, 0.31), Color(0.40, 0.69, 0.42), Color(0.55, 0.43, 0.66), Color(0.88, 0.75, 0.54)]


static func id_for_index(index: int) -> String:
	if index < 0 or index >= COUNT:
		return ""
	if index == 0: return "trail_blade"
	if index == 1: return "leaf_blade"
	return "weapon_%03d" % index


static func index_for_id(id: String) -> int:
	if id == "trail_blade": return 0
	if id == "leaf_blade": return 1
	if not id.begins_with("weapon_") or id.length() != 10:
		return -1
	var number := id.substr(7)
	if not number.is_valid_int(): return -1
	var index := int(number)
	return index if index >= 2 and index < COUNT and id_for_index(index) == id else -1


static func name_for_id(id: String) -> String:
	var index := index_for_id(id)
	if index < 0: return ""
	if index == 0: return "Trail Blade"
	if index == 1: return "Leaf Blade"
	return "%s %s" % [PREFIXES[index / 10], TYPES[index % 10]]


static func bonus(id: String) -> float:
	var index := index_for_id(id)
	if index < 0: return 0.0
	if index < 2: return 0.15
	return 0.08 + float(index / 10) * 0.015


static func quest_weapon(site_id: String, resident_index: int) -> String:
	var data := preload("res://scripts/settlement_data.gd")
	if resident_index < 0 or resident_index >= data.RESIDENT_COUNT:
		return ""
	for site_index in range(data.SITES.size()):
		if data.SITES[site_index]["id"] == site_id:
			return id_for_index((site_index * data.RESIDENT_COUNT + resident_index) % COUNT)
	return ""
