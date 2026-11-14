# Nature pack assets

The valley's entire environment — trees, grass, bushes, flowers, rocks, logs and
stumps — comes from the **Quaternius Ultimate Stylized Nature Pack**.

* Author: **[Quaternius](https://quaternius.com)**
* Pack page: <https://quaternius.com/packs/ultimatestylizednature.html>
* Licence: **CC0-1.0 (public domain)** — no attribution required, no restriction
  on redistribution or modification. It is recorded here anyway, because a
  binary in a tree should never have an unknown origin.
* Vendored from: <https://github.com/trebeljahr/quaternius-showcase>
  (`public/glb/nature_pack/`), a viewer project that republishes the packs as
  `.glb`. The models themselves are unmodified copies of the pack.

## Why these files

The pack ships **no textures at all**: colour lives in each model's named
materials, and the meshes carry only `POSITION` and `NORMAL` (no UVs). That is
why `scripts/nature_pack.gd` bakes every surface's colour into **vertex colours**
and flattens each model to a single surface, which is what lets one MultiMesh
draw an entire batch of trees with one material.

Each model is authored in centimetres behind a 100× node scale, so
`NaturePack.height_of()` measures the baked mesh rather than assuming a size.

## Files

All 21 files are `<raw.githubusercontent>`-equivalent copies of
`public/glb/nature_pack/<name>.glb` upstream.

| local file | kind used in code | height (m) | tris |
|---|---|---|---|
| `CommonTree_1.glb` | `tree_common_1` | 2.48 | 2888 |
| `CommonTree_3.glb` | `tree_common_3` | 3.46 | 1584 |
| `CommonTree_Dead_1.glb` | `tree_dead` | 2.22 | 2360 |
| `BirchTree_1.glb` | `tree_birch` | 3.57 | 1704 |
| `PineTree_1.glb` | `tree_pine_1` | 2.70 | 1911 |
| `PineTree_3.glb` | `tree_pine_3` | 3.30 | 2383 |
| `Willow_1.glb` | `tree_willow` | 2.85 | 1946 |
| `Bush_1.glb` | `bush_1` | 1.24 | 364 |
| `Bush_2.glb` | `bush_2` | 1.11 | 266 |
| `Plant_1.glb` | `plant_1` | 0.51 | 295 |
| `Plant_3.glb` | `plant_3` | 0.94 | 600 |
| `Flowers.glb` | `flowers` | 0.83 | 408 |
| `Grass.glb` | `grass` | 1.01 | 192 |
| `Grass_2.glb` | `grass_2` | 1.20 | 192 |
| `Grass_Short.glb` | `grass_short` | 0.40 | 192 |
| `Rock_1.glb` | `rock_1` | 0.88 | 70 |
| `Rock_2.glb` | `rock_2` | 0.65 | 80 |
| `Rock_4.glb` | `rock_4` | 0.78 | 128 |
| `Rock_Moss_1.glb` | `rock_moss` | 0.95 | 70 |
| `WoodLog.glb` | `log` | 0.75 | 464 |
| `TreeStump.glb` | `stump` | 0.62 | 232 |

Total ~1.1 MB.

## The one derived asset

`Grass.glb` is ~100 separate blades in 192 triangles. The meadow instances
tens of thousands of tufts, so `NaturePack.clump("grass", 36)` keeps only the
tallest 36 blades (64 triangles), found as connected components of the index
buffer. The blades are the pack's own geometry — nothing is redrawn — and the
budget it protects is the frame's.

## Renderer note: do not give these batches custom data

The models carry `POSITION` and `NORMAL` only, so every colour arrives through
`COLOR`, which `NaturePack` bakes from the glTF materials. On Godot 4.3's
Compatibility renderer a `MultiMesh` with `use_custom_data = true` loses that
attribute: the batch draws as a near-black silhouette of itself, while the same
mesh in a batch without custom data draws correctly. That is worth its own
paragraph because it does not look like a bug in a screenshot — it looks like
"those props are in shadow", or unlit, or missing a texture, and the trees
standing green over black ferns makes it read as a per-species problem.

The foliage shader therefore derives its per-instance tint from world position
(two sines) instead of `INSTANCE_CUSTOM.r`. If a species ever needs another
per-instance value, put it in the mesh or derive it from position; do not turn
custom data back on.
