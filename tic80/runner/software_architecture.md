# Software Architecture — TIC-80 Runner

Companion document to [requirements.md](requirements.md). Describes the structure of
`runner.lua` as implemented: a single TIC-80 cart driven by the `TIC()` callback, with
gameplay split into a level/tile layer, shared entity physics, and per-feature systems
(digging, guards, collision) orchestrated once per frame.

## 1. Architectural Overview

The cart has no external modules (TIC-80 constraint, see NFR-8.1/NFR-8.5). Internally it is
organized into layers by responsibility, all within one file:

```mermaid
flowchart TB
    subgraph Engine["TIC-80 Runtime"]
        API["btn / btnp / spr / print / cls"]
    end

    subgraph Cart["runner.lua"]
        Loop["Main Loop (TIC)"]
        Level["Level & Tile System\n(level_data, load_level, tile_xy, set_tile_xy)"]
        Physics["Shared Entity Physics\n(try_move_horizontal, try_vertical_move, apply_gravity)"]
        Dig["Digging & Holes\n(try_dig, update_holes)"]
        Guards["Guard AI & State\n(guard_ai, scan_floor, schedule_guards,\nupdate_guard, check_trap, respawn_guard)"]
        Collision["Collision & Lives\n(check_guard_collision, lose_life)"]
        Render["Rendering & HUD"]
    end

    API --> Loop
    Loop --> Level
    Loop --> Physics
    Loop --> Dig
    Loop --> Guards
    Loop --> Collision
    Loop --> Render
    Physics --> Level
    Dig --> Level
    Guards --> Physics
    Guards --> Dig
    Collision --> Guards
    Render --> Level
    Render --> API
```

Key design decision: **runner and guards share the same physics functions** (`try_move_horizontal`,
`try_vertical_move`, `apply_gravity`), parameterized by a generic *entity* table and boolean
directional inputs. The runner supplies real button state; guards supply AI-derived intent
(`guard_ai`). This satisfies NFR-2.2 and NFR-4.1/4.2 and avoids duplicated movement code.

Guards differ from the runner in one respect: they do not move on a fixed tick divisor but
only when `schedule_guards` grants them a step from a shared budget. Section 4 covers the
guard AI and its scheduler in full.

## 2. Data Model (Class / Entity Diagram)

Entities are plain Lua tables, not OOP classes (no metatables needed at this scope). The
diagram below models them as classes for clarity.

```mermaid
classDiagram
    class Entity {
        +number x
        +number y
        +number dir
        +boolean falling
        +boolean ready
        +number idx
    }

    class Runner {
        +number spawn_x
        +number spawn_y
    }

    class Guard {
        +number spawn_x
        +number spawn_y
        +string state  "run|trapped"
        +number trapped_timer
        +number tx
        +number ty
    }

    class Hole {
        +number tx
        +number ty
        +number timer
        +string orig
        +Guard guard
    }

    class Level {
        +string[] rows
        +tile_xy(tx, ty) string
        +set_tile_xy(tx, ty, ch)
        +tile_char_at_pixel(px, py) string, tx, ty
    }

    class GameState {
        +number current_level
        +number boxes_remaining
        +boolean ladders_revealed
        +boolean level_complete
        +number level_complete_timer
        +boolean final_level_complete
        +boolean game_over
        +number lives
    }

    class LevelRecord {
        +string[] rows
        +Runner runner_spawn
        +Guard[] guard_spawns
    }

    Entity <|-- Runner
    Entity <|-- Guard
    Hole "0..1" --> "0..1" Guard : traps
    GameState --> Level
    GameState --> LevelRecord : selects current level
    Runner "1" -- "0..*" Guard : pursued by
```

Each entry in `level_data` is a `LevelRecord` containing the tile rows, one runner spawn
table, and a configurable guard spawn list. `load_level(level_index)` binds those records
to the active `level`, `runner`, and `guards` tables and resets level-local mutable state.

## 3. Guard State Machine

Guards are the only entities with an explicit state machine (`run` / `trapped`); the runner
is stateless aside from its `falling` flag, since it never gets trapped by design (falling
into a hole behaves like normal empty-space physics for the player).

```mermaid
stateDiagram-v2
    [*] --> Running

    Running --> Trapped : enters a hole tile (check_trap)
    Trapped --> Escaping : trapped_timer expires (climbs out, y-8)
    Escaping --> Running : grace window elapses
    Trapped --> Respawning : hole refills while trapped
    Respawning --> Running : respawn_guard() (back to spawn point)

    state Running {
        [*] --> Chasing
        Chasing --> Falling : unsupported
        Falling --> Chasing : lands / climbs
        Chasing --> Climbing : on ladder, moving up/down
        Climbing --> Chasing
    }

    note right of Trapped
        Guard is immobile.
        Its tile becomes safe
        support for the runner
        (guard_support_at).
    end note

    note right of Escaping
        apply_gravity's support
        check is skipped for
        grace ticks so the guard
        isn't yanked straight back
        into the still-open hole.
    end note
```

## 4. Guard AI in Detail

The guard AI is a feature enhanced version of classic runner or chasing games. It replaced an earlier
greedy "move towards the runner on both axes" controller, which could not express a detour
and therefore stalled whenever reaching the runner required temporarily increasing distance.

Two properties define it:

- **It is not a pathfinder.** There is no BFS, no A\*, no open/closed set, no memory between
  frames. Every decision is recomputed from scratch against the live tile grid.
