# Train Foundry

A big building (40×22) that assembles **complete trains from a blueprint** and sends them off onto
your rail network on their own — locomotives, wagons, colours, fuel, schedule, train group and
blueprint parameters included.

> Looking for the Smart Train Combinator version (build trains from STC models, no blueprint)? See
> the companion mod **Train Foundry for Smart Train Combinator**. Both can be installed together.

## How it works

1. **Place** the foundry on your map. It lays its own exit track — just connect your network to it.
2. **Drop a train blueprint** into the blue blueprint chest on the west apron. The book in the
   foundry window mirrors the chest; each plan shows its locomotive/wagon counts. A plan that isn't a
   pure train, is too long, or isn't on a straight track is flagged in red with the reason.
3. **Click a plan** to queue it (blueprint parameters are asked for at that point).
4. **Feed the parts** into the internal stock — by hand or with inserters anywhere along the edge.
   The window shows, per component, the available/required ratio.
5. The train is **assembled and dispatched** automatically: composition, colours, fuel, schedule,
   train group and parameters all reproduced from the blueprint.

## Features

- **Queue + production loop**: plans wait for parts and a clear track, build, then the finished
  train leaves on its own.
- **Fuel**: by default the train uses the fuel from the blueprint. A **Generic fuel** option (in the
  Configuration window) instead fills every locomotive with the best unlocked compatible fuel
  available in the stock and adds a refuel interrupt. A blueprint with no fuel always uses this.
  An **Accepted fuels** window (gear button in Configuration) decides what "best" may pick from, with
  one checkbox per fuel and quality.
- **Exit sides**: left (west) by default; a right (east) exit can be enabled in the window. The train
  picks the side its schedule reaches.
- **Longer trains**: chain extensions against the east side — each adds room for 5 more vehicles.
- **Circuit connector**: an electric pole (power and/or circuit). Stock contents and missing
  components are two independent outputs, each with its own wire choice (red, green, or both).
- **Clear stuck train**: one click destroys and refunds a train that cannot leave.
- **Remote control**: a shortcut-bar button (and Ctrl+Alt+F) opens the foundry from anywhere.
- One foundry per planet. Vanilla, Space Age and Nullius compatible.

## Credits

The reserve-chest sprite is the "tall steel chest" graphic from the **Wide Containers
Assets** mod by **Lebothegizebo**, used under the MIT License. Thanks!
