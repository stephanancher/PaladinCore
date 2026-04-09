# PaladinCore Addon — Developer Notes

## Current Version: `1.2.1`

> **Rule: bump the version on every meaningful change.**
> Update `local PCA_VERSION` in `PaladinCore.lua` AND `## Version:` in `PaladinCore.toc`.
> Use semantic versioning: `MAJOR.MINOR.PATCH`
> - **PATCH** — bug fixes, tweaks
> - **MINOR** — new spells, new options, new UI controls
> - **MAJOR** — full rotation redesign or breaking config changes

### Changelog
| 1.8.1 | Restricted auto-targeting to combat only (prevents accidental long-range pulls with Exorcism). |
| 1.8.0 | Added in-game version sync. Addon now checks for updates by communicating with other players in Guild/Party/Raid. |
| 1.7.1 | Absolute priority for Exorcism against Undead/Demon targets (overrides all rotation steps). |
| 1.7.0 | Tabbed UI refactor (Rotation, Config, Info). Added Info tab with repository link and dedication. |
| 1.6.2 | (Previous stable version) |
| 1.2.1 | Auto-attack guardian: ensures auto-attack is always running in combat; never toggles it off. |
| 1.2.0 | Fighting Undead toggle (Exorcism opener on undead targets). Cooldown feedback: action bar macro button dims when next spell is on CD. Icon prediction fixed for Judgement and Consecration. Rotation changed to strict slot priority order (seals no longer jump to front of queue). |
| 1.1.1 | Removed dead 'Are you tanking?' button and Tanking config key. |
| 1.1.0 | Draggable settings window. Scale +/- buttons (saved per character, default 0.85). Version shown in subtitle. |
| 1.0.0 | Priority-based 3-slot rotation system. Opener + pre-buff dropdowns. Seal-twist (SotC→SoR auto-swap). Holy Strike / Crusader Strike alternating combo. All seals + Crusader Strike + Consecration selectable. |

---


## ⚠️ Critical Rules (read before touching anything)

### 1. Never shorten or "optimize" texture strings
Turtle WoW returns exact texture path strings from `UnitBuff` / `UnitDebuff`.
These must be stored **verbatim** in `spellTextures`. Do NOT shorten, rename,
or "clean up" these strings — it will break buff detection silently.

**Only change a texture string if the user explicitly confirms the new value
from the `/pcabuffs` command output.**

### 2. Never change the buff/debuff detection approach
`HasBuffTexture` and `HasDebuffTexture` use **case-insensitive** `string.find`
(via `string.lower`). Do not revert this to case-sensitive matching.

### 3. UIDropDownMenu API is WoW 1.12 — argument order is reversed
In WoW 1.12, `UIDropDownMenu_SetText(text, frame)` takes **text first, frame second**.
This is the opposite of later expansions. Do not "fix" this to `(frame, text)`.
`UIDropDownMenu_SetSelectedValue` does **not exist** in 1.12 — use `UIDropDownMenu_SetText`.

### 4. Rotation is a single strict-priority loop — do NOT split into phases
The combat rotation in `paladincore()` uses **one loop** over the 3 rotation slots
in strict slot order (1 → 2 → 3). Each slot is evaluated fully (seal applied if
missing, attack cast if ready) before moving to the next. Judgement is a filler
**after** the full loop, not a separate early phase.

Do NOT revert to a "seals first, then Judgement, then attacks" multi-phase design —
this caused seals in lower priority slots to override higher-priority attack spells
(e.g. Consecration in Slot 1 would never fire before a seal in Slot 3).

### 5. XML Scripts block must be LAST inside a Frame element
In WoW 1.12 XML, `<Scripts>` must come after `<Layers>`, `<Frames>`,
and `<Buttons>`. If placed earlier, `OnLoad` fires before child elements
exist, causing silent failures.

### 6. FontStrings must be inside `<Layers><Layer>`
In WoW 1.12 XML, a `<FontString>` placed directly inside a `<Frame>`
(not wrapped in `<Layers><Layer>`) causes a parse error and the entire
addon will fail to load.

### 7. `COMBO_HS_CS` is a special local constant string
The "Holy Strike / Crusader Strike" alternating option is identified by the
local constant `COMBO_HS_CS`. It must be checked with `spell == COMBO_HS_CS`
in all rotation and icon prediction code paths, not by string literal.

### 8. Vanilla 1.12 API — functions that do NOT exist
These functions are **TBC+ only** and will cause `attempt to call global ... (a nil value)` errors:
- `GetActionInfo(slot)` — use `GetActionText(slot)` instead (returns macro name for macro slots)
- `SetCooldown()` on CooldownFrame — not exposed as a Lua method; use `SetAlpha()` instead
- `StartAttack()` — does not exist; use `AttackTarget()` guarded by swing-timer check
- `IsAttacking()` — does not exist; detect via `GetSpellCooldown` on the Attack spell slot

### 9. `AttackTarget()` is a TOGGLE — never call it blindly
In vanilla WoW, `AttackTarget()` toggles auto-attack on **and** off. Always guard
it with a swing-timer check via `GetSpellCooldown(attackSpellSlot, BOOKTYPE_SPELL)`.
Only call `AttackTarget()` when `start == 0` (no swing running = auto-attack is off).

---

## Confirmed Texture Strings (Turtle WoW)

Verified with `/pcabuffs` in-game. **Do not change without re-confirming.**