- **It is deliberately exploitable.** The scan is limited to the guard's *current floor
  segment*, so a player can bait guards into predictable positions. This is a gameplay
  requirement, not a limitation to be fixed — a true shortest-path chase would be unbeatable
  and unfun.

### 4.1 The Three-Layer Decision

`guard_ai(g)` returns exactly **one** action per call: `"left"`, `"right"`, `"up"`, `"down"`,
or `nil` (stand still). Layers are evaluated in priority order and the first one that
produces an answer wins.

| Layer | Condition | Mechanism | Result |
|-------|-----------|-----------|--------|
| 1 — Gravity | guard unsupported | handled entirely by `apply_gravity`, not by the AI | AI output ignored while falling |
| 2 — Same-floor dash | `gy == ry` and runner not falling | virtual cursor walk from `gx` to `rx` verifying every tile is standable | `"left"` / `"right"` if the cursor arrives |
| 3 — Floor scan | everything else | `scan_floor` rates every descent/climb point on the current floor segment | direction of the best-rated probe |

Returning a single action rather than a set of directional booleans is essential: the shared
physics apply horizontal and vertical movement in the same tick, and `try_vertical_move`
snaps `e.x` onto the ladder column. A simultaneous "left" + "down" would see the horizontal
step silently discarded every frame, pinning the guard to the ladder column.

### 4.2 Pit-Awareness Policy

`guards_pit_aware` controls only route planning; it does not disable pit physics or trap
detection. The default is `true`.

```lua
guards_pit_aware=true   -- guards route around live dug pits
guards_pit_aware=false  -- guards ignore live dug pits while choosing a route
```

`is_guard_pit(tx, ty)` is the central policy predicate. A tile is a recognized guard pit only
when it exists in the live `holes` table *and* `guards_pit_aware` is true. The AI uses this
predicate through `can_walk_at`, `can_branch`, and `scan_down`:

```mermaid
flowchart TD
    H["Live hole exists in holes[tx,ty]"] --> A{"guards_pit_aware?"}
    A -- "true" --> R["Reject pit from route planning"]
    A -- "false" --> I["Ignore pit during route planning"]
    R --> P["Guard searches for another floor, ladder, or drop"]
    I --> M["Guard keeps direct pursuit toward runner"]
    M --> F["Normal gravity moves guard into opening"]
    F --> T["check_trap() sets state = trapped"]
```

The coordinate relationship is important. A guard walking on `(tx, ty)` falls into a dug
brick at `(tx, ty+1)`. Therefore, in unaware mode `can_walk_at(tx, ty)` also treats the tile
above a live hole as traversable. Without this case, the same-floor path check would reject
the position before physics could make the guard fall, and the AI could turn away even though
pit awareness was disabled.

The policy deliberately leaves `try_dig`, `apply_gravity`, and `check_trap` unchanged:

| Setting | Route planner | Physics and trap result |
|---------|---------------|-------------------------|
| `true` | Rejects live pits and searches for another route | A guard that nevertheless reaches a pit can still fall and be trapped |
| `false` | Treats live pits, including their walk tiles, as ordinary route space | A guard pursuing across a newly dug pit can fall and become trapped |

This is a gameplay policy rather than a collision mode. Turning awareness off makes guards
less cautious; it does not make pits non-existent.

### 4.3 Use Case Diagram

Actors and the goals the guard AI subsystem serves.

```mermaid
flowchart LR
    Player(["Player<br/>(actor)"])
    Clock(["TIC-80 Frame Clock<br/>(actor)"])

    subgraph S["Guard AI Subsystem"]
        UC1(["Pursue the runner"])
        UC2(["Reach the runner's floor"])
        UC3(["Choose a descent point"])
        UC4(["Choose a climb point"])
        UC5(["Throttle the guard population"])
        UC6(["Be trapped in a dug hole"])
        UC7(["Escape or respawn"])
    end

    Clock --> UC5
    Clock --> UC1
    Player --> UC6
    Player --> UC1

    UC1 -. includes .-> UC2
    UC2 -. extends .-> UC3
    UC2 -. extends .-> UC4
    UC6 -. extends .-> UC7
    UC5 -. constrains .-> UC1
```

### 4.4 Package Diagram

Dependency direction is strictly downward — the AI reads the tile grid but never writes it.

```mermaid
flowchart TB
    subgraph P1["guard.ai"]
        A1["guard_ai"]
        A2["scan_floor"]
        A3["scan_down / scan_up / scan_rate"]
        A4["is_guard_pit / can_walk_at / can_branch / supports_walking"]
    end

    subgraph P2["guard.schedule"]
        B1["MOVE_POLICY"]
        B2["schedule_guards"]
    end

    subgraph P3["guard.lifecycle"]
        C1["update_guard"]
        C2["check_trap / respawn_guard"]
    end

    subgraph P4["entity.physics"]
        D1["try_move_horizontal"]
        D2["try_vertical_move"]
        D3["apply_gravity"]
    end

    subgraph P5["level.grid"]
        E1["tile_xy / tile_char_at_pixel"]
        E2["is_solid / is_visible_ladder_char"]
        E3["level_w / level_h"]
    end

    C1 --> A1
    C1 --> D1
    C1 --> D2
    C1 --> D3
    C1 --> C2
    B2 --> B1
    B2 -. sets ready flag .-> P4
    A1 --> A2
    A2 --> A3
    A3 --> A4
    A4 --> E2
    A1 --> E1
    A3 --> E3
    D1 --> E2
    D2 --> E2
    D3 --> E2
```

