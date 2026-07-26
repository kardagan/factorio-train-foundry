<!--
  Description prête à coller dans le champ "Description" du mod portal Factorio
  pour train-foundry-stc. Même repo GitHub que la variante BP (factorio-train-foundry) :
  les images docs/stc-*.png sont donc au même endroit, URLs ABSOLUES
  raw.githubusercontent.com sur la branche `main`. À créer via screenshots, puis
  pousser. À la prochaine release, mets ce fichier à jour et recolle-le.
-->

## Train Foundry for Smart Train Combinator

Build complete trains **from your Smart Train Combinator models** — no blueprint
needed. Pick a train shape, choose what it carries, and the foundry assembles the
whole train and sends it off onto your network, already matched to your STC stops.

> **Requires [Smart Train Combinator](https://mods.factorio.com/mod/smart-train-combinator).**
> Prefer defining trains with a blueprint? Get the companion mod
> **[Train Foundry](https://mods.factorio.com/mod/train-foundry)** instead — you can run both,
> one building of each per surface.

![The foundry](https://raw.githubusercontent.com/kardagan/factorio-train-foundry/main/docs/stc-building.png)

### How it works

- **Place it anywhere buildable.** The foundry lays its own exit track — no need
  to prepare a rail first. Just connect your network to the exit afterwards.
- **Pick a train shape.** The foundry's window lists the distinct shapes your
  Smart Train Combinator combinators describe on this surface: solid or fluid,
  wagon type, wagon count, and the storage variant. There is no blueprint chest —
  the shapes come straight from your combinators.
- **Choose the resource.** Click a shape, then pick what the train carries (the
  picker only offers items for a solid shape, fluids for a fluid shape).
- **Feed the parts.** Each build pulls its locomotives and wagons from the
  foundry's internal stock — fill it by hand or with inserters. Each component
  shows an available/required ratio, green when covered, red when short.
- **Off it goes.** The finished train leaves with a ready-made schedule — a
  loading stop plus refuel, stop and unload interrupts — and a train group that
  encodes its shape. The station names match Smart Train Combinator's own naming,
  so the interrupts line up with your STC stops out of the box.

![The interface](https://raw.githubusercontent.com/kardagan/factorio-train-foundry/main/docs/stc-interface.png)

### Fuel, handled for you

You don't pick a fuel. The foundry fills every locomotive with the **best unlocked
fuel** available in its stock, and only starts a build once one compatible fuel is
present in a full load. The generated **refuel interrupt** covers every fuel the
locomotive can burn (it tops up at 10% and leaves once full). A solar locomotive
needs no fuel and gets no refuel interrupt. The window shows a fuel row, and the
circuit "read requests" mode asks for every candidate fuel so at least one is
delivered by your logistics.

### Left or right exit, longer trains, and more

- **Exit sides.** Trains leave to the left (west) by default; enable a right
  (east) exit in the **Configuration** window. The train takes whichever open
  side its schedule leads to.
- **Longer trains.** Chain extensions against the east side — each module adds
  room for five more vehicles.
- **Circuit network.** Broadcast the stock contents or the components (and fuels)
  still needed.
- **Clear a stuck train.** If a built train cannot leave, one click destroys it
  and refunds its cost.
- **Remote control.** A shortcut-bar button (or CTRL+ALT+F) opens the foundry
  from anywhere. One foundry (chain) per planet.
- **Compatible** with vanilla, Space Age and Nullius.
