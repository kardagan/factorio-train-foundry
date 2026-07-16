# Mod Factorio : Train Factory

## Objectif

Mod Factorio 2.0 (compatible Space Age). Un bâtiment long (~36×10 tuiles, capacité 5 locomotives/wagons) qui construit des trains complets à partir de templates blueprint, avec file d'attente, approvisionnement logistique automatique et sortie autonome des trains sur le réseau.

## Fonctionnement cible (gameplay)

1. Le joueur pose le bâtiment ; le rail interne doit être raccordable au réseau (snap sur rail existant ou rail posé par le bâtiment, sortie à une extrémité).
2. Le joueur importe un ou plusieurs blueprints de trains dans la GUI du bâtiment → ils deviennent des "templates" persistants (le BP peut être rendu/jeté ensuite).
3. Le joueur sélectionne un template, ajuste les paramètres (nom/schedule, couleur, fuel, quantité), et l'ajoute à la file d'attente.
4. Le bâtiment requeste les composants (locos, wagons, fuel) comme un coffre requester ; les bots livrent.
5. Quand tout est disponible ET que le bloc de sortie est libre (rail signal vert), le train est spawné sur le rail interne, fuel inséré, filtres/couleur/schedule appliqués, puis `manual_mode = false` → il part vers sa première gare. Le suivant de la file démarre.

## Architecture technique

### Entité composite
- Entité principale visible (le hangar) : prototype type `simple-entity-with-owner` ou `assembling-machine` sans recette, collision box ~36×10.
- Au placement (`on_built_entity` / `script_raised_built`), spawner via script :
  - segment de rails droits cachés sous le bâtiment (`straight-rail`), raccordés à la sortie
  - 1+ `logistic-container` (mode requester) invisibles pour les inputs
  - 1 `rail-signal` à la sortie (contrôle du bloc + rend le segment unidirectionnel sortant)
  - optionnel : un connecteur circuit (constant combinator caché) exposant l'état (file, occupé…)
- Gérer les 4 rotations du bâtiment : toutes les positions relatives (rails, coffres, signal, positions de spawn des wagons) calculées depuis direction + position de l'entité principale.
- À la destruction/minage : détruire toutes les entités cachées, rembourser les items en attente dans les coffres, annuler la file.

### Parsing des blueprints
- La GUI accepte un blueprint item ; lire `LuaItemStack.get_blueprint_entities()`.
- Filtrer `locomotive`, `cargo-wagon`, `fluid-wagon`, `artillery-wagon` ; reconstituer l'ordre et l'orientation des wagons le long du rail.
- Extraire et stocker par template : composition ordonnée, orientation de chaque loco, filtres/limite des wagons, couleur, fuel (les BP 2.0 contiennent fuel et schedule), schedule.
- Stocker les templates dans `storage` (structure sérialisable, pas de références LuaObject persistées).

### File d'attente et construction
- File FIFO par bâtiment dans `storage`.
- Pour l'item de tête : calculer le coût total (avec qualité si Space Age), scripter les requests sur les coffres cachés via les logistic sections (API 2.0 : `LuaLogisticPoint` / `get_section` / `set_slot`).
- Boucle de contrôle sur `script.on_nth_tick` (ex. 30 ticks), PAS de on_tick lourd : vérifier items disponibles + `rail_signal.signal_state == green`.
- Spawn : `surface.create_entity` de chaque wagon aux positions exactes (espacement 7 tuiles) → connexion automatique ; insérer fuel ; appliquer couleur/filtres ; assigner le schedule ; `train.manual_mode = false`.
- Optionnel gameplay : durée de "construction" par wagon avant la sortie.

### GUI
- Prototype `shortcut` (icône barre d'outils) + `custom-input` pour ouvrir la GUI du bâtiment sélectionné/le plus proche, et GUI à l'ouverture de l'entité (`on_gui_opened`).
- Écrans : liste des templates (import BP, renommer, supprimer), paramètres de lancement, file d'attente (réordonner/annuler), état des requests.
- LuaGuiElement natif, style vanilla (frames, tables, sprite-buttons).

### Contraintes Factorio
- Déterminisme multiplayer : aucun état hors `storage`, pas de `math.random` non seedé côté logique, mêmes calculs pour tous les joueurs.
- `on_configuration_changed` + migrations pour la persistance des templates.
- Localisation : `locale/fr/` et `locale/en/`.
- Compatibilité qualité (Space Age) dans les coûts et requests.

## Structure du projet

```
train-factory/
├── info.json            # factorio_version = "2.0"
├── data.lua             # prototypes: entity, item, recipe, technology, shortcut, custom-input
├── control.lua          # bootstrap, dispatch des events
├── scripts/
│   ├── composite.lua    # création/destruction des entités cachées, rotations
│   ├── blueprint.lua    # parsing des BP → templates
│   ├── queue.lua        # file d'attente, requests logistiques
│   ├── builder.lua      # spawn du train, fuel, schedule, départ
│   └── gui.lua          # toute la GUI
├── graphics/            # placeholder fourni (train-factory-placeholder.png)
└── locale/fr, locale/en
```

## Milestones suggérés

1. Entité posable + composite (rails, coffres, signal) + destruction propre, 4 rotations.
2. Parsing blueprint → template dans storage (test via commande console).
3. File + requests logistiques + spawn du train qui part tout seul.
4. GUI complète + shortcut.
5. Polish : circuit network, durée de construction, sons, qualité, migrations.

## Références utiles

- API runtime : https://lua-api.factorio.com/latest/
- Le testing se fait en copiant le dossier dans `~/.factorio/mods/` (dev sur Ubuntu) ; prévoir un script de sync + `factorio --load-game` pour itérer.
