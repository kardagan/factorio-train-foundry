-- Train Foundry — prototypes COMMUNS aux deux variantes (BP / STC).
--
-- Ne définit QUE ce qui est partagé : styles GUI, entités enfants (rails,
-- coffre réserve, signal, combinateur), recipe-category, raccourci. Le bâtiment
-- principal, son item/recette/techno et le coffre à blueprints (BP only) vivent
-- dans data-variant.lua, propre à chaque variante.
--
-- Les NOMS viennent de names.lua (require("names")) : la variante BP retombe sur
-- les noms historiques (train-foundry, tf-*), la variante STC utilise tfstc-*.

local names = require("names")

local MAIN       = names.building
local RAIL       = names.rail
local RAIL_OVER  = names.rail_over
local INPUT      = names.input
local SIGNAL     = names.signal
local COMBINATOR = names.combinator
local WALL       = names.wall
local GATE       = names.gate
local TRACK_DECO = names.track_deco

-- Chemin graphique du mod courant (le nom de mod diffère par variante : on passe
-- par le placeholder résolu à l'exécution du data stage).
local GFX  = "__" .. names.mod .. "__/graphics/"
local ICON = GFX .. "foundry-icon.png"

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

-- ============================================================================
-- Entités cachées (enfants runtime — pas d'item, pas de recette)
-- ============================================================================

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
  local seen, flags = {}, {}
  for _, f in ipairs(proto.flags or {}) do
    if not seen[f] then seen[f] = true; flags[#flags + 1] = f end
  end
  for _, f in ipairs(HIDDEN_FLAGS) do
    if not seen[f] then seen[f] = true; flags[#flags + 1] = f end
  end
  proto.flags = flags
end

-- Rail interne : clone du rail vanilla, créé par la fonderie sous sa voie.
local rail = table.deepcopy(data.raw["straight-rail"]["straight-rail"])
rail.name = RAIL
hide(rail)

-- Rail "over" : clone du rail vanilla, RENDU NORMAL (comme le rail interne).
-- Depuis le passage aux VRAIES entités (murs/portes) le bâtiment n'a plus de gros
-- sprite mono-bloc masquant la voie : le rail-over n'a donc PLUS besoin d'un
-- render_layer élevé (higher-object-above) qui, historiquement, le faisait passer
-- par-dessus le sprite du mur — mais aussi par-dessus le personnage et les roues
-- des wagons (bug visuel). On garde un prototype distinct (RAIL_OVER) pour ne pas
-- changer la logique de pose (raccords ouest/est, jonctions), mais son rendu est
-- désormais celui d'un rail ordinaire.
local rail_over = table.deepcopy(data.raw["straight-rail"]["straight-rail"])
rail_over.name = RAIL_OVER
hide(rail_over)

-- Réserve : un VRAI coffre de fer (visible, posé sur le parvis ouest).
local input = table.deepcopy(data.raw["container"]["iron-chest"])
input.name = INPUT
input.minable = nil
input.next_upgrade = nil
input.fast_replaceable_group = nil
input.flags = { "not-blueprintable", "not-deconstructable", "not-upgradable",
                "no-copy-paste", "player-creation" }
input.inventory_size = 100
input.circuit_wire_max_distance = 0
input.hidden_in_factoriopedia = true
input.selection_priority = 100

-- Signal de sortie : contrôle le bloc aval, rend le segment interne sortant.
local signal = table.deepcopy(data.raw["rail-signal"]["rail-signal"])
signal.name = SIGNAL
hide(signal)

-- Connecteur circuit : un VRAI constant-combinator (visible, point d'accroche câble).
local combinator = table.deepcopy(
  data.raw["constant-combinator"]["constant-combinator"])
combinator.name = COMBINATOR
combinator.minable = nil
combinator.next_upgrade = nil
combinator.fast_replaceable_group = nil
combinator.flags = { "not-blueprintable", "not-deconstructable",
                     "not-upgradable", "no-copy-paste", "player-creation",
                     "hide-alt-info" }
combinator.hidden_in_factoriopedia = true
combinator.selection_priority = 100

-- Enceinte : clone du mur de pierre vanilla, posé au pourtour du bâtiment.
-- hide() le rend non-minable/non-sélectionnable ; il conserve sa collision
-- (bloque le personnage → l'intérieur n'est accessible que par les portes).
local wall = table.deepcopy(data.raw["wall"]["stone-wall"])
wall.name = WALL
hide(wall)

-- Porte : clone du gate vanilla, posée aux sorties actives des voies. hide()
-- garde sa collision (bloque tant que fermée) et son comportement d'ouverture.
-- NB : l'ouverture au passage d'un TRAIN (le gate vanilla réagit au personnage)
-- est à valider en jeu — repli éventuel (décoratif / piloté) hors de ce jet.
local gate = table.deepcopy(data.raw["gate"]["gate"])
gate.name = GATE
hide(gate)

-- ============================================================================
-- Bâtiment principal (identique aux deux variantes, seul le name diffère)
-- ============================================================================

local main = {
  type = "assembling-machine",
  name = MAIN,
  icons = { { icon = ICON, icon_size = 64 } },
  flags = { "placeable-neutral", "placeable-player", "player-creation",
            "get-by-unit-number", "not-rotatable" },
  minable = { mining_time = 3, result = MAIN },
  max_health = 3000,
  -- Collision RÉTRÉCIE côté ouest/est (−16 / +17.7 au lieu de −18 / +19.7) : les
  -- PORTES (x=-18/+19) sont ainsi HORS de la collision du bâtiment. Sinon une gate
  -- collée au bâtiment ne se referme jamais (le bâtiment reste dans son rayon
  -- d'activation → déclencheur permanent). Les VRAIS MURS gardent l'enceinte
  -- étanche ; la bande libérée entre collision et murs est protégée par les murs.
  collision_box = { { -16.0, -10.7 }, { 17.7, 10.7 } },
  selection_box = { { -20, -11 }, { 20, 11 } },
  selection_priority = 40,
  tile_width = 40,
  tile_height = 22,
  build_grid_size = 2,
  -- Pas de layer "player" : le personnage peut ENTRER à pied (par les portes) et
  -- marcher sur le sol intérieur. Ce sont les VRAIS MURS (stone-wall) qui
  -- l'arrêtent au pourtour, les portes qui le laissent passer. On garde
  -- is_object/meltable pour bloquer la construction et les entités dans le footprint.
  collision_mask = { layers = { meltable = true, is_object = true } },
  crafting_categories = { names.dummy_cat },
  crafting_speed = 1,
  energy_source = { type = "electric", usage_priority = "secondary-input",
                    drain = "30kW" },
  energy_usage = "450kW",
  allowed_effects = {},
  -- [TEMPORAIRE] Sprites du bâtiment DÉSACTIVÉS le temps de câbler les vraies
  -- entités (murs, 2 voies, portes) : le sol + les portiques masquaient tout ce
  -- qu'on veut voir. Bâtiment invisible pour l'instant. Les 2 couches (SOL
  -- foundry-floor.png en lower-object + TOIT foundry-roof.png en
  -- higher-object-above) seront REMISES une fois la structure entités validée.
  graphics_set = {
    -- working_visualisations = {
    --   { always_draw = true, render_layer = "lower-object",
    --     animation = { filename = GFX .. "foundry-floor.png", width = 1280,
    --       height = 689, scale = 1, shift = { 0, -0.171875 } } },
    --   { always_draw = true, render_layer = "higher-object-above",
    --     animation = { filename = GFX .. "foundry-roof.png", width = 1280,
    --       height = 689, scale = 1, shift = { 0, -0.171875 } } },
    -- },
    animation = {
      filename = "__core__/graphics/empty.png",
      width = 1,
      height = 1,
    },
  },
}

-- [DISCOVERY] Entité-déco de voie de jonction : une simple-entity-with-owner
-- INVISIBLE et INERTE, posée par la fonderie sur chaque module, dont le sprite
-- (variation pilotée au runtime via entity.graphics_variation) peint la voie
-- jusqu'aux bords selon le côté ouvert. render_layer "lower-object" = SOUS les
-- roues des wagons (comme le working_visualisation du bâtiment), contrairement à
-- LuaRendering qui dessine au-dessus des entités (roues masquées partout).
-- Variations base 1 : 1=right (bout ouest), 2=both (milieu), 3=left (bout est).
-- random_variation_on_create=false SINON Factorio tire une variation au hasard à
-- la pose et écrase notre graphics_variation.
local function deco_variation(file)
  return {
    filename = GFX .. file,
    width = 1280,
    height = 689,
    scale = 1,
    shift = { 0, -0.171875 },
    flags = { "no-crop" },
  }
end
local track_deco = {
  type = "simple-entity-with-owner",
  name = TRACK_DECO,
  render_layer = "lower-object",
  random_variation_on_create = false,
  collision_mask = { layers = {} },
  pictures = {
    deco_variation("foundry-link-right.png"),  -- 1
    deco_variation("foundry-link-both.png"),   -- 2
    deco_variation("foundry-link-left.png"),   -- 3
  },
}
hide(track_deco)

data:extend({
  { type = "recipe-category", name = names.dummy_cat },

  main, rail, rail_over, input, signal, combinator, wall, gate, track_deco,

  -- Vue d'ensemble : raccourci + touche perso ouvrant la fonderie de la surface.
  {
    type = "custom-input",
    name = names.shortcut,
    key_sequence = "CONTROL + ALT + F",
    action = "lua",
  },
  {
    type = "shortcut",
    name = names.shortcut,
    action = "lua",
    associated_control_input = names.shortcut,
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
-- Compatibilité Nullius (le bâtiment/recette/techno, communs)
-- ============================================================================
if mods["nullius"] then
  local r = data.raw.recipe[MAIN]
  r.category = "huge-crafting"
  r.order = "nullius-h"
  r.energy_required = 80
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
  tech.ignore_tech_cost_multiplier = true
  tech.name = "nullius-" .. MAIN
  data.raw.technology["nullius-" .. MAIN] = tech
  data.raw.technology[MAIN] = nil
end
