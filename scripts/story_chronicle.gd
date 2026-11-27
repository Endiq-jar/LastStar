extends RefCounted
## Recovered accounts keyed by the existing permanent Hollow IDs. Entries are
## presented only after their corresponding clear; no new save keys are needed.
const ACCOUNTS := {
	"ashvale": "The patrol did not flee. In the Hollow's last light, they held a breach open long enough for Ashvale's families to escape. One guard pressed a fragment into the stone: Tell them we stayed. Someone later called their silence desertion.",
	"memory_vault": "The Vault's oldest record describes seven shields, not seven prisons. A hand has crossed out the names of the people who raised them. Beneath the ink is a warning: a shield held by one hand can become a lock.",
	"suncrest_roost": "The dragon did not guard treasure. It guarded the last caravan and the scraps of knowledge hidden among its ordinary cargo. When the road burned, the travellers divided their record so no single loss could erase it.",
	"memory_04": "The Ashvale watch counted six lights in a sky that should have held seven. Their warning reached the village before the Hollow opened, but the message sent onward returned with its final line scraped away: The star is not the only thing missing.",
	"memory_05": "A baker's Gift failed as neighbours gathered at her door. She fed the hearth with the last of her stores anyway; others brought what they could. The shared flame lasted the night. The next page asks who taught them to share it.",
	"memory_06": "The first Star Guard was told to escort a sealed chest while families waited outside the gate. They broke their orders, opened the gate, and swore that the Guard would protect people before secrets. The oath survived; the order did not.",
	"memory_07": "At the capital's breach, Gifted defenders bought a road for fleeing families. Their commander agreed to a desperate bargain: hold the line while the Seals were raised. The surviving account does not say who gave that command.",
	"memory_08": "A Lunareth scholar recorded the voices of cooks, children and sentries instead of only rulers. When the light faltered, those memories held it steady for a moment. Their notes ask whether remembering together could do what power alone could not.",
	"memory_09": "A Wander carried words written by hands other than its owner's. Its margins argue over a dangerous idea: a Gift is personal, but its light can be freely offered. A later owner tried to remove every other voice from the pages.",
	"memory_10": "Tidefall's crews pushed off into black water with strangers aboard. A ferryman turned back for one more boat despite the warning bell. His passengers remembered a pale light moving beneath the waves, following the fleet.",
	"memory_11": "The drowned bell rang after its tower vanished beneath the sea. Each strike gave the coast time to flee another Hollow. The bellkeeper's last note asks why the warnings were arriving later each time.",
	"memory_12": "Glassheaven's crystals preserved voices the official record had lost. One voice insists the Seals were a promise made by many people; another begs that no one be left to bear them alone. The recording breaks before the answer.",
	"memory_13": "A broken lens split a Seal's light into separate colours. When the fragments were brought together willingly, the failing pattern steadied. Someone concealed the experiment, fearing that trust between strangers would never last.",
	"memory_14": "Frostmere's guides marked a path through a storm for the last caravans. The guide at the rear erased their own tracks to lead the creatures away. At the pass, survivors found one empty place beside the fire.",
	"memory_15": "Around that fire, the survivors promised that no settlement would face the Silence alone again. They carried the promise in different languages and different books. A later record calls their agreement an inconvenience.",
	"memory_16": "Suncrest's traders hid fragments of the Seal routes in ledgers and packages. No single caravan carried the whole map. One guard's name appears on every surviving page, then has been scratched out.",
	"memory_17": "The scratched-out guard became known as the Keeper. They fought beside the caravan, not above it, and counted the people they could not save. The title came later; the grief came first.",
	"memory_18": "The Orchard's roots sheltered children while Hollow creatures searched above. An elder stayed outside to draw them away. The children survived with a handful of seeds and a story they were told never to repeat.",
	"memory_19": "The surviving trees grew around small remnants of shared light. Their roots carried it farther than any one gardener could see. The Orchard kept growing even after the person who planted the first seed was forgotten.",
	"memory_20": "Ravenhold held a breach until the final refugees crossed its wall. The defenders sent word that the road was clear, but their own retreat was cut off. The Keeper arrived in time to see the wall fall.",
	"memory_21": "The Keeper counted the lives lost at Ravenhold and decided uncertainty was the enemy. They could not accept another promise that depended on people choosing to keep it. Protection slowly became a demand for obedience.",
	"memory_22": "A Duskhaven witness found that a Seal could close over memories as well as Hollows. The Keeper called the missing accounts a necessary mercy. The witness hid a copy, asking who would protect people from a shield they could not question.",
	"memory_23": "Without the missing voices, the surviving records made control look like the only answer. The witnesses were not in agreement about every event, but they agreed on this: silence had been mistaken for consent.",
	"memory_24": "Builders from the Deep left a passage under Aetheris for the day the Seals needed repair. Its instructions describe a way to reach the heart, not a weapon to destroy it. The last line reads: Bring witnesses.",
	"memory_25": "The last record completes the broken pattern: the Seven Seals can be renewed by light freely shared. No one person has to be its keeper. The question is whether Elaris can choose that responsibility together."
}

