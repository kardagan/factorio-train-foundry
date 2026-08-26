-- ===========================================================================
-- Modèle de train « STC » -> template synthétique
-- ---------------------------------------------------------------------------
-- Convertit une FORME de train en un objet compatible avec l'interface
-- `template` attendue par builder.lua (.stock, .horizontal, .schedules,
-- .parameters). Deux sources de formes :
--
--   * DÉFAUT (stc_template.build) : une « forme » lue chez Smart Train
--     Combinator (get_models). Composition imposée : 1 locomotive de tête + N
--     wagons, tous tournés vers l'ouest.
--   * CUSTOM (stc_template.build_custom) : une composition dessinée par le
--     joueur dans le composeur (plusieurs locos, locos en queue à contre-sens,
--     double traction...). Persistée dans state.custom.
--
-- Dans les DEUX cas l'itinéraire est le MÊME patron figé, calqué sur le
-- blueprint de référence du joueur : un record de chargement + trois
-- interruptions (Refuel / stop / déchargement), un groupe. Il ne dépend que de
-- la FORME LOGIQUE (kind, type et qualité de wagon, nombre de wagons, segment
-- group) — pas du nombre de locos ni de leur orientation, qui n'apparaissent
-- dans aucun nom de gare. C'est ce qui permet à un train custom de se poser sur
-- exactement les mêmes gares STC qu'un train par défaut de même forme.
--
-- La ressource reste le paramètre `parameter-0` — la substitution est faite par
-- builder.spawn via subst_station (comme un blueprint paramétré), donc le joueur
-- choisit la ressource dans le dialogue habituel.
--
-- Ce qui VARIE selon la forme : le kind (item/fluid → [item=]/[fluid=]), le
-- nombre d'icônes wagon (N), le segment `group` (renvoyé déjà rendu par STC,
-- non interprété ; reconstruit à l'identique pour un custom), et le nom de
-- l'interruption de déchargement (kind+group+N).
--
-- Carburant : PAS géré ici (plus de choix, plus de fuel-request). Le remplissage
-- est fait par builder (meilleur carburant débloqué compatible dispo). Ici on ne
-- produit QUE l'interruption Refuel : elle liste tous les carburants du jeu que
-- les locos peuvent brûler (condition ≤ 10 % du plein de CE carburant), et
-- reprend sur la condition native `fuel_full`. Omise si AUCUNE loco n'a de
-- burner (ex. train 100 % solaire).
-- ===========================================================================

local names = require("names")

local stc_template = {}

-- Préfixe TF collé devant le nom de groupe ET chaque nom d'interruption, pour
-- repérer d'un coup d'œil les trains/interruptions issus d'une fonderie. On
-- privilégie l'icône de l'entité (names.building) ; repli sur l'item de même nom,
-- puis rien (un sprite rich-text invalide ne planterait qu'à l'AFFICHAGE).
-- Calculé une fois, mémoïsé (les prototypes ne changent pas en cours de partie).
local tf_prefix_cache = nil
local function tf_prefix()
  if tf_prefix_cache ~= nil then return tf_prefix_cache end
  for _, tag in ipairs({ "[entity=" .. names.building .. "]",
                         "[item=" .. names.building .. "]" }) do
    local path = tag:sub(2, -2):gsub("=", "/")  -- "entity/<building>"
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
-- du jeu. Un template CUSTOM n'en dépend pas : le joueur y choisit ses locos.
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

