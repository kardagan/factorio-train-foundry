-- Train Foundry — construction des trains.
--
-- Briques composables utilisées par la boucle de production (control.lua) :
--   compute_need  : items requis par un template
--   missing       : ce qui manque dans la réserve
--   consume/refund: prélève / rend les composants
--   track_free    : la voie interne est-elle libre ?
--   exit_open     : le bloc de sortie est-il libre ?
--   spawn         : matérialise le train (véhicules, couleurs, fuel,
--                   itinéraire, interruptions, groupe, paramètres)
-- try_spawn (immédiat, tout-en-un) reste exposé pour l'interface remote et
-- les tests.

local builder = {}

local STOCK_TYPES = { "locomotive", "cargo-wagon", "fluid-wagon",
                      "artillery-wagon" }

-- Géométrie : voie interne sur la rangée +5, utilisable du mur ouest (-16)
-- au bout des rails (+18). Tête du train à l'ouest, véhicules espacés de 7.
local RAIL_Y = 5
local DECO_RAIL_Y = 1   -- 2e voie (recyclage), doit coïncider avec composite
local HEAD_X = -12
local SPACING = 7
-- Longueur max d'un train (nombre de véhicules) par MODULE. La capacité réelle
-- d'une fonderie = PER_MODULE × (1 + nombre d'extensions accolées).
builder.MAX_STOCK = 5
local PER_MODULE = builder.MAX_STOCK

-- Capacité (véhicules max) d'une chaîne : base + une portion par extension.
-- `state` est le master (celui qui porte extensions/queue/work).
function builder.capacity(state)
  local n_ext = (state and state.extensions and #state.extensions) or 0
  return PER_MODULE * (1 + n_ext)
end

-- Durée de construction : 4 s par véhicule.
builder.TICKS_PER_VEHICLE = 240

-- Inventaire de la réserve : le coffre de fer sur le parvis.
local function shared_inventory(state)
  local chest = state.input
  if chest and chest.valid then
    return chest.get_inventory(defines.inventory.chest)
  end
end

-- Recopie la grille d'équipement du blueprint dans le véhicule construit
-- (mods type Vehicle Equipment Grids). grid_data = array de
-- {equipment=<{name,quality} ou string>, position={x,y}} tel que renvoyé par
-- get_blueprint_entities(). Défensif : rien si le véhicule n'a pas de grille,
-- on saute les équipements absents de la partie (mod retiré), et chaque pose
-- est protégée (quality inconnue = erreur possible).
local function apply_grid(entity, grid_data)
  if not grid_data then return end
  local grid = entity.grid
  if not grid then return end
  for _, comp in pairs(grid_data) do
    local eq = comp.equipment
    local name = (type(eq) == "table") and eq.name or eq
    local quality = (type(eq) == "table") and eq.quality or nil
    if name and prototypes.equipment[name] then
      pcall(function()
        grid.put({ name = name, quality = quality, position = comp.position })
      end)
    end
  end
end

-- L'item qui pose cette entité (ex. locomotive nullius = item du même nom ;
-- on passe par items_to_place_this pour les mods qui divergent).
local function place_item_for(entity_name)
  local proto = prototypes.entity[entity_name]
  local items = proto and proto.items_to_place_this
  if items and items[1] then return items[1].name end
  return entity_name
end

-- Item requests d'une entité du blueprint (carburant des locos, munitions
-- d'un wagon d'artillerie...) : map item -> quantité totale.
local function requested_items(s)
  local out = {}
  for _, req in pairs(s.items or {}) do
    local name = req.id and req.id.name
    local total = 0
    local positions = req.items and req.items.in_inventory
    if positions then
      for _, pos in pairs(positions) do
        total = total + (pos.count or 1)
      end
    end
    if name and total > 0 then
      out[name] = (out[name] or 0) + total
    end
  end
  return out
end

-- Le template porte-t-il un carburant blueprinté (au moins une item-request qui
-- est un carburant) ? Sert au « générique implicite » : un BP SANS aucun
-- carburant se comporte comme générique même si l'option est décochée (rien à
-- respecter → on remplit au meilleur carburant dispo).
function builder.template_has_bp_fuel(template)
  for _, s in ipairs(template.stock or {}) do
    for name in pairs(requested_items(s)) do
      local it = prototypes.item[name]
      if it and it.fuel_value and it.fuel_value > 0 then return true end
    end
  end
  return false
