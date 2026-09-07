# Requirements — TIC-80 Lode Runner Clone

Scope: `runner.lua`, a single-cart TIC-80 game implementing a Lode Runner style
platformer (collect boxes, climb ladders/ropes, dig traps for guards, avoid capture).

Requirements are grouped by architecture topic. Each requirement has a stable ID for
traceability with the architecture document and future test cases.

## 1. Level & Tile System

### Functional Requirements

- **FR-1.1**: The level shall be represented as a grid of fixed-size (8x8px) tiles, addressable by column/row.
- **FR-1.2**: The system shall support at least the following tile types: empty space, brick (diggable), floor (indestructible), ladder, hidden ladder-top, bar/rope, box (collectible).
- **FR-1.3**: Ladder-top tiles (`h`) shall remain invisible/non-functional until all boxes on the level have been collected, at which point they become visible and climbable.
- **FR-1.4**: The system shall provide read/write access to individual tiles by column/row so gameplay systems (digging, box pickup) can mutate the level at runtime.
- **FR-1.5**: Any pixel coordinate shall be resolvable to its containing tile (column/row + character).

### Non-Functional Requirements

- **NFR-1.1**: Tile lookups shall be out-of-bounds safe (return a neutral/empty tile instead of erroring) to avoid crashing the game loop.
- **NFR-1.2**: The level format shall stay human-editable as plain ASCII rows to keep level design lightweight.

## 2. Player (Runner) Mechanics

### Functional Requirements

- **FR-2.1**: The player shall move left/right at constant speed, blocked by solid tiles (brick, floor).
- **FR-2.2**: The player shall climb up/down while overlapping a visible ladder tile, snapping horizontally to the ladder's column while doing so.
- **FR-2.3**: The player shall be able to descend onto a ladder from a tile directly above it.
- **FR-2.4**: Reaching the top or bottom of a ladder shall flush-align the player to the adjacent tile/floor (no partial-tile overlap).
- **FR-2.5**: The player shall be able to hang on and traverse horizontal bar/rope tiles.
- **FR-2.6**: The player shall drop from a bar only while the down input is held, and shall fall through (not re-catch) the same bar once dropping.
- **FR-2.7**: The player shall fall (gravity) whenever unsupported by solid ground, a ladder, or a trapped guard, and landing shall flush-align to the supporting tile.
- **FR-2.8**: Horizontal movement input shall be ignored while the player is falling.
- **FR-2.9**: The player shall collect a box on overlapping it; the box shall disappear and the remaining-box counter shall decrement.
- **FR-2.10**: Collecting the last box shall reveal all hidden ladder-top tiles.
- **FR-2.11**: The level shall be marked complete once all boxes are collected and the player reaches the topmost row.
- **FR-2.12**: When a level is complete and another level is available, gameplay shall pause for six seconds and then load the next level.
- **FR-2.13**: After the final level is complete, gameplay shall remain paused and display a final celebration state instead of attempting another level transition.

### Non-Functional Requirements

- **NFR-2.1**: Movement shall be frame-rate/tick based (fixed step) to keep behavior deterministic and replayable.
- **NFR-2.2**: Player physics logic shall be implemented as reusable functions shared with other movable entities (see §7) rather than duplicated per-entity code.

## 3. Digging & Hole Mechanics

### Functional Requirements

- **FR-3.1**: The player shall be able to dig a hole into the brick tile immediately to the left or right of, and one row below, their current position.
- **FR-3.2**: Digging shall only succeed against brick tiles; floor tiles and any other tile type shall not be diggable.
- **FR-3.3**: Digging shall be blocked if the tile directly above the target brick is solid (brick or floor), since that would dig a pit nobody could ever fall into. The one exception is when that tile above is itself a currently-open pit (already dug), in which case digging is still allowed.
- **FR-3.4**: A dug hole shall temporarily behave as empty/open space.
- **FR-3.5**: A dug hole shall automatically refill (revert to brick) after a fixed time period.
- **FR-3.6**: Digging shall be triggered by a discrete key press (not continuously while held).
- **FR-3.7**: At most one hole shall exist per tile at a time (re-digging an already-open hole shall have no additional effect).
- **FR-3.8**: If the player is standing inside a hole's tile at the moment it refills, the player shall be caught (lose a life), the same as a guard being crushed by a refilling hole.
- **FR-3.9**: When a life is lost for any reason, all still-active holes shall be restored to their original brick tiles and removed from the active-hole registry before actor respawn is performed.

### Non-Functional Requirements

- **NFR-3.1**: Hole state shall be tracked independently of the level grid's static character data so refill/trap logic can be reasoned about without re-scanning the level.

## 4. Guard Behavior

### Functional Requirements

- **FR-4.1**: One or more guard entities shall path toward the player's current position using the same movement primitives as the player (walk, climb ladders, use bars, fall).
- **FR-4.2**: Guards shall not be able to dig holes.
- **FR-4.3**: A guard entering a dug hole tile shall become trapped and stop pursuing the player.
- **FR-4.4**: A trapped guard shall automatically climb out (repositioning one tile up, onto the surface) and resume pursuit after a fixed escape time, provided the hole has not yet refilled.
- **FR-4.4a**: Immediately after climbing out, a guard shall be temporarily immune to falling back into the same still-open hole, for long enough to walk clear of it, since the surface tile it climbs onto is not otherwise considered supported while the hole beneath remains open.
- **FR-4.5**: If a hole refills while a guard is still trapped inside it, that guard shall respawn at its original spawn location.
- **FR-4.6**: A trapped guard's tile shall act as safe, walkable support for the player (the player may stand on / cross over a trapped guard without dying and without falling through the hole).
- **FR-4.7**: Contact between the player and a guard that is not trapped shall count as the player being caught.
- **FR-4.8**: Guards shall have distinct sprites/animations for running, hanging on a bar, climbing a ladder, and falling, mirrored by facing direction the same way as the player.

