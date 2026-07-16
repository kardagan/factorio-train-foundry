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

local MAIN   = "train-foundry"
local RAIL   = "tf-rail"
local INPUT  = "tf-input"
local SIGNAL = "tf-signal"

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

-- Point de chargement : linked-container invisible, collision nulle. Tous
-- les points d'une même fonderie partagent le MÊME inventaire (link_id =
-- unit_number, posé au runtime) : un bras qui insère n'importe où sur le
-- pourtour alimente la réserve unique du bâtiment.
local input = table.deepcopy(data.raw["linked-container"]["linked-chest"])
input.name = INPUT
hide(input)
input.icons = { { icon = ICON, icon_size = 64 } }
input.icon, input.icon_size = nil, nil
input.collision_box = { { 0, 0 }, { 0, 0 } }
input.collision_mask = { layers = {} }
-- 20 stacks de réserve interne (locos, wagons, fuel...) — choix gameplay.
input.inventory_size = 20
input.picture = util.empty_sprite()
-- GUI de coffre accessible : pas cliquable en jeu (non sélectionnable) mais
-- ouvrable via le bouton "Déposer / retirer" de notre fenêtre, pour charger
-- la réserve depuis l'inventaire du joueur avec l'UI vanilla.
input.gui_mode = "all"
input.circuit_wire_max_distance = 0

-- Signal de sortie : contrôle le bloc aval et rend le segment interne
-- unidirectionnel sortant. Visible en jeu (posé au bord du bâtiment),
-- mais non sélectionnable/minable.
local signal = table.deepcopy(data.raw["rail-signal"]["rail-signal"])
signal.name = SIGNAL
hide(signal)

-- ============================================================================
-- Item, recette, technologie (vanilla)
-- ============================================================================

data:extend({
  { type = "recipe-category", name = "train-foundry-dummy" },

  main, rail, input, signal,

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
      { type = "item", name = "concrete",             amount = 200 },
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
  -- Attention aux noms : « reinforced concrete » est l'item vanilla
  -- refined-concrete relocalisé, le rail est l'item vanilla "rail" (produit
  -- par la recette nullius-rail) et le « Calculateur » est l'item vanilla
  -- arithmetic-combinator (produit par la recette nullius-arithmetic-circuit,
  -- débloqué par computation, prérequis transitif de traffic-control).
  r.ingredients = {
    { type = "item", name = "nullius-steel-beam",    amount = 40 },
    { type = "item", name = "refined-concrete",      amount = 100 },
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
