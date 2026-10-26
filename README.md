# Naruto Storm Remaster (ReShade)

A UI-aware, moody "modern remaster" look for **NARUTO: Ultimate Ninja STORM** (PC, Steam app 495140), tuned on an **ASUS ROG Ally Z1 Extreme** at 1080p.

Darker, cinematic grading with an adaptive filmic tone curve, super-bright jutsu glow, bloom, lens flares and anamorphic streaks, light shafts, screen-space reflections, two-stage sharpening and depth fog. The health bars, portraits and item wheels stay untouched.

| Effects off | Naruto Storm Remaster (High) |
|---|---|
| ![before](docs/screenshots/final-before.jpg) | ![after](docs/screenshots/final-after.jpg) |
| ![before](docs/screenshots/chakra-before.jpg) | ![after](docs/screenshots/chakra-after.jpg) |

![Valley of the End](docs/screenshots/valley-of-the-end.jpg)
![Jutsu glow](docs/screenshots/jutsu-glow.jpg)

*Screenshots were captured on the ROG Ally at 1920×1080 during development. Pairs were taken a fraction of a second apart by toggling ReShade, so the animation frames differ slightly.*

## Features

All effects are original shader code in one file, [`NS_Remaster.fx`](src/reshade-shaders/Shaders/NarutoStorm/NS_Remaster.fx).

| Effect | What it does |
|---|---|
| **Adaptive filmic tone mapping** | ACES-style toe and shoulder applied to brightness only, so colours keep their vibrancy. Auto-exposure eases toward a balanced level (±0.4 EV), and adaptive vibrance boosts dull scenes. Deep, moody base exposure. |
| **Colour grade** | Filmic contrast, highlight roll-off, warm highlights with neutral shadows, and saturation and vibrance with **skin-tone** and **teal-clothing** protection. Vignette. |
| **Jutsu / FX glow** | Near-clipped, strongly coloured pixels (chakra, fire, lightning, Rasengan) feed an extra-strong bloom and are exempt from the darker grade, so they shine. |
| **Bloom** | 6-level HUD-masked bloom. The glow spills into darker surroundings instead of blowing out bright walls. |
| **Lens flare + anamorphic streaks** | Chromatic ghost reflections and a halo ring from bright hotspots only, plus short horizontal streaks. |
| **Light shafts** | Radial god rays from bright sky or distant haze. They switch off automatically under overcast skies. |
| **Screen-space reflections** | On floors and other upward-facing surfaces, with grass rejection and Fresnel. The surface reads as "wet" rather than mirrored. |
| **Sharpening** | Contrast-adaptive one-pixel sharpening clamped to neighbouring pixel values (no halos on cel outlines), plus a wider detail boost. |
| **Fog** | Distance-only, starting where this game's arenas end, with its colour matched to the sky and glowing toward the sun side. |
| **Rim light** | Anime-style edge glow on characters standing in front of a bright background. |
| **Simulated RTGI (Ultra only)** | GTAO ambient occlusion plus one-bounce screen-space colour bleeding. *This is a screen-space approximation, not hardware ray tracing.* |
| **Anti-aliasing (Ultra only)** | Luma edge search plus directional resample. |
| **Manga look (Manga preset)** | Depth/normal ink lines with reduced lines on grass, and soft cel tone bands on scenery. |

## Install

1. Download ReShade from **https://reshade.me** (tested with 6.7.3). Leave `ReShade_Setup_x.y.z.exe` in your **Downloads** folder. You don't need to run it.
2. Download `NarutoStormRemaster-<version>.zip` from [Releases](../../releases) and extract it anywhere.
3. Close the game and double-click **`Install.bat`**.
   - It finds the game through Steam. If that fails, run it again with a path: `Install.bat -GameDir "D:\SteamLibrary\steamapps\common\<game folder>"` (the folder containing `NSUNS1.exe`).
   - It extracts ReShade's DLL from your downloaded setup file as `dxgi.dll`. If another mod already uses `dxgi.dll`, it installs as `d3d11.dll` instead. An existing ReShade install is reused.
   - It copies the shader and presets into their own `NarutoStorm` subfolders and writes `ReShade.ini`, backing up any existing one. **No game files are modified**, and every change is recorded in `NarutoStormRemaster.install.txt`.
4. Start the game. The **High** preset is active.

### Controls

| Key | Action |
|---|---|
| **End** | Effects on/off (instant original-look comparison) |
| **Home** | ReShade menu: presets, every slider, debug views |
| **Page Up / Page Down** | Previous / next preset |

## Presets

All presets keep the same look. Lower presets only drop the more expensive effects.

| Preset | Effects | GPU cost @1080p, Z1 Extreme |
|---|---|---|
| Vanilla | none | 0 ms |
| Low | grade, fog, bloom, jutsu glow, flares, sharpening | ~5.4 ms *(estimated from per-effect timings)* |
| Medium | Low + light shafts | ~6.3 ms *(estimated)* |
| **High** (default) | Medium + reflections | **7.1 ms measured** (before flares/streaks were added; those add ~0.3 ms estimated) |
| Ultra | High + simulated RTGI/AO (half-res) + AA | ~10 ms *(estimated)* |
| Manga | High + ink lines + cel tone bands | ~7.6 ms *(estimated)* |

## Performance (measured)

Device: ASUS ROG Ally **Z1 Extreme** (Radeon 780M), Windows 11, game at **1920×1080 fullscreen**, in-game MSAA on, FXAA on, shadows 1, motion blur on, glare on, streamed over Parsec. Timings come from ReShade's Statistics tab during real battles.

