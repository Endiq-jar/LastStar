# Credits

## LastStar

Original code, shaders, procedural art and design: the LastStar contributors, 2026.
Released under the MIT License (see `LICENSE`).

## Forked base

This project began as a fork of **[flips100/realistic-open-world](https://github.com/flips100/realistic-open-world)**
— "a playable Godot 4.x 3D open-world prototype" released under the MIT License.

The following ideas/structures were carried over and then heavily rewritten:

* procedural heightfield terrain with `get_height_at()` sampling (`scripts/terrain_generator.gd`)
* `MultiMesh`-based vegetation scatter (`scripts/vegetation_spawner.gd`)
* third-person character controller skeleton and camera spring arm (`scripts/player.gd`)
* layered `WorldEnvironment` + directional light setup (`scripts/world.gd`)
* project structure (scenes / scripts / shaders) and export preset approach

Copyright notice of the original work, as required by the MIT License:

```
MIT License

Copyright (c) 2026 flips100

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Engine & tooling

* **Godot Engine 4.3** — MIT License, © Godot Engine contributors.
* **godot-ci** (`barichello/godot-ci:4.3`) — MIT License, used by the GitHub Actions workflow
  to install export templates and the Android SDK.

## Trademarks

*Genshin Impact* is a trademark of HoYoverse / miHoYo. LastStar is an independent,
fan-inspired project. It ships **no** HoYoverse assets (no models, textures, audio, story text
or data of any kind) and is not affiliated with or endorsed by HoYoverse.
All characters (Sora, Ember, Volt) and all art are original and procedurally generated.
