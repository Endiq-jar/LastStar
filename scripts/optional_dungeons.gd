extends RefCounted
## Deterministic optional Hollow roster. IDs must remain stable for save files.
## These encounters reuse the existing arena, bosses and enemy families.
const DESIGNS := preload("res://scripts/optional_hollow_designs.gd")
const SETTLEMENTS := preload("res://scripts/settlement_data.gd")
const COUNT := 75
const TITLES := ["Forgotten Passage", "Ember Crypt", "Lantern Keep", "Echo Chamber", "Shattered Refuge", "Starless Sanctuary"]


static func entry(index: int) -> Dictionary:
	if index < 0 or index >= COUNT: return {}
	var site_index := index % SETTLEMENTS.SITES.size()
	var slot := index / SETTLEMENTS.SITES.size()
	var id := "optional_%03d" % index
	var design: Dictionary = DESIGNS.get_design(id)
	return {"id": id, "site": site_index, "slot": slot,
		"rank": index, "name": str(design.get("name", "%s %s" % [SETTLEMENTS.SITES[site_index]["name"], TITLES[slot]]))}


static func by_id(id: String) -> Dictionary:
	if not id.begins_with("optional_") or id.length() != 12: return {}
	var number := id.substr(9)
	if not number.is_valid_int(): return {}
	var result := entry(int(number))
	return result if not result.is_empty() and result["id"] == id else {}


static func count_cleared(clears: Dictionary) -> int:
	var count := 0
	for index in range(COUNT):
		if bool(clears.get(entry(index)["id"], false)): count += 1
	return count
