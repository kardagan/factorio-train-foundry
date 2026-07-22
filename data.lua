-- Train Foundry — prototypes.
--
-- Le bâtiment principal est un assembling-machine SANS recette utilisable,
-- NON ROTATABLE : une seule orientation, la sortie rail à l'OUEST (gauche),
-- la voie sur la rangée basse du bâtiment (lateral +4 depuis le centre).
-- Les enfants cachés (rails, points de chargement, signal) sont des clones
-- de prototypes vanilla, créés/détruits par control.lua.
--
-- Chargement des composants : PAS de logistique distante — le joueur insère
-- les items "aux bras" n'importe où sur le pourtour, via un anneau de
-- linked-containers invisibles qui partagent UN SEUL inventaire par fonderie
-- (link_id = unit_number du bâtiment). Qui veut du requester pose ses
-- propres coffres à côté.
--
-- Géométrie (offsets depuis le centre de l'entité) :
--   footprint 36×20 tuiles, collision ±17.7×±9.7, build_grid_size 2
--   voie : rangée lateral +4, rails aux x pairs -16..+16, sortie à l'ouest
--   sprite 1152×753 : 640 px de bâtiment (20 tuiles) + 113 px de débord
--   visuel en haut (cheminées/toits), d'où le shift de -1.765625 tuile.

local util = require("util")

-- Styles GUI : slots d'ingrédients teintés vert (dispo) / rouge (manquant).
-- Dérivés de slot_button avec un fond de couleur uni, pour ne pas dépendre
-- d'un style vanilla qui n'existe pas dans toutes les versions.
local styles = data.raw["gui-style"].default
styles["tf_slot_ok"] = {
  type = "button_style",
  parent = "slot_button",
  default_graphical_set = { base = { position = { 0, 0 }, corner_size = 8,
    tint = { 30, 255, 40, 255 } } },
  hovered_graphical_set = { base = { position = { 0, 0 }, corner_size = 8,
    tint = { 90, 255, 100, 255 } } },
  clicked_graphical_set = { base = { position = { 0, 0 }, corner_size = 8,
    tint = { 30, 255, 40, 255 } } },
}
styles["tf_slot_missing"] = {
  type = "button_style",
  parent = "slot_button",
  default_graphical_set = { base = { position = { 0, 0 }, corner_size = 8,
    tint = { 255, 25, 25, 255 } } },
  hovered_graphical_set = { base = { position = { 0, 0 }, corner_size = 8,
    tint = { 255, 80, 80, 255 } } },
  clicked_graphical_set = { base = { position = { 0, 0 }, corner_size = 8,
    tint = { 255, 25, 25, 255 } } },
}

local MAIN       = "train-foundry"
local RAIL       = "tf-rail"
local RAIL_OVER  = "tf-rail-over"
local INPUT      = "tf-input"
local SIGNAL     = "tf-signal"
local COMBINATOR = "tf-combinator"
local BPCHEST    = "tf-blueprints"

local GFX  = "__train-foundry__/graphics/"
local ICON = GFX .. "foundry-icon.png"

-- ============================================================================
-- Bâtiment principal
-- ============================================================================

local main = {
  type = "assembling-machine",
  name = MAIN,
  icons = { { icon = ICON, icon_size = 64 } },
  flags = { "placeable-neutral", "placeable-player", "player-creation",
            "get-by-unit-number", "not-rotatable" },
  minable = { mining_time = 3, result = MAIN },
  max_health = 3000,

  -- Box ASYMÉTRIQUE : elle s'arrête à -18.0 côté ouest alors que le
  -- footprint va jusqu'à -20. La bande ouest (2 tuiles, le parvis de sortie
  -- dessiné) reste donc hors collision : c'est là que doit déjà se trouver
  -- le rail de RACCORD du joueur (exigence de pose vérifiée dans
  -- control.lua ; le rail centré à -19 a sa box jusqu'à -18.01, qui ne
  -- touche pas la nôtre). Partout ailleurs le bâtiment garde le mask PAR
  -- DÉFAUT d'un crafting machine : il collisionne avec tout (arbres, rails,
  -- bâtiments) et l'eau est interdite. Le sprite du parvis recouvre le rail
  -- de raccord → la jonction visuelle est masquée par l'art.
  collision_box = { { -18.0, -10.7 }, { 19.7, 10.7 } },
  selection_box = { { -20, -11 }, { 20, 11 } },
  -- Priorité de sélection SOUS le défaut (50) : la selection_box couvre tout
  -- le footprint 40×22, y compris la zone libre du parvis où le joueur pose
  -- ses propres tapis/bras. À priorité égale, la plus grande entité gagne le
  -- survol → le bâtiment masquait ces entités et les rendait intouchables. En
  -- passant à 40, toute entité posée dessus (prio 50 par défaut) reprend le
  -- survol. La fonderie reste ouvrable par son corps ailleurs, par le
  -- combinateur (prio 100) et par le raccourci CTRL+ALT+F.
  selection_priority = 40,
  tile_width = 40,
  tile_height = 22,
  -- Snap sur la grille 2×2 des rails, pour que la rangée de voie tombe
  -- toujours sur la grille des rails.
  build_grid_size = 2,

  -- Le bâtiment doit pouvoir se poser PAR-DESSUS un rail existant (snap de
  -- la sortie sur le réseau) : on retire du mask par défaut tous les layers
  -- partagés avec les rails (item, object, water_tile, is_lower_object).
  -- Ce qui bloque encore : le personnage et la plupart des obstacles
  -- naturels (layer "player"), les autres bâtiments ("is_object"). Les
  -- trains passent (pas de layer "train"). Effet de bord assumé : posable
  -- sur l'eau — check runtime éventuel au polish (milestone 5).
  collision_mask = { layers = { player = true, meltable = true,
                                is_object = true } },

  -- Machine sans recette : catégorie dédiée dans laquelle aucune recette
  -- n'existe. La GUI vanilla est interceptée et fermée dans control.lua.
  crafting_categories = { "train-foundry-dummy" },
  crafting_speed = 1,
  -- Branché au réseau électrique : drain permanent modeste, la consommation
  -- pleine (energy_usage) ne tirera que pendant la construction d'un train
  -- (milestone 3). Sans courant, l'icône vanilla "pas d'électricité" apparaît.
  energy_source = { type = "electric", usage_priority = "secondary-input",
                    drain = "30kW" },
  energy_usage = "450kW",
  allowed_effects = {},

  graphics_set = {
    -- Le sprite passe par une working_visualisation et PAS par l'animation
    -- de base : le render_layer est IGNORÉ sur l'animation d'un crafting
    -- machine (constat partagé par le mod trainConstructionSite, même
    -- problème). "lower-object" passe sous les roues des trains — sinon le
    -- bâtiment recouvre les roues des wagons sur sa voie interne (les corps
    -- se dessinent en "object" trié par y, les roues dans une couche fixe
    -- entre lower-object et object).
    working_visualisations = {
      {
        always_draw = true,
        render_layer = "lower-object",
        -- Art v4 (fond magenta) dont la voie dessinée a été REMPLACÉE par
        -- un tampon des sprites du rail vanilla (calques stone-path/ties/
        -- backplates/metals de __base__, 19 pièces, variations alternées)
        -- sur la rangée +5 — la jonction avec le réseau du joueur est donc
        -- pixel-identique par construction. Le shift cale l'axe du tampon
        -- (y=510 dans le PNG) exactement sur la rangée +5 du monde :
        -- (5 - shift) * 32 + 689/2 = 510.
        animation = {
          filename = GFX .. "foundry.png",
          width = 1280,
          height = 689,
          scale = 1,
          shift = { 0, -0.171875 },
        },
      },
    },
    animation = {
      filename = "__core__/graphics/empty.png",
      width = 1,
      height = 1,
    },
  },
}