### 4.5 Component Diagram

Provided and required interfaces between the guard components.

```mermaid
flowchart LR
    subgraph Sched["«component» GuardScheduler"]
        SP["provides: ready flags"]
        SR["requires: guard count, frame tick"]
    end

    subgraph AI["«component» GuardAI"]
        AP["provides: action(g)"]
        AR["requires: read-only tile queries,<br/>runner tile position"]
    end

    subgraph Phys["«component» SharedPhysics"]
        PP["provides: move / climb / gravity"]
        PR["requires: ready flag, action"]
    end

    subgraph Grid["«component» LevelGrid"]
        GP["provides: tile_xy, classifiers, bounds"]
    end

    subgraph Life["«component» GuardLifecycle"]
        LP["provides: update_guard"]
        LR["requires: action, physics, trap state"]
    end

    SP --> PR
    AP --> LR
    LP --> PR
    AR --> GP
    PR --> GP
    LR --> AP
```

### 4.6 Composite Structure Diagram

Internal wiring of the `GuardAI` component, showing ports and the delegation of each
port to an internal part.

```mermaid
flowchart TB
    subgraph GuardAI["«component» GuardAI"]
        direction TB
        PortIn(["port: guard g"])
        PortTile(["port: tile queries"])
        PortOut(["port: action"])

        Layer2["part: SameFloorDash<br/>(cursor walk)"]
        Layer3["part: FloorScanner"]
        Ends["part: SegmentBounds<br/>(left_end / right_end)"]
        Probe["part: Prober<br/>(scan_down / scan_up)"]
        Rate["part: Rater<br/>(scan_rate, best_rating)"]

        PortIn --> Layer2
        Layer2 -- "no path" --> Layer3
        Layer2 -- "path found" --> PortOut
        Layer3 --> Ends
        Ends --> Probe
        Probe --> Rate
        Rate --> PortOut
        Layer2 -.-> PortTile
        Ends -.-> PortTile
        Probe -.-> PortTile
    end
```

### 4.7 Class Diagram

The AI is plain functions over tables; modelled here as classes for clarity. Note the
`ready` attribute added to `Entity` — it is the contract between scheduler and physics.

```mermaid
classDiagram
    class Entity {
        +number x
        +number y
        +boolean falling
        +boolean ready
    }

    class Guard {
        +string state
        +number trapped_timer
        +number grace
    }

    class GuardScheduler {
        +MOVE_POLICY table
        +number MOVE_CYCLE
        +number move_offset
        +number move_id
        +schedule_guards()
    }

    class GuardAI {
        +boolean guards_pit_aware
        +guard_ai(g) string
        +scan_floor(g) string
        +is_guard_pit(tx, ty) boolean
        +tile_of(e) tx, ty
    }

    class FloorScan {
        +scan_down(tx, start_ty, runner_ty) y
        +scan_up(tx, start_ty, runner_ty) y
        +scan_rate(x, y, runner_ty, start_x) rating
    }

    class TilePredicates {
        +supports_walking(c) boolean
        +can_walk_at(tx, ty) boolean
        +can_branch(tx, ty) boolean
    }

    class SharedPhysics {
        +try_move_horizontal(e, left, right)
        +try_vertical_move(e, up, down) boolean
        +apply_gravity(e, moved_vert, down)
    }

    class LevelGrid {
        +number level_w
        +number level_h
        +tile_xy(tx, ty) string
        +is_solid(c) boolean
        +is_visible_ladder_char(c) boolean
    }

    Entity <|-- Guard
    GuardScheduler ..> Guard : sets ready
    GuardAI ..> Guard : reads position
    GuardAI ..> FloorScan : uses
    FloorScan ..> TilePredicates : uses
    TilePredicates ..> LevelGrid : queries
    GuardAI ..> LevelGrid : queries
    SharedPhysics ..> Entity : mutates
    SharedPhysics ..> LevelGrid : queries
```

### 4.8 Object Diagram

A snapshot of level 3 at the instant the third guard decides to go left (see the worked
example in 4.17). Values are tile coordinates unless suffixed with `px`.

```mermaid
classDiagram
    class runner_obj {
        <<object : Runner>>
        x = 112px
        y = 112px
        tile = (15, 15)
        falling = false
    }

    class guard3_obj {
        <<object : Guard>>
        x = 120px
        y = 72px
        tile = (16, 10)
        state = "run"
        ready = true
    }

    class scan_obj {
        <<object : FloorScan>>
        start_x = 16
        start_y = 10
        left_end = 1
        right_end = 22
        best_rating = 6
        best_path = "left"
    }

    class sched_obj {
        <<object : GuardScheduler>>
        guard_count = 3
        move_offset = 2
        move_id = 3
        budget = 2
    }

    sched_obj --> guard3_obj : granted a step
    guard3_obj --> scan_obj : produced
    scan_obj --> runner_obj : rated against
```

### 4.9 Activity Diagram — `guard_ai`

Swimlanes separate the two decision layers from the grid queries they depend on.

