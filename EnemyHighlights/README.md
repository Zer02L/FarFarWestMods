# EnemyHighlights — Warframe-Style Enemy Fresnel Rim Glow

A high-performance, client-side visual accessibility mod for **Far Far West** (Unreal Engine 5.8 / UE4SS).

Adds a customizable **Warframe-style Fresnel rim glow** to enemies, making them clearly readable across dusty canyons, dark caverns, and hectic supernatural gunfights without breaking visual immersion.

---

## ✨ Features

- **Warframe-Style Fresnel Rim Glow:** Highlights enemy contours and silhouettes using an edge-grazing Fresnel glow. The center of the enemy remains shaded with their normal model textures and details.
- **100% Depth-Tested (NOT a Wallhack):** Renders via hardware Z-buffer tested mesh overlay passes. Enemies behind rocks, walls, buildings, or hills are completely occluded and will **never** glow through solid geometry.
- **Aimed-Part & Target Acquisition Overlay:** When you aim directly at an enemy or an enemy's limb / weakpoint, the highlight dynamically shifts to a high-contrast target color (Electric Cyan by default) and boosts brightness for immediate aim confirmation. Also recolors in-game native aimed weakspot overlays.
- **Configurable Colors & Tiers:** Fully customizable RGBA / Hex colors and intensity per enemy tier:
  - **Regular Enemies:** Energy Orange (`#FF6600` / Warframe default)
  - **Elite Enemies:** Vibrant Violet (`#B800FF`)
  - **Bosses:** Blazing Crimson (`#FF1030`)
  - **Aimed Target:** Electric Cyan (`#00E5FF`)
- **100% Client-Side:** Purely visual, zero network replication or server impact. Safe for co-op multiplayer.
- **Hot-Reload & Toggle:** Toggle on/off instantly with `F8`, or tweak `config.ini` and press `F7` to reload colors without restarting the game.

---

## 🎮 Controls

| Key | Action |
|---|---|
| **F8** | Toggle Enemy Highlights On / Off |
| **F7** | Reload `config.ini` in real-time (no restart required) |

*(Keybindings can be customized in `config.ini`)*

---

## ⚙️ Configuration (`config.ini`)

Edit `config.ini` in the mod folder to customize colors, brightness, and behavior:

```ini
[General]
Enabled = 1
IntensityMultiplier = 3.0   ; Overall glow brightness
FresnelExponent = 2.5       ; 1.5 = broader glow, 4.0 = razor-sharp rim
InnerAlpha = 0.05           ; Interior body tint (0.0 = pure rim, 0.2 = subtle body wash)
MaxDistance = 15000.0       ; Max highlight distance in cm (150m; 0 = unlimited)

[Colors]
; Regular enemy color (RGB 0.0 - 1.0)
EnemyColorR = 1.0
EnemyColorG = 0.4
EnemyColorB = 0.0
EnemyColorA = 1.0

; Elite enemy color
EliteColorR = 0.72
EliteColorG = 0.0
EliteColorB = 1.0
EliteColorA = 1.0

; Boss enemy color
BossColorR = 1.0
BossColorG = 0.06
BossColorB = 0.18
BossColorA = 1.0

[AimedOverlay]
RecolorAimedPart = 1        ; Dynamic target acquisition highlight
AimedColorR = 0.0           ; Electric Cyan
AimedColorG = 0.9
AimedColorB = 1.0
AimedColorA = 1.0
AimedIntensity = 5.0        ; Brightness boost when on-target
AimedPartOnly = 0           ; 0 = whole enemy shifts color, 1 = only the aimed bone/mesh
MaxAimDistance = 20000.0    ; 200m aim raycast reach
```

### Popular Color Presets

- **Warframe Default:**
  - `EnemyColor`: Orange (`R=1.0, G=0.4, B=0.0`)
  - `AimedColor`: Cyan (`R=0.0, G=0.9, B=1.0`)
- **Orokin Gold:**
  - `EnemyColor`: Amber (`R=1.0, G=0.7, B=0.1`)
  - `AimedColor`: Ruby Red (`R=1.0, G=0.05, B=0.15`)
- **Cyberpunk Neon:**
  - `EnemyColor`: Hot Pink (`R=1.0, G=0.08, B=0.58`)
  - `AimedColor`: Neon Green (`R=0.1, G=1.0, B=0.2`)

---

## 📁 Installation

The mod is installed in:
```text
FarFarWest/FarFarWest/Binaries/Win64/ue4ss/Mods/EnemyHighlights/
├── enabled.txt
├── config.ini
├── README.md
└── Scripts/
    └── main.lua
```

Ensure UE4SS is installed, then launch the game. UE4SS loads `EnemyHighlights` automatically via `enabled.txt`.

---

## 🔧 Technical Details

1. **Hardware Depth-Testing:** Applied through Unreal Engine's `UMeshComponent::SetOverlayMaterial` with depth testing enabled. The GPU hardware rasterizer compares overlay depth against the scene depth buffer; occluded pixels are discarded before shading.
2. **Dynamic Material Instances (MID):** Dynamically allocates and tunes parameters (`Color`, `Intensity`, `FresnelExponent`, `InnerAlpha`, `DepthBias`) across material parameter tables.
3. **Continuous Aim Raycast:** Runs a dedicated async trace along the active player camera's forward vector using `UKismetSystemLibrary::LineTraceSingle`, querying `Visibility` channel and identifying specific skeletal bones and sub-components.
