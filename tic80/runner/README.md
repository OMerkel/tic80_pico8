# TIC-80 Runner

A small Runner-style platform game for TIC-80, written in Lua.

The game includes tile-based platforming, ladders, horizontal bars, collectible
boxes, digging, temporary pits, guard chasing, guard traps, multiple levels,
level progression, lives, and final-level celebration.

## Files

- `runner.lua` - editable game source code.
- `runner.tic` - playable TIC-80 cartridge containing the current code and sprite data.
- `requirements.md` - functional and non-functional requirements.
- `software_architecture.md` - architecture notes and Mermaid diagrams.

## Run the Game

From this directory, open the binary cartridge with TIC-80:

```powershell
.\tic80.exe runner.tic
```

You can also open the cartridge from the TIC-80 interface using its file browser.

## Controls

| Action | Keyboard / Controller |
| --- | --- |
| Move left/right | Arrow keys / TIC-80 directions |
| Climb up/down | Up and Down keys |
| Dig left | Z or Y, depending on keyboard layout; controller button 4 |
| Dig right | X; controller button 5 |

The left-dig binding accepts both physical Y and Z key positions so it works on
QWERTY and QWERTZ keyboard layouts.

## Gameplay

- Collect every box to reveal the hidden ladder tops.
- Reach the top after collecting all boxes to complete the current level.
- A completed level pauses for a few seconds before the next level loads.
- Completing the final level displays the final celebration state.
- Guards chase the runner using the same movement and gravity rules as the player.
- Dig only into brick tiles. Floor tiles cannot be dug.
- Digging is blocked when a solid brick or floor tile sits directly above the target brick.
- Open pits refill after a timer expires.
- A guard trapped in a pit can crawl out after its escape timer, or respawns if the pit closes first.
- A trapped guard supports the runner and cannot catch the runner while trapped.
- If the runner touches an active guard, is buried when a pit closes, or falls below the screen, a life is lost.
- Losing a life first closes and restores every still-existing pit, then respawns the runner and resets all guards to their spawn positions.
- Pit processing stops immediately after a buried-runner life loss, preventing stale pit state from being processed after the reset.
- A guard falling below the screen respawns that guard without costing a life.

## Updating the Playable Cartridge

The repository uses the Lua file as the editable source and the TIC cartridge as
the playable artifact. The installed TIC-80 executable is a non-Pro build and
cannot load a plain Lua cart directly, so code changes should be imported into
the binary cartridge:

```powershell
.\tic80.exe --skip --cli --fs . --cmd "load runner.tic & import code runner.lua & save & exit"
```

This preserves the sprite and cartridge data already stored in `runner.tic` while
updating its embedded code from `runner.lua`.

## Development Notes

Movement uses an 8x8 tile grid and deterministic tick-based physics. The runner
moves faster than guards by default. The main game loop is the TIC-80 `TIC()`
callback, and the implementation uses standard TIC-80 APIs such as `btn`, `btnp`,
`keyp`, `spr`, `print`, and `cls`.

For detailed behavior and design decisions, see [requirements.md](requirements.md)
and [software_architecture.md](software_architecture.md).
