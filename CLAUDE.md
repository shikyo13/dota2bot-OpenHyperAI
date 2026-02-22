# Dota2AI - OpenHyperAI Bot Scripts

## Overview

Forked from [forest0xia/dota2bot-OpenHyperAI](https://github.com/forest0xia/dota2bot-OpenHyperAI). Lua-based Dota 2 bot AI covering all 126+ heroes. TypeScript source compiles to Lua via `typescript-to-lua`. Most bot logic is hand-written Lua; TypeScript covers newer modules (roles, buffs, matchups, utilities).

## Architecture

### Bot Lifecycle
1. **Hero Selection** (`bots/hero_selection.lua`) — Matchup-aware drafter with role/position weighting, ban lists, weak-hero caps, and customization support.
2. **Bot Init** (`bots/bot_generic.lua`) — Entry point per hero. Loads hero-specific config from `BotLib/hero_<name>.lua`, delegates `MinionThink`.
3. **Item Purchase** (`bots/item_purchase_generic.lua`) — Reads `sBuyList`/`sSellList` from hero config, handles courier, secret shop, shard/aghs timing, ward buying.
4. **Ability Usage** (`bots/ability_item_usage_generic.lua`) — Generic ability/item casting framework.
5. **Mode Scripts** (`bots/mode_*_generic.lua`) — Laning, farming, pushing, defending, assembling, attacking.

### Key Directories
| Path | Purpose |
|------|---------|
| `bots/BotLib/` | Per-hero configs (127 files): talent trees, ability builds, item builds per role, skill usage |
| `bots/FunLib/` | Shared utility library — the core AI logic |
| `bots/Customize/` | User-facing settings (hero picks, bans, names, difficulty, trash talk) |
| `bots/FretBots/` | Enhanced difficulty system with neutral items, gold/XP bonuses, matchup data |
| `bots/Buff/` | Buff/modifier handling per hero |
| `typescript/bots/` | TypeScript sources that compile to Lua |
| `game/` | Game-level overrides (botsinit, gameinit) |

### Core Modules in `FunLib/`
- **`jmz_func.lua`** — Central hub (`J` table). Aggregates Item, Buff, Role, Skill, Chat, Utils, Customize. Contains `SetUserHeroInit()` for loading custom hero overrides, plus hundreds of helper functions for combat, movement, targeting.
- **`aba_item.lua`** — Item purchase AI: role-based item lists, secret shop routing, item usage (BKB, blink, manta, etc).
- **`aba_role.lua`** — Role assignment (pos 1-5) per team, lane assignment, carry/support/initiator classification.
- **`aba_skill.lua`** — Ability leveling and skill build management.
- **`aba_buff.lua`** — Buff/debuff detection and response.
- **`aba_site.lua`** — Map awareness: ward spots, rune locations, jungle camps.
- **`aba_defend.lua`** — Tower defense logic.
- **`aba_push.lua`** — Push/siege decision making.
- **`utils.lua`** — General utilities (distance, validation, team queries, HTTP for LLM).
- **`custom_loader.lua`** — Loads Customize settings from `game/Customize/` (persists across updates) with fallback to `bots/Customize/`.

### Hero Config Pattern (`BotLib/hero_*.lua`)
Each hero file exports:
- `sBuyList` — Item purchase order per role (pos_1 through pos_5)
- `sSellList` — Items to sell when upgrading
- `sSkillList` — Ability/talent leveling order
- `bDeafaultAbility` / `bDeafaultItem` — Whether to use generic behavior
- `MinionThink()` — Summoned unit AI
- `GetDesire_*()` / `Consider_*()` — Hero-specific ability casting logic

## Build Commands
```bash
npm run build:lua    # Compile TypeScript to Lua + post-process require paths
npm run dev          # Watch mode (auto-recompile on TS changes)
npm run build:node   # Build Node.js scripts (matchup/neutral scrapers)
npm run prettier     # Format all code
npm run release      # Update version + build + format
```

**Note:** `npm install --legacy-peer-deps` is required due to typescript@5.5.4 vs typescript-to-lua peer dep on 5.5.2.

## Paths
| What | Path |
|------|------|
| Project root | `D:\Dev\Projects\Dota2AI` |
| Bot scripts (Lua) | `D:\Dev\Projects\Dota2AI\bots` |
| TypeScript source | `D:\Dev\Projects\Dota2AI\typescript` |
| Dota 2 game | `D:\Steamlibrary\steamapps\common\dota 2 beta` |
| Dota 2 bot symlink | `...\game\dota\scripts\vscripts\bots` -> project `bots/` |
| Dota 2 custom overrides | `...\game\dota\scripts\vscripts\game\Customize\` |

## Git Workflow
- **`main`** — Synced with upstream (`forest0xia/dota2bot-OpenHyperAI`)
- **`dev`** — Development branch for our improvements
- **`upstream`** remote — Original repo. Sync with: `git fetch upstream && git merge upstream/main`

## Testing Workflow
1. Build: `npm run build:lua`
2. Launch Dota 2
3. Create lobby (Local Lobby > fill with bots)
4. Play/observe bot behavior
5. Check console for `[ERROR]`/`[WARN]` messages from bot scripts

## Coding Conventions
- Lua files use local modules: `local X = {} ... return X`
- The `J` table (from `jmz_func.lua`) is the primary API for hero configs
- Role-based item builds use keys: `pos_1` through `pos_5`
- Talent trees use `{left_value, right_value}` format, 0 = pick left, 10 = pick right
- Hero internal names: `npc_dota_hero_<name>` (e.g., `npc_dota_hero_axe`)
- TypeScript source uses TSTL conventions; compiled Lua goes through post-processing to fix `require()` paths

## Improvement Areas
- Better itemization (no double boots, neutral item awareness)
- Camp pulling and stacking logic
- Warding and dewarding AI
- Reducing bots getting stuck
- Better tower defense for both sides
- Optional LLM-powered behavior