| Spell | Texture pattern |
|-------|----------------|
| Seal of Righteousness | `Ability_ThunderBolt` |
| Seal of Wisdom | `Spell_Holy_RighteousnessAura` |
| Seal of the Crusader | `Spell_Holy_HolySmite` (same as Judgement of the Crusader debuff) |
| Seal of Justice | `Spell_Holy_SealOfWrath` |
| Seal of Light | `Spell_Holy_SealOfLight` *(unconfirmed — test with /pcabuffs)* |
| Seal of Command | `Ability_Thunderbolt` *(unconfirmed — test with /pcabuffs)* |
| Holy Strike | `Ability_Paladin_HolyStrike` |
| Crusader Strike | `Spell_Holy_CrusaderStrike` |
| Consecration | `Spell_Holy_Consecration` |

---

## Addon File Structure

```
PaladinCore/
  PaladinCore.toc   — TOC. Load order: .lua first, then .xml
  PaladinCore.lua   — All logic (rotation, UI building, helpers)
  PaladinCore.xml   — Only the PCAFrame shell and minimap button; widgets built in Lua
  DEVNOTES.md       — This file
  Devnotes          — Raw in-game texture notes (informal scratch)
```

### TOC fields
```
## SavedVariablesPerCharacter: PCA_Config
PaladinCore.lua
PaladinCore.xml
```

### PCA_Config fields
| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `OpenerSpell` | string | `"Holy Strike"` | Spell cast as the combat opener |
| `OpenerPrebuff` | string | `"Seal of Righteousness"` | Seal applied while running in (when opener = attack spell) |
| `RotationSpell1` | string | `"Seal of Righteousness"` | Slot 1 — highest priority rotation spell |
| `RotationSpell2` | string | `"None"` | Slot 2 — second priority rotation spell |
| `RotationSpell3` | string | `"None"` | Slot 3 — lowest priority rotation spell |
| `HSCSToggle` | string | `"Holy Strike"` | Tracks which spell fires next in the HS/CS alternating combo |
| `FightingUndead` | bool | `false` | When ON, casts Exorcism on undead targets after the pre-buff seal is applied |
| `Debug` | bool | `false` | Whether debug messages print to chat |
| `MinimapPos` | number | `45` | Angle (degrees) of the minimap button position |
| `UIScale` | number | `0.85` | Scale of the settings window |

---

## Rotation Logic (`paladincore()`)

The rotation is executed via the `PalCore` macro (`/script paladincore()`).
It evaluates state on *every press* and performs exactly **one action**.

### Out of Combat (Opener)
1. If **Fighting Undead** is ON and target is Undead/Demon and Exorcism is ready → cast Exorcism + start auto-attack (Absolute Priority).
2. If opener = **attack spell** (Holy Strike, Crusader Strike, or combo):
   - Attempt the attack if in range and ready
   - Apply `OpenerPrebuff` seal while running in / on GCD
3. If opener = **a seal**: apply it silently as a pre-buff

### In Combat — Single Priority Loop

1. If **Fighting Undead** is ON and target is Undead/Demon and Exorcism is ready → cast Exorcism (Absolute Priority).
2. Slots are evaluated in strict order (1 → 2 → 3) with no pre-sealing phase:

- **Seal slot**: if the seal is missing → apply it and stop. If active → skip to next slot.
- **Attack slot**: if the spell is ready → cast it and stop. If on cooldown → skip to next slot.
3. After all slots: if **Judgement** is off cooldown → cast it (filler).

`GetEffectiveSpell()` maps utility seals (SotC/SoW/SoL/SoJ) to `"Seal of Righteousness"`
when their judgement debuff is already on the target — enabling automatic seal-twisting.
SoR and SoC always return as-is.

### Seal-Twist Cycle (example: Slot 1 = SotC, Slot 2 = SoR)
```
Apply SotC → Judge (JotC on target) → SotC slot swaps to SoR → Apply SoR
→ Judge (with SoR) → Attacks → JotC expires → Apply SotC again → repeat
```

### Auto-Attack Guardian
`PCA_EnsureAutoAttack()` is called:
- At the top of every combat rotation press
- Every ~1 second from the OnUpdate frame

It checks `GetSpellCooldown(attackSpellSlot, BOOKTYPE_SPELL)`. If `start == 0`
(no swing timer = auto-attack is off), it calls `AttackTarget()`. If `start > 0`,
auto-attack is already running and nothing is done — preventing accidental toggle-off.

---

## Slash Commands

| Command | Effect |
|---------|--------|
| `/pca` | Open settings menu (Escape closes it) |
| `/pcabuffs` | Dump all player buff textures + target debuff textures to chat |

---

## Settings Menu

The `/pca` menu (also opens via minimap button) contains:

| Control | Purpose |
|---------|---------|
| **Opener Spell** dropdown | What to cast/apply when entering combat |
| **Pre-buff (out of range)** dropdown | Seal to apply while running in (only when opener = attack) |
| **1. Rotation Spell** dropdown | Highest priority slot |
| **2. Rotation Spell** dropdown | Second priority slot |
| **3. Rotation Spell** dropdown | Lowest priority slot |
| **Fighting Undead** toggle | ON/OFF — casts Exorcism on undead targets after pre-buff seal |
| **Debug** toggle | ON/OFF debug chat output |
| **Drag button** | Drag to action bar to place the `PalCore` macro |
| **Scale −/+** | Resize the settings window (saved, range 0.5–1.5) |

Rotation spell options include: `None`, all 6 seals, `Holy Strike`, `Crusader Strike`,
`Holy Strike / Crusader Strike`, `Consecration`.

---

## Action Bar Button & Cooldown Feedback

The `PalCore` macro icon updates dynamically ~3× per second to show the next
expected action. The **action bar button** dims to 45% opacity when the next
spell is on cooldown and snaps back to full brightness when it's ready.

The settings panel **drag button** icon tints dark grey when on cooldown
and restores to full colour when ready.

The addon scans action bar slots every 5 seconds (using `GetActionText`, the
vanilla-1.12-compatible API) to find which button holds the macro, then
applies `SetAlpha()` accordingly.
