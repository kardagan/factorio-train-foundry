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
4. **Feed the parts** into the internal stock — by hand or with inserters anywhere along the edge.
5. The train is **assembled and dispatched** with a matching schedule — a loading stop plus
   refuel / stop / unload interrupts — and a train group encoding the shape. The station names match
   the combinator's own naming convention, so the interrupts line up with your STC stops.

## Features

- **Shapes from Smart Train Combinator** (`get_models`): solid and fluid trains, any wagon count,
  and the storage variant. Group and interrupt names carry the foundry icon and are colour-coded
  (white refuel, orange stop, red unload).
- **Generic fuelling**: fills every locomotive with the best unlocked compatible fuel available in
  the stock; production waits until one such fuel is present in a full load. The refuel interrupt
  covers every fuel the locomotive can burn (trigger at 10% of full, refill to full). A solar
  locomotive needs no fuel and gets no refuel interrupt. The window shows a fuel row; the circuit
  "read requests" mode requests every candidate fuel so at least one is delivered.
- **Exit sides** (left/right), **chainable extensions** for longer trains, **circuit connector**,
  **clear stuck train** button, and Factoriopedia on component/fuel slots.
- **Remote control**: a shortcut-bar button (and Ctrl+Alt+F) opens the foundry from anywhere.
- One foundry per planet. Vanilla, Space Age and Nullius compatible.

## Credits

The reserve-chest sprite is the "tall steel chest" graphic from the **Wide Containers
Assets** mod by **Lebothegizebo**, used under the MIT License. Thanks!
