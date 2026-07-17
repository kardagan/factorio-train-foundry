# Train Foundry

A Factorio 2.0 / 2.1 mod. Build complete trains from blueprint templates instead
of placing every locomotive and wagon by hand.

![The foundry](docs/building.png)

A large foundry building sits on the end of one of your rail lines. Import a
train blueprint, queue it, and the foundry assembles the whole train and sends it
off onto your network on its own — composition, orientation, colors, fuel,
schedule, train group and blueprint parameters included.

![The interface](docs/interface.png)

## How it works

- **Place it on a rail** — the exit gate goes on the end of an east-west rail
  line (one straight rail under the western apron).
- **Import blueprints** into the foundry's library (from your inventory or the
  blueprint library). The blueprint must contain only the train.
- **Queue trains** — click a template; blueprint parameters are asked once.
- **Feed the parts** — locomotives, wagons and fuel come from the foundry's
  internal chest; fill it by hand or with inserters.
- Built trains **drive off** with their schedule, group and fuel set.

## Extras

- **Circuit network** — wire the connector to broadcast the internal stock or the
  missing components.
- **Remote control** — a shortcut-bar button (or `CTRL+ALT+F`) opens the
  foundry's window from anywhere. One foundry per planet.
- Compatible with vanilla, Space Age and Nullius.

## Building from source

`./build.sh package` produces the Factorio 2.0 zip (`0.1.0`) and the 2.1 zip
(`0.2.0`) from the same source. `./build.sh link` symlinks the repo into
`~/.factorio/mods` for development.

## License

MIT — see [LICENSE](LICENSE).