-- ============================================================================
-- Entités cachées (enfants runtime — pas d'item, pas de recette)
-- ============================================================================

-- Flags communs : intouchables par le joueur, invisibles des outils
-- (blueprint, déconstruction, upgrade, copy-paste), absents de la carte,
-- muets en mode alt (sinon les 112 quais affichent leur contenu en anneau
-- autour du bâtiment).
local HIDDEN_FLAGS = { "not-on-map", "not-blueprintable", "not-deconstructable",
                       "not-upgradable", "no-copy-paste", "hide-alt-info" }

local function hide(proto)
  proto.hidden = true
  proto.hidden_in_factoriopedia = true
  proto.minable = nil
  proto.selectable_in_game = false
  proto.next_upgrade = nil
  proto.fast_replaceable_group = nil
  proto.corpse = nil
  proto.dying_explosion = nil
  -- Fusion sans doublon avec les flags d'origine du prototype cloné
  -- (un flag dupliqué est un risque de refus au chargement).
  local seen, flags = {}, {}
  for _, f in ipairs(proto.flags or {}) do
    if not seen[f] then seen[f] = true; flags[#flags + 1] = f end
  end
  for _, f in ipairs(HIDDEN_FLAGS) do
    if not seen[f] then seen[f] = true; flags[#flags + 1] = f end
  end
  proto.flags = flags
end

-- Rail interne : clone du rail vanilla, créé par la fonderie sous sa voie
-- (la connectivité rail est géométrique, il se raccorde au rail de raccord
-- du joueur sans problème). Détruit avec le bâtiment.
local rail = table.deepcopy(data.raw["straight-rail"]["straight-rail"])
rail.name = RAIL
hide(rail)

-- Rail "over" : identique au rail interne, MAIS dessiné PAR-DESSUS le sprite du
-- bâtiment (qui est en "lower-object"). Sert au tronçon de sortie qui traverse
-- le MUR du bâtiment (est) : un rail vanilla se dessine en couches rail-* (sous
-- lower-object) et serait masqué par le mur. On surcharge les 5 couches de
-- pictures.render_layers (le mapping feuille->couche d'un rail 2.0 est centralisé
-- là, pas sur chaque sprite) vers object / higher-object-above (> lower-object),
-- pour que la voie "écrase" visuellement le mur. Défensif si la structure du
-- prototype vanilla évolue.
local rail_over = table.deepcopy(data.raw["straight-rail"]["straight-rail"])
rail_over.name = RAIL_OVER
hide(rail_over)
if rail_over.pictures and type(rail_over.pictures) == "table" then
  rail_over.pictures.render_layers = {
    stone_path_lower = "object",
    stone_path       = "object",
    tie              = "object",
    screw            = "object",
    metal            = "higher-object-above",
  }
end

-- Réserve : un VRAI coffre de fer (visible, posé sur le parvis ouest). Les
-- bras y déposent/prennent sans souci (c'est un coffre vanilla). Solidaire
-- de la fonderie : non minable, indestructible, créé/détruit avec elle.
-- Fini les linked-containers invisibles (les bras ne ciblent pas une entité
-- hidden/collision nulle).
local input = table.deepcopy(data.raw["container"]["iron-chest"])
input.name = INPUT
input.minable = nil
input.next_upgrade = nil
input.fast_replaceable_group = nil
input.flags = { "not-blueprintable", "not-deconstructable", "not-upgradable",
                "no-copy-paste", "player-creation" }
input.inventory_size = 20
input.circuit_wire_max_distance = 0
-- Enfant de la fonderie (pas d'item/recette) : hors Factoriopedia, mais reste
-- sélectionnable pour que le joueur puisse l'ouvrir.
input.hidden_in_factoriopedia = true
-- Priorité de sélection AU-DESSUS du bâtiment (dont la selection box couvre
-- le parvis) : sinon survoler le coffre sélectionne le bâtiment.
input.selection_priority = 100

-- Teinte récursivement les feuilles de sprite (toute table portant un
-- `filename`) d'une structure quelconque : sprite simple, `layers`,
-- `variations`... — indépendant du nom/forme des champs 2.0. L'ombre
-- (draw_as_shadow) est ignorée pour rester réaliste ; seul le métal est
-- coloré.
local function tint_sprite(node, tint)
  if type(node) ~= "table" then return end
  if node.filename and not node.draw_as_shadow then
    node.tint = tint
    node.apply_runtime_tint = false
  end
  for _, sub in pairs(node) do
    tint_sprite(sub, tint)
  end
end

-- Coffre à BLUEPRINTS : un vrai coffre visible sur le parvis, filtré pour
-- n'accepter que des blueprints. Le joueur y dépose ses plans de trains (à la
-- main ou aux bras) ; le livre de la fenêtre lit ce coffre. Grâce à ça, la
-- fenêtre principale n'a plus besoin de gérer l'import → elle redevient une
-- fenêtre classique (player.opened) et Échap la ferme nativement.
--
-- Rendu BLEU (tint sur le sprite du coffre de fer) pour le distinguer d'un
-- coup d'œil de la réserve grise et rappeler la couleur des blueprints.
local bpchest = table.deepcopy(data.raw["container"]["iron-chest"])
bpchest.name = BPCHEST
bpchest.minable = nil
bpchest.next_upgrade = nil
bpchest.fast_replaceable_group = nil
bpchest.flags = { "not-blueprintable", "not-deconstructable", "not-upgradable",
                  "no-copy-paste", "player-creation" }
bpchest.inventory_size = 50
bpchest.inventory_type = "with_filters_and_bar"
bpchest.circuit_wire_max_distance = 0
-- Enfant de la fonderie (pas d'item/recette) : hors Factoriopedia, reste ouvrable.
bpchest.hidden_in_factoriopedia = true
bpchest.selection_priority = 100

-- Bleu blueprint (clair, légèrement cyan). Appliqué à la vue en jeu.
local BP_TINT = { r = 0.35, g = 0.6, b = 1.0, a = 1.0 }
if bpchest.picture then tint_sprite(bpchest.picture, BP_TINT) end

-- Signal de sortie : contrôle le bloc aval et rend le segment interne
-- unidirectionnel sortant. Visible en jeu (posé au bord du bâtiment),
-- mais non sélectionnable/minable.
local signal = table.deepcopy(data.raw["rail-signal"]["rail-signal"])
signal.name = SIGNAL
hide(signal)

-- Connecteur circuit : un VRAI constant-combinator (visible, posé sur le
-- parvis à côté du coffre). Le câble s'y accroche sans souci (entité
-- vanilla câblable). Solidaire de la fonderie : non minable, indestructible.
local combinator = table.deepcopy(
  data.raw["constant-combinator"]["constant-combinator"])
combinator.name = COMBINATOR
combinator.minable = nil
combinator.next_upgrade = nil
combinator.fast_replaceable_group = nil
-- hide-alt-info : pas de prévisu des signaux émis en mode alt sur le
-- combinateur (il ne sert que de point d'accroche du câble ; le choix
-- stock/request est dans notre fenêtre).
combinator.flags = { "not-blueprintable", "not-deconstructable",
                     "not-upgradable", "no-copy-paste", "player-creation",
                     "hide-alt-info" }
-- Pas craftable/posable directement (enfant de la fonderie) : on le retire de
-- la Factoriopedia. On NE le masque pas via hidden/selectable : le joueur doit
-- pouvoir le cliquer pour ouvrir la fonderie.
combinator.hidden_in_factoriopedia = true
-- Priorité de sélection au-dessus du bâtiment (comme le coffre).
combinator.selection_priority = 100

-- ============================================================================
-- Item, recette, technologie (vanilla)
-- ============================================================================

data:extend({
  { type = "recipe-category", name = "train-foundry-dummy" },

  main, rail, rail_over, input, signal, combinator, bpchest,

  -- Vue d'ensemble : bouton dans la barre de raccourcis + touche
  -- personnalisable (défaut CTRL+ALT+F) ouvrant la fonderie de la surface
  -- courante, pour la piloter À DISTANCE sans se déplacer.
  {
    type = "custom-input",
    name = "tf-open-overview",
    key_sequence = "CONTROL + ALT + F",
    action = "lua",
  },
  {
    type = "shortcut",
    name = "tf-open-overview",
    action = "lua",
    associated_control_input = "tf-open-overview",
    toggleable = false,
    icon = ICON,
    icon_size = 64,
    small_icon = ICON,
    small_icon_size = 64,
  },

  {
    type = "item",
    name = MAIN,
    icons = { { icon = ICON, icon_size = 64 } },
    subgroup = "train-transport",
    order = "a[train-system]-zz[train-foundry]",
    place_result = MAIN,
    stack_size = 1,
  },

  {
    type = "recipe",
    name = MAIN,
    enabled = false,
    energy_required = 60,
    ingredients = {
      { type = "item", name = "steel-plate",          amount = 200 },
      { type = "item", name = "concrete",             amount = 1000 },
      { type = "item", name = "electric-engine-unit", amount = 20 },
      { type = "item", name = "advanced-circuit",     amount = 50 },
      { type = "item", name = "rail",                 amount = 30 },
      { type = "item", name = "rail-signal",          amount = 2 },
      { type = "item", name = "steel-chest",          amount = 4 },
    },
    results = { { type = "item", name = MAIN, amount = 1 } },
  },

  {
    type = "technology",
    name = MAIN,
    icons = { { icon = GFX .. "tech.png", icon_size = 256 } },
    -- Mêmes prérequis que Smart Train Combinator : le chargement se fait
    -- aux bras, plus besoin de la robotique logistique.
    prerequisites = { "advanced-combinators", "automated-rail-transportation" },
    unit = {
      count = 100,
      ingredients = {
        { "automation-science-pack", 1 },
        { "logistic-science-pack",   1 },
        { "chemical-science-pack",   1 },
      },
      time = 30,
    },
    effects = {
      { type = "unlock-recipe", recipe = MAIN },
    },
  },
})

-- ============================================================================
-- Compatibilité Nullius
-- ============================================================================
-- Nullius (prototypes/hidden.lua, phase data-updates) cache toute recette,
-- techno ou item dont ni le name ni l'order ne commence par "nullius-". On
-- s'en échappe par l'ORDER pour la recette et l'item (garder name == produit,
-- sinon Recipe Book duplique l'entrée), et par RENOMMAGE pour la techno
-- (localised_name figé avant, pour garder nos clés locale). L'item doit
-- impérativement s'échapper aussi : sinon hidden.lua cache l'entité en
-- cascade via minable.result. Ce bloc vit en data.lua (et pas en
-- data-final-fixes) car il doit être en place AVANT le data-updates de
-- nullius — même convention que smart-train-combinator.
if mods["nullius"] then
  local r = data.raw.recipe[MAIN]
  -- Pattern nullius pour les gros bâtiments : des bâtiments inférieurs +
  -- quelques intermédiaires. "huge-crafting" = craft main + large assemblers
  -- (la catégorie des locomotives), cohérent pour un hangar 36×20.
  r.category = "huge-crafting"
  -- Subgroup "railway" de nullius (rail=nullius-d, train stop=eb, signaux
  -- f/g) : la foundry se range juste après les signaux, au lieu de rester
  -- seule dans le subgroup vanilla train-transport déplacé par boblogistics.
  r.order = "nullius-h"
  r.energy_required = 80
  -- Attention aux noms : le rail est l'item vanilla "rail" (produit par la
  -- recette nullius-rail) et le « Calculateur » est l'item vanilla
  -- arithmetic-combinator (produit par la recette nullius-arithmetic-circuit,
  -- débloqué par computation, prérequis transitif de traffic-control).
  -- Brique de pierre (dispo tôt) plutôt que le béton armé nullius (trop loin
  -- dans l'arbre), en gros volume vu la taille du bâtiment.
  r.ingredients = {
    { type = "item", name = "nullius-steel-beam",    amount = 40 },
    { type = "item", name = "stone-brick",           amount = 1000 },
    { type = "item", name = "nullius-motor-2",       amount = 8 },
    { type = "item", name = "arithmetic-combinator", amount = 10 },
    { type = "item", name = "rail",                  amount = 20 },
  }
  data.raw.item[MAIN].subgroup = "railway"
  data.raw.item[MAIN].order = "nullius-h"

  local tech = data.raw.technology[MAIN]
  tech.localised_name        = { "technology-name." .. MAIN }
  tech.localised_description = { "technology-description." .. MAIN }
  -- Mêmes prérequis que Smart Train Combinator (ancré sur traffic-control).
  tech.prerequisites = { "nullius-computation", "nullius-traffic-control" }
  tech.unit = {
    count = 30,
    ingredients = {
      { "nullius-climatology-pack", 1 },
      { "nullius-mechanical-pack",  1 },
      { "nullius-electrical-pack",  1 },
    },
    time = 25,
  }
  tech.order = "nullius-h"
  -- Les coûts nullius sont déjà calibrés (nullius le met sur ses techs).
  tech.ignore_tech_cost_multiplier = true
  tech.name = "nullius-" .. MAIN
  data.raw.technology["nullius-" .. MAIN] = tech
  data.raw.technology[MAIN] = nil
end
