extends RefCounted
## Stable offline stock. Collectibles use the existing inventory and save data;
## all stalls also carry the original Wanderer's Shop supplies.
const BUY_PRICE := 45
const SELL_PRICE := 15
const SHOPS := {
	"ashvale": {"merchant": "Luma", "name": "Hearthside Supplies", "item": "Starflower"},
	"capital": {"merchant": "Corin", "name": "Guard Road Market", "item": "Moonstone"},
	"lunareth": {"merchant": "Selen", "name": "Scholar's Counter", "item": "Moonstone"},
	"tidefall": {"merchant": "Miko", "name": "Tide Market", "item": "Stormglass"},
	"glassheaven": {"merchant": "Vela", "name": "Prism Exchange", "item": "Moonstone"},
	"frostmere": {"merchant": "Torren", "name": "Pass Provisioner", "item": "Stormglass"},
	"suncrest": {"merchant": "Dalia", "name": "Caravan Market", "item": "Sunshard"},
	"orchard": {"merchant": "Wren", "name": "Orchard Stall", "item": "Starflower"},
	"ravenhold": {"merchant": "Fenn", "name": "Sentry Supplies", "item": "Sunshard"},
	"duskhaven": {"merchant": "Mora", "name": "Twilight Market", "item": "Moonstone"},
	"deep": {"merchant": "Brann", "name": "Passage Market", "item": "Moonstone"},
	"starfall": {"merchant": "Solin", "name": "Starwatch Supplies", "item": "Sunshard"},
	"evergloom": {"merchant": "Lark", "name": "Pathfinder's Stall", "item": "Stormglass"},
	"aetheris": {"merchant": "Aven", "name": "Sealkeeper's Market", "item": "Starflower"},
}


static func by_id(site_id: String) -> Dictionary:
	return SHOPS.get(site_id, {})