```mermaid
flowchart TB
    subgraph L1["Lane: guard_ai"]
        S(["start"]) --> A["gx, gy = tile_of(g)<br/>rx, ry = runner tile"]
        A --> B{"gy equals ry<br/>and runner not falling?"}
        B -- no --> J["delegate to scan_floor"]
        B -- yes --> C["cursor x = gx"]
        C --> D{"x not equal rx<br/>and can_walk_at(x, gy)?"}
        D -- yes --> E["step cursor one tile<br/>towards rx"]
        E --> D
        D -- no --> F{"cursor reached rx?"}
        F -- no --> J
        F -- yes --> G{"compare pixel x"}
        G -- "g.x less than runner.x" --> H1(["return right"])
        G -- "g.x greater than runner.x" --> H2(["return left"])
        G -- equal --> H3(["return nil"])
        J --> K(["return scan_floor(g)"])
    end

    subgraph L2["Lane: level.grid"]
        Q1["can_walk_at:<br/>pit policy first, then:<br/>ladder or bar here, OR<br/>bottom row, OR<br/>solid / ladder / bar / gold below"]
    end

    D -.-> Q1
```

### 4.10 Activity Diagram — `scan_floor`

This is the core routine and the reason guards now seek ladders.

```mermaid
flowchart TB
    S(["start"]) --> A["start_x, start_y = tile_of(g)<br/>runner_ty = runner tile row<br/>best_rating = 255, best_path = nil"]
    A --> B["walk left while neighbour not solid;<br/>include one tile past the<br/>last walkable cell"]
    B --> C["left_end"]
    C --> D["walk right the same way"]
    D --> E["right_end"]
    E --> F["probe(start_x) with<br/>down_path = down, up_path = up"]
    F --> G["path = left, x = left_end"]
    G --> H{"x equals start_x?"}
    H -- yes --> I{"path is left<br/>and right_end differs<br/>from start_x?"}
    I -- yes --> J["path = right<br/>x = right_end"]
    J --> H
    I -- no --> Z(["return best_path"])
    H -- no --> K["probe(x) with<br/>down_path = up_path = path"]
    K --> L["advance x towards start_x"]
    L --> H

    subgraph PR["probe(tx)"]
        P1{"tile below start_y<br/>is solid?"}
        P1 -- no --> P2["y = scan_down(tx)"]
        P2 --> P3["rate(tx, y)"]
        P1 -- yes --> P4{"tile at start_y<br/>is a visible ladder?"}
        P3 --> P4
        P4 -- yes --> P5["y = scan_up(tx)"]
        P5 --> P6["rate(tx, y)"]
        P4 -- no --> P7(["done"])
        P6 --> P7
    end

    subgraph RT["rate(tx, y)"]
        R1["r = scan_rate(tx, y, runner_ty, start_x)"]
        R1 --> R2{"r less than best_rating?"}
        R2 -- yes --> R3["best_rating = r<br/>best_path = path"]
        R2 -- no --> R4(["discard"])
    end

    F -.-> PR
    K -.-> PR
    P3 -.-> RT
    P6 -.-> RT
```

Note the deliberate asymmetry in the segment-bounds walk: the loop steps onto the boundary
tile **and then** breaks if that tile was not walkable. The drop at the end of a platform is
therefore itself a candidate probe column — that is how a guard decides to walk off a ledge.

### 4.11 State Machine Diagram — AI Action State

Complements the lifecycle machine in section 3. This one models what the *decision* layer
produces, which is orthogonal to trap/respawn state.

```mermaid
stateDiagram-v2
    [*] --> Unscheduled

    Unscheduled --> Deciding : scheduler sets ready
    Deciding --> Unscheduled : ready cleared next frame

    state Deciding {
        [*] --> CheckFloor
        CheckFloor --> DirectChase : same row and path confirmed
        CheckFloor --> Scanning : different row or blocked
        Scanning --> Descending : best probe was scan_down
        Scanning --> Climbing : best probe was scan_up
        Scanning --> Traversing : best probe was on a side column
        Scanning --> Idle : no probe beat rating 255
    }

    DirectChase --> Unscheduled
    Descending --> Unscheduled
    Climbing --> Unscheduled
    Traversing --> Unscheduled
    Idle --> Unscheduled

    Deciding --> Suppressed : g.falling
    Suppressed --> Unscheduled : gravity owns the tick

    note right of Idle
        best_path stays nil when every
        probe rates 255 or worse.
        Guard stands still this tick.
    end note

    note right of Traversing
        The action is left or right even
        though the goal is vertical: the
        guard is walking to the column
        that owns the best ladder or drop.
    end note
```

### 4.12 Sequence Diagram — One Scheduled Guard Tick

```mermaid
sequenceDiagram
    participant Loop as TIC()
    participant Sched as schedule_guards
    participant UG as update_guard
    participant AI as guard_ai
    participant SF as scan_floor
    participant Scan as scan_down / scan_up
    participant Grid as level grid
    participant Phys as shared physics

    Loop->>Sched: schedule_guards()
    Sched->>Sched: clear ready on every guard
    alt t mod STEP_TICKS is 0
        Sched->>Sched: advance move_offset (1..6)
        Sched->>Sched: budget = MOVE_POLICY[n][move_offset]
        loop budget times
            Sched->>Sched: move_id = next guard (round robin)
            Sched->>UG: mark ready unless trapped
        end
    end

    loop each guard
        Loop->>UG: update_guard(g)
        alt g.state is trapped
            UG->>UG: tick trapped_timer, maybe climb out
        else
            UG->>AI: guard_ai(g)
            AI->>Grid: tile_of(g), runner tile
            alt same floor
                AI->>Grid: can_walk_at along cursor path
                Grid-->>AI: standable / blocked
                AI-->>UG: "left" or "right"
            else
                AI->>SF: scan_floor(g)
                SF->>Grid: find left_end / right_end
                loop each column in segment
                    SF->>Scan: scan_down / scan_up
                    Scan->>Grid: tile_xy, can_branch
                    Grid-->>Scan: tile chars
                    Scan-->>SF: landing row y
                    SF->>SF: scan_rate, keep best
                end
                SF-->>AI: best_path
                AI-->>UG: action
            end
            UG->>Phys: try_move_horizontal(g, action is left, action is right)
            UG->>Phys: try_vertical_move(g, action is up, action is down)
            Phys-->>UG: moved_vert
            UG->>Phys: apply_gravity(g, moved_vert, action is down)
            Note over Phys: every entry point returns early unless g.ready
            UG->>UG: check_trap(g)
        end
    end
```

