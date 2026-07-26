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

-- Rail "over" : identique, mais dessiné PAR-DESSUS le sprite du bâtiment (mur est).
local rail_over = table.deepcopy(data.raw["straight-rail"]["straight-rail"])
rail_over.name = RAIL_OVER
hide(rail_over)
-- Le rail-over doit se dessiner AU-DESSUS du sprite du bâtiment (lower-object,
-- sinon masqué par les murs aux jonctions) mais SOUS les roues des wagons (qui
-- sont sur une couche fixe entre lower-object et object). On vise donc
-- "lower-object-above-shadow", la couche juste au-dessus de lower-object : la
-- voie de jonction reste visible par-dessus les murs, sans masquer les roues ni
-- paraître plus claire que le tampon peint. (Avant : object/higher-object-above
-- → au-dessus des roues, d'où les roues masquées et l'aspect trop clair.)
-- Le rail-over ne sert plus qu'au tronçon de SORTIE qui traverse le mur EST du
-- bâtiment (open_east/lay_east_rails) — là il DOIT passer au-dessus du sprite,
-- et le masquage des roues n'y est pas gênant (le train ne stationne pas sous ce
-- mur). Aux jonctions internes on utilise désormais un rail normal (voir
-- fill_track_abs). D'où le retour aux couches hautes object/higher-object-above.
if rail_over.pictures and type(rail_over.pictures) == "table" then
  rail_over.pictures.render_layers = {
    stone_path_lower = "object",
    stone_path       = "object",
    tie              = "object",
    screw            = "object",
    metal            = "higher-object-above",
  }
end

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
  collision_box = { { -18.0, -10.7 }, { 19.7, 10.7 } },
  selection_box = { { -20, -11 }, { 20, 11 } },
  selection_priority = 40,
  tile_width = 40,
  tile_height = 22,
  build_grid_size = 2,
  collision_mask = { layers = { player = true, meltable = true,
                                is_object = true } },
  crafting_categories = { names.dummy_cat },
  crafting_speed = 1,
  energy_source = { type = "electric", usage_priority = "secondary-input",
                    drain = "30kW" },
  energy_usage = "450kW",
  allowed_effects = {},
  graphics_set = {
    working_visualisations = {
      {
        always_draw = true,
        render_layer = "lower-object",
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

data:extend({
  { type = "recipe-category", name = names.dummy_cat },

  main, rail, rail_over, input, signal, combinator,

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
