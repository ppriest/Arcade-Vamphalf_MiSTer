# Vamphalf: hardware notes

What the board is, from MAME and any other source, each fact with where it came from. The
research phase writes this before the roadmap (the skill's SKILL.md, phase 1).

Source: MAME `src/mame/<maker>/<driver>.cpp` at `git -C $MAME_SRC log -1` commit, and
`mame -listxml` from MAME 0.NNN. Everything here is MAME's model unless marked otherwise.

## Sets

| Set | Game | Board variant | ROM loaded | MAME flags |
|---|---|---|---|---|

Region CRCs compared across sets: byte-identical copies are stored once.

## CPUs and chips

| Tag | Part | Clock | Role | Existing RTL |
|---|---|---|---|---|

## Clocks

Every board clock with its source line, and the pixel clock. The plan built on them is in the
roadmap's Clocks section (the skill's clocks.md).

## Video

Display from `-listxml` or `screen.set_raw()`: visible and total size, pixel clock, refresh.
Layers, sprite format, palette, mixing, flip, and what MAME says it does not emulate. Aspect is
4:3 unless the driver says otherwise.

## Memory map

Main CPU map, with the driver's line numbers; the sound CPU's if there is one.

## Feasibility

Only for a large board (the skill's SKILL.md, phase 1): each blocking unknown and the
measurement that would close it.