### 4.13 Communication Diagram

The same interaction, emphasising the object links and message ordering rather than the
timeline.

```mermaid
flowchart LR
    Loop["TIC()"]
    Sched["schedule_guards"]
    Guard["guard : Guard"]
    AI["guard_ai"]
    SF["scan_floor"]
    Pred["tile predicates"]
    Grid["level grid"]
    Phys["shared physics"]

    Loop -- "1: schedule_guards()" --> Sched
    Sched -- "1.1: ready = false" --> Guard
    Sched -- "1.2: ready = true (budget)" --> Guard
    Loop -- "2: update_guard(g)" --> Guard
    Guard -- "2.1: guard_ai(g)" --> AI
    AI -- "2.1.1: tile_of / runner tile" --> Grid
    AI -- "2.1.2: scan_floor(g)" --> SF
    SF -- "2.1.2.1: can_walk_at / can_branch" --> Pred
    Pred -- "2.1.2.1.1: tile_xy" --> Grid
    SF -- "2.1.2.2: best_path" --> AI
    AI -- "2.2: action" --> Guard
    Guard -- "2.3: move / climb / gravity" --> Phys
    Phys -- "2.3.1: reads ready" --> Guard
    Phys -- "2.3.2: is_solid / ladder" --> Grid
```

### 4.14 Interaction Overview Diagram

Control flow between the interaction fragments defined above.

```mermaid
flowchart TB
    S(["start of frame"]) --> F1["ref:<br/>schedule_guards<br/>(4.12 budget loop)"]
    F1 --> D1{"guard ready?"}
    D1 -- no --> SKIP["no movement<br/>this tick"]
    D1 -- yes --> D2{"trapped?"}
    D2 -- yes --> F2["ref:<br/>trap countdown<br/>(section 9)"]
    D2 -- no --> D3{"same floor<br/>as runner?"}
    D3 -- yes --> F3["ref:<br/>cursor walk<br/>(4.9)"]
    D3 -- no --> F4["ref:<br/>floor scan<br/>(4.10)"]
    F3 --> D4{"path confirmed?"}
    D4 -- no --> F4
    D4 -- yes --> F5["ref:<br/>apply action<br/>(4.12 physics)"]
    F4 --> F5
    F5 --> F6["ref:<br/>check_trap"]
    SKIP --> E(["end of frame"])
    F2 --> E
    F6 --> E
```

### 4.15 Timing Diagram — `MOVE_POLICY` Cadence

UML timing diagram showing scheduler state over one full policy cycle with three guards
on level 3. The policy row for three guards is `{1,2,1,1,2,1}` — eight steps per cycle.
The scheduler only runs on frames where `t mod STEP_TICKS == 0`, so one cycle spans
6 × 3 = 18 TIC frames.

```text
 TIC frame   : 0    3    6    9    12   15   18
 move_offset : 1    2    3    4    5    6    1
 budget      : 1    2    1    1    2    1    1
              ---------------------------------
 guard[1]    : __/‾‾\____________/‾‾\_______/‾‾\
 guard[2]    : ______/‾‾\____________/‾‾\______
 guard[3]    : ___________/‾‾\____/‾‾\_________
              ---------------------------------
 runner      : /‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\
              (steps every STEP_TICKS = 3 frames)

 ‾‾ = ready (movement permitted this frame)
 __ = not scheduled
```

Resulting rates, compared with the fixed 6-frame gate this replaced:

| Guards | Steps per cycle | Per guard | Equivalent period | vs. old fixed gate |
|--------|-----------------|-----------|-------------------|--------------------|
| 1 | 4 | 4.00 | 1 step / 4.5 frames | faster |
| 2 | 6 | 3.00 | 1 step / 6.0 frames | identical |
| 3 | 8 | 2.67 | 1 step / 6.75 frames | slightly slower |

The sublinear growth is the point: a lone guard is genuinely threatening, while a crowd is
individually sluggish, so difficulty does not scale linearly with guard count.

### 4.16 Deployment Diagram

```mermaid
flowchart TB
    subgraph Host["«device» Player machine"]
        subgraph RT["«execution environment» TIC-80 runtime"]
            subgraph Cart["«artifact» runner.tic"]
                Chunk["«artifact» runner.lua (code chunk)"]
                Sprites["«artifact» sprite sheet"]
            end
            Lua["«execution environment» Lua 5.3 VM"]
        end
    end

    subgraph Web["«device» Browser (optional)"]
        subgraph WASM["«execution environment» tic80.js"]
            CartW["«artifact» runner.html/cart.tic"]
        end
    end

    Chunk --> Lua
    Cart --> RT
    CartW --> WASM
    Lua -. "60 Hz TIC() callback drives<br/>schedule_guards + update_guard" .-> Chunk
```

The guard AI has no distribution concerns — it is included here for completeness. The only
deployment-relevant property is that the entire AI must fit the single-chunk cart constraint
(NFR-8.1/NFR-8.5), which rules out external pathfinding libraries.

