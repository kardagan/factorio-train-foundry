# Train Foundry for Smart Train Combinator

A big building (40×22) that assembles **complete trains from Smart Train Combinator models** and
sends them off onto your rail network on their own — no blueprint needed.

> **Requires [Smart Train Combinator](https://mods.factorio.com/mod/smart-train-combinator).**
> Prefer defining trains with a blueprint instead? See the companion mod **Train Foundry**. Both can
> be installed together (one building of each per surface).

## How it works

1. **Place** the foundry on your map. It lays its own exit track — just connect your network to it.
2. Open the window: the book lists the **distinct train shapes** your Smart Train Combinator
   combinators describe on this surface — kind (solid/fluid), wagon type, wagon count, storage
   variant. (No blueprint chest here.)
3. **Click a shape**, then **choose its resource** (the picker is restricted to items or fluids to
   match the shape).
4. Or switch the list to **Custom** and draw the train yourself — see below.
5. **Feed the parts** into the internal stock — by hand or with inserters anywhere along the edge.
6. The train is **assembled and dispatched** with a matching schedule — a loading stop plus
   refuel / stop / unload interrupts — and a train group encoding the shape. The station names match
   the combinator's own naming convention, so the interrupts line up with your STC stops.

## Custom compositions

The shapes read from the combinators have a fixed composition: one head locomotive plus its
wagons. The **Custom** tab holds compositions you draw yourself, in a composer that lays the
train out as a row of slots like a chest lays out its inventory. The first slot is a train stop
marking the **head** of the train — the direction it leaves in; every slot after it takes a
locomotive, a cargo wagon or a fluid wagon (click it, or click it with the item in hand). The
button above a locomotive **turns it around**, which is what double-heading and a tail
locomotive facing the other way are made of.

A custom train serves **the same stops**: locomotives appear in no station name, so a
double-header with four wagons produces the same loading station, group and interrupts as the
default four-wagon shape. Hence the two rules — one wagon type, one wagon quality per
composition (a station name carries a single wagon icon and a single quality). Locomotives are
free.

## Features

- **Shapes from Smart Train Combinator** (`get_models`): solid and fluid trains, any wagon count,
  and the storage variant. Group and interrupt names carry the foundry icon and are colour-coded
  (white refuel, orange stop, red unload).
- **Generic fuelling**: fills every locomotive with the best unlocked compatible fuel available in
  the stock; production waits until one such fuel is present in a full load. The refuel interrupt
  covers every fuel the locomotive can burn (trigger at 10% of full, refill to full). A solar
  locomotive needs no fuel and gets no refuel interrupt. The window shows a fuel row; the circuit's
  missing-components output requests every candidate fuel so at least one is delivered.
- **Accepted fuels**: a window (gear button in Configuration) with one checkbox per fuel and quality
  decides what the foundry may burn — click a fuel icon to toggle its row, a quality header for its
  column. Among the ticked ones it takes the highest fuel value, then the highest quality.
- **Circuit connector**: an electric pole (power and/or circuit). Stock contents and missing
  components are two independent outputs, each with its own wire choice (red, green, or both).
- **Exit sides** (left/right), **chainable extensions** for longer trains, **clear stuck train**
  button, and Factoriopedia on component/fuel slots.
- **Remote control**: a shortcut-bar button (and Ctrl+Alt+F) opens the foundry from anywhere.
- One foundry per planet. Vanilla, Space Age and Nullius compatible.

## Credits

The reserve-chest sprite is the "tall steel chest" graphic from the **Wide Containers
Assets** mod by **Lebothegizebo**, used under the MIT License. Thanks!
