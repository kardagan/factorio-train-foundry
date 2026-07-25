-- ===========================================================================
-- Modèle de train « STC » -> template synthétique
-- ---------------------------------------------------------------------------
-- Convertit une « forme » lue chez Smart Train Combinator (get_models) en un
-- objet compatible avec l'interface `template` attendue par builder.lua
-- (.stock, .horizontal, .schedules, .parameters). L'itinéraire est un PATRON
-- figé, calqué sur le blueprint de référence du joueur : un record de
-- chargement + trois interruptions (Refuel / stop / déchargement), un groupe.
-- La ressource reste le paramètre `parameter-0` — la substitution est faite par
-- builder.spawn via subst_station (comme un blueprint paramétré), donc le joueur
-- choisit la ressource dans le dialogue habituel.
--
-- Ce qui VARIE selon la forme : le kind (item/fluid → [item=]/[fluid=]), le
-- nombre d'icônes wagon (N), le segment `group` (renvoyé déjà rendu par STC,
-- non interprété), et le nom de l'interruption de déchargement (kind+group+N).
--
-- Carburant : PAS géré ici (plus de choix, plus de fuel-request). Le remplissage
-- est fait par builder (meilleur carburant débloqué compatible dispo). Ici on ne
-- produit QUE l'interruption Refuel : elle liste tous les carburants du jeu que la
-- loco peut brûler (condition ≤ 10 % du plein de CE carburant), et reprend sur la
-- condition native `fuel_full`. Omise pour une loco sans burner (ex. loco solaire).
-- ===========================================================================

local stc_template = {}

-- Préfixe TF collé devant le nom de groupe ET chaque nom d'interruption, pour
-- repérer d'un coup d'œil les trains/interruptions issus d'une fonderie. On
-- privilégie l'icône de l'entité train-foundry ; repli sur l'item, puis rien
-- (un sprite rich-text invalide ne planterait qu'à l'AFFICHAGE, on l'évite).
-- Calculé une fois, mémoïsé (les prototypes ne changent pas en cours de partie).
local tf_prefix_cache = nil
local function tf_prefix()
  if tf_prefix_cache ~= nil then return tf_prefix_cache end
  for _, tag in ipairs({ "[entity=train-foundry]", "[item=train-foundry]" }) do
    local path = tag:sub(2, -2):gsub("=", "/")  -- "entity/train-foundry"
    if helpers.is_valid_sprite_path(path) then
      tf_prefix_cache = tag
      return tag
    end
  end
  tf_prefix_cache = ""
  return ""
end

-- Orientation "par défaut" du stock (loco tête ouest, wagons est), utilisée quand
-- le train sort à GAUCHE. La sortie DROITE seule est gérée par builder.spawn qui
-- retourne le train (loco à l'est) au moment du spawn — voir source_kind "stc".
local LOCO_ORIENT  = 0.75
local WAGON_ORIENT = 0.25

-- Nom de la locomotive pour un wagon donné : même « type/tier » que le wagon
-- (v1). Heuristique : on remplace le segment cargo-wagon / fluid-wagon par
-- locomotive en gardant le préfixe mod et le tier. Repli : première locomotive
-- du jeu. Le raffinage (choix explicite du tier/nombre de locos) viendra plus tard.
local function locomotive_for(wagon_type)
  local cand = wagon_type
    :gsub("cargo%-wagon", "locomotive")
    :gsub("fluid%-wagon", "locomotive")
  local proto = prototypes.entity[cand]
  if proto and proto.type == "locomotive" then return cand end
  -- repli : n'importe quelle locomotive existante
  for name, p in pairs(prototypes.entity) do
    if p.type == "locomotive" then return name end
  end
  return cand  -- dernier recours (create_entity échouera proprement en amont)
end

-- Nombre de slots de carburant d'une loco (0 si pas de burner → loco solaire).
local function fuel_slots(loco_type)
  local proto = prototypes.entity[loco_type]
  if not (proto and proto.burner_prototype) then return 0 end
  local n = proto.get_inventory_size(defines.inventory.fuel)
  return n or 0
end

-- TOUS les carburants du jeu que cette loco peut brûler (item.fuel_value>0 dont
-- la catégorie est acceptée par le burner). Liste statique (indépendante du
-- débloquage) : une condition sur un carburant jamais présent est neutre. Vide
-- si la loco n'a pas de burner (solaire). Trié par fuel_value décroissant pour un
-- affichage stable.
local function compatible_fuels(loco_type)
  local proto = prototypes.entity[loco_type]
  local burner = proto and proto.burner_prototype
  if not (burner and burner.fuel_categories) then return {} end
  local out = {}
  for name, it in pairs(prototypes.item) do
    if it.fuel_value and it.fuel_value > 0
       and it.fuel_category and burner.fuel_categories[it.fuel_category] then
      out[#out + 1] = { name = name, fuel_value = it.fuel_value,
                        stack_size = it.stack_size }
    end
  end
  table.sort(out, function(a, b) return a.fuel_value > b.fuel_value end)
  return out
end

-- Répète le tag d'icône wagon N fois. On passe par [item=<place-item>] quand il
-- existe (forme que le sélecteur rich-text insère et que STC utilise pour ses
-- noms de gares) et [entity=...] en repli.
local function wagon_run(wagon_type, n)
  local proto = prototypes.entity[wagon_type]
  local place = proto and proto.items_to_place_this
  local tag
  if place and place[1] and place[1].name then
    tag = "[item=" .. place[1].name .. "]"
  else
    tag = "[entity=" .. wagon_type .. "]"
  end
  return string.rep(tag, n)
end

-- Libellé du kind pour le nom de l'interruption de déchargement (anglais, pour
-- un mod international).
local function kind_label(kind)
  return (kind == "fluid") and "fluid" or "solid"
end

-- Icône STC de déchargement pour le nom de l'interruption. Validée (STC est en
-- dépendance du mode, donc normalement présente) ; "" en repli si absente.
local function unload_icon()
  local p = "virtual-signal/stc2-unload"
  return helpers.is_valid_sprite_path(p) and "[virtual-signal=stc2-unload]" or ""
