extends RefCounted
## Authored narratives for the fourteen leaders' existing side-quest IDs.
## Each stage corresponds to the existing available/active/found/done state;
## the physical item, rewards and old saves remain unchanged.
const STORIES := {
	"ashvale": {
		"title": "The Place at the Hearth",
		"available": "Mira: A family left a keepsake by the road before the patrol vanished. They are afraid the Guard will call asking about it disloyal. Please find it; I promised them a place to speak without an officer listening.",
		"active": "Mira: The family keepsake is marked near Ashvale. Bring it to me, not the Guard's archive.",
		"found": "A small keepsake carries a child's stitching and a note: save my place by the fire. Mira should bring it to the family.",
		"done": "Mira: The family asked me to leave the place set, even on nights they cannot bear to sit there. Remembering someone does not have to happen on the Guard's timetable.",
		"after": "Mira: The family brought the keepsake to the hearth themselves. No one asked them to explain why they were ready now."
	},
	"capital": {
		"title": "The Badge and the Oath",
		"available": "Ren: One of my recruits discarded a patrol insignia after I refused to answer a family's questions. I need to return it and listen to why. Will you recover it?",
		"active": "Ren: The patrol insignia is marked near the capital. Bring it back; I owe that recruit a conversation.",
		"found": "The insignia is scratched but intact. Inside is the recruit's own copy of the Guard's oath, underlined at protect the people.",
		"done": "Ren: The recruit accepted the badge only after I agreed to meet the family. I cannot command their trust back, but I can earn it one answer at a time.",
		"after": "Ren: That recruit now teaches the oath to new guards. The questions are part of the lesson."
	},
	"lunareth": {
		"title": "The Lens in the Margin",
		"available": "Veya: My apprentice misplaced a lost lens while trying to read an erased annotation. I scolded her for risking a record, but never asked why she was afraid to bring me the page. Could you find the lens?",
		"active": "Veya: The lost lens is marked near Lunareth. Please bring it back so my apprentice can finish reading safely.",
		"found": "The lens magnifies a note on its case: Ask before correcting another person's words. Veya's apprentice wrote it for herself.",
		"done": "Veya: We read the page together without overwriting it. My apprentice has permission to challenge my interpretations; I should have offered that before she needed to ask.",
		"after": "Veya: My apprentice now keeps the archive's margin notes alongside the official copies, with each writer's permission."
	},
	"tidefall": {
		"title": "A Charm for the Return",
		"available": "Neri: A seafarer's charm belongs to a courier who always returned for the last boat. Their crew will sail without it, but they asked for one more chance to carry it home. Please find it.",
		"active": "Neri: The seafarer's charm is marked near Tidefall. Bring it here before the crew's next crossing.",
		"found": "The charm is knotted with three different cords. Each crew member tied one, so nobody would mistake a shared promise for a captain's order.",
		"done": "Neri: The crew tied a fourth cord for the people waiting on shore. The charm is theirs again, and they have promised to signal before turning back.",
		"after": "Neri: Those four cords hang beside the crews' new warning signals. Every boat has someone listening."
	},
	"glassheaven": {
		"title": "A Flaw Worth Keeping",
		"available": "Prism: A polishing stone was borrowed to erase a crack in a family crystal. The crack holds the only voice its owner recognises. Please find the stone before anyone polishes it away.",
		"active": "Prism: The polishing stone is marked near Glassheaven. Bring it to me so we can show the family what the crack contains.",
		"found": "The stone is wrapped in a note from the artisan: I thought a perfect surface would make them happy. Prism should hear this before the crystal is altered.",
		"done": "Prism: The family chose to keep the crack and invited the artisan to hear the voice. A repair can protect a memory without making it look untouched.",
		"after": "Prism: The artisan now asks what a family wants preserved before touching a crystal. The cracked recording is still audible."
	},
	"frostmere": {
		"title": "Warmth for the Rear Guide",
		"available": "Bryn: A warming charm was meant for the guide who brings up the rear. It was lost while we argued about who should take that dangerous place. Find it and I will make sure no one walks there alone.",
		"active": "Bryn: The warming charm is marked near Frostmere. Bring it back before the next group leaves for the pass.",
		"found": "The charm has two attachment loops, not one. It was designed to be shared between guides travelling together.",
		"done": "Bryn: Two guides will carry it between them. We cannot promise the road is safe, but we can stop pretending that leaving someone alone makes them brave.",
		"after": "Bryn: The rear guides still share the warming charm. They check each other's return, not just the number of people ahead."
	},
	"suncrest": {
		"title": "The Unstamped Caravan",
		"available": "Zara: A merchant's seal was lost before a caravan could leave. Without it the checkpoint will turn away the whole group, including families who have nothing to trade. Help me recover it.",
		"active": "Zara: The merchant's seal is marked near Suncrest. Bring it to me before the caravan reaches the checkpoint.",
		"found": "The seal's ledger lists passengers in the margin, separate from cargo. Someone refused to count the families as goods.",
		"done": "Zara: The caravan can pass. I asked the checkpoint to record the passengers as people, not cargo; the merchants agreed to carry that rule to the next stop.",
		"after": "Zara: The caravan's new ledger has a place for passengers and for the names they choose to give."
	},
	"orchard": {
		"title": "Seeds with No Owner",
		"available": "Orin: A seed pouch was set aside for the children who sheltered under the old roots. Some neighbours want to claim it for the oldest family. Please find it before the next planting.",
		"active": "Orin: The seed pouch is marked near the Orchard. Bring it to me so the children can decide where to plant.",
		"found": "The pouch contains seeds from several trees and no owner's mark. A child's drawing shows many hands planting together.",
		"done": "Orin: The children chose a shared patch, and the neighbours agreed to tend it in turn. No single family owns the shade it will make.",
		"after": "Orin: The shared patch has sprouted. The children made a rota so every family can help care for it."
	},
	"ravenhold": {
		"title": "The Bell for Retreat",
		"available": "Tamsin: A watch bell went missing from a drill. The old orders taught us how to stand but not when to withdraw. Find the bell; I intend to teach both signals.",
		"active": "Tamsin: The watch bell is marked near Ravenhold. Bring it to the sentries before the next drill.",
		"found": "One side of the bell is marked hold; the other is marked return. The return mark was worn almost smooth from neglect.",
		"done": "Tamsin: We rang both signals. Some sentries felt retreat sounded like failure, until the families told them they wanted the watch to come home too.",
		"after": "Tamsin: The return signal is now part of every drill. The watch knows which road the families will take."
	},
	"duskhaven": {
		"title": "A Lantern for the Copyist",
		"available": "Nox: A lantern lens belongs to the copyist who preserved a witness statement in secret. They are afraid to claim it while people still call their work a lie. Please bring it back.",
		"active": "Nox: The lantern lens is marked near Duskhaven. Bring it to me; the copyist will not have to come forward alone.",
		"found": "The lens carries a tiny etched correction: this account is a copy. The copyist wanted readers to know exactly what they were seeing.",
		"done": "Nox: The copyist took back the lens and agreed to show the corrections beside the original. We will protect their name if they choose to remain anonymous.",
		"after": "Nox: The copyist's corrections have their own place in the archive. Their name stays private unless they decide otherwise."
	},
	"deep": {
		"title": "A Token for the Surface",
		"available": "Delve: A miner's token belongs to an apprentice sent to the surface for help. They feared the surface would ignore a request without an official seal. Recover it, and I will go with them.",
		"active": "Delve: The miner's token is marked near the Deep. Bring it to me so the apprentice can make their request.",
		"found": "The token bears a hand-drawn tunnel and two arrows: one toward the surface, one home. It was made to help its bearer find their way back.",
		"done": "Delve: We delivered the request together. The apprentice spoke for themself; I was there to make sure the surface heard them.",
		"after": "Delve: That apprentice now helps both teams mark the repair route. Every surface sign has a matching way home."
	},
	"starfall": {
		"title": "The Second Observer",
		"available": "Aster: A skywatch ribbon belongs to a second observer whose notes were left out of our star records. They stopped attending the watch. Find the ribbon and I will ask whether they want their observations restored.",
		"active": "Aster: The skywatch ribbon is marked near Starfall Haven. Bring it back so I can visit its owner.",
		"found": "The ribbon is tied around a sketch of the falling star from a different hill. The second observer saw its path from another angle.",
		"done": "Aster: The observer agreed to add the sketch, provided the difference is left visible. Two views make a better record than one corrected to match.",
		"after": "Aster: Both observations hang at the watch, with their different angles intact. New observers can add their own."
	},
	"evergloom": {
		"title": "The Road Back",
		"available": "Rook: An explorer's compass was left by a family considering a return to Evergloom. They do not want the town declared safe on their behalf. Recover it and I will show them the survey.",
		"active": "Rook: The explorer's compass is marked near Evergloom. Bring it back and we can let the family make their own decision.",
		"found": "The compass cover contains two routes, one into the town and one away. The family planned for both possibilities.",
		"done": "Rook: The family chose to visit first, not move back yet. I gave them the survey without asking them to call their decision courageous or afraid.",
		"after": "Rook: The family still visits on its own terms. The return road stays open whether or not they choose to settle."
	},
	"aetheris": {
		"title": "A Key with Two Hands",
		"available": "Seren: An archive key was hidden by two keepers who feared the records could be locked away again. Find it; I want their successors to decide together how the archive opens.",
		"active": "Seren: The archive key is marked near Aetheris. Bring it to me, and I will invite both successors to read the conditions.",
		"found": "The key is accompanied by a note: no single hand should close the archive. It names two successors rather than one owner.",
		"done": "Seren: Both successors agreed on public hours and a private room for sensitive testimony. Opening an archive also means respecting what people choose not to publish.",
		"after": "Seren: The successors still share the key. Witnesses can read the records and request privacy for their own words."
	}
}