### 4.17 Profile Diagram

Stereotypes used across the diagrams in this section.

```mermaid
classDiagram
    class Metaclass_Function {
        <<metaclass>>
        UML::Operation
    }
    class pure {
        <<stereotype>>
        reads grid, no mutation
    }
    class tickGated {
        <<stereotype>>
        no-op unless e.ready
    }
    class scheduler {
        <<stereotype>>
        allocates step budget
    }

    Metaclass_Function <|.. pure : extends
    Metaclass_Function <|.. tickGated : extends
    Metaclass_Function <|.. scheduler : extends

    note for pure "applies to: scan_floor, scan_down, scan_up,\nscan_rate, is_guard_pit, can_walk_at, can_branch, guard_ai"
    note for tickGated "applies to: try_move_horizontal,\ntry_vertical_move, apply_gravity"
    note for scheduler "applies to: schedule_guards"
```

The `pure` stereotype is a real invariant worth preserving: **no AI function mutates the
level or any entity**. All mutation happens in the physics layer. This is what makes the AI
safe to call repeatedly, and what would make it testable in isolation.

### 4.18 The Rating Function

`scan_rate` is the heart of the algorithm. It converts a probe's landing row into a cost,
using banded constants that encode a lexicographic preference rather than a distance metric.

```lua
if y == runner_ty then return math.abs(start_x - x) end   -- band 0
if y  > runner_ty then return y - runner_ty + 200 end      -- band 200
return runner_ty - y + 100                                 -- band 100
```

| Band | Meaning | Range | Interpretation |
|------|---------|-------|----------------|
| `0 + abs(start_x - x)` | probe lands on the runner's row | 0 … ~level width | best; ties broken by nearest column |
| `100 + (runner_ty - y)` | probe ends **above** the runner | 101 … ~100+height | acceptable; guards prefer height |
| `200 + (y - runner_ty)` | probe ends **below** the runner | 201 … ~200+height | worst; hard to recover from |

Because the bands are wider than any achievable in-band value on these level sizes, the
comparison is effectively: *reach the runner's row first; failing that, end up above them;
only then minimise distance*. `best_rating` starts at 255, so a probe landing more than 55
rows below the runner would be rejected outright — unreachable on a 16-row level, which is
why 255 works as a sentinel.

Ties resolve to whichever probe ran first, because the comparison is `<` and not `<=`. Probe
order is: centre column, then left end sweeping right, then right end sweeping left.

### 4.19 Worked Example — Level 3, Third Guard

Initial state: guard 3 spawns at pixel `(120, 72)` → tile `(16, 10)`. The runner spawns at
pixel `(112, 112)` → tile `(15, 15)`. Different rows, so layer 2 is skipped and `scan_floor`
runs.

**Segment bounds on row 10.** Row 11 beneath it is `#########H##########H` — solid almost
everywhere, so the guard can walk freely. The left walk runs to `left_end = 1`; the right
walk stops at `right_end = 22`, one tile past column 21, because column 22 has nothing
underneath it.

**Probes and ratings:**

| Column | Probe | Landing row | Rating | Note |
|--------|-------|-------------|--------|------|
| 16 (centre) | — | — | — | row 11 below is solid, no ladder here: no probe |
| 3 | `scan_up` | 7 | `100 + (15-7) = 108` | ladder up to row 7, wrong direction |
| **10** | **`scan_down`** | **15** | **`abs(16-10) = 6`** | **ladder down to row 13, then falls to row 15** |
| 21 | `scan_down` | 13 | `100 + (15-13) = 102` | ladder ends on row 13, above the runner |
| 21 | `scan_up` | 7 | `108` | wrong direction |
| 22 | `scan_down` | 13 | `102` | open drop, lands above the runner |

