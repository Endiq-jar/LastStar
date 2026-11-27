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


const RESIDENT_COUNT := 20
const FIRST_NAMES := ["Ari", "Bela", "Cira", "Daren", "Eli", "Fara", "Galen", "Hana", "Iven", "Jori", "Kira", "Lio", "Maren", "Navi", "Oren", "Pera", "Quin", "Risa", "Tavi"]
const ROLES := ["baker", "apprentice", "gardener", "mason", "traveller", "weaver", "caretaker", "scribe", "courier", "forager", "carpenter", "musician", "cook", "herbalist", "hunter", "potter", "archivist", "trader", "watcher"]
const MAIN_ITEMS := ["supply list", "old letter", "settlement record", "guard note", "travel journal", "repair plans", "lantern order", "archive page", "sealed message", "trail sketch", "building plan", "song fragment", "provision ledger", "herb journal", "tracking notes", "trade charter", "lost chapter", "cargo list", "watch report"]
const SIDE_ITEMS := ["bread basket", "practice charm", "seed packet", "carving tool", "travel badge", "thread bundle", "spare key", "writing pen", "satchel clasp", "gathering pouch", "woodworking gauge", "small bell", "recipe card", "flower press", "trail marker", "painted cup", "reading lens", "coin purse", "lantern hook"]


static func resident(site_id: String, index: int) -> Dictionary:
	var site := by_id(site_id)
	if site.is_empty() or index < 0 or index >= RESIDENT_COUNT:
		return {}
	if index == 0:
		return {"name": site["npc"], "role": site["role"], "main": site["main"], "side": site["side"]}
	var i := index - 1
	return {"name": FIRST_NAMES[i], "role": ROLES[i], "main": MAIN_ITEMS[i], "side": SIDE_ITEMS[i]}


static func quest_offset(index: int, kind: String) -> Vector2:
	if index == 0:
		return Vector2(0, -27) if kind == "main" else Vector2(27, 0)
	var slot := index - 1
	var angle := TAU * float(slot % 10) / 10.0 + (PI / 10.0 if kind == "side" else 0.0)
	var radius := 32.0 + float(slot / 10) * 11.0
	return Vector2(sin(angle), -cos(angle)) * radius


static func resolve_site(origin: Vector2, height: Callable, wet: Callable) -> Vector2:
	# Avoid water and excessive gradients; deterministic offsets keep quest IDs
	# and settlement locations stable across saves.
	for radius in [0.0, 40.0, 80.0, 120.0, 180.0, 250.0, 350.0, 500.0]:
		for i in range(8):
			var p: Vector2 = origin + Vector2(cos(TAU * i / 8.0), sin(TAU * i / 8.0)) * radius
			if bool(wet.call(p.x, p.y)):
				continue
			var h := float(height.call(p.x, p.y))
			if h < 2.0:
				continue
			var good := true
			for offset in [Vector2(-12, -6), Vector2(12, -6), Vector2(0, 14)]:
				var q: Vector2 = p + offset
				var low := INF
				var high := -INF
				for corner in [Vector2(-3, -3), Vector2(-3, 3), Vector2(3, -3), Vector2(3, 3), Vector2.ZERO]:
					var sample: Vector2 = q + corner
					if bool(wet.call(sample.x, sample.y)):
						good = false
					var y := float(height.call(sample.x, sample.y))
					low = minf(low, y)
					high = maxf(high, y)
				if high - low > 2.0 or absf(high - h) > 12.0:
					good = false
			for offset in [Vector2(0, -27), Vector2(27, 0)]:
				var q: Vector2 = p + offset
				if bool(wet.call(q.x, q.y)) or absf(float(height.call(q.x, q.y)) - h) > 12.0:
					good = false
			if good:
				return p
	return origin
