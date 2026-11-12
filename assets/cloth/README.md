# Bone cloth models

Six glTF models by **[Quaternius](https://quaternius.com)**, released under
**[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/)**
(public domain dedication) — the same licence as the packs they come from. CC0
requires no attribution; this file exists so the provenance of every binary in
this directory is recorded.

They were downloaded from the mirror
[`trebeljahr/quaternius-showcase`](https://github.com/trebeljahr/quaternius-showcase),
which republishes the packs byte-for-byte and lists the upstream licence and
source page for each one in its `LICENSES.md` (checked 2026-10-10).

| File here | Upstream path | Pack | Licence | Source page |
| --- | --- | --- | --- | --- |
| `bone_cloth_banner.glb` | `public/glb/modular_dungeon_1/Banner.glb` | Modular Dungeons Pack | CC0-1.0 | <https://quaternius.com/packs/modulardungeon.html> |
| `bone_cloth_banner_wall.glb` | `public/glb/modular_dungeon_1/Banner_wall.glb` | Modular Dungeons Pack | CC0-1.0 | <https://quaternius.com/packs/modulardungeon.html> |
| `bone_cloth_curtain.glb` | `public/glb/house_interior_pack/Curtains_Single.glb` | Ultimate House Interior Pack | CC0-1.0 | <https://quaternius.com/packs/ultimatehomeinterior.html> |
| `bone_cloth_carpet.glb` | `public/glb/modular_dungeon_pack/Carpet.glb` | Modular Dungeon Pack | CC0-1.0 | <https://quaternius.com/packs/medievaldungeon.html> |
| `bone_cloth_bones.glb` | `public/glb/modular_dungeon_pack/Bones.glb` | Modular Dungeon Pack | CC0-1.0 | <https://quaternius.com/packs/medievaldungeon.html> |
| `bone_cloth_skull.glb` | `public/glb/modular_dungeon_1/Skull.glb` | Modular Dungeons Pack | CC0-1.0 | <https://quaternius.com/packs/modulardungeon.html> |

## How the game uses them

`scripts/bone_cloth.gd` is the only place these files are touched. It

* instantiates each model once per placement and re-materialles every surface by
  its glTF material name (`Main`, `Wood`, `Bone`, …), keeping the wooden pole
  wooden and the iron rings iron while the cloth becomes bone-linen;
* gives cloth surfaces a double-sided toon material, because a banner is a plane
  and single-sided it vanishes when the camera goes round it;
* marks every cloth mesh `cloth_soft`, so the entity culler
  (`scripts/performance/entity_culler.gd`) never treats hanging cloth as a wall;
* composes the dressing placements: `hanging()` (banner + hem bones + skull) on
  the ruin gates, the spawn altar and the waypoints, `drape()` inside the camp
  shelters, `ground_cloth()` on the floor and `bone_pile()` beside the fire, and
  the small clasp/skull charms on the player rig.

## Why the models are vendored rather than fetched

The Godot Asset Store (`godotengine.org`) is not reachable from the build
sandbox, and the project ships from GitHub Actions, so a runtime download would
add a network dependency to every build. Six small CC0 `.glb` files (~200 KB
total) are checked in instead, which also means the APK has no external
dependency and the scene is reproducible offline.