Column 10 is the only probe that reaches the runner's row, so it wins with rating 6 and
`best_path = "left"` (column 10 lies left of the guard's column 16).

**Behaviour:** the guard walks *left*, away from nothing in particular but towards the ladder
at column 10 — the ladder descends rows 11–13, after which the guard falls to row 15 and lands
on the runner's floor. The old greedy AI would have set `down` (runner is below) and `left`
(runner is left), then been pinned to whatever ladder column it first touched.

### 4.20 Known Characteristics

These are consequences of the design, documented so they are not mistaken for defects:

- **Single-segment horizon.** A guard only considers ladders and drops reachable on its
  current floor segment. Multi-hop routes emerge frame by frame as the guard arrives on each
  new floor, not from any plan.
- **No tie-breaking jitter guard.** Two equally-rated probes on opposite sides resolve by
  probe order, which is stable — but a guard oscillating between floors can flip its answer as
  `start_x` changes. Worth watching in play-testing.
- **Runner-falling exception.** Layer 2 is skipped while `runner.falling`, matching the
  reference implementation; without it a guard on a ladder would commit to a horizontal dash
  at a runner who is about to leave the row.
- **Hidden ladders are invisible to the AI.** All predicates go through
  `is_visible_ladder_char`, so an unrevealed `h` tile is treated as empty space. Revealing the
  escape ladders therefore changes guard routing, not just the runner's options.
- **Pit awareness is policy-controlled.** `is_guard_pit` combines the live `holes` registry
    with `guards_pit_aware`. When awareness is enabled, `can_walk_at`, `can_branch`, and
    `scan_down` exclude live pits from route planning. When it is disabled, `can_walk_at` also
    treats the walk tile directly above a live pit as traversable, so direct pursuit continues
    and physics can drop the guard into the pit.
- **Dug holes are read from live state.** `try_dig` writes a blank into `level` and records the
    hole in `holes`; the AI uses both representations. `check_trap` remains authoritative for
    the outcome, so disabling awareness makes a guard more likely to be trapped rather than
    making the pit harmless.

## 5. Frame Sequence (One `TIC()` Tick)

```mermaid
sequenceDiagram
    participant TIC80 as TIC-80 Engine
    participant Loop as TIC()
    participant Runner
    participant Holes
    participant Guards
    participant Collision
    participant Render

    TIC80->>Loop: call TIC() (~60x/sec)
    alt level_complete and not final_level_complete
        Loop->>Loop: increment level_complete_timer
        alt timer reaches 360 ticks and another level exists
            Loop->>Loop: load_level(current_level + 1)
        else timer reaches 360 ticks on final level
            Loop->>Loop: final_level_complete = true
        end
    else not game_over and not level_complete
        Loop->>Runner: try_move_horizontal / try_vertical_move / apply_gravity
        Loop->>Runner: box pickup check
        Loop->>Runner: try_dig() on btnp(4)/btnp(5)
        Loop->>Holes: update_holes() (tick down, refill, respawn trapped guard)
        Loop->>Guards: schedule_guards() (clear ready flags, grant shared step budget)
        loop each guard
            Loop->>Guards: update_guard() (AI -> ready-gated physics -> check_trap)
        end
        Loop->>Collision: check_guard_collision() -> lose_life() if caught
        Loop->>Collision: check_offscreen_falls() -> runner loses life or guard respawns
        Loop->>Loop: evaluate level_complete
    end
    Loop->>Render: draw level tiles
    Loop->>Render: draw guards (state-based sprite)
    Loop->>Render: draw runner (animation state)
    Loop->>Render: draw HUD (boxes/lives or game-over/level-complete)
    Loop->>Render: draw level progress and transition countdown
    Render-->>TIC80: frame buffer
```

## 6. Level Completion & Progression

```mermaid
flowchart TD
    A["All boxes collected and runner reaches top row"] --> B["level_complete = true\nfreeze gameplay"]
    B --> C["Show LEVEL COMPLETE!\nand six-second countdown"]
    C --> D{"360 ticks elapsed?"}
    D -- no --> C
    D -- yes, another level --> E["load_level(current_level + 1)"]
    E --> F["Reset level-local state:\nrows, spawns, boxes, ladders, holes"]
    F --> G["Resume gameplay"]
    D -- yes, final level --> H["final_level_complete = true"]
    H --> I["Show ALL LEVELS SOLVED!\nkeep gameplay paused"]
```

## 7. Off-Screen Fall Recovery

```mermaid
flowchart LR
    A["Entity physics updates"] --> B{"Entity y > 136?"}
    B -- no --> C["Continue normal gameplay"]
    B -- yes, runner --> D["lose_life()\nrunner respawns\nall guards reset"]
    B -- yes, guard --> E["respawn_guard(g)\nguard returns to own spawn"]
```

## 8. Digging Flow

```mermaid
flowchart TD
    A["Player presses dig key\n(Z/Y key or gamepad btn 4 = left,\nbtn 5 = right)"] --> B{"Target tile\n(one row below player,\nadjacent column) is brick '#'?"}
    B -- no --> Z1["No-op"]
    B -- yes --> C{"Tile directly above\nthe target is solid\n('#' or '=')?"}
    C -- "yes, and it is NOT\nan already-open pit" --> Z2["Blocked: would dig\na pit nothing can\never fall into"]
    C -- "no (open air, ladder, bar,\nor already an open pit)" --> D{"A hole already\ntracked at that tile?"}
    D -- yes --> Z3["No-op (one hole per tile)"]
    D -- no --> E["Tile cleared to ' '\nhole recorded: {tx,ty,timer=HOLE_LIFETIME,orig='#'}"]
```

## 9. Hole Lifecycle: Guard Trap vs. Runner Buried (Timing)

Tick numbers use the current tuning constants (`GUARD_TRAP_ESCAPE=150`,
`HOLE_LIFETIME=360`, `GUARD_STEP_TICKS=6` → escape grace `= GUARD_STEP_TICKS*4 = 24`).
Both branches start at the moment the hole is dug (tick 0).

```mermaid
sequenceDiagram
    participant Hole
    participant Guard
    participant Runner

    Note over Hole: tick 0 - hole dug, timer=360

    alt Guard falls into the hole (check_trap)
        Hole->>Guard: traps it, trapped_timer=150
        Note over Guard: tick 0..150 - immobile,\nsupports the runner if stepped on
        alt Escape before refill (150 < remaining hole life)
            Guard->>Guard: tick 150 - trapped_timer expires\ny -= 8, state=running, grace=24
            Note over Guard: tick 150..174 - grace window,\ngravity support-check skipped
            Guard->>Guard: tick 174 - grace ends, resumes\nnormal chase (already walked clear)
        else Hole refills first (guard fell in late)
            Hole->>Hole: tick 360 - timer expires\nwhile hole.guard is still set
            Hole->>Guard: respawn_guard() - back to\nspawn_x/spawn_y, state=running
        end
    else Runner is standing in the hole's tile when it refills
        Runner->>Hole: still overlapping (tx,ty) at tick 360
        Hole->>Runner: lose_life() - close_all_holes() first
        Hole->>Hole: restore every active pit to orig ('#')\nand clear holes registry
        Hole->>Runner: runner respawns, ALL guards reset\nto their configured spawns
        Note over Hole: update_holes() returns immediately\nso no stale pit entry is processed
        Note over Runner,Guard: matches original arcade behavior:\ndeath resets every actor's position
    end
    Hole->>Hole: tile restored to orig ('#')
```

## 10. Module Responsibilities (Reference Table)

| Section in `runner.lua`            | Responsibility                                                        | Related Requirements |
|-------------------------------------|-------------------------------------------------------------------------|-----------------------|
| Level data/loading (`level_data`, `load_level`) | Multi-level records, active-level binding, level-local reset | FR-2.12, FR-2.13, FR-9.1, FR-9.2 |
| Level helpers (`tile_xy`, `set_tile_xy`, `tile_char_at_pixel`, `count_boxes`) | Grid storage & mutation, pixel-to-tile resolution | FR-1.x |
| `get_context`, `is_solid`, `is_visible_ladder_char` | Tile classification shared by all physics code | FR-1.x, NFR-1.1 |
| `try_move_horizontal`, `try_vertical_move`, `apply_gravity` (incl. `e.grace` immunity window) | Shared movement/gravity/climbing primitives for any entity | FR-2.x, FR-4.4a, NFR-2.2 |
| `try_dig` (incl. above-tile solid check), `update_holes`, `close_all_holes` | Hole creation, above-tile validation, lifetime management, buried-runner death, and pit cleanup before respawn | FR-3.x, FR-5.2a |
| `guard_ai`, `scan_floor`, `scan_down`, `scan_up`, `scan_rate`, `is_guard_pit`, `can_walk_at`, `can_branch` | Classic runner or chasing game pursuit: same-floor dash, floor-segment scan, banded rating, and configurable live-pit awareness (see section 4) | FR-4.x |
| `schedule_guards`, `MOVE_POLICY` | Shared guard step budget; sublinear difficulty scaling with guard count | FR-4.x, NFR-2.2 |
| `update_guard`, `check_trap`, `respawn_guard`, `guard_support_at` | Guard lifecycle: action dispatch, trapping, escape (with grace)/respawn, safe-support behavior | FR-4.x |
| `overlaps`, `check_guard_collision`, `check_offscreen_falls`, `lose_life` (resets runner AND all guards) | Player/guard collision resolution, off-screen recovery, lives & game-over | FR-5.x |
| `TIC()` completion branch | Six-second level transition and final-level celebration | FR-2.12, FR-2.13, FR-6.6 |
| `TIC()` draw section (per-state guard/runner sprite selection) | Tile/entity/HUD rendering, level progress, boxes, lives, countdown | FR-6.x, FR-4.8 |
| `TIC()` input reads (`btn`, `btnp`, `keyp`) | Player input polling, dual-layout dig key | FR-7.x |

## 11. Design Rationale & Trade-offs

- **Single-file, sectioned layout** rather than multiple Lua modules: TIC-80 carts are most
  portable as one file; sections are kept cohesive by naming convention and ordering
  (level → physics → digging → guards → collision → loop) instead of a module system.
- **Tables over classes**: Lua's lightweight tables are sufficient for the current entity
  count (1 runner + up to 3 guards); introducing metatables/OOP would add indirection without
  benefit at this scale (kept in mind for FR-9.x if entity variety grows).
- **Tick-gated movement via a `ready` flag**: the runner sets `ready` from `STEP_TICKS`, while
  guards receive it from `schedule_guards`. Routing both through the same flag keeps the shared
  physics ignorant of *why* an entity may move this frame, so the scheduler could be changed or
  removed without touching movement code.
- **Ported guard AI rather than a pathfinder**: `scan_floor` reproduces the original's
  floor-segment scan and its `0 / +100 / +200` rating bands verbatim. A BFS or A\* chase would be
  strictly "better" at catching the runner and strictly worse as a game — the exploitable,
    single-segment horizon is the mechanic (see section 4.20). Pit awareness is layered on top
    of that scan so the same AI can intentionally choose between cautious and trap-prone play.
- **Flush-snapping on tile transitions**: climbing/landing snaps position to the tile grid
  to avoid sub-pixel overlap bugs (see project history: ladder/bar alignment fixes) — this is
  now centralized in `try_vertical_move`/`apply_gravity` instead of duplicated per entity.
- **Grace-period after escaping a hole**: standing on the tile above a still-open hole is, by
  the same physics that trapped the guard in the first place, unsupported - naively climbing
  out would cause an immediate fall back in and permanent re-trapping. `e.grace` suppresses
  the support check for a few ticks (long enough to fully clear the hole's column) instead of
  special-casing hole tiles as "supported", which would otherwise break the original trap
  mechanic entirely.
- **Full actor reset on death**: `lose_life()` resets every guard to its spawn point, not just
  the runner, matching the original arcade behavior and avoiding the runner respawning right
  next to (or on top of) the guard that just caught it.
- **Pit cleanup precedes actor reset**: `close_all_holes()` restores every active pit and clears
    the hole registry before runner and guard positions are reset. The buried-runner branch then
    returns from `update_holes()` immediately, preventing the old hole table from being processed
    after life-loss state has already been reset.
- **Above-tile dig check uses the live grid, not the static level data**: checking
  `tile_xy` (which digging/refill already mutate in place) means an already-open pit above the
  target naturally reads as non-solid, with no separate bookkeeping needed for that exception.