| Scene | Preset | Post-processing GPU time | FPS |
|---|---|---|---|
| Any, effects off | — | — | 60 (the game's frame cap) |
| Valley of the End arena (rain) | High (final) | 7.1 ms | 50–58 |
| Forest arena, heavy chakra effects | High + flares | n/a | 46–49 |
| Forest arena, all effects incl. half-res AO | ≈Ultra (earlier build) | 9.0 ms | 42–46 |

Per-effect GPU cost (High, final build): Begin 1.28 ms, Reflections 1.05 ms, Light shafts 0.93 ms, Bloom 1.34 ms (+flares), Sharpen 0.72 ms, Finish 1.80 ms.

**The game is capped at 60 FPS**, so the original 70 FPS target is impossible for any mod. The mod targets 40+ FPS minimum. High stayed above that in every battle tested; Ultra is close to it in the heaviest scenes. If you want more headroom, use Medium or Low.

## How the HUD is protected

The HUD is drawn after the 3D scene, but ReShade only sees the final frame. Measurements from this game drove three layers of protection:

1. **Depth-tagged HUD heads.** The fighter portraits are 3D heads drawn at linear depth < 0.001 (the nearest real scenery is > 0.03), so those pixels are restored exactly.
2. **HUD boxes.** The battle HUD (both health blocks and both item wheels) and the free-roam HUD (portrait and button help) were measured in-game. A box activates only while its HUD is detected: battle mode is recognised by the opponent's portrait in the top-right. Inside a box only per-pixel grading applies. No bloom, sharpening, reflections, AO or flares are drawn there, and no bloom is generated from it.
3. **Menus and videos.** Full-screen menus and pre-rendered videos have no 3D depth, so they're shown untouched.

![HUD mask debug](docs/screenshots/hud-mask-debug.jpg)

## Depth sync fix ("ghost doubles")

This game shows each image one frame after its depth buffer. Without correction, every depth effect trails moving characters, producing ghost outlines. The shader keeps the previous frame's depth (**Depth → Delay depth by one frame**, on by default), and `ReShade.ini` enables `DepthCopyBeforeClears`. The red edges in the debug view below sit exactly on the characters:

![Depth alignment](docs/screenshots/depth-alignment-debug.jpg)

## Known limitations

- **Text and prompts outside the HUD boxes** (combo counter, move names, Ninjutsu-clash prompts, the battle results screen) still get grading and glow.
- **Pause and results screens drawn over the 3D scene** still have depth, so they get effects. Only depth-less menus are bypassed.
- **Screen-space effects can't see off-screen objects.** Reflections fade at screen edges, and the simulated GI only bounces visible colour.
- **On camera cuts**, one frame can show depth effects from the previous shot, because of the one-frame depth delay.
- **Not yet tested:** free-roam dialogue boxes, story-mode menus, the map and inventory screens, and other resolutions or aspect ratios. The HUD boxes are fractions of the screen measured at 16:9.
- **In-game FXAA** is applied before the HUD by the game. The Ultra preset adds its own AA, so turn the game's FXAA off in its launcher settings when using Ultra.

## Troubleshooting

| Problem | Fix |
|---|---|
| Nothing changes in game | Press **End** (effects may be toggled off). Check that `dxgi.dll` or `d3d11.dll` and `ReShade.ini` are next to `NSUNS1.exe`. |
| "failed to compile" in the ReShade menu | Hover the red entry for the message and open an issue with it. Make sure ReShade is 5.0 or newer. |
| Outlines/AO trail behind characters | **Home → NS_Remaster.fx → Depth → Delay depth by one frame** must be on. |
| Too dark / too bright | **Colour grade → Exposure** (default −0.9) and **Adaptive exposure**. |
| HUD looks affected | **Debug view → HUD mask** shows protected areas in magenta. Add an extra box in **HUD / Menus → Extra protected box**. |
| Low FPS | Switch to Medium or Low with **Page Down**. |

## Uninstall

Close the game and double-click **`Uninstall.bat`**. It removes exactly what the installer added (listed in `NarutoStormRemaster.install.txt`) and restores your previous `ReShade.ini`. It removes ReShade only if the installer added it, and it never touches your other shaders or presets.

## Building / development

```bash
python tools/check_presets.py
```
```bash
powershell -ExecutionPolicy Bypass -File tools/test_install.ps1 -ReShadeSetup "$HOME/Downloads/ReShade_Setup_6.7.3.exe"
```
```bash
powershell -ExecutionPolicy Bypass -File tools/build_release.ps1 -Version 1.0.0
```

- `check_presets.py` checks that every preset only uses techniques and settings that exist in the shader.
- `test_install.ps1` runs a full install/uninstall round trip against a fake game folder (13 checks).
- `build_release.ps1` writes `dist/NarutoStormRemaster-1.0.0.zip`. ReShade binaries are never included.

The shader only compiles inside ReShade. For live iteration, keep the game running, edit `NS_Remaster.fx` in the game's `reshade-shaders\Shaders\NarutoStorm` folder, and press **Reload** in the ReShade menu.

## License

MIT for everything in this repository (see [LICENSE](LICENSE)). ReShade is © crosire and is downloaded separately. NARUTO © Masashi Kishimoto/Shueisha. The game is © BANDAI NAMCO/CyberConnect2, and screenshots are included for illustration only.