end

-- Cache équipement -> item qui le pose. Un équipement est placé par l'item
-- dont le prototype a placed_as_equipment_result = <cet équipement>. À défaut
-- (mapping introuvable), on retombe sur un item de même nom si présent.
local equipment_item_cache = nil
local function build_equipment_item_map()
  local map = {}
  for item_name, proto in pairs(prototypes.item) do
    local eq = proto.place_as_equipment_result
    if eq then map[eq.name] = item_name end
  end
  return map
end
local function item_for_equipment(eq_name)
  equipment_item_cache = equipment_item_cache or build_equipment_item_map()
  if equipment_item_cache[eq_name] then return equipment_item_cache[eq_name] end
  if prototypes.item[eq_name] then return eq_name end
  return nil
end

-- Équipements présents dans la grille d'un véhicule du blueprint : map item de
-- l'équipement -> quantité. Ce qui alimente la réserve exactement comme le
-- carburant (compté, consommé, remboursé) — plus de génération « par magie ».
local function grid_items(s)
  local out = {}
  for _, comp in pairs(s.grid or {}) do
    local eq = comp.equipment
    local eq_name = (type(eq) == "table") and eq.name or eq
    if eq_name then
      local item = item_for_equipment(eq_name)
      if item then out[item] = (out[item] or 0) + 1 end
    end
  end
  return out
end

-- ===========================================================================
-- Carburant générique
-- ---------------------------------------------------------------------------
-- Le carburant du train n'est plus un item figé (ni celui du blueprint, ni un
-- choix manuel) : on remplit chaque loco à plein avec le MEILLEUR carburant
-- débloqué compatible présent dans la réserve. Une loco sans burner (ex. loco
-- solaire) n'a aucun besoin de carburant.
-- ===========================================================================

-- Catégories de carburant acceptées par les LOCOMOTIVES du stock (set
-- fuel_category -> true). Vide si aucune loco à burner (ex. loco solaire).
local function compatible_fuel_categories(stock)
  local cats = {}
  for _, s in ipairs(stock or {}) do
    local proto = prototypes.entity[s.name]
    local burner = proto and proto.burner_prototype
    if burner and burner.fuel_categories then
      for cat in pairs(burner.fuel_categories) do cats[cat] = true end
    end
  end
  return cats
end
builder.compatible_fuel_categories = compatible_fuel_categories

