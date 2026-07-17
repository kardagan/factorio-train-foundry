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
- **Import blueprints.** Open the foundry and drop a train blueprint into its
  library (from your inventory or the blueprint library). Blueprints must contain
  only the train (rails and signals under it are fine).
- **Queue trains.** Click a template to queue it; blueprint parameters are asked
  once. Trains are built one after another.
- **Feed the parts.** Each build pulls its locomotives, wagons and fuel from the
  foundry's internal chest — fill it by hand or with inserters. Missing parts are
  shown in red, available ones in green.
- **Off it goes.** Once built and the track is clear, the train drives away with
  its schedule, group and fuel already set.

![The interface](https://raw.githubusercontent.com/kardagan/factorio-train-foundry/main/docs/interface.png)

### Extras

- **Circuit network.** Wire the foundry's connector to broadcast either the
  internal stock contents or the components it still needs.
- **Remote control.** A shortcut-bar button (or CTRL+ALT+F) opens the foundry's
  window from anywhere — no need to walk to it. One foundry per planet.
- **Compatible** with vanilla, Space Age and Nullius.