-- Profil carburant d'un STOCK complet (plusieurs locos possibles, de types
-- différents) : UNION des carburants brûlables et MAX des nombres de slots.
--   * union : l'interruption Refuel doit couvrir tout ce que le train peut
--     brûler ; un carburant qu'une seule des locos accepte reste pertinent ;
--   * max des slots : la condition `fuel_item_count_any` se déclenche dès qu'UNE
--     loco descend sous le seuil. Calibrer le seuil sur la loco la PLUS capable
--     (max) fait partir au ravitaillement un peu tôt pour les plus petites, ce
--     qui est le bon sens de l'erreur — l'inverse laisserait une grosse loco
--     tomber en panne sèche avant d'atteindre le seuil.
-- Retourne { fuels = <liste triée>, slots = <int> } ; fuels vide si aucune loco
-- n'a de burner (train solaire → pas d'interruption Refuel).
local function fuel_profile(stock)
  local seen, fuels, slots = {}, {}, 0
  for _, s in ipairs(stock or {}) do
    local proto = prototypes.entity[s.name]
    if proto and proto.type == "locomotive" then
      slots = math.max(slots, fuel_slots(s.name))
      for _, f in ipairs(compatible_fuels(s.name)) do
        if not seen[f.name] then
          seen[f.name] = true
          fuels[#fuels + 1] = f
        end
      end
    end
  end
  table.sort(fuels, function(a, b)
    if a.fuel_value ~= b.fuel_value then return a.fuel_value > b.fuel_value end
    return a.name < b.name   -- ordre TOTAL : deux carburants de même valeur ne
  end)                       -- doivent pas dépendre de l'ordre d'itération
  return { fuels = fuels, slots = slots }
end

-- Item de placement d'un wagon — MÊME logique que STC (wagon_item_name) pour que
-- le tag soit BYTE-IDENTIQUE à ce que STC met dans ses noms de gares (matching
-- des interruptions). En 2.0 le champ est items_to_place_this[1].item (PAS .name).
local function wagon_item_name(proto, entity_name)
  local place = proto.items_to_place_this
  if place and place[1] and place[1].item then return place[1].item end
  local mp = proto.mineable_properties
  if mp and mp.products then
    for _, p in ipairs(mp.products) do
      if p.type == "item" and p.name then return p.name end
    end
  end
  if prototypes.item[entity_name] then return entity_name end
  return nil
end

-- Suffixe de qualité d'un tag rich-text. Émis UNIQUEMENT pour une qualité NON
-- normale : une forme en qualité normale doit continuer à produire la chaîne
-- d'avant la qualité, sinon tous les noms de gares existants (et les
-- interruptions écrites à la main qui les visent) changeraient. MÊME règle que
-- STC quality_suffix — le matching des gares est une comparaison byte-à-byte.
local function quality_suffix(quality)
  return (quality and quality ~= "normal") and (",quality=" .. quality) or ""
end

-- Tag rich-text d'un matériel roulant, qualité comprise : [item=<place-item>],
-- repli [entity=]. Sert aux noms de gares (wagons) ET aux libellés lisibles
-- (locos d'un template custom).
local function stock_tag(entity_name, quality)
  local suffix = quality_suffix(quality)
  local proto = prototypes.entity[entity_name]
  local item = proto and wagon_item_name(proto, entity_name)
  if item then return "[item=" .. item .. suffix .. "]" end
  return "[entity=" .. entity_name .. suffix .. "]"
end

-- Run d'icône wagon dans le nom : jusqu'à 5 icônes répétées (format HISTORIQUE de
-- STC, inchangé → compat des gares/interruptions existantes préservée), au-delà
-- "icône×N" (compact, sinon le nom dépasse la limite ~200 car et est tronqué
-- mid-tag ; le × est U+00D7, pas un x ASCII). MÊME règle et MÊME seuil que STC
-- wagon_run, suffixe de qualité inclus. [item=<place-item>], repli [entity=].
-- wagon_item_name = même résolution que STC (champ .item en 2.0).
local WAGON_ICON_MAX = 5
local function wagon_run(wagon_type, n, quality)
  local tag = stock_tag(wagon_type, quality)
  if n <= WAGON_ICON_MAX then return string.rep(tag, n) end
  return tag .. "×" .. n
end

stc_template.wagon_run = wagon_run

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

-- ---------------------------------------------------------------------------
-- FORME LOGIQUE
-- ---------------------------------------------------------------------------
-- Une « forme » est le seul intrant des noms de gares :
--   { kind, wagon_type, wagon_quality, wagons, group, storage }
-- C'est exactement la structure renvoyée par get_models chez STC. Un template
-- custom en dérive une équivalente pour retomber sur les MÊMES noms de gares.

-- Segment `group` d'une forme custom. MÊME règle que STC group_segment (v1 :
-- dérivé du seul marqueur storage) — reconstruit ici, car un custom n'est pas
-- lu chez STC. C'est la couture à élargir si STC généralise ses segments.
local function group_segment(is_storage)
  return is_storage and "[virtual-signal=stc2-storage]" or ""
end

