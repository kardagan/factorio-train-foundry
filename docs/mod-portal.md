<!--
  Description prête à coller dans le champ "Description" du mod portal Factorio.
  Différence avec le README : les images pointent sur des URLs ABSOLUES
  raw.githubusercontent.com (les chemins relatifs ne fonctionnent pas sur le
  portail). Les URLs supposent que les fichiers docs/*.png sont poussés sur la
  branche `main`. À la prochaine release, mets ce fichier à jour et recolle-le.
-->

## Train Foundry

Build complete trains from blueprint templates — no more placing locomotives and
wagons by hand.

A large foundry building sits on the end of one of your rail lines. Import a
train blueprint into it, queue it, and the foundry assembles the whole train and
sends it off onto your network on its own — with the right composition,
orientation, colors, fuel, schedule, train group and blueprint parameters.

![The foundry](https://raw.githubusercontent.com/kardagan/factorio-train-foundry/main/docs/building.png)

### How it works

- **Place it anywhere buildable.** The foundry lays its own exit track — no need
  to prepare a rail first. Just connect your network to the exit afterwards.
- **Drop blueprints in the chest.** A dedicated blue blueprint chest sits on the
  west apron — drop your train blueprints there (by hand or with inserters). The
  foundry's window lists them; click a plan to queue it. Blueprints must contain
  only the train (rails and signals under it are fine).
![The blueprint chest](https://raw.githubusercontent.com/kardagan/factorio-train-foundry/main/docs/bp-chest.png)

- **Queue trains.** Click a template to queue it; blueprint parameters are asked
  once. Trains are built one after another.
- **Feed the parts.** Each build pulls its locomotives, wagons, fuel, ammo and
  equipment-grid gear from the foundry's internal stock — fill it by hand or with
  inserters. Each component shows an available/required ratio, green when covered,
  red when short.
- **Off it goes.** Once built and the track is clear, the train drives away with
  its schedule, group, fuel and equipment already set.

![The interface](https://raw.githubusercontent.com/kardagan/factorio-train-foundry/main/docs/interface.png)

### Left or right exit

Trains leave to the **left (west)** by default. Open the foundry's window, click
the panel button in the title bar, and use the **Configuration** window to tick
**Left (west)** and/or **Right (east)** — either or both sides can be open at
once. The train takes whichever open side its schedule leads to. On a chained
foundry the east exit follows the far end of the chain automatically.

### Longer trains

Need trains longer than five vehicles? Place another Train Foundry right against
the east side of an existing one and it chains on as an **extension** — the
internal track and capacity extend across the whole hall. Each module adds room
for five more vehicles (5 alone, 10 with one extension, 15 with two, and so on).
Extensions have no chests or signal of their own: the whole chain is driven from
one window, and the stock stays on the west end while the exits work across the
whole hall.

![Chained foundries for longer trains](https://raw.githubusercontent.com/kardagan/factorio-train-foundry/main/docs/extensions.png)

### Extras

- **Circuit network.** Wire the foundry's connector and, in the Configuration
  window, choose to broadcast either the internal stock contents or the
  components it still needs.
- **Remote control.** A shortcut-bar button (or CTRL+ALT+F) opens the foundry's
  window from anywhere — no need to walk to it. One foundry (chain) per planet.
- **Compatible** with vanilla, Space Age and Nullius.