const REGION_HOOKS := {
	"ashvale": "Our lamps flicker on the same nights the patrol's names disappear from the watch book. Find my dispatch and I can show you where to look.",
	"capital": "Our orders mention an old breach, but the signature has been cut away. Bring me the report; the Guard deserves the whole story.",
	"lunareth": "A page of research vanished from the archive. It may explain why a memory can hold light when a Gift fails.",
	"tidefall": "The bell is ringing without a tower, and the crews are afraid to sail. My chart may show where the sound begins.",
	"glassheaven": "A crystal has begun repeating a voice no one here recognises. Find the sample and we can trace its source.",
	"frostmere": "The old trail markers have surfaced in the thaw. My record may lead to the pass where the caravans vanished.",
	"suncrest": "The caravans carried more than trade goods. Recover my ledger and I will share the old routes.",
	"orchard": "The oldest roots are exposing a shelter beneath the trees. A rubbing may tell us whose names were hidden there.",
	"ravenhold": "Our wall bears a repair older than any surviving order. Find the sentry records; I want to know who held it.",
	"duskhaven": "A witness left notes in the twilight and someone tried to burn them. Bring them back before their account is lost.",
	"deep": "The passages beneath Aetheris were built for a purpose our records no longer explain. My sketch may reopen the route.",
	"starfall": "A fallen star brought our founders here, but its first observer left no name. Help me recover the skywatch notes.",
	"evergloom": "Our abandoned streets are full of tracks leading into Hollows. The survey may tell us why people left.",
	"aetheris": "The oldest Seal inscriptions describe a door as well as a shield. Recover the notes and we can read them together."
}