end

-- Construit le template synthétique. `model` = une entrée de get_models
-- { kind, wagon_type, wagon_quality, wagons, group, storage }.
function stc_template.build(model)
  local n      = math.max(1, model.wagons or 1)
  local loco   = locomotive_for(model.wagon_type)
  local wagons = wagon_run(model.wagon_type, n)
  local group  = model.group or ""
  local prefix = tf_prefix()  -- icône TF devant le groupe et les interruptions
  local slots  = fuel_slots(loco)              -- 0 si loco solaire
  local fuels  = compatible_fuels(loco)        -- carburants brûlables (vide si solaire)

  -- --- .stock : loco (tête) + N wagons -----------------------------------
  -- Aucun carburant ici : builder remplit avec le meilleur carburant débloqué
  -- dispo au spawn. Le stock ne porte que les véhicules.
  local stock = { { name = loco, orientation = LOCO_ORIENT,
                    quality = model.wagon_quality } }
  for _ = 1, n do
    stock[#stock + 1] = { name = model.wagon_type, orientation = WAGON_ORIENT,
                          quality = model.wagon_quality }
  end

  -- --- Itinéraire (patron figé) ------------------------------------------
  -- Ressource = parameter-0 (substituée par builder.spawn / subst_station).
  local load_station = "[item=parameter-0]" .. group
    .. "[virtual-signal=stc2-load]" .. wagons

  -- Nom de GROUPE : il DOIT encoder la forme, pas seulement la ressource — sinon
  -- deux trains de même ressource mais de formes différentes tombent dans le même
  -- groupe et leurs interruptions (rattachées au groupe en 2.0) se mélangent.
  -- On répète l'icône ressource N fois (un picto par wagon) et on inclut le
  -- segment storage : chaque (ressource, N, storage) a son propre groupe.
  local group_name = prefix .. group .. string.rep("[item=parameter-0]", n)

  local unload_name = prefix .. unload_icon() .. "[color=red]unload " .. kind_label(model.kind)
    .. (model.storage and " storage" or "") .. " " .. n .. "[/color]"
  local unload_station = "[virtual-signal=signal-item-parameter]" .. group
    .. wagons .. "[virtual-signal=stc2-unload]"

  local records = {
    {
      station = load_station,
      wait_conditions = { { type = "full", compare_type = "and" } },
    },
  }

  local interrupts = {}

  -- Refuel : dès qu'UN des carburants brûlables passe sous 10 % de son plein,
  -- aller à la gare fuel ; repartir quand le carburant est plein (fuel_full natif).
  -- Une condition par carburant compatible du jeu, en AND (comme le BP de réf) ;
  -- une condition sur un carburant jamais présent est neutre. Omise si loco solaire
  -- (aucun carburant brûlable → pas de burner).
  if #fuels > 0 and slots > 0 then
    local conds = {}
    for _, f in ipairs(fuels) do
      local threshold = math.max(1, math.ceil(f.stack_size * slots * 0.10))
      conds[#conds + 1] = {
        type = "fuel_item_count_any", compare_type = "and",
        condition = { first_signal = { name = f.name },
                      constant = threshold, comparator = "<=" },
      }
    end
    interrupts[#interrupts + 1] = {
      name = prefix .. "[color=white]Refuel[/color]",
      conditions = conds,
      targets = {
        { station = "[virtual-signal=signal-fuel]",
          wait_conditions = {
            { type = "fuel_full", compare_type = "and" },
            { type = "inactivity", compare_type = "or", ticks = 300 },
          } },
      },
      inside_interrupt = true,
    }
  end

  -- Stop : destination pleine / sans chemin → parking temporaire.
  interrupts[#interrupts + 1] = {
    name = prefix .. "[color=orange]stop[/color]",
    conditions = {
      { type = "destination_full_or_no_path", compare_type = "and" },
    },
    targets = {
      { station = "[virtual-signal=signs-2][virtual-signal=signs-2][virtual-signal=signs-2]",
        wait_conditions = {
          { type = "time", compare_type = "and", ticks = 60 },
        } },
    },
    inside_interrupt = true,
  }

  -- Déchargement : plein → gare de décharge (le jeu résout signal-item-parameter
  -- selon le contenu du wagon), repartir une fois vide.
  interrupts[#interrupts + 1] = {
    name = unload_name,
    conditions = { { type = "full", compare_type = "and" } },
    targets = {
      { station = unload_station,
        wait_conditions = { { type = "empty", compare_type = "and" } } },
    },
    inside_interrupt = false,
  }

  -- Nom lisible du template (affiché dans la file / en-cours) : icône(s) wagon +
  -- N + variante. Sans ça, les trains STC apparaissent sans libellé (name nil).
  local tname = wagons .. " ×" .. n
    .. (model.storage and " [virtual-signal=stc2-storage]" or "")

  return {
    name        = tname,
    stock       = stock,
    horizontal  = true,
    schedules   = { { schedule = { records = records,
                                   group = group_name,
                                   interrupts = interrupts } } },
    -- Déclenche le dialogue de choix de la ressource (même flux que les BP
    -- paramétrés). subst_station remplacera [item=parameter-0] selon le type
    -- (item ou fluid) du signal choisi.
    parameters  = { { type = "id", id = "parameter-0" } },
    source_kind = "stc",
    created_tick = game.tick,
  }
end

return stc_template
