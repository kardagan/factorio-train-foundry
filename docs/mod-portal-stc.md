<!--
  Description prête à coller dans le champ "Description" du mod portal Factorio
  pour train-foundry-stc. Même repo GitHub que la variante BP (factorio-train-foundry) :
  les images docs/stc-*.png sont donc au même endroit, URLs ABSOLUES
  raw.githubusercontent.com sur la branche `main`. À créer via screenshots, puis
  pousser. À la prochaine release, mets ce fichier à jour et recolle-le.
-->

## Train Foundry for Smart Train Combinator

**The train factory for your Smart Train Combinator network.** If you drive your
trains with [Smart Train Combinator](https://mods.factorio.com/mod/smart-train-combinator),
this foundry closes the loop: it reads the train shapes your combinators already
define, builds those exact trains for you, and sends them out **pre-wired to your
STC stops** — no blueprint, and no hand-editing a single schedule.

> **Requires [Smart Train Combinator](https://mods.factorio.com/mod/smart-train-combinator).**
> Prefer defining trains with a blueprint? Get the companion mod
> **[Train Foundry](https://mods.factorio.com/mod/train-foundry)** instead — you can run both,
> one building of each per surface.

![The foundry](https://raw.githubusercontent.com/kardagan/factorio-train-foundry/main/docs/stc-building.png)

### Built around Smart Train Combinator

Smart Train Combinator already knows everything about your trains: which shapes
run on your network (solid/fluid, wagon type and count, storage or not) and how
their stops are named. This foundry taps straight into that:

- **Your combinators are the catalogue.** The window doesn't ask you to draw a
  train — it lists the exact shapes your STC combinators describe on the surface.
  Add or change a combinator, and the list follows.
- **The trains slot right into your STC setup.** Every train leaves with the
  loading/refuel/stop/unload schedule and a train group built to **Smart Train
  Combinator's own station-naming convention** — so its interrupts match your STC
  stops immediately, exactly as if you'd wired the train by hand.
- **You only choose the cargo.** Pick a shape, pick what it carries — that's it.
  The foundry handles composition, fuel, schedule, group and dispatch.

So instead of blueprinting a train, tuning its schedule, and hoping the stop
names line up, you press two buttons and a matching train rolls onto your STC
network.

### How it works

- **Place it anywhere buildable.** While you hold the item (or a ghost for robots),
  a full preview of the building follows the cursor — in the game view and on the
  map — so you see exactly where the tracks and walls will land. The foundry lays
  its own exit track; just connect your network to the exit afterwards. It can even
  be placed on water: the footprint is filled with landfill automatically.
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

### Or draw the train yourself

The shapes read from your combinators come with a fixed composition: one head
locomotive plus its wagons. When that isn't the train you want, switch the list to
**Custom** and draw it.

**+ New custom template** opens a composer that lays the train out as a row of
slots, the way a chest lays out its inventory. The first slot is a train stop: it
marks the **head** of the train, the direction it leaves in. Every slot after it
takes a locomotive, a cargo wagon or a fluid wagon — click it to pick from a
filtered list, or click it with the item in hand. The free slot at the end
lengthens the train, up to the capacity of the foundry chain; emptying a slot
shortens it.

The button above a locomotive **turns it around**. That is what double-heading and
a tail locomotive facing the other way are made of — a train that pulls in both
directions, which the default shapes could never describe.

The important part: **a custom train serves exactly the same stops.** Locomotives
appear in no station name, so a double-header with four wagons produces the very
same loading station, train group and interrupts as the default four-wagon shape.
The composer shows the generated station name as you build, to compare it with
your existing STC stops at a glance.

Two rules keep that promise: every wagon must be the same type, and the same
quality — a station name carries a single wagon icon and a single quality, so a
mixed train could never match a stop. Locomotives are free: type, tier and quality
as you like.

![The composer](https://raw.githubusercontent.com/kardagan/factorio-train-foundry/main/docs/stc-composer.png)

### Fuel, handled for you

You never have to pick a fuel per train. The foundry fills every locomotive with
the **best unlocked fuel** available in its stock, and only starts a build once one
compatible fuel is present in a full load. The generated **refuel interrupt** covers
every fuel the locomotive can burn (it tops up at 10% and leaves once full). A solar
locomotive needs no fuel and gets no refuel interrupt. The window shows a fuel row,
and the circuit's missing-components output asks for every candidate fuel so at
least one is delivered by your logistics.

You do decide what "best" may pick from. The gear button next to **Accepted fuels**
opens a window listing every unlocked fuel a locomotive can burn, with one checkbox
per quality — click a fuel's icon to toggle its whole row, or a quality header to
toggle its whole column. Only ticked fuels are burned and requested, and among them
the foundry takes the highest fuel value first, then the highest quality: tick solid
fuel in legendary, rare and normal and it burns legendary while you have some, rare
otherwise, normal as a last resort. Handy for keeping pentapod eggs and Gleba
produce out of your locomotives, or for reserving rocket fuel for something else.
Left untouched, every fuel is accepted in normal quality.

![The Accepted fuels window](https://raw.githubusercontent.com/kardagan/factorio-train-foundry/main/docs/accepted-fuels.png)

### Left or right exit, longer trains, and more

- **Exit sides.** Trains leave to the left (west) by default; enable a right
  (east) exit in the **Configuration** window. The train takes whichever open
  side its schedule leads to.
- **Longer trains.** Chain extensions against the east side — each module adds
  room for five more vehicles.

![The Configuration window](https://raw.githubusercontent.com/kardagan/factorio-train-foundry/main/docs/stc-configuration.png)

![Chained foundries for longer trains](https://raw.githubusercontent.com/kardagan/factorio-train-foundry/main/docs/stc-extensions.png)

- **Recycling track.** Tick it in the Configuration window to add a second,
  dead-end track with a **Train Recycle** stop: route a train onto it and the
  foundry destroys it and refunds its full cost (vehicles, fuel and cargo) into
  the stock. A one-way block signal keeps it from backing out.
- **Circuit network.** The connector is an electric pole — wire it for power, for
  circuit, or both. The stock contents and the components (and fuels) still needed
  are two independent outputs: enable either or both and pick the wire (red, green,
  or both) each one goes out on, so you can read what you have and what you need at
  the same time.
- **Clear a stuck train.** If a built train cannot leave, one click destroys it
  and refunds its cost.
- **Remote control.** A shortcut-bar button (or CTRL+ALT+F) opens the foundry
  from anywhere. One foundry (chain) per planet.
- **Compatible** with vanilla, Space Age and Nullius.

### Credits

The reserve-chest sprite is the "tall steel chest" graphic from the **Wide
Containers Assets** mod by **Lebothegizebo**, used under the MIT License. Thanks!
