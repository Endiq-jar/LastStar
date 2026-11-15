extends RefCounted
## Small playable outposts named for the settlements in Resources.txt. Positions
## are stable; changing an id would orphan saved quest progress.
const SITES := [
	{"id":"ashvale", "name":"Ashvale", "pos":Vector2(36, 40), "npc":"Mira", "role":"hearthkeeper", "lore":"Ashvale keeps the first lamps lit for travellers leaving the shore.", "main":"Guard dispatch", "side":"Family keepsake"},
	{"id":"capital", "name":"Elaris Capital", "pos":Vector2(390, -440), "npc":"Captain Ren", "role":"Star Guard captain", "lore":"The capital sends the Star Guard to investigate breaches near the Seven Seals.", "main":"Seal report", "side":"Patrol insignia"},
	{"id":"lunareth", "name":"Lunareth", "pos":Vector2(-390, -560), "npc":"Scholar Veya", "role":"Wander scholar", "lore":"Our scholars study the marks that Gifts leave on forgotten pages.", "main":"Research folio", "side":"Lost lens"},
	{"id":"tidefall", "name":"Tidefall", "pos":Vector2(610, 390), "npc":"Neri", "role":"coastal courier", "lore":"The tide carries strange memories from the First Silence to our shores.", "main":"Tide chart", "side":"Seafarer's charm"},
	{"id":"glassheaven", "name":"Glassheaven", "pos":Vector2(-720, 280), "npc":"Prism", "role":"crystal artisan", "lore":"Glassheaven's crystal workers can read a faint light inside Remnants.", "main":"Prism sample", "side":"Polishing stone"},
	{"id":"frostmere", "name":"Frostmere", "pos":Vector2(-800, -930), "npc":"Bryn", "role":"mountain guide", "lore":"Our winter trails hide tracks of creatures escaping the Hollows.", "main":"Trail record", "side":"Warming charm"},
	{"id":"suncrest", "name":"Suncrest", "pos":Vector2(1020, -740), "npc":"Zara", "role":"trade scout", "lore":"Suncrest's caravans carry news between settlements before the storms arrive.", "main":"Caravan ledger", "side":"Merchant's seal"},
	{"id":"orchard", "name":"Whispering Orchard", "pos":Vector2(-1110, 620), "npc":"Orin", "role":"orchard keeper", "lore":"The oldest trees whisper of a time before the First Silence.", "main":"Bark rubbing", "side":"Seed pouch"},
	{"id":"ravenhold", "name":"Ravenhold", "pos":Vector2(1300, 450), "npc":"Tamsin", "role":"fortress sentry", "lore":"Our sentries watch the roads for Hollow creatures and lost travellers.", "main":"Sentry orders", "side":"Watch bell"},
	{"id":"duskhaven", "name":"Duskhaven", "pos":Vector2(-1400, -300), "npc":"Nox", "role":"twilight warden", "lore":"Duskhaven's long twilight makes even familiar roads feel strange.", "main":"Twilight notes", "side":"Lantern lens"},
	{"id":"deep", "name":"The Deep", "pos":Vector2(1500, -1150), "npc":"Delve", "role":"underworld envoy", "lore":"Our people come to the surface when the passages begin to hum.", "main":"Passage sketch", "side":"Miner's token"},
	{"id":"starfall", "name":"Starfall Haven", "pos":Vector2(450, 1400), "npc":"Aster", "role":"star watcher", "lore":"Our haven grew around a fallen star whose light never quite fades.", "main":"Star fragment notes", "side":"Skywatch ribbon"},
	{"id":"evergloom", "name":"Evergloom", "pos":Vector2(-1450, 1200), "npc":"Rook", "role":"Hollow investigator", "lore":"Evergloom was abandoned when the Hollows began to change the land.", "main":"Hollow survey", "side":"Explorer's compass"},
	{"id":"aetheris", "name":"Aetheris", "pos":Vector2(1450, 1300), "npc":"Seren", "role":"seal archivist", "lore":"Aetheris remembers the Seven Seals, even if their makers are forgotten.", "main":"Seal inscription", "side":"Archive key"},
]


static func by_id(id: String) -> Dictionary:
	for site in SITES:
		if site["id"] == id:
			return site
	return {}