-- Kind d'un type de wagon : les citernes portent des fluides, tout le reste des
-- items. C'est ce qui décide du tag de ressource ([fluid=] vs [item=]) et du
-- picker proposé au joueur.
local function kind_of(wagon_type)
  local proto = prototypes.entity[wagon_type]
  return (proto and proto.type == "fluid-wagon") and "fluid" or "item"
end

stc_template.kind_of = kind_of

-- ---------------------------------------------------------------------------
-- ITINÉRAIRE (patron figé, commun défaut / custom)
-- ---------------------------------------------------------------------------

-- Nom de gare de CHARGEMENT d'une forme. Ressource = parameter-0, substituée par
-- builder.spawn / subst_station à la mise en file. SEULE définition de ce nom : il
-- sert à l'itinéraire ET à l'aperçu du composeur, et ces deux-là doivent être le
-- même octet pour octet.
local function load_station_of(shape)
  return "[item=parameter-0]" .. (shape.group or "")
    .. "[virtual-signal=stc2-load]"
    .. wagon_run(shape.wagon_type, shape.wagons, shape.wagon_quality)
end

-- Nom de gare de chargement, pour l'aperçu du composeur : le joueur voit tout de
-- suite si le nom généré correspond à ses gares STC.
stc_template.load_station = load_station_of

