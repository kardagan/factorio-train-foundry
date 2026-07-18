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

- **Place it on a rail.** The foundry's exit gate goes on the end of an
  east-west rail line (one straight rail under the western apron). The rest of
  the building can sit anywhere buildable.
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

### Longer trains

Need trains longer than five vehicles? Place another Train Foundry right against
the east side of an existing one and it chains on as an **extension** — the
internal track and capacity extend across the whole hall. Each module adds room
for five more vehicles (5 alone, 10 with one extension, 15 with two, and so on).
Extensions have no chests or signal of their own: the whole chain is driven from
one window, and the stock and exit stay on the west end.

![Chained foundries for longer trains](https://raw.githubusercontent.com/kardagan/factorio-train-foundry/main/docs/extensions.png)

### Extras

- **Circuit network.** Wire the foundry's connector to broadcast either the
  internal stock contents or the components it still needs.
- **Remote control.** A shortcut-bar button (or CTRL+ALT+F) opens the foundry's
  window from anywhere — no need to walk to it. One foundry (chain) per planet.
- **Compatible** with vanilla, Space Age and Nullius.
