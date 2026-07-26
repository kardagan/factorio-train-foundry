-- Train Foundry (variante BP) — prototypes SPÉCIFIQUES à la variante blueprint.
--
-- Seule différence de data stage vs la variante STC : le COFFRE À BLUEPRINTS.
-- Le bâtiment, l'item, la recette, la techno et les enfants communs sont dans
-- common/data-common.lua.

local names = require("names")

-- Teinte récursivement les feuilles de sprite (toute table portant un
-- `filename`) : sprite simple, `layers`, `variations`... L'ombre est ignorée.
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

-- Coffre à BLUEPRINTS : vrai coffre visible sur le parvis, filtré blueprints.
-- Le joueur y dépose ses plans de trains ; le livre de la fenêtre lit ce coffre.
-- Rendu BLEU pour le distinguer de la réserve grise.
local bpchest = table.deepcopy(data.raw["container"]["iron-chest"])
bpchest.name = names.bpchest
bpchest.minable = nil
bpchest.next_upgrade = nil
bpchest.fast_replaceable_group = nil
bpchest.flags = { "not-blueprintable", "not-deconstructable", "not-upgradable",
                  "no-copy-paste", "player-creation" }
bpchest.inventory_size = 50
bpchest.inventory_type = "with_filters_and_bar"
bpchest.circuit_wire_max_distance = 0
bpchest.hidden_in_factoriopedia = true
bpchest.selection_priority = 100

local BP_TINT = { r = 0.35, g = 0.6, b = 1.0, a = 1.0 }
if bpchest.picture then tint_sprite(bpchest.picture, BP_TINT) end

data:extend({ bpchest })
