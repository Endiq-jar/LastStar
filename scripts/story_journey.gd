extends RefCounted
## The 25 established story memories arranged as a narrative reading order.
## This is journal guidance, not a new gate: a Hollow cleared out of order is
## credited immediately by its existing permanent save flag.
const ACTS := [
	{
		"title": "Act I · The Missing Patrol",
		"intro": "Ashvale's lamps are failing and a patrol's names have vanished from the record. Follow the first warnings and learn what the Guard was ordered to protect.",
		"conclusion": "The patrol stayed, the warning was altered, and the first Guard put people before a sealed order. The missing names are part of a larger history, not an accident in one watch book.",
		"quests": [
			{"id": "ashvale", "brief": "Enter Ashvale Hollow with Ilyra's quest and recover the patrol's fragment."},
			{"id": "memory_04", "brief": "Investigate the watchtower's warning near Ashvale and find what was sent onward."},
			{"id": "memory_05", "brief": "Search the common hearth near Ashvale for how neighbours survived when Gifts failed."},
			{"id": "memory_06", "brief": "Follow the Guard's first oath near Elaris Capital and question the sealed order."},
			{"id": "memory_07", "brief": "Explore the capital breach and discover the bargain made while families fled."}
		]
	},
	{
		"title": "Act II · Voices in the Light",
		"intro": "The Guard's records are incomplete. Lunareth's scholars and Tidefall's crews may have preserved what official accounts missed.",
		"conclusion": "The Vault describes shields rather than prisons. The scholars' pages, a Wander and the coast's warnings show that ordinary voices carried knowledge through the Silence.",
		"quests": [
			{"id": "memory_08", "brief": "Recover the scholar's page near Lunareth and investigate how memories interact with light."},
			{"id": "memory_09", "brief": "Trace the Wander's mark near Lunareth and listen for the voices in its margins."},
			{"id": "memory_vault", "brief": "Enter the Memory Vault near Lunareth and recover the oldest record of the Seven Seals."},
			{"id": "memory_10", "brief": "Follow Tidefall's tidal road and learn what its crews carried across the dark water."},
			{"id": "memory_11", "brief": "Search for the drowned bell near Tidefall and discover how the coast was warned."}
		]
	},
	{
		"title": "Act III · The Promise",
		"intro": "The surviving accounts point beyond a single settlement. Follow the crystals, mountain guides and caravan routes to understand the promise they carried.",
		"conclusion": "Crystals preserved many voices; a broken lens showed a pattern of shared light. The survivors carried a promise across the pass and hid their routes in ordinary cargo.",
		"quests": [
			{"id": "memory_12", "brief": "Listen to the prism of voices near Glassheaven and recover its interrupted account."},
			{"id": "memory_13", "brief": "Investigate the broken lens near Glassheaven and its scattered light."},
			{"id": "memory_14", "brief": "Trace the frozen passage near Frostmere and learn what happened to the guide at the rear."},
			{"id": "memory_15", "brief": "Find the winter promise near Frostmere and hear what the survivors pledged."},
			{"id": "memory_16", "brief": "Recover the caravan's map near Suncrest and follow the missing pieces of its route."}
		]
	},
	{
		"title": "Act IV · The Keeper's Shadow",
		"intro": "The caravan left traces across Elaris. Follow them through Suncrest, the Orchard and Ravenhold to understand the people behind the title Keeper.",
		"conclusion": "The Keeper was once a caravan guard who witnessed terrible losses. The Orchard and Ravenhold remember people protected by others, but also the cost of holding the line.",
		"quests": [
			{"id": "suncrest_roost", "brief": "Enter Suncrest Roost and discover why the dragon guards the caravan's memory."},
			{"id": "memory_17", "brief": "Find the Keeper's name near Suncrest and discover who travelled with the caravan."},
			{"id": "memory_18", "brief": "Search the Orchard's roots for the missing account of the sheltered children."},
			{"id": "memory_19", "brief": "Recover the seed of light near the Orchard and learn what grew from the survivors' refuge."},
			{"id": "memory_20", "brief": "Investigate Ravenhold's wall and the defenders who held the breach."}
		]
	},
	{
		"title": "Act V · The Last Star",
		"intro": "Ravenhold's loss changed the Keeper. Seek the witnesses and the builders' path before confronting what the Seals have become.",
		"conclusion": "Fear led the Keeper to silence witnesses. The builders left a road for repair, and the final record reveals a different answer: the Seals can be tended with light freely shared.",
		"quests": [
			{"id": "memory_21", "brief": "Search Ravenhold for the shield's cost and understand how the Keeper's fear hardened."},
			{"id": "memory_22", "brief": "Find the twilight witness near Duskhaven and recover the account someone tried to erase."},
			{"id": "memory_23", "brief": "Follow the missing voices near Duskhaven and learn what the official record left out."},
			{"id": "memory_24", "brief": "Explore the underground path near the Deep and recover the builders' instructions."},
			{"id": "memory_25", "brief": "Recover the last star's record near the Deep and discover how the Seal pattern can be renewed."}
		]
	}
]
