extends RefCounted
## Twenty additional region-specific expeditions. IDs are the original save IDs.
## The chambers and enemies are modular; names and story fragments are authored.
const ENTRIES := [
	["Ashvale Lamp Catacombs", "The Lamp-Eater", "Ashen pulse", "A keeper carried the last lamp beneath Ashvale.", "Its flame guided families through the night."],
	["Capital's Broken Rampart", "The Rampart Butcher", "Breach shock", "The capital's soldiers sealed a breach below the walls.", "Their warning bought the city time to evacuate."],
	["Lunareth's Lost Folio", "The Inkbound Sage", "Arcane flare", "Scholars hid a folio where the Silence could not reach it.", "Its pages recorded the names of ordinary rescuers."],
	["Tidefall Salt Vault", "The Saltbound Mariner", "Tidal flash", "A courier left a route through the salt vault.", "The path carried stranded families toward waiting boats."],
	["Glassheaven Prism Crypt", "The Prism Maw", "Crystal pulse", "A prism captured a cry from the first night.", "Its colours kept the voice from being forgotten."],
	["Frostmere White Gallery", "The Frozen Pursuer", "Frostfall", "Guides sheltered a caravan in a white gallery.", "Their footprints led the lost through the storm."],
	["Suncrest Ember Vault", "The Ember Tyrant", "Solar flare", "Traders buried supplies beneath the desert road.", "Those stores fed the people who followed them."],
	["Orchard Root Refuge", "The Hollowed Root", "Root tremor", "The oldest roots covered an underground refuge.", "The keepers left seeds so the shelter could grow again."],
	["Ravenhold Iron Passage", "The Iron Ravager", "Iron shock", "A fortress patrol held this narrow passage.", "Its last guard gave the refugees time to cross."],
	["Duskhaven Lantern Crypt", "The Lantern Shade", "Twilight strike", "A lantern burned beneath Duskhaven's twilight.", "Its light revealed records the Keeper tried to hide."],
	["The Deep's Builder Vault", "The Stone Delver", "Stonefall", "Builders shaped a road below the surface.", "They marked it for anyone brave enough to follow."],
	["Starfall's Fallen Chamber", "The Fallen Star", "Starlight burst", "Fragments fell around the first starfall.", "Watchers protected their light from the Hollow."],
	["Evergloom's Silent Gate", "The Gate Devourer", "Gloom pulse", "Investigators found a gate in abandoned Evergloom.", "They closed it before the creatures reached the road."],
	["Aetheris Seal Archive", "The Sealbreaker", "Seal rupture", "The archivists stored a record beneath Aetheris.", "It describes the Seals as a promise shared by all."],
	["Ashvale Common Hearth", "The Hearth Warden", "Hearthfire", "Neighbours kindled a fire in a forgotten shelter.", "No Gift was needed to keep one another warm."],
	["Capital's Watch Crypt", "The Watch Commander", "Oath's recoil", "The watch refused an order to abandon the outer ward.", "They stayed until every family had passed."],
	["Lunareth Echo Library", "The Silent Librarian", "Echo flare", "A library recorded the voices of refugees.", "Its echoes carried the truth beyond the Silence."],
	["Tidefall Bell Grotto", "The Drowned Ringer", "Bellwave", "A bell rang through the flooded grotto.", "Its sound warned the last boat away from danger."],
	["Glassheaven Mirror Vault", "The Mirror Sentinel", "Mirror burst", "Artisans hid a mirror beneath the crystal city.", "It reflected the light of a Seal into the darkness."],
	["Frostmere Winter Reliquary", "The Winter Revenant", "Winter pulse", "A guide left winter provisions for strangers.", "Their promise was that nobody would face the cold alone."],
]
const COLORS := [Color(0.98, 0.65, 0.34), Color(0.74, 0.70, 0.88), Color(0.60, 0.79, 1.0), Color(0.40, 0.84, 0.84), Color(0.86, 0.67, 1.0)]


static func get_design(id: String) -> Dictionary:
	if not id.begins_with("optional_") or id.length() != 12: return {}
	var suffix := id.substr(9)
	if not suffix.is_valid_int(): return {}
	var index := int(suffix)
	if index < 0 or index >= ENTRIES.size() or id != "optional_%03d" % index: return {}
	var row: Array = ENTRIES[index]
	var side := -1 if index % 2 == 0 else 1
	return {"name": row[0], "theme": row[0].to_upper(), "boss": row[1],
		"hazard": row[2], "first": row[3], "second": row[4],
		"side": side, "color": COLORS[index % COLORS.size()],
		"depth": 24 + (index % 4) * 4, "rule": "ordered" if index % 2 == 0 else "guarded",
		"attack": ["slash", "ring", "circle"][index % 3],
		"runes": [Vector3(-side * 6, 0, -6), Vector3(side * 14, 0, 2 if index % 3 == 0 else -2)],
		"columns": [Vector3(side * -6, 0, 3), Vector3(side * 6, 0, -6), Vector3(side * 14, 0, 3)]}