### Non-Functional Requirements

- **NFR-4.1**: Guard AI shall be simple/heuristic (directional chase), avoiding pathfinding complexity not present in the original 8-bit reference behavior.
- **NFR-4.2**: Guard count shall be configurable via data (a list of spawn entries) rather than hardcoded per-guard logic.
- **NFR-4.3**: Guard movement speed shall be independently configurable from the player's and shall default to slower than the player, to keep the chase fair.

## 5. Lives, Failure & Progression

### Functional Requirements

- **FR-5.1**: The player shall start with a fixed number of lives.
- **FR-5.2**: Being caught (by a non-trapped guard, or by being buried in a refilling pit per FR-3.8) shall decrement the player's lives, respawn the player at the level's starting position, and reset every guard back to its own spawn position (a full positional reset of all actors, matching the reference game).
- **FR-5.2a**: Life-loss handling shall be atomic from the gameplay loop's perspective: after a buried-runner loss, hole processing shall stop immediately so no stale hole entry is processed after the reset.
- **FR-5.3**: Reaching zero lives shall end the game and display a game-over state.
- **FR-5.4**: Completing the level (see FR-2.11) shall display a level-complete state.
- **FR-5.5**: Gameplay updates (movement, digging, guard AI, collision) shall stop once the game has ended or the level is complete.
- **FR-5.6**: If the runner falls below the TIC-80 screen, the runner shall lose a life and respawn at the current level's starting position.
- **FR-5.7**: If a guard falls below the TIC-80 screen, that guard shall respawn at its configured spawn position without reducing the runner's lives.

### Non-Functional Requirements

- **NFR-5.1**: Game-state transitions (playing → game-over / level-complete) shall be represented by explicit flags checked once per frame, not scattered conditionals.

## 6. Rendering & HUD

### Functional Requirements

- **FR-6.1**: The system shall render all level tiles, the player, and all guards every frame, reflecting current animation state (running, climbing, hanging, falling).
- **FR-6.2**: The HUD shall display the number of boxes remaining and the player's remaining lives during normal play.
- **FR-6.3**: The HUD shall display a distinct message when the game is over and when the level is complete.
- **FR-6.4**: Sprites shall visually mirror (flip) based on facing direction.
- **FR-6.5**: During normal play, the HUD shall display the current level number and total number of levels on the same line as the boxes and lives counters.
- **FR-6.6**: During the six-second level transition, the HUD shall display the completion message and remaining countdown; after the final level it shall display a final-all-levels-solved celebration.

### Non-Functional Requirements

- **NFR-6.1**: Rendering shall not mutate gameplay state (pure read of current entity/level state).

## 7. Input Handling

### Functional Requirements

- **FR-7.1**: Directional input (up/down/left/right) shall drive player movement per §2.
- **FR-7.2**: Two dedicated inputs shall trigger left-dig and right-dig respectively, independent of movement input.
- **FR-7.3**: The left-dig input shall be triggered by the gamepad button, or either physical Y or Z key, so that it works the same on both QWERTY and QWERTZ keyboard layouts (TIC-80 key codes are physical-position based, and Y/Z swap position between those layouts).

### Non-Functional Requirements

- **NFR-7.1**: Input shall be polled once per frame via the platform's button API; no custom input buffering/queuing is required at this scope.

## 8. Platform & Engineering Constraints (TIC-80)

### Non-Functional Requirements

- **NFR-8.1**: The game shall run as a single TIC-80 Lua cart (`runner.lua`) using only the standard TIC-80 API (`TIC`, `btn`, `btnp`, `spr`, `print`, `cls`).
- **NFR-8.2**: The implementation shall stay within TIC-80's default screen resolution (240x136) and 8x8 sprite grid conventions.
- **NFR-8.3**: All gameplay logic shall run within the `TIC()` callback budget of a single frame at the console's default 60 FPS target, without noticeable slowdown for the current level size and entity count.
- **NFR-8.4**: Shared physics helpers (movement, gravity, climbing) shall be engine-agnostic Lua functions operating on plain entity tables, to ease unit-testing outside TIC-80 if desired.
- **NFR-8.5**: The codebase shall remain a single file consistent with simple TIC-80 cart distribution, but internally organized into clearly delimited sections (level, physics, digging, guards, collision, main loop) for maintainability.

## 9. Multi-Level Architecture & Extensibility

- **FR-9.1**: Levels shall be defined as data records containing level rows, a runner spawn record, and a configurable guard spawn list.
- **FR-9.2**: Loading a level shall reset its mutable runtime state (active holes, box count, ladder visibility, completion timer, runner, and guards) while preserving the global lives count.
- **FR-9.3 (Candidate)**: Persist high scores or best times across sessions.
- **FR-9.4 (Candidate)**: Distinct sprite/animation for a trapped guard (currently reuses the run-frame-0 pose) instead of reusing the run animation.
- **FR-9.5 (Candidate)**: Sound effects/music via TIC-80's `sfx`/`music` API.

These are explicitly out of current scope but noted so the architecture leaves room for them.