# Written specifically for each leader's existing main-quest item. These are
# delivered at the found and completed stages, not as new fetch objectives.
const REGIONAL_PAYOFFS := {
	"ashvale": ["The dispatch is addressed to the missing patrol. Its final order is sealed, but Mira will recognise the hand.", "Mira: I wrote this order. I told them to guide families out, not hold the breach alone. I will give the families their names and help Ilyra find the truth."],
	"capital": ["The report bears two seals: an official order and an older note hidden beneath it. Captain Ren should see both.", "Ren: The Guard was ordered to protect a secret before the people. I cannot undo that order, but I can refuse it today. Take our guide and let the record be challenged."],
	"lunareth": ["The folio's margins contain a second set of notes on memories and light. Veya can make sense of the experiment.", "Veya: These are not the notes of a lone genius. Several scholars corrected one another. Perhaps light holds because memories are allowed to disagree."],
	"tidefall": ["The tide chart marks a safe crossing and a bell below the waterline. Neri will know which crews are still at sea.", "Neri: The chart gives us time to warn the boats. We cannot raise the old tower, but we can keep its warning alive. Follow these routes to the echoes."],
	"glassheaven": ["The prism carries a faint, unfinished voice. Prism has the tools to hear it without breaking the crystal.", "Prism: There are several voices inside, not one. I will preserve the recording without deciding which voice matters most. You should hear where it came from."],
	"frostmere": ["The trail record marks a return route that ends before the pass. Bryn may know why the guides never used it.", "Bryn: They erased the trail behind the caravans to draw the creatures away. We will mark the path again and remember who stayed behind."],
	"suncrest": ["A caravan ledger hides directions among ordinary trades. Zara can separate the route from the cargo list.", "Zara: The traders divided the route because no single caravan was safe. I will share the pieces with the other settlements; you can follow this one."],
	"orchard": ["The bark rubbing reveals marks beneath the oldest roots. Orin may recognise their pattern.", "Orin: Those marks were made by the people sheltering children here. I will plant their seeds where their names can be spoken again."],
	"ravenhold": ["The sentry orders include a retreat signal that was never answered. Tamsin needs to read the last page.", "Tamsin: The defenders held the wall after the road was clear. Their sacrifice will not become an excuse to leave the next watch alone."],
	"duskhaven": ["The twilight notes contain a copy of a witness statement, hidden inside a damaged cover. Nox asked for the original.", "Nox: Someone tried to erase this testimony. I will keep both the damaged record and the copy, so no one can pretend they were always the same."],
	"deep": ["The passage sketch shows a service route under Aetheris. Delve can check whether its markings are still trustworthy.", "Delve: Our builders made the passage for repair, not conquest. I will send word to the surface; the people who enter should know why it exists."],
	"starfall": ["The skywatch notes describe a falling light and a group of unnamed observers. Aster can compare them with the current sky.", "Aster: Our founders were witnesses, not owners of a star. I will add their account to the records we share with the other settlements."],
	"evergloom": ["The survey marks abandoned homes and the tracks of those who left them. Rook can tell which paths remain safe.", "Rook: They did not simply vanish. Some escaped and some stayed to hold a route open. I will trace both stories instead of treating this place as empty."],
	"aetheris": ["The inscription names a shield, a passage, and a promise. Seren can compare it with the guarded record.", "Seren: The Last Seal was meant to be tended, not owned. I will open the archive to witnesses. When you are ready, follow the passage beneath Aetheris."]
}

const KEEPER_PHASES := [
	"The Keeper: I watched a world go dark. I will not let it happen again.",
	"The Keeper: Trust did not save the people at the wall. My Seals did.",
	"The Keeper: If you break my hold, who will answer when the Silence returns?",
	"The Keeper: Then show me a promise strong enough to outlive its keeper."
]

const FINAL_ECHOES := [
	"A witness: The Seals were raised to give the living time, not to make their choices for them.",
	"The Keeper: I counted every person I lost. I could not bear to entrust the next life to chance.",
	"The witness: Then let us bear it together. A promise is not a prison when every voice can answer."
]

static func account(id: String) -> String:
	return str(ACCOUNTS.get(id, ""))


static func ending(choice: String, resolution: String = "") -> String:
	var first := "At the Last Seal, the Keeper's grip breaks. The Seals do not fall: the people of Elaris take up the work together, keeping the promise the lost voices preserved."
	if choice == "share":
		first += " In Ashvale, the patrol's families speak their names aloud; Ilyra carries their words into the new record."
	elif choice == "study":
		first += " In Ashvale, Ilyra and the scholars prepare the preserved fragment for the families, so its truth need not stay locked away."
	else:
		first += " Ilyra brings the recovered accounts home, where the work of remembering begins."
	if resolution == "witness":
		first += " The Keeper's testimony joins the public record beside those who challenged them. No single account is treated as the whole truth."
	elif resolution == "private":
		first += " The Keeper's memory remains private, but witnesses retain their own accounts. Ilyra promises that privacy will not become another erased history."
	else:
		first += " At the Seal's heart, the Keeper's memory still waits for a decision."
	return first
