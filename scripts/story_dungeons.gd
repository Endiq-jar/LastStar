extends RefCounted
## Stable story-dungeon IDs. Existing Ashvale, Memory Vault and Suncrest Roost
## remain in Game.STORY_MEMORIES; these records provide the remaining 22.
## Encounters deliberately share the Hollow arena and creature families.
const ENTRIES := [
	{"id":"memory_04", "name":"The First Warning", "lore":"Ashvale's watch saw the stars dim before the first Hollow opened.", "site":0, "slot":0},
	{"id":"memory_05", "name":"A Shared Flame", "lore":"Neighbours kept a common fire alight when individual Gifts failed.", "site":0, "slot":1},
	{"id":"memory_06", "name":"The Guard's Oath", "lore":"The first Star Guard swore to protect people, not the secrets of rulers.", "site":1, "slot":0},
	{"id":"memory_07", "name":"The Crown's Bargain", "lore":"The capital sent its strongest Gifted to hold a breach while families fled.", "site":1, "slot":1},
	{"id":"memory_08", "name":"The Scholar's Page", "lore":"Lunareth's scholars discovered that memories could anchor the light.", "site":2, "slot":0},
	{"id":"memory_09", "name":"The Wander's Mark", "lore":"A Wander recorded the voices of many people, not just its owner.", "site":2, "slot":1},
	{"id":"memory_10", "name":"The Tidal Road", "lore":"Tidefall's boats carried strangers to safety across a dark sea.", "site":3, "slot":0},
	{"id":"memory_11", "name":"The Drowned Bell", "lore":"A bell beneath the waves warned the coast when the Hollow returned.", "site":3, "slot":1},
	{"id":"memory_12", "name":"A Prism of Voices", "lore":"Glassheaven's crystals preserved voices from the night of the Silence.", "site":4, "slot":0},
	{"id":"memory_13", "name":"The Broken Lens", "lore":"A lens showed that the Seals could be renewed by light freely shared.", "site":4, "slot":1},
	{"id":"memory_14", "name":"The Frozen Passage", "lore":"Frostmere's guides held open a mountain pass for the fleeing caravans.", "site":5, "slot":0},
	{"id":"memory_15", "name":"The Winter Promise", "lore":"The survivors promised no settlement would have to stand alone again.", "site":5, "slot":1},
	{"id":"memory_16", "name":"The Caravan's Map", "lore":"Suncrest's traders carried the locations of the Seals beyond the desert.", "site":6, "slot":0},
	{"id":"memory_17", "name":"The Keeper's Name", "lore":"Once, the Keeper was among the people who defended the last caravan.", "site":6, "slot":1},
	{"id":"memory_18", "name":"The Orchard's Roots", "lore":"In the Orchard, roots sheltered children from the creatures above.", "site":7, "slot":0},
	{"id":"memory_19", "name":"The Seed of Light", "lore":"The trees grew around remnants of light that the people had saved.", "site":7, "slot":1},
	{"id":"memory_20", "name":"The Fortress Wall", "lore":"Ravenhold's defenders held a breach until the final refugees escaped.", "site":8, "slot":0},
	{"id":"memory_21", "name":"The Shield's Cost", "lore":"The Keeper watched friends fall and came to fear freedom more than silence.", "site":8, "slot":1},
	{"id":"memory_22", "name":"The Twilight Witness", "lore":"Duskhaven remembered that the Keeper began sealing away memories as well as Hollows.", "site":9, "slot":0},
	{"id":"memory_23", "name":"The Missing Voices", "lore":"Without those memories, people mistook the Keeper's control for the only protection.", "site":9, "slot":1},
	{"id":"memory_24", "name":"The Underground Path", "lore":"The Deep's builders left a path beneath Aetheris to the heart of the Seals.", "site":10, "slot":0},
	{"id":"memory_25", "name":"The Last Star", "lore":"The Seals need not belong to one Keeper: shared light can hold them together.", "site":10, "slot":1},
]


static func by_id(id: String) -> Dictionary:
	for entry in ENTRIES:
		if entry["id"] == id: return entry
	return {}
