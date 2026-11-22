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
	},
	"memory_09": {
		"side": 1, "color": Color(0.60, 0.67, 1.0), "boss": "The Silent Scribe",
		"theme": "THE WANDER'S VAULT", "first": "A Wander gathered the voices of those who could no longer speak.",
		"second": "Its pages prove that a Gift belongs to the people it protects.",
		"runes": [Vector3(-6, 0, -5), Vector3(14, 0, 2)],
		"columns": [Vector3(-6, 0, -6), Vector3(6, 0, 3), Vector3(14, 0, -3)]
	},
	"memory_10": {
		"side": -1, "color": Color(0.25, 0.72, 0.94), "boss": "The Tidebound Warden",
		"theme": "THE TIDAL ROAD", "first": "Tidefall's boats waited beyond the darkened harbour.",
		"second": "Their crews ferried strangers to safety through the black water.",
		"runes": [Vector3(6, 0, -6), Vector3(-14, 0, 2)],
		"columns": [Vector3(-6, 0, -6), Vector3(6, 0, -6), Vector3(-14, 0, -3)]
	},
	"memory_11": {
		"side": 1, "color": Color(0.42, 0.82, 0.80), "boss": "The Drowned Bellkeeper",
		"theme": "THE DROWNED BELFRY", "first": "A bell rang beneath the waves when the Hollow returned.",
		"second": "The warning carried across the coast and gave the boats time to flee.",
		"runes": [Vector3(-6, 0, -6), Vector3(14, 0, -2)],
		"columns": [Vector3(-6, 0, 3), Vector3(6, 0, 3), Vector3(14, 0, 3)]
	},
	"memory_12": {
		"side": -1, "color": Color(0.94, 0.68, 1.0), "boss": "The Fractured Voice",
		"theme": "THE PRISM CHOIR", "first": "Glassheaven's crystals held the voices of the lost.",
		"second": "Together those voices preserved the night of the First Silence.",
		"runes": [Vector3(5, 0, -6), Vector3(-14, 0, -2)],
		"columns": [Vector3(-6, 0, -6), Vector3(6, 0, 3), Vector3(-14, 0, 3)]
	},
	"memory_13": {
		"side": 1, "color": Color(0.90, 0.84, 1.0), "boss": "The Shattered Lens",
		"theme": "THE BROKEN OBSERVATORY", "first": "A broken lens scattered the light of the Seven Seals.",
		"second": "When freely shared, those fragments could renew what was failing.",
		"runes": [Vector3(-6, 0, -5), Vector3(14, 0, 2)],
		"columns": [Vector3(-5, 0, 3), Vector3(6, 0, -6), Vector3(14, 0, -3)]
	},
	"memory_14": {
		"side": -1, "color": Color(0.67, 0.86, 1.0), "boss": "The White Pass Sentinel",
		"theme": "THE FROZEN PASSAGE", "first": "Frostmere's guides marked a path through the storm.",
		"second": "They held the pass open until the last caravan escaped.",
		"runes": [Vector3(6, 0, -6), Vector3(-14, 0, 2)],
		"columns": [Vector3(-6, 0, -6), Vector3(6, 0, -6), Vector3(-14, 0, -3)]
	},
	"memory_15": {
		"side": 1, "color": Color(0.70, 0.93, 0.98), "boss": "The Winter Oathkeeper",
		"theme": "THE WINTER PROMISE", "first": "In the cold, the survivors gathered around one last fire.",
		"second": "They promised no settlement would face the Silence alone again.",
		"runes": [Vector3(-6, 0, -5), Vector3(14, 0, -2)],
		"columns": [Vector3(-5, 0, 3), Vector3(6, 0, -6), Vector3(14, 0, 3)]
	},
	"memory_16": {
		"side": -1, "color": Color(1.0, 0.76, 0.38), "boss": "The Caravan's Bane",
		"theme": "THE CARAVAN ROAD", "first": "Suncrest's traders hid the locations of the Seals among their wares.",
		"second": "Each caravan carried a fragment beyond the desert's reach.",
		"runes": [Vector3(5, 0, -6), Vector3(-14, 0, -2)],
		"columns": [Vector3(-6, 0, 3), Vector3(6, 0, -6), Vector3(-14, 0, 3)]
	},
	"memory_17": {
		"side": 1, "color": Color(0.96, 0.56, 0.34), "boss": "The Keeper's Shadow",
		"theme": "THE KEEPER'S NAME", "first": "The Keeper once fought beside the guards of the last caravan.",
		"second": "The losses they suffered would later harden their fear into control.",
		"runes": [Vector3(-6, 0, -6), Vector3(14, 0, 2)],
		"columns": [Vector3(-6, 0, 3), Vector3(6, 0, 3), Vector3(14, 0, -3)]
	},
	"memory_18": {
		"side": -1, "color": Color(0.51, 0.85, 0.56), "boss": "The Rootbound Guardian",
		"theme": "THE ORCHARD'S ROOTS", "first": "The Orchard's ancient trees bent over a hidden shelter.",
		"second": "Their roots protected the children while creatures searched above.",
		"runes": [Vector3(6, 0, -5), Vector3(-14, 0, 2)],
		"columns": [Vector3(-6, 0, -6), Vector3(6, 0, 3), Vector3(-14, 0, -3)]
	}
}


static func get_design(id: String) -> Dictionary:
	return DESIGNS.get(id, {})
