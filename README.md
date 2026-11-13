# LastStar

**An open-world, cel-shaded action-RPG inspired by _Genshin Impact_ — built with Godot 4.3, targeting Android first.**

LastStar started life as a fork of the MIT-licensed Godot 4 open-world prototype
[`flips100/realistic-open-world`](https://github.com/flips100/realistic-open-world)
(procedural terrain + vegetation + third-person controller), and has been rebuilt into an
anime-styled action RPG: a toon-shaded party of three elemental characters, gliding, elemental
skills and bursts, slimes with elemental reactions, star-sigil hunting and waypoint statues —
all rendered with a mobile-friendly renderer and shipped through an automatic CI pipeline that
produces an installable APK on every push.

> **This is an original, fan-inspired project.** It contains **no Genshin Impact assets** — no
> characters, models, textures, audio or data. Everything you see is generated procedurally in
> GDScript (characters, props, terrain, sky, sound effects) or is a **CC0 public-domain** art
> asset from Quaternius' stylized packs — the valley's trees, grass, plants and rocks and the
> cloth the world is dressed in. Every file and its licence is listed in `CREDITS.md`.
> "Genshin Impact" is a trademark of HoYoverse; this project is not affiliated with them.

![style](https://img.shields.io/badge/renderer-Mobile%20(Vulkan)-5ac8fa) ![engine](https://img.shields.io/badge/Godot-4.3-478cbf) ![license](https://img.shields.io/badge/license-MIT-green)

---

## ✨ What's in the game

| System | Details |
|---|---|
| **Renderer** | OpenGL ES 3.0 (Compatibility) — runs on every Android device since 2013, including PowerVR GPUs like the Helio P95 where the Vulkan path black-screens |
| **Anime terrain** | A **10 km** procedural world, streamed in three layers around the player (96 m tiles at 4 m, 672 m tiles at 32 m, one coarse shell over the whole map), custom `terrain_anime` shader: painterly banded meadow, slope-aware rock, wet shoreline and snow caps. Mountains stand 2–3.2 km out; a concave collision patch follows the player instead of a shape over the map |
| **Cel shading** | `anime_toon.gdshader` — world-space two-band ramp, cool tinted shadows, a small cool rim + inverted-hull outline pass. No specular lobe: on near-black cloth it only ever painted grey patches, so the ramp and the outline carry the form |
| **Party of three** | Sora (Anemo, sword), Ember (Pyro, catalyst), Volt (Electro, bow). Switch instantly with **T** or the portrait row |
| **Traversal** | Sprint with stamina, double jump, **gliding** with wind wings, plunge attack from a dive |
| **Combat** | 3-hit melee combo, elemental skill (E) with cooldown, elemental burst (Q) that spends energy, damage numbers, hit flashes, shockwaves |
| **Enemies** | Elemental slimes that hop at you and take **reaction multipliers** (same element resisted, opposite empowered) |
| **Progression** | 12 star sigils to recover, waypoint statues that heal the party and set your respawn, quest tracker, victory banner |
| **Water** | One surface at sea level over the whole map, because a sea in the south-east, a lake, a carved river and six ponds are all the same water table. The terrain carves the beds; wherever it falls below the waterline there is water, so a coastline needs no special case |
| **World dressing** | Scattered trees, pines, dead trees, bushes, ferns, flowers, pebbles and boulders from the Ultimate Stylized Nature Pack, batched into MultiMeshes and occluded per entity; wind arches, glowing crystal clusters, campfires and bone-cloth banners at the shrines |
| **Day / night** | Sun angle, colour and ambient light drift over time; campfire and crystal lights carry the night |
| **Environment (rendered)** | ![wide](docs/render_wide.webp) ![gameplay](docs/render_world.webp) |
| **Character (rendered, front)** | ![front](docs/render_player.webp) |
| **Grass** | The painted carpet is back: two crossed alpha-cut cards a tuft, **4 triangles an instance** against the 3D tuft's 64, on a jittered grid at 9.2 cards/m² near the player and thinning with distance (6 200 / 2 600 / 460 per 26 m chunk). ~95 000 cards and 0.59 M triangles for the whole meadow. **No wind** — the shader has no `TIME` in it. What it does do is not draw: behind-camera collapse, a clearing around the character, distance fade and a dissolve at the streaming edge |
| **Mobile UI** | Touch joystick + right-side camera drag + on-screen action buttons, plus a **Quality** toggle (Balanced / Performance / High) |

### Controls

| Action | Keyboard / mouse | Touch |
|---|---|---|
| Move | WASD | Left joystick |
| Camera | Mouse | Drag the right side of the screen |
| Sprint | Shift | — |
| Jump / double jump / glide | Space (hold in the air) | Jump button |
| Attack | Left mouse | Slash button |
| Elemental skill | E | Skill button |
| Elemental burst | Q | Burst button |
| Switch character | T | — |
| Spell wheel | 1–5 | Book button (right), then tap a slot |
| Assign a spell | — | Long-press a spell slot |
| Pause | Esc | II button |

---

## 📱 Install the app (Android)

**One-click download — always the newest build:**

## ⬇️ [**Download LastStar.apk**](https://github.com/Endiq-jar/LastStar/releases/download/latest-apk/LastStar.apk)

Every push to the repository builds a fresh APK and re-uploads it to the rolling
[`latest-apk`](https://github.com/Endiq-jar/LastStar/releases/tag/latest-apk) release, so that
URL never goes stale. To install:

1. Open the link above on an Android phone (Android 7.0 or newer).
2. Allow "install unknown apps" for your browser / file manager when prompted.
3. Open `LastStar.apk` and install, then launch **LastStar**. It runs fully offline.

You can also grab the **`LastStar-android`** artifact from the **Actions** tab, or
tagged builds (`git tag v1.0.0 && git push --tags`) publish a **GitHub Release** with the
APK, a Linux build and a Windows build attached.

**Requirements:** arm64-v8a device, Android 7.0+ (API 24), ~25 MB download. Renderer: Mobile
(Vulkan), landscape, touch joystick + action buttons.

## 🩺 Rendering safety net

The game is written so it **cannot** show a black screen with only the HUD:

* the player (and therefore the camera) is built **first**; all optional scenery
  is dressed on afterwards,
* the character rig is built *after* the camera and every rig accessor is
  null-safe, so a rig problem can't stop rendering,
* `world.tscn` ships a real `Environment`, the sun never drops below the
  horizon, and ambient light has a floor - the valley stays lit,
* a deferred fallback camera is installed if the viewport somehow has none,
* a render watchdog samples the first frames and calls `repair_render()` if the
  view comes out black,
* **Pause menu → "Repair view"** rebuilds the camera, environment and lights on
  demand, and quality tiers are reversible and remembered in `user://video.cfg`.
* an automatic tuner samples real frame time on startup and drops to the
  Performance tier on weak hardware, and vegetation beyond ~190 m is culled.
* **`performance/entity_culler.gd`** decides which enemies, sigils and waypoints
  the terrain, walls and ceilings actually leave visible, on a `WorkerThreadPool`
  task rather than on the main thread. Hidden entities are skipped by the
  renderer and lose their AI, animation and sparkle ticks until they are in
  sight again. It is not a frustum test: a sight line is path-traced against a
  baked height grid and the structural AABBs, so a slime behind a ridge, a ruin
  wall or a pavilion roof is not drawn, while one glimpsed through the gap
  between two pillars is.
* the world bootstrap contains **no coroutines and no GPU readbacks** — both
  could wedge the main loop on software/GL drivers.
* **the environment is one CC0 art pack** — every tree, blade of grass, bush,
  flower, rock, log and stump is a model from Quaternius' *Ultimate Stylized
  Nature Pack* (`assets/nature/`, twenty-one `.glb` files), consumed by
  `scripts/nature_pack.gd`, which bakes each model's material colours into
  vertex colours so a whole species can be drawn as one MultiMesh with one
  material. The painted pngs the vegetation used to sample are gone. The
  meadow's tuft is the pack's grass decimated to its tallest 36 blades, because
  a 100-blade tuft at meadow density is tens of millions of triangles.
  The per-instance tint is a function of world position rather than a custom
  data buffer: on the Compatibility renderer a MultiMesh with custom data on
  loses the mesh's vertex colours, and every prop drawn that way came out a
  black silhouette of itself. `tests/render_probe.gd` measures both the frame's
  near-black fraction and the colour of a plain mesh against the same mesh in a
  MultiMesh, so the regression cannot come back quietly.
* **bone cloth** — the cloth the world is dressed in (ruin-gate banners, shelter
  drapes, the altar carpet, waypoint totems, and the player's cape hem and
  charms) is built from six CC0-1.0 Quaternius models in `assets/cloth/`,
  re-materialled to the toon ramp by `scripts/bone_cloth.gd`. Sources and licences
  are listed in `assets/cloth/README.md`.

CI enforces all of it: `tests/render_probe.tscn` actually renders the world under
Xvfb, screenshots the framebuffer and measures mean luminance, non-black coverage
and distinct colour count. A build fails if the 3D view is genuinely black, and
the screenshots are uploaded as the `render-probe` artifact on every run.

### Release signing (optional)

Without configuration the CI ships a *debug-signed* APK that installs fine on any device.
To ship a proper release APK, add these repository secrets
(*Settings → Secrets and variables → Actions*):

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w 0 release.keystore` |
| `ANDROID_KEYSTORE_USER` | key alias |
| `ANDROID_KEYSTORE_PASSWORD` | keystore + key password |

The workflow then builds `--export-release` with your keystore automatically.

---

## 🛠 Build it yourself

Requirements: **Godot 4.3** (standard, not .NET) and, for Android, the Android SDK + JDK 17.

```bash
git clone https://github.com/Endiq-jar/LastStar.git
cd LastStar
godot --headless --editor --quit          # import assets once
godot                                     # play in the editor, F5

# Android
godot --headless --install-android-build-template \
      --export-debug "Android" build/android/LastStar.apk
```

`export_presets.cfg` ships three presets: **Android** (arm64-v8a), **Linux**, **Windows Desktop**.

---

## 🗂 Project layout

```
project.godot              Mobile renderer, input map, autoload "Game"
export_presets.cfg         Android / Linux / Windows presets
default_env.tres           Fallback environment
scenes/
  main_menu.tscn           Title screen (live 3D diorama)
  world.tscn               Terrain + vegetation + HUD
  ui/hud.tscn              HUD root
scripts/
  game_state.gd            Autoload: party, HP/energy/stamina, sigils, waypoints, quality
  character_builder.gd     Procedural anime character rigs (toon + outline shaders)
  terrain_generator.gd     Heightfield + trimesh collision + lake bowl + rim mountains
  vegetation_spawner.gd    MultiMesh grass, trees, rocks, flowers
  world.gd                 Environment, day/night, landmarks, spawns
  player.gd                Movement, glide, combat, party switching, touch camera
  slime.gd                 Enemy AI + elemental reactions
  sigil.gd / waypoint_statue.gd
  performance/entity_culler.gd  Async path-traced occlusion culling + tick gating
  hud.gd / touch_controls.gd
  fx.gd                    Tweened procedural VFX
shaders/
  anime_toon.gdshader      Cel shading + rim + specular band
  outline.gdshader         Inverted-hull outline
  terrain_anime.gdshader   Painterly triplanar terrain
  water_anime.gdshader     Stylized lake
  grass_sway.gdshader      Wind-swept MultiMesh grass
.github/workflows/build.yml  Auto-build APK + desktop, publish releases
```

### Tuning performance

Open the pause menu and press **Quality**, or edit `Game.quality_tier` (0 Balanced,
1 Performance, 2 High). For deeper tuning: `VegetationSpawner` counts, `TerrainGenerator.RESOLUTION`,
`RenderingServer.directional_shadow_atlas_set_size`.

---

## 📜 Credits & licence

* **Code:** MIT — see [LICENSE](LICENSE) and [CREDITS.md](CREDITS.md).
* **Forked base:** [`flips100/realistic-open-world`](https://github.com/flips100/realistic-open-world) (MIT)
  — the procedural terrain, vegetation scatter and third-person prototype this project grew from.
* **Rendering techniques** (toon ramp, SSR-free stylized water, MultiMesh wind grass) are original
  GDScript/GLSL written for this project.
* Inspired by *Genshin Impact* (© HoYoverse). No HoYoverse assets are included or required.
