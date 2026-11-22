extends RefCounted
## Hand-authored first batch. IDs are existing memory IDs and never change.
## Rune positions are deliberately clear of the entrance, exit and guardians.
const DESIGNS := {
	"memory_04": {
		"side": -1, "color": Color(0.52, 0.76, 1.0), "boss": "The Dimming Watcher",
		"theme": "THE WATCHTOWER", "first": "The watch saw a star flicker out above Ashvale.",
		"second": "Its warning reached the village before the first Hollow opened.",
		"runes": [Vector3(5, 0, -6), Vector3(-14, 0, -2)],
		"columns": [Vector3(-6, 0, -6), Vector3(6, 0, 3)]
	},
	"memory_05": {
		"side": 1, "color": Color(1.0, 0.59, 0.27), "boss": "The Ashen Devourer",
		"theme": "THE COMMON HEARTH", "first": "One by one, the villagers' Gifts went dark.",
		"second": "They fed one shared flame until their neighbours found shelter.",
		"runes": [Vector3(-6, 0, -5), Vector3(14, 0, 2)],
		"columns": [Vector3(-5, 0, 3), Vector3(6, 0, -6), Vector3(14, 0, -3)]
	},
	"memory_06": {
		"side": -1, "color": Color(0.91, 0.84, 0.52), "boss": "The Oathbreaker",
		"theme": "THE GUARD'S SANCTUM", "first": "The first Star Guard was ordered to protect a ruler's secrets.",
		"second": "Instead, they swore to protect the people who had been left behind.",
		"runes": [Vector3(6, 0, -5), Vector3(-14, 0, 2)],
		"columns": [Vector3(-6, 0, -6), Vector3(6, 0, -6), Vector3(-14, 0, -3)]
	},
	"memory_07": {
		"side": 1, "color": Color(0.87, 0.48, 0.57), "boss": "The Breach Tyrant",
		"theme": "THE CROWN'S BREACH", "first": "The capital's strongest Gifted stood at a widening breach.",
		"second": "Their bargain bought the fleeing families a road to safety.",
		"runes": [Vector3(-6, 0, -6), Vector3(14, 0, -2)],
		"columns": [Vector3(-6, 0, 3), Vector3(6, 0, 3), Vector3(14, 0, 3)]
	},
	"memory_08": {
		"side": -1, "color": Color(0.71, 0.55, 1.0), "boss": "The Forgotten Curator",
		"theme": "THE SCHOLAR'S ARCHIVE", "first": "A scholar recorded voices rather than the names of kings.",
		"second": "Those memories could anchor the light when Gifts alone could not.",
		"runes": [Vector3(6, 0, -6), Vector3(-14, 0, -2)],
		"columns": [Vector3(-6, 0, -6), Vector3(6, 0, 3), Vector3(-14, 0, 3)]
	}
}


static func get_design(id: String) -> Dictionary:
	return DESIGNS.get(id, {})