-- Carburants DÉBLOQUÉS (une recette enabled de la force les produit) dont la
-- catégorie est acceptée par les locos, triés par pouvoir calorifique décroissant
-- (meilleur rendement d'abord). `cats` = set renvoyé par compatible_fuel_categories.
local function unlocked_fuels(force, cats)
  if not next(cats) then return {} end
  -- Ensemble des items produits par une recette activée de la force.
  local producible = {}
  for _, recipe in pairs(force.recipes) do
    if recipe.enabled then
      for _, p in pairs(recipe.products) do
        if p.type == "item" and p.name then producible[p.name] = true end
      end
    end
  end
  local out = {}
  for name in pairs(producible) do
    local it = prototypes.item[name]
    if it and it.fuel_value and it.fuel_value > 0
       and it.fuel_category and cats[it.fuel_category] then
      out[#out + 1] = { name = name, fuel_value = it.fuel_value }
    end
  end
  table.sort(out, function(a, b) return a.fuel_value > b.fuel_value end)
  return out
end
builder.unlocked_fuels = unlocked_fuels

-- Nombre de slots de carburant d'une loco (0 si pas de burner).
local function loco_fuel_slots(loco_name)
  local proto = prototypes.entity[loco_name]
  if not (proto and proto.burner_prototype) then return 0 end
  local n = proto.get_inventory_size(defines.inventory.fuel)
  return n or 0
end

-- Quantité de `fuel` (item) nécessaire pour remplir À PLEIN toutes les locos du
-- stock : Σ slots(loco) × stack_size(fuel).
local function loco_fuel_capacity(stock, fuel)
  local stack = prototypes.item[fuel] and prototypes.item[fuel].stack_size or 0
  if stack <= 0 then return 0 end
  local slots = 0
  for _, s in ipairs(stock or {}) do
    slots = slots + loco_fuel_slots(s.name)
  end
  return slots * stack
end
builder.loco_fuel_capacity = loco_fuel_capacity

-- Items requis par le template. `generic` = mode carburant générique :
--   true  (STC toujours, ou BP avec l'option cochée) → le carburant des
--         item-requests du blueprint est IGNORÉ (géré par le volet need.fuel :
--         meilleur carburant débloqué dispo) ;
--   false (BP option décochée, défaut) → comportement 0.5.x : le carburant
--         blueprinté est COMPTÉ comme un composant (need.items) et inséré tel
--         quel au spawn ; PAS de volet need.fuel, PAS d'interruption Refuel.
function builder.compute_need(template, generic)
  local need = {}
  local items = {}
  for _, s in ipairs(template.stock) do
    local item = place_item_for(s.name)
    items[item] = (items[item] or 0) + 1
    for name, n in pairs(requested_items(s)) do
      local it = prototypes.item[name]
      local is_fuel = it and it.fuel_value and it.fuel_value > 0
      -- En générique on ignore le carburant du BP (volet fuel s'en charge) ; en
      -- mode BP historique on le garde comme composant.
      if (not is_fuel) or (not generic) then
        items[name] = (items[name] or 0) + n
      end
    end
    for name, n in pairs(grid_items(s)) do
      items[name] = (items[name] or 0) + n
    end
  end
  need.items = items
  -- Volet carburant générique : SEULEMENT en mode générique, et s'il y a une loco
  -- à burner (nil pour loco solaire).
  if generic then
    local cats = compatible_fuel_categories(template.stock)
    if next(cats) then
      need.fuel = { categories = cats, stock = template.stock }
    end
  end
  return need
end

-- Choisit le meilleur carburant débloqué compatible PRÉSENT en réserve en
-- quantité suffisante pour remplir toutes les locos à plein. Retourne
-- item_name, capacity (quantité pour le plein) ou nil si aucun ne convient.
-- `candidates` peut être fourni (déjà trié) pour éviter de recalculer.
local function pick_fuel(state, fuel_need)
  local inv = shared_inventory(state)
  if not inv then return nil end
  local force = state.entity and state.entity.valid and state.entity.force
  if not force then return nil end
  local candidates = unlocked_fuels(force, fuel_need.categories)
  for _, c in ipairs(candidates) do  -- meilleur fuel_value d'abord
    local cap = loco_fuel_capacity(fuel_need.stock, c.name)
    if cap > 0 and inv.get_item_count(c.name) >= cap then
      return c.name, cap
    end
  end
  return nil
end
builder.pick_fuel = pick_fuel

-- Détail des carburants candidats pour l'affichage / le circuit : pour chaque
-- carburant débloqué compatible, son plein (Σ slots×stack) et ce que la réserve
-- en a. Trié par fuel_value décroissant. {} si pas de besoin carburant.
function builder.fuel_candidates(state, need)
  if not (need and need.fuel) then return {} end
  local inv = shared_inventory(state)
  local force = state.entity and state.entity.valid and state.entity.force
  if not force then return {} end
  local out = {}
  for _, c in ipairs(unlocked_fuels(force, need.fuel.categories)) do
    local full = loco_fuel_capacity(need.fuel.stock, c.name)
    if full > 0 then
      out[#out + 1] = {
        name = c.name,
        need = full,
        have = inv and inv.get_item_count(c.name) or 0,
      }
    end
  end
  return out
end

-- Ce qui manque dans la réserve. Retourne :
--   miss       : map item -> quantité manquante (composants)
--   caption    : chaîne rich-text prête à afficher ("" si rien ne manque)
--   fuel_item  : carburant retenu pour le plein (nil si pas de besoin carburant
--                OU aucun carburant compatible débloqué dispo en quantité suffisante)
--   fuel_short : true si un carburant EST requis mais aucun candidat ne convient
-- Deux lignes dans la caption : composants, puis carburant (si manquant).
function builder.missing(state, need)
  local inv = shared_inventory(state)
  local items = need.items or need   -- compat : ancien need plat = les items
  local miss, parts = {}, {}
  for item, n in pairs(items) do
    local have = inv and inv.get_item_count(item) or 0
    if have < n then
      miss[item] = n - have
      parts[#parts + 1] = "[item=" .. item .. "]×" .. (n - have)
    end
  end

  local fuel_item, fuel_short, fuel_caption = nil, false, ""
  if need.fuel then
    fuel_item = pick_fuel(state, need.fuel)
    if not fuel_item then
      fuel_short = true
      -- Besoin d'un carburant, aucun candidat dispo en réserve : liste des
      -- carburants compatibles débloqués (rich-text) pour guider le joueur.
      local force = state.entity and state.entity.valid and state.entity.force
      local cands = force and unlocked_fuels(force, need.fuel.categories) or {}
      local icons = {}
      for _, c in ipairs(cands) do icons[#icons + 1] = "[item=" .. c.name .. "]" end
      fuel_caption = (#icons > 0) and table.concat(icons, " / ") or "?"
    end
  end

  return miss, table.concat(parts, "  "), fuel_item, fuel_short, fuel_caption
end

-- Consomme les composants + le plein du carburant retenu (fuel_item, quantité
-- calculée depuis le stock). fuel_item peut être nil (pas de besoin carburant).
function builder.consume(state, need, fuel_item)
  local inv = shared_inventory(state)
  if not inv then return end
  local items = need.items or need
  for item, n in pairs(items) do
    inv.remove({ name = item, count = n })
  end
  if fuel_item and need.fuel then
    local cap = loco_fuel_capacity(need.fuel.stock, fuel_item)
    if cap > 0 then inv.remove({ name = fuel_item, count = cap }) end
  end
end

-- Rend les composants + le carburant consommé (annulation). Ce qui ne rentre
-- plus dans la réserve est déversé au sol. `fuel_item` = carburant consommé (nil
-- si aucun).
function builder.refund(state, need, fuel_item)
  local inv = shared_inventory(state)
  local e = state.entity
  local items = need.items or need
  local to_refund = {}
  for item, n in pairs(items or {}) do to_refund[item] = n end
  if fuel_item and need.fuel then
    local cap = loco_fuel_capacity(need.fuel.stock, fuel_item)
    if cap > 0 then to_refund[fuel_item] = (to_refund[fuel_item] or 0) + cap end
  end
  for item, n in pairs(to_refund) do
    local inserted = inv and inv.insert({ name = item, count = n }) or 0
    if inserted < n and e and e.valid then
      e.surface.spill_item_stack({
        position = e.position,
        stack = { name = item, count = n - inserted },
        enable_looted = true,
        force = e.force,
      })
    end
  end
end

-- Largeur d'un module (doit coïncider avec composite.MODULE_WIDTH).
local MODULE_WIDTH = 40

-- La voie interne est-elle libre de tout véhicule ? La zone s'étend vers l'est
-- d'un module par extension accolée (voie continue de toute la chaîne).
function builder.track_free(state)
  local e = state.entity
  if not (e and e.valid) then return false end
  local n_ext = (state.extensions and #state.extensions) or 0
  -- Borne est étendue de +18 à +21 : la sortie est prolonge la voie au-delà du
  -- bord (jusqu'à +21), un véhicule y stationnant doit être détecté.
  local area = {
    { e.position.x - 18, e.position.y + RAIL_Y - 1.5 },
    { e.position.x + 21 + n_ext * MODULE_WIDTH, e.position.y + RAIL_Y + 1.5 },
  }
  return #e.surface.find_entities_filtered({
    type = STOCK_TYPES, area = area }) == 0
end

-- Zone de la voie interne (même calcul que track_free) — factorisé pour clear_track.
local function internal_track_area(state)
  local e = state.entity
  local n_ext = (state.extensions and #state.extensions) or 0
  return {
    { e.position.x - 18, e.position.y + RAIL_Y - 1.5 },
    { e.position.x + 21 + n_ext * MODULE_WIDTH, e.position.y + RAIL_Y + 1.5 },
  }
end

-- Détruit une liste de véhicules et REMBOURSE leur coût dans la réserve : l'item
-- de placement de chaque véhicule + le contenu de tous ses inventaires (carburant,
-- cargaison, munitions). Débordement déversé au sol (via builder.refund). Retourne
-- le nombre de véhicules retirés. Cœur partagé par clear_track (voie d'assemblage)
-- et check_recycle (voie de recyclage).
function builder.scrap_vehicles(state, vehicles)
  if not vehicles or #vehicles == 0 then return 0 end
  local refund = {}
  local function add(name, n)
    if name and n and n > 0 then refund[name] = (refund[name] or 0) + n end
  end
  local count = 0
  for _, v in ipairs(vehicles) do
    if v.valid then
      count = count + 1
      add(place_item_for(v.name), 1)  -- le véhicule lui-même
      -- Contenu de tous ses inventaires (fuel, cargo, munitions...).
      for i = 1, v.get_max_inventory_index() do
        local inv = v.get_inventory(i)
        if inv then
          -- get_contents (2.0) = liste de { name, count, quality }.
          for _, it in pairs(inv.get_contents()) do add(it.name, it.count) end
        end
      end
    end
  end
  for _, v in ipairs(vehicles) do if v.valid then v.destroy() end end
  builder.refund(state, { items = refund })
  return count
end

-- « Nettoyer » : détruit + rembourse tout le matériel roulant coincé sur la voie
-- d'ASSEMBLAGE (bouton GUI pour débloquer la production). Retourne le nombre retiré.
function builder.clear_track(state)
  local e = state.entity
  if not (e and e.valid) then return 0 end
  return builder.scrap_vehicles(state, e.surface.find_entities_filtered({
    type = STOCK_TYPES, area = internal_track_area(state) }))
end

-- Aire INTERNE de la voie de RECYCLAGE (rangée DECO_RAIL_Y). Bornes -17..+17
-- (intérieur de l'enceinte) : un train sur le raccord EXTERNE (avant d'entrer)
-- n'est pas capté ; seul un train engagé DANS le hall l'est. Le signal de blocage
-- l'y garde piégé → immobile = à recycler.
local function recycle_area(state)
  local e = state.entity
  local n_ext = (state.extensions and #state.extensions) or 0
  return {
    { e.position.x - 17, e.position.y + DECO_RAIL_Y - 1.5 },
    { e.position.x + 17 + n_ext * MODULE_WIDTH, e.position.y + DECO_RAIL_Y + 1.5 },
  }
end

-- Déconstruction : tout train IMMOBILE dans l'aire interne de la voie de recyclage
-- est détruit + intégralement remboursé (tout le train). La voie est un cul-de-sac
-- dédié, avec un signal de blocage à l'entrée : un train immobile à l'intérieur
-- est forcément entré pour être recyclé (il ne peut plus repartir). On ne teste
-- donc PAS train.station (le train s'arrête souvent AU SIGNAL rouge, pas à la
-- gare). Un train de passage (en mouvement) ou resté sur le raccord externe
-- (hors aire) est ignoré. Appelé par on_nth_tick. Retourne le nombre scrapé.
function builder.check_recycle(state)
  local e = state.entity
  if not (state.deco and e and e.valid) then return 0 end
  if #(state.recycle_stops or {}) == 0 then return 0 end
  local scrapped = 0
  local seen = {}  -- évite de traiter deux fois le même train (plusieurs wagons)
  for _, v in ipairs(e.surface.find_entities_filtered({
    type = STOCK_TYPES, area = recycle_area(state) })) do
    if v.valid and v.train then
      local t = v.train
      local id = t.id
      if not seen[id] and math.abs(t.speed) < 0.01 then
        seen[id] = true
        scrapped = scrapped + builder.scrap_vehicles(state, t.carriages)
      end
    end
  end
  return scrapped
end

-- Le bloc de sortie est-il libre ? Avec deux sorties possibles (ouest/est), il
-- suffit qu'UN côté OUVERT ait son signal ouvert : le pathfinder choisira ce
-- côté selon le schedule. Un signal absent est traité comme ouvert (comme avant).
-- Un signal DÉTACHÉ (aucun rail connecté — ex. fonderie posée sans réseau câblé
-- côté sortie) ne gouverne aucun bloc : on le considère ouvert, sinon la
-- production serait bloquée SILENCIEUSEMENT en phase "ready". Dès que le joueur
-- câble sa voie, le signal s'attache et gouverne réellement le bloc.
local function signal_clear(sig)
  if sig and sig.valid then
    if #sig.get_connected_rails() == 0 then return true end
    return sig.signal_state == defines.signal_state.open
  end
  return true
end

function builder.exit_open(state)
  -- Garde-fou : un state non migré (ni exit_left ni exit_right) retombe sur le
  -- signal ouest seul, comportement historique. En pratique migrate_all remplit
  -- toujours ces champs avant le premier appel, mais on ne s'y fie pas.
  if not (state.exit_left or state.exit_right) then
    return signal_clear(state.signal)
  end
  local left_ok = state.exit_left and signal_clear(state.signal)
  local right_ok = state.exit_right and signal_clear(state.signal_east)
  return left_ok or right_ok
end

-- Substitution des paramètres de blueprint (BP paramétrés 2.0) : `params`
-- mappe l'ID de placeholder -> {type=, name=} choisi par le joueur. Le
-- placeholder est l'ID déclaré dans la section parameters du blueprint —
-- souvent l'icône d'origine (ex. signal-0). On remplace donc toute balise
-- rich-text et tout signal dont le nom correspond à un paramètre connu.
local RICH_KIND = { item = "item", fluid = "fluid", virtual = "virtual-signal" }

local function subst_station(name, params)
  if not (params and name) then return name end
  return (name:gsub("%[([%a%-]+)=([%w%-_]+)%]", function(kind, id)
    local p = params[id]
    if p and p.name then
      return "[" .. (RICH_KIND[p.type] or "item") .. "=" .. p.name .. "]"
    end
    return "[" .. kind .. "=" .. id .. "]"
  end))
end

local function subst_signal(sig, params)
  if params and sig and sig.name and params[sig.name] then
    local p = params[sig.name]
    if p.name then
      return { type = p.type, name = p.name }
    end
  end
  return sig
end

-- Matérialise le train du template sur la voie interne. Ne vérifie NI ne
-- consomme les composants (au caller de le faire) ; vérifie seulement que
-- la pose des véhicules réussit. Retourne "spawn-ok-departed" /
-- "spawn-ok-manual", ou nil, "clé-erreur".
-- `fuel_item` (optionnel) = carburant retenu par missing/consume, DÉJÀ prélevé
-- de la réserve ; on l'insère dans les locos jusqu'au plein. nil = pas de besoin
-- carburant (loco solaire) ou repli sur ce qui traîne en réserve.
-- `generic` = mode carburant générique (STC, ou BP option cochée). En mode BP
-- historique (generic=false), on insère le carburant BLUEPRINTÉ tel quel (les
-- item-requests fuel, déjà payées comme composants) et on ne fait NI remplissage
-- au meilleur carburant NI repli.
function builder.spawn(state, template, params, fuel_item, generic)
  local e = state.entity
  if not (e and e.valid) then return nil, "spawn-failed" end
  if #template.stock > builder.capacity(state) then
    return nil, "spawn-too-long"
  end
  local inv = shared_inventory(state)

  -- ORIENTATION au spawn.
  -- Le template est trié le long de l'axe (stock[1] = le plus à l'OUEST), et pour le
  -- BP l'horizontalité est GARANTIE à l'import (les BP verticaux sont refusés), donc
  -- l'orientation de chaque véhicule (s.orientation) a un sens est/ouest fiable.
  --
  -- flip_east = sortie DROITE seule → le train se retourne (miroir est-ouest) : la
  -- tête part à l'est et chaque orientation est inversée. Sinon (gauche seule ou les
  -- deux) → train tel quel, tête à l'ouest.
  --   - BP  : on RESPECTE l'orientation du véhicule (s.orientation), inversée si flip.
  --   - STC : pas d'orientation propre → ouest par défaut, est si flip.
  local flip_east = state.exit_right and not state.exit_left
  local is_stc = (template.source_kind == "stc")
  local count = #template.stock

  -- Orientation est/ouest d'un véhicule BP depuis son orientation Factorio (0..1) :
  -- 0.25 = est, 0.75 = ouest (voie horizontale). Défaut ouest.
  local function bp_dir(s)
    local o = s.orientation or 0.75
    return (math.abs(o - 0.25) < 0.26) and defines.direction.east
      or defines.direction.west
  end

  local spawned = {}
  for i, s in ipairs(template.stock) do
    local dir, slot
    if flip_east then
      slot = count - i          -- i=1 (tête BP, ouest) -> slot le plus à l'EST
      if is_stc then
        dir = defines.direction.east
      else
        -- miroir : on inverse l'orientation BP
        dir = (bp_dir(s) == defines.direction.east)
          and defines.direction.west or defines.direction.east
      end
    else
      slot = i - 1              -- i=1 (tête) le plus à l'ouest
      dir = is_stc and defines.direction.west or bp_dir(s)
    end
    local v = e.surface.create_entity({
      name = s.name,
      position = { e.position.x + HEAD_X + slot * SPACING,
                   e.position.y + RAIL_Y },
      direction = dir,
      force = e.force,
    })
    if not v then
      for _, w in ipairs(spawned) do
        if w.valid then w.destroy() end
      end
      return nil, "spawn-failed"
    end
    if s.color then v.color = s.color end
    -- Grille d'équipement du BP (mods type Vehicle Equipment Grids) : on la
    -- recopie dans la grille du véhicule si le prototype en a une.
    apply_grid(v, s.grid)
    spawned[#spawned + 1] = v
  end

  -- Remplissage. Deux volets :
  --  1) Item-requests NON-carburant du blueprint (munitions d'artillerie…) :
  --     déjà consommées de la réserve avec les composants, on les insère.
  --  2) Carburant : on remplit chaque loco À PLEIN avec `fuel_item` (déjà prélevé
  --     par consume). Repli si fuel_item nil : premier carburant compatible
  --     trouvé dans la réserve (prélevé au passage) — sécurité, ne devrait servir
  --     que pour un template legacy sans volet fuel.
  for i, v in ipairs(spawned) do
    for name, n in pairs(requested_items(template.stock[i])) do
      local ip = prototypes.item[name]
      local is_fuel = ip and ip.fuel_value and ip.fuel_value > 0
      -- Non-carburant (munitions…) : toujours inséré. Carburant du BP : inséré
      -- UNIQUEMENT en mode BP historique (generic=false) ; en générique le
      -- carburant est géré par fuel_item ci-dessous.
      if (not is_fuel) or (not generic) then
        v.insert({ name = name, count = n })
      end
    end
    -- Remplissage carburant GÉNÉRIQUE seulement (STC / BP option cochée). En mode
    -- BP historique, le carburant vient déjà des item-requests insérées ci-dessus.
    if generic and v.type == "locomotive" then
      local fi = v.get_fuel_inventory()
      if fi then
        if fuel_item then
          -- Plein avec le carburant retenu (déjà payé, on ne retouche pas la réserve).
          local stack = prototypes.item[fuel_item] and prototypes.item[fuel_item].stack_size or 0
          local slots = #fi
          if stack > 0 and slots > 0 then
            fi.insert({ name = fuel_item, count = stack * slots })
          end
        elseif inv then
          -- Repli : premier carburant compatible dispo en réserve, une pile.
          local bp = v.prototype.burner_prototype
          if bp then
            for _, it in pairs(inv.get_contents()) do
              local ip = prototypes.item[it.name]
              if ip and ip.fuel_category and bp.fuel_categories[ip.fuel_category] then
                local count = math.min(it.count, ip.stack_size)
                local inserted = fi.insert({ name = it.name, count = count })
                if inserted > 0 then inv.remove({ name = it.name, count = inserted }) end
                break
              end
            end
          end
        end
      end
    end
  end

  -- Itinéraire, interruptions puis groupe (ordre IMPORTANT : écrire
  -- train.schedule sort le train de son groupe ; inscrire le train dans un
  -- groupe inexistant crée ce groupe à partir du schedule ACTUEL du train).
  local train = spawned[1].train
  local departed = false
  if template.schedules and train then
    pcall(function()
      local sc = template.schedules[1] or {}
      local body = sc.schedule or sc
      local records = body.records
      local group = body.group or sc.group
      local interrupts = body.interrupts

      if not (records and #records > 0) then
        -- Train piloté par groupe et/ou interruptions, sans itinéraire de
        -- base (réseau logistique 2.0). On applique les interrupts et le
        -- groupe, puis on passe en automatique : un tel train roule sans
        -- aucun record — exiger des records ici le laisserait en manuel.
        if interrupts and #interrupts > 0 then
          pcall(function()
            local ls = train.get_schedule()
            for _, it in ipairs(interrupts) do
              ls.add_interrupt(it)
            end
          end)
        end
        if group and group ~= "" then
          pcall(function()
            train.group = subst_station(group, params)
          end)
        end
        if (group and group ~= "") or (interrupts and #interrupts > 0) then
          train.manual_mode = false
          departed = true
        end
        return
      end

      local clean = {}
      for _, r in ipairs(records) do
        local rec = {
          station = subst_station(r.station, params),
          temporary = r.temporary or nil,
        }
        if r.wait_conditions then
          rec.wait_conditions = {}
          for _, wc in ipairs(r.wait_conditions) do
            local cond = wc.condition
            if cond then
              cond = {
                comparator = cond.comparator,
                constant = cond.constant,
                first_signal = subst_signal(cond.first_signal, params),
                second_signal = subst_signal(cond.second_signal, params),
              }
            end
            rec.wait_conditions[#rec.wait_conditions + 1] = {
              type = wc.type,
              compare_type = wc.compare_type or "or",
              ticks = wc.ticks,
              condition = cond,
            }
          end
        end
        if rec.station then
          clean[#clean + 1] = rec
        end
      end
      if #clean == 0 then return end

      train.schedule = { current = 1, records = clean }
      if interrupts and #interrupts > 0 then
        pcall(function()
          local ls = train.get_schedule()
          for _, it in ipairs(interrupts) do
            ls.add_interrupt(it)
          end
        end)
      end
      if group and group ~= "" then
        pcall(function()
          train.group = subst_station(group, params)
        end)
      end
      train.manual_mode = false
      departed = true
    end)
  end

  return departed and "spawn-ok-departed" or "spawn-ok-manual"
end

-- Met à jour les signaux du connecteur circuit selon les cases cochées :
-- contenu du stock OU composants manquants, selon state.emit_mode
-- ("stock" ou "request"). Émis sur rouge ET vert identiquement (le moteur
-- ne sépare pas les fils). Pour ne rien émettre : ne pas brancher de câble.
function builder.update_circuit(state)
  local comb = state.combinator
  if not (comb and comb.valid) then return end
  local cb = comb.get_or_create_control_behavior()
  if not cb then return end
  local section = cb.get_section(1) or cb.add_section()
  if not section then return end

  local mode = state.emit_mode or "stock"

  local acc = {}  -- name -> quantité cumulée
  if mode == "stock" then
    local inv = shared_inventory(state)
    if inv then
      for _, it in pairs(inv.get_contents()) do
        acc[it.name] = (acc[it.name] or 0) + it.count
      end
    end
  end
  if mode == "request" then
    -- Composants manquants du travail EN ATTENTE uniquement. Un travail déjà
    -- en construction (phase building/ready) a déjà consommé ses composants
    -- dans la réserve → ne PAS les redemander (sinon on réclame le contenu
    -- d'un train déjà en cours).
    if state.work and state.work.phase == "waiting" and state.work.need then
      local miss = builder.missing(state, state.work.need)
      for item, n in pairs(miss) do acc[item] = (acc[item] or 0) + n end
      -- Carburant : on demande le PLEIN pour CHAQUE carburant candidat, pour
      -- qu'au moins un arrive par la logistique. Dès qu'un carburant satisfait le
      -- plein (have >= need), la prod part et ce bloc n'est plus atteint. On
      -- n'ajoute la demande que pour les carburants pas encore au plein.
      for _, f in ipairs(builder.fuel_candidates(state, state.work.need)) do
        if f.have < f.need then
          acc[f.name] = (acc[f.name] or 0) + (f.need - f.have)
        end
      end
    end
  end

  local filters = {}
  for name, count in pairs(acc) do
    if count ~= 0 then
      filters[#filters + 1] = {
        value = { type = "item", name = name, quality = "normal" },
        min = count,
      }
    end
  end
  section.filters = filters
end

-- Construction immédiate tout-en-un (interface remote / tests) : vérifie les
-- composants, la voie et la sortie, consomme puis pose. `generic` = mode carburant
-- générique (voir compute_need/spawn).
function builder.try_spawn(state, template, params, generic)
  if #template.stock > builder.capacity(state) then
    return nil, "spawn-too-long"
  end
  local need = builder.compute_need(template, generic)
  local miss, miss_str, fuel_item, fuel_short = builder.missing(state, need)
  if next(miss) or fuel_short then return nil, "spawn-missing", miss_str end
  if not builder.track_free(state) then return nil, "spawn-track-occupied" end
  if not builder.exit_open(state) then return nil, "spawn-exit-blocked" end
  builder.consume(state, need, fuel_item)
  local ok, err = builder.spawn(state, template, params, fuel_item, generic)
  if not ok then
    builder.refund(state, need, fuel_item)
    return nil, err
  end
  return ok
end

return builder