-- Construit { records, group, interrupts } pour une forme donnée. `prof` = profil
-- carburant du stock (fuel_profile) : il ne pilote QUE l'interruption Refuel.
local function schedule_for(shape, prof)
  local n      = shape.wagons
  local wagons = wagon_run(shape.wagon_type, n, shape.wagon_quality)
  local group  = shape.group or ""
  local prefix = tf_prefix()  -- icône TF devant le groupe et les interruptions

  local load_station = load_station_of(shape)

  -- Nom de GROUPE : il DOIT encoder la forme, pas seulement la ressource — sinon
  -- deux trains de même ressource mais de formes différentes tombent dans le même
  -- groupe et leurs interruptions (rattachées au groupe en 2.0) se mélangent.
  -- Ressource + "×N" (compact, comme le nom de gare — évite le débordement de
  -- longueur sur les trains longs) + segment storage : chaque (ressource, N,
  -- storage) a son propre groupe. Le nombre de LOCOS n'y entre pas : un train
  -- custom double-traction partage donc le groupe (et les interruptions) du train
  -- par défaut de même forme — c'est voulu, ils desservent les mêmes gares.
  local group_name = prefix .. group .. "[item=parameter-0]×" .. n

  local unload_name = prefix .. unload_icon() .. "[color=red]unload " .. kind_label(shape.kind)
    .. (shape.storage and " storage" or "") .. " " .. n .. "[/color]"
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
  -- une condition sur un carburant jamais présent est neutre. Omise si aucune loco
  -- n'a de burner (train solaire).
  if #prof.fuels > 0 and prof.slots > 0 then
    local conds = {}
    for _, f in ipairs(prof.fuels) do
      local threshold = math.max(1, math.ceil(f.stack_size * prof.slots * 0.10))
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
          -- fuel_full ET inactivity (AND, pas OR) : chez Nullius la loco reçoit des
          -- sous-produits à décharger sans qu'on sache quand c'est fini ; en OR,
          -- l'inactivité seule ferait repartir le train AVANT le plein. On exige
          -- donc le plein ET une pause d'inactivité.
          wait_conditions = {
            { type = "fuel_full", compare_type = "and" },
            { type = "inactivity", compare_type = "and", ticks = 300 },
          } },
      },
      inside_interrupt = true,
    }
  end

  -- Stop : destination pleine / sans chemin → parking temporaire. Gare nommée avec
  -- signal-hourglass (VANILLA, évoque l'attente) ×3 — auparavant signs-2 (mod
  -- « Signals extended », non dépendance → icône manquante hors de ce mod). Le nom
  -- exact importe peu, il doit juste être cohérent entre l'interruption et la gare
  -- de parking du joueur.
  interrupts[#interrupts + 1] = {
    name = prefix .. "[color=orange]stop[/color]",
    conditions = {
      { type = "destination_full_or_no_path", compare_type = "and" },
    },
    targets = {
      { station = "[virtual-signal=signal-hourglass][virtual-signal=signal-hourglass][virtual-signal=signal-hourglass]",
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

  return { records = records, group = group_name, interrupts = interrupts }
end

-- ---------------------------------------------------------------------------
-- TEMPLATE PAR DÉFAUT (forme lue chez Smart Train Combinator)
-- ---------------------------------------------------------------------------

-- `model` = une entrée de get_models { kind, wagon_type, wagon_quality, wagons,
-- group, storage }.
function stc_template.build(model)
  local n      = math.max(1, model.wagons or 1)
  local loco   = locomotive_for(model.wagon_type)
  local wagons = wagon_run(model.wagon_type, n, model.wagon_quality)

  -- --- .stock : loco (tête) + N wagons -----------------------------------
  -- Aucun carburant ici : builder remplit avec le meilleur carburant débloqué
  -- dispo au spawn. Le stock ne porte que les véhicules.
  local stock = { { name = loco, orientation = LOCO_ORIENT,
                    quality = model.wagon_quality } }
  for _ = 1, n do
    stock[#stock + 1] = { name = model.wagon_type, orientation = WAGON_ORIENT,
                          quality = model.wagon_quality }
  end

  local shape = {
    kind = model.kind, wagon_type = model.wagon_type,
    wagon_quality = model.wagon_quality, wagons = n,
    group = model.group or "", storage = model.storage,
  }

  -- Nom lisible du template (affiché dans la file / en-cours) : icône(s) wagon +
  -- N + variante. Sans ça, les trains STC apparaissent sans libellé (name nil).
  local tname = wagons .. " ×" .. n
    .. (model.storage and " [virtual-signal=stc2-storage]" or "")

  return {
    name        = tname,
    stock       = stock,
    horizontal  = true,
    schedules   = { { schedule = schedule_for(shape, fuel_profile(stock)) } },
    -- Déclenche le dialogue de choix de la ressource (même flux que les BP
    -- paramétrés). subst_station remplacera [item=parameter-0] selon le type
    -- (item ou fluid) du signal choisi.
    parameters  = { { type = "id", id = "parameter-0" } },
    source_kind = "stc",
    created_tick = game.tick,
  }
end

-- ---------------------------------------------------------------------------
-- TEMPLATE CUSTOM (composition dessinée par le joueur)
-- ---------------------------------------------------------------------------
-- Un custom persisté (state.custom[i]) a la forme :
--   { id = <int>, name = "<libre>", storage = <bool>,
--     slots = { { name = "<entité>", quality = "<qualité>", flip = <bool> }, ... } }
-- L'ordre des slots va de l'OUEST (tête, côté de la première case du composeur)
-- vers l'EST. `flip` ne concerne que les locos : true = tournée vers l'est
-- (contre-sens, loco de queue d'un train à double traction).

-- Classe un slot : "loco", "wagon" ou nil (prototype disparu / type non géré).
local function slot_class(slot)
  local proto = slot and slot.name and prototypes.entity[slot.name]
  if not proto then return nil end
  if proto.type == "locomotive" then return "loco" end
  if proto.type == "cargo-wagon" or proto.type == "fluid-wagon" then return "wagon" end
  return nil
end

stc_template.slot_class = slot_class

-- Analyse une composition custom. Retourne :
--   shape ou nil, err
-- où `err` est le SUFFIXE d'une clé de locale (tf-gui.custom-err-<err>).
--
-- Les règles interdisent tout ce qui ferait diverger le nom de gare généré du
-- nommage STC : un seul type de wagon (donc pas de mélange citerne/wagon, ni de
-- mélange de tiers), une seule qualité de wagon (le nom n'en encode qu'une). Les
-- LOCOS sont libres (type, tier, qualité) : elles n'apparaissent dans aucun nom.
function stc_template.shape_of(custom)
  local slots = (custom and custom.slots) or {}
  local wagon_type, wagon_quality, n_wagons, n_locos = nil, nil, 0, 0
  -- Intersection des catégories de carburant des locos À BURNER. builder facture
  -- et insère UN SEUL carburant pour tout le train : si deux locos n'ont aucune
  -- catégorie commune, celle qui refuse le carburant retenu partirait à sec alors
  -- que son plein a été prélevé de la réserve. On refuse donc le mélange. Une loco
  -- sans burner (solaire) est neutre : elle n'a rien à recevoir.
  local fuel_cats, n_burners = nil, 0
  for _, s in ipairs(slots) do
    local class = slot_class(s)
    if not class then return nil, "bad-slot" end
    if class == "loco" then
      n_locos = n_locos + 1
      local burner = prototypes.entity[s.name].burner_prototype
      if burner and burner.fuel_categories then
        n_burners = n_burners + 1
        if fuel_cats == nil then
          fuel_cats = {}
          for cat in pairs(burner.fuel_categories) do fuel_cats[cat] = true end
        else
          for cat in pairs(fuel_cats) do
            if not burner.fuel_categories[cat] then fuel_cats[cat] = nil end
          end
        end
      end
    else
      local q = s.quality or "normal"
      if wagon_type == nil then
        wagon_type, wagon_quality = s.name, q
      else
        if s.name ~= wagon_type then return nil, "mixed-wagons" end
        if q ~= wagon_quality then return nil, "mixed-quality" end
      end
      n_wagons = n_wagons + 1
    end
  end
  if n_locos == 0 then return nil, "no-loco" end
  if n_wagons == 0 then return nil, "no-wagon" end
  if n_burners > 1 and not next(fuel_cats or {}) then
    return nil, "mixed-fuel"
  end
  return {
    kind = kind_of(wagon_type),
    wagon_type = wagon_type,
    wagon_quality = wagon_quality,
    wagons = n_wagons,
    group = group_segment(custom.storage),
    storage = not not custom.storage,
  }
end

-- Libellé lisible d'un custom : son nom s'il en a un, sinon les icônes de la
-- composition (locos groupées + run de wagons). Affiché dans la liste, la file
-- et le panneau « en cours ».
function stc_template.custom_caption(custom, shape)
  if custom.name and custom.name ~= "" then return custom.name end
  if not shape then return "" end
  -- Locos groupées par (type, qualité), dans l'ordre de rencontre : une double
  -- traction homogène s'écrit « [loco]×2 », pas deux icônes identiques.
  local order, seen = {}, {}
  for _, s in ipairs(custom.slots or {}) do
    if slot_class(s) == "loco" then
      local tag = stock_tag(s.name, s.quality)
      if seen[tag] then
        order[seen[tag]].count = order[seen[tag]].count + 1
      else
        order[#order + 1] = { tag = tag, count = 1 }
        seen[tag] = #order
      end
    end
  end
  local parts = {}
  for _, g in ipairs(order) do
    parts[#parts + 1] = g.tag .. ((g.count > 1) and ("×" .. g.count) or "")
  end
  parts[#parts + 1] = wagon_run(shape.wagon_type, shape.wagons, shape.wagon_quality)
    .. " ×" .. shape.wagons
  if shape.storage then parts[#parts + 1] = "[virtual-signal=stc2-storage]" end
  return table.concat(parts, " ")
end

-- Template synthétique d'une composition custom. Retourne nil, err si la
-- composition est invalide (mêmes codes que shape_of) — l'appelant refuse alors
-- la mise en file.
function stc_template.build_custom(custom)
  local shape, err = stc_template.shape_of(custom)
  if not shape then return nil, err end

  -- --- .stock : les slots dans l'ordre, orientation par slot ---------------
  -- Contrairement au template par défaut (tout vers l'ouest), l'orientation est
  -- SIGNIFIANTE ici : c'est elle qui fait une loco de queue à contre-sens. D'où
  -- `free_orientation` plus bas, qui demande à builder.spawn de la respecter
  -- (et de la refléter quand le train sort à droite).
  local stock = {}
  for _, s in ipairs(custom.slots) do
    stock[#stock + 1] = {
      name = s.name,
      quality = s.quality,
      orientation = s.flip and WAGON_ORIENT or LOCO_ORIENT,
    }
  end

  return {
    name        = stc_template.custom_caption(custom, shape),
    stock       = stock,
    horizontal  = true,
    schedules   = { { schedule = schedule_for(shape, fuel_profile(stock)) } },
    parameters  = { { type = "id", id = "parameter-0" } },
    source_kind = "stc",
    -- builder.spawn : respecte l'orientation de chaque véhicule au lieu de
    -- coucher tout le train vers l'ouest (voir la logique flip_east).
    free_orientation = true,
    custom_id   = custom.id,
    created_tick = game.tick,
  }
end

return stc_template
