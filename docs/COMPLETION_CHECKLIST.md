# Last Star continuation checklist

This is a scope and evidence checklist, not a claim of completion. The original
brief contains qualitative and overlapping requirements as well as numerical
ones; a defensible project-wide percentage needs an agreed, individually tested
requirements inventory. Counts of quest entries do not prove their narrative or
encounter quality. See `STORY_OUTLINE.md`, `MODEL_AUDIT.md` and
`VISUAL_OVERHAUL_PROGRESS.md` for details.

## Implemented portions to retain and verify

- [x] 25 existing memory IDs and five-act journal, including old/out-of-order
  clears; Last Seal still requires the original 100 Hollows, with five additional
  optional Hollows. Automated probes exercise these paths; not a full playthrough.
- [x] Keeper choice, seven optional witnesses, and an Ashvale homecoming ending;
  optional companion and regional quest decisions can change ending text.
- [x] Three cross-region/personal stories (Ilyra's patrol, Neri's harbour and
  Veya's lost Wander), and Frostmere's replayable defense, with saved choices and
  rewards. Neri and Veya can follow without duplicating their resident identities.
- [x] All 14 leaders have authored dialogue for the existing side-quest stages;
  these are retrieval quests, not 14 bespoke encounters.
- [x] Fourteen settlement pads are flat and stone-paved with no village entrance
  stairs or ramps. Automated structural tests cover all sites.
- [x] Five graphics profiles and targeted terrain, foliage, character, settlement,
  furniture and weapon optimizations exist. Device FPS and memory are unmeasured.
- [x] Offline-only game systems and existing quest IDs/save progression retained
  in the automated regression suite.

## Unfinished work

- [ ] Author and integrate the remaining distinct side stories and encounters;
  the numerous generic resident retrieval quests are not equivalent to 165
  fully authored, meaningful side quests. Include actual world/NPC consequences,
  rewards, prerequisites and save-compatible state; test each interaction.
- [ ] Expand companion relationship progression, personal histories, dialogue,
  companion interactions and Gift development beyond the currently implemented
  Ilyra, Neri and Veya arcs; create any missing companions from the design brief.
- [ ] Replace reusable modular story rooms with the remaining bespoke locations,
  encounters, environmental storytelling and phase mechanics where warranted;
  conduct a full progression and balance playthrough.
- [ ] Complete the requested anime-quality asset overhaul, animations and textures;
  audit every requested category and vertex/triangle/LOD target. Some budgets in
  the request conflict or are infeasible as written; report actual measurements.
- [ ] Complete performance work, including the requested Rust approach if a
  compatible toolchain and viable Godot/Android integration are available;
  existing GDScript optimizations are not a Rust integration. Do not perform
  device performance verification unless the user changes that instruction.
- [ ] Integrate the requested Renend Studio pack only if its archive is supplied
  or legally obtainable; the available environment could not access its download.
- [ ] Re-run available static checks, all Godot probes, desktop and Android builds,
  and review the actual published probe log after every integrated change. CI and
  probes are not a substitute for complete manual gameplay or visual review.

## Save and branch policy

Keep original quest IDs, finale gate, and existing save fields compatible. Work
only on the current Arena branch; do not reset or clean away local changes. Check
CI for the exact pushed commit and inspect the probe transcript, because the
render job can mask a failed probe. Do not claim all requirements verified until
all above work and acceptance tests are actually completed.
