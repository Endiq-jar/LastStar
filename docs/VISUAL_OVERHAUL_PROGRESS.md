# Visual overhaul: approximate progress

This is a planning estimate for the requested visual/performance overhaul, **not** a measure of the whole game's completion. It is subjective: the weights are allocated to workstreams, not measured hours or proof of visual quality. The user-supplied FPS and memory goals require tests on actual devices. Re-estimate as the unfinished work is assessed.

| Workstream | Weight | Estimated credit | Evidence and remaining work |
|---|---:|---:|---|
| Model budget audit and optimization | 25 | 7 | Playable rig triangle check, resident and weapon checks, two optimized scout triangle counts, 20 simple props; buildings, remaining creatures, furniture and runtime vertex counts still need work. |
| High-quality anime character, enemy and prop art/animation | 20 | 0 | Current playable characters and residents remain procedural; no complete handcrafted high-quality art or new animation pass. Scout deformation needs manual review. |
| Textures, normals and lighting | 10 | 0 | No systematic requested-resolution, hand-painted texture or normal-map pipeline and no newly baked lighting pass. |
| LOD coverage | 15 | 3 | Residents and Ilyra have four distance bands; other major assets do not all have authored, verified LODs. |
| Performance profiles | 10 | 5 | Five selectable graphics profiles, scaling and effects controls exist; texture variants, scene budgets and device verification are missing. |
| Object interactions | 10 | 3 | Doors, existing furniture, 20 small props, residents and dungeon interactions work; not every relevant object has a contextual interaction. |
| Validation and visual review | 10 | 1 | Desktop/Android builds and automated probes exist; manual scene, animation and low-end-device checks are still needed. |
| **Total** | **100** | **19** | **Approximately 19% of this overhaul**, by these provisional weights. |

These credits are intentionally conservative and should not be interpreted as a literal measurement. Previously completed game systems are outside this table.
