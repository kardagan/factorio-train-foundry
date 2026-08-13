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

-- require doit se faire ICI : Factorio ne l'autorise QUE pendant le parsing de
-- control.lua, jamais depuis un handler d'événement. composite ne require pas
-- builder, donc aucun cycle.
local composite = require("scripts.composite")

local builder = {}

local STOCK_TYPES = { "locomotive", "cargo-wagon", "fluid-wagon",
                      "artillery-wagon" }

-- ===========================================================================
-- Clé composite (item, qualité)
-- ---------------------------------------------------------------------------
-- Les besoins/manques/remboursements sont des maps indexées par ITEM. Depuis le
-- support de la qualité, deux qualités du même item sont deux composants
-- DISTINCTS (une loco légendaire ne satisfait pas un besoin de loco normale, et
-- ne doit pas être consommée pour en fabriquer une). La clé devient donc une
-- chaîne "nom\0qualité" : sérialisable dans storage (contrairement à une table)
-- et utilisable telle quelle comme index unique.
--
-- COMPAT : les saves d'avant portent des clés nom nu pour un travail DÉJÀ PAYÉ
-- (phase building/ready, dont le need sert de facture au remboursement). split()
-- accepte donc une clé sans séparateur et la lit comme qualité normale.
-- ===========================================================================
local QSEP = "\0"
local NORMAL = "normal"

local function qkey(name, quality)
  return name .. QSEP .. (quality or NORMAL)
end
builder.qkey = qkey

-- Clé -> name, quality. Une clé legacy (sans séparateur) vaut qualité normale.
-- La qualité est validée contre les prototypes : une save faite AVEC le mod
-- quality puis rouverte SANS lui porterait un nom inconnu, que l'API refuserait
-- (insert/create_entity lèvent sur une QualityID inexistante).
local function qsplit(key)
  local sep = string.find(key, QSEP, 1, true)
  if not sep then return key, NORMAL end
  local name = string.sub(key, 1, sep - 1)
  local quality = string.sub(key, sep + 1)
  if not prototypes.quality[quality] then return name, NORMAL end
  return name, quality
end
builder.qsplit = qsplit

-- Qualité (string) portée par une entité de blueprint, un stock STC, une entité
-- vivante ou un ItemIDAndQualityIDPair. Le champ est selon la source : absent,
-- une string, ou un LuaQualityPrototype (userdata) / une table {name=...}.
local function quality_of(s)
  local q = s and s.quality
  if q == nil then return NORMAL end
  if type(q) ~= "string" then q = q.name end
  if not (q and prototypes.quality[q]) then return NORMAL end
  return q
end
builder.quality_of = quality_of

local function qadd(map, name, quality, n)
  if not (name and n and n > 0) then return end
  local k = qkey(name, quality)
  map[k] = (map[k] or 0) + n
end

-- Rich-text d'un item qualifié : la qualité n'est écrite que si elle n'est pas
-- normale (un tag nu reste identique à l'historique).
local function qtag(name, quality)
  if quality and quality ~= NORMAL then
    return "[item=" .. name .. ",quality=" .. quality .. "]"
  end
  return "[item=" .. name .. "]"
end
builder.qtag = qtag

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
-- En 2.0 le champ d'items_to_place_this est `.item` (et non `.name` comme en
-- 1.1) ; replis pour les wagons moddés qui ne déclarent pas items_to_place_this :
-- le produit de minage, puis un item de même nom (item-with-entity-data).
local function place_item_for(entity_name)
  local proto = prototypes.entity[entity_name]
  if not proto then return entity_name end
  local items = proto.items_to_place_this
  if items and items[1] then
    local it = items[1]
    if it.item then return it.item end
    if it.name then return it.name end
  end
  local mp = proto.mineable_properties
  if mp and mp.products then
    for _, p in ipairs(mp.products) do
      if p.type == "item" and p.name then return p.name end
    end
  end
  return entity_name
end

-- Matériel roulant d'un template groupé par (item de placement, qualité), dans
-- l'ordre de rencontre : liste de { item, quality, count }. Sert à étiqueter les
-- tuiles du livre / des modèles avec les VRAIES icônes du plan et leur qualité —
-- deux trains de même forme mais de qualités ≠ sont autrement indiscernables.
function builder.template_stock_groups(template)
  local index, out = {}, {}
  for _, s in ipairs((template and template.stock) or {}) do
    local item = place_item_for(s.name)
    local quality = quality_of(s)
    local k = qkey(item, quality)
    local at = index[k]
    if at then
      out[at].count = out[at].count + 1
    else
      out[#out + 1] = { item = item, quality = quality, count = 1 }
      index[k] = #out
    end
  end
  return out
end

-- Item requests d'une entité du blueprint (carburant des locos, munitions d'un
-- wagon d'artillerie...) : map CLÉ COMPOSITE -> quantité totale. req.id est un
-- ItemIDAndQualityIDPair, d'où la qualité demandée par le plan.
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
      qadd(out, name, quality_of(req.id), total)
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
    for key in pairs(requested_items(s)) do
      local name = qsplit(key)
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
-- La qualité facturée ici DOIT être celle que apply_grid pose réellement dans la
-- grille, sinon un équipement de qualité serait produit au prix du normal.
local function grid_items(s)
  local out = {}
  for _, comp in pairs(s.grid or {}) do
    local eq = comp.equipment
    local eq_name = (type(eq) == "table") and eq.name or eq
    if eq_name then
      local item = item_for_equipment(eq_name)
      if item then qadd(out, item, quality_of(eq), 1) end
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
-- Un item périssable ? get_spoil_ticks est une MÉTHODE (il n'existe AUCUN attribut
-- spoil_ticks runtime : la qualité module la durée via spoil_ticks_multiplier) et
-- renvoie 0 — pas nil — pour un item qui ne pourrit pas : d'où la comparaison
-- explicite, un simple test de véracité exclurait tout.
--
-- La QUALITÉ est OBLIGATOIRE malgré une signature documentée `quality?` : appelée
-- sans argument, la méthode lève « Invalid QualityID: expected LuaQualityPrototype
-- or string. » — le pcall avalait l'erreur, is_perishable renvoyait donc false pour
-- TOUT, et les périssables (jellynut, œufs de biter/pentapode) restaient proposés.
-- On interroge en qualité normale : le spoil est une propriété de l'item, la qualité
-- ne fait que moduler la durée (spoil_ticks_multiplier), jamais l'existence du spoil.
local function is_perishable(item_proto)
  if not item_proto then return false end
  local ok, ticks = pcall(function() return item_proto:get_spoil_ticks(NORMAL) end)
  return ok and type(ticks) == "number" and ticks > 0
end
builder.is_perishable = is_perishable

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
    -- Les PÉRISSABLES sont exclus : œufs (pentapode, biter) et produits Gleba
    -- (yumako, jellynut, nutrients, bioflux…) sont brûlables mais pourrissent en
    -- soute. Le critère est générique — aucun vrai carburant ne pourrit — donc
    -- valable aussi pour les carburants ajoutés par un mod.
    if it and it.fuel_value and it.fuel_value > 0
       and it.fuel_category and cats[it.fuel_category]
       and not is_perishable(it) then
      out[#out + 1] = { name = name, fuel_value = it.fuel_value }
    end
  end
  table.sort(out, function(a, b) return a.fuel_value > b.fuel_value end)
  return out
end
builder.unlocked_fuels = unlocked_fuels

-- ---------------------------------------------------------------------------
-- Préférence de carburant du joueur (state.fuel_pref)
-- ---------------------------------------------------------------------------
-- L'auto-sélection « meilleur carburant débloqué » ne suffit pas : avec des mods
-- la liste est longue et contient des carburants indésirables, et le joueur peut
-- vouloir brûler de la qualité (carb. solide légendaire, sinon rare, sinon
-- normal). state.fuel_pref = set de clés composites (item, qualité) ACCEPTÉES,
-- ou nil = tout accepté en qualité normale (comportement d'avant 1.1.0, donc
-- valeur des saves migrées et des fonderies neuves).
--
-- L'ordre de préférence n'est PAS stocké : il se déduit (choix retenu en 1.1.0),
-- carburants par fuel_value décroissant, et pour un même carburant les qualités
-- de la meilleure à la moins bonne (prototypes.quality[q].level).
local function quality_levels()
  local out = {}
  for name, q in pairs(prototypes.quality) do
    -- On écarte la seule qualité « quality-unknown » du moteur (elle donnait une
    -- colonne « Unknown » parasite), PAR SON NOM et non via `hidden` : la qualité
    -- NORMALE est elle aussi hidden=true dans base (« hidden in the base game, to not
    -- confuse by its existence in the selection gui »), et filtrer sur `hidden` vidait
    -- donc toute la liste quand le mod Quality est désactivé — plus aucune case à
    -- cocher. Le mod Quality ne dé-cache pas normal, il ajoute seulement les autres.
    -- `level` ne permettrait pas de distinguer unknown (0, comme normal).
    if name ~= "quality-unknown" then
      out[#out + 1] = { name = name, level = q.level or 0 }
    end
  end
  table.sort(out, function(a, b)
    if a.level ~= b.level then return a.level > b.level end
    return a.name < b.name
  end)
  return out
end
builder.quality_levels = quality_levels

-- Catégories brûlables par UNE LOCOMOTIVE QUELCONQUE du jeu. Sert à peupler la
-- fenêtre de réglage : elle est persistante et ne doit pas dépendre du train en
-- file (state.work peut être vide, et la préférence vaut pour les suivants).
function builder.all_loco_fuel_categories()
  local cats = {}
  for _, proto in pairs(prototypes.get_entity_filtered({
      { filter = "type", type = "locomotive" } })) do
    local burner = proto.burner_prototype
    if burner and burner.fuel_categories then
      for cat in pairs(burner.fuel_categories) do cats[cat] = true end
    end
  end
  return cats
end

-- Le couple (item, qualité) est-il accepté ? pref nil → seule la normale l'est.
local function fuel_allowed(pref, name, quality)
  if not pref then return quality == NORMAL end
  return pref[qkey(name, quality)] == true
end
builder.fuel_allowed = fuel_allowed

-- Couples (carburant, qualité) candidats, DANS L'ORDRE DE PRÉFÉRENCE : carburant
-- par fuel_value décroissant, puis qualité décroissante. Filtré par fuel_pref.
local function preferred_fuels(force, cats, pref)
  local qualities = quality_levels()
  local out = {}
  for _, c in ipairs(unlocked_fuels(force, cats)) do
    for _, q in ipairs(qualities) do
      if fuel_allowed(pref, c.name, q.name) then
        out[#out + 1] = { name = c.name, quality = q.name, fuel_value = c.fuel_value }
      end
    end
  end
  return out
end
builder.preferred_fuels = preferred_fuels

-- Nombre de slots de carburant d'une loco (0 si pas de burner). La qualité est
-- passée car un mod peut faire varier la taille d'inventaire avec elle : sans
-- elle, le plein FACTURÉ divergerait du plein réellement inséré au spawn.
local function loco_fuel_slots(loco_name, quality)
  local proto = prototypes.entity[loco_name]
  if not (proto and proto.burner_prototype) then return 0 end
  local n = proto.get_inventory_size(defines.inventory.fuel, quality)
  return n or 0
end

-- Quantité de `fuel` (item) nécessaire pour remplir À PLEIN toutes les locos du
-- stock : Σ slots(loco) × stack_size(fuel).
local function loco_fuel_capacity(stock, fuel)
  local stack = prototypes.item[fuel] and prototypes.item[fuel].stack_size or 0
  if stack <= 0 then return 0 end
  local slots = 0
  for _, s in ipairs(stock or {}) do
    slots = slots + loco_fuel_slots(s.name, quality_of(s))
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
    -- L'item de placement hérite de la qualité du véhicule blueprinté.
    qadd(items, place_item_for(s.name), quality_of(s), 1)
    for key, n in pairs(requested_items(s)) do
      local name, quality = qsplit(key)
      local it = prototypes.item[name]
      local is_fuel = it and it.fuel_value and it.fuel_value > 0
      -- En générique on ignore le carburant du BP (volet fuel s'en charge) ; en
      -- mode BP historique on le garde comme composant.
      if (not is_fuel) or (not generic) then
        qadd(items, name, quality, n)
      end
    end
    for key, n in pairs(grid_items(s)) do
      local name, quality = qsplit(key)
      qadd(items, name, quality, n)
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

-- Choisit le carburant à brûler : premier couple (carburant, qualité) ACCEPTÉ par
-- la préférence du joueur, dans l'ordre de préférence, présent en réserve en
-- quantité suffisante pour le plein de toutes les locos. Retourne
-- fuel_key (clé composite), capacity ou nil si aucun ne convient.
local function pick_fuel(state, fuel_need)
  local inv = shared_inventory(state)
  if not inv then return nil end
  local force = state.entity and state.entity.valid and state.entity.force
  if not force then return nil end
  for _, c in ipairs(preferred_fuels(force, fuel_need.categories, state.fuel_pref)) do
    local cap = loco_fuel_capacity(fuel_need.stock, c.name)
    -- Le comptage porte sur le couple EXACT : additionner les qualités ferait
    -- consommer du carburant de qualité pour satisfaire un besoin de normal.
    if cap > 0 and inv.get_item_count({ name = c.name, quality = c.quality }) >= cap then
      return qkey(c.name, c.quality), cap
    end
  end
  return nil
end
builder.pick_fuel = pick_fuel

-- Détail des carburants candidats pour l'affichage / le circuit : pour chaque
-- couple (carburant, qualité) accepté, son plein (Σ slots×stack) et ce que la
-- réserve en a. Dans l'ordre de préférence. {} si pas de besoin carburant.
function builder.fuel_candidates(state, need)
  if not (need and need.fuel) then return {} end
  local inv = shared_inventory(state)
  local force = state.entity and state.entity.valid and state.entity.force
  if not force then return {} end
  local out = {}
  for _, c in ipairs(preferred_fuels(force, need.fuel.categories, state.fuel_pref)) do
    local full = loco_fuel_capacity(need.fuel.stock, c.name)
    if full > 0 then
      out[#out + 1] = {
        name = c.name,
        quality = c.quality,
        need = full,
        have = inv and inv.get_item_count({ name = c.name, quality = c.quality }) or 0,
      }
    end
  end
  return out
end

-- Ce qui manque dans la réserve. Retourne :
--   miss       : map item -> quantité manquante (composants)
--   caption    : chaîne rich-text prête à afficher ("" si rien ne manque)
--   fuel_item  : CLÉ COMPOSITE (item, qualité) du carburant retenu pour le plein
--                (nil si pas de besoin carburant OU aucun couple accepté dispo en
--                quantité suffisante). Une save d'avant 1.1.0 peut en porter un nom
--                nu : qsplit le lit en qualité normale, ce qui est bien ce qui avait
--                été prélevé à l'époque.
--   fuel_short : true si un carburant EST requis mais aucun candidat ne convient
-- Deux lignes dans la caption : composants, puis carburant (si manquant).
function builder.missing(state, need)
  local inv = shared_inventory(state)
  local items = need.items or need   -- compat : ancien need plat = les items
  local miss, parts = {}, {}
  for key, n in pairs(items) do
    local name, quality = qsplit(key)
    -- get_item_count(name) additionnerait TOUTES les qualités : on interroge
    -- la réserve sur le couple exact, sinon du légendaire « satisfait » un
    -- besoin de normal (puis se fait consommer à sa place).
    local have = inv and inv.get_item_count({ name = name, quality = quality }) or 0
    if have < n then
      miss[key] = n - have
      parts[#parts + 1] = qtag(name, quality) .. "×" .. (n - have)
    end
  end

  local fuel_item, fuel_short, fuel_caption = nil, false, ""
  if need.fuel then
    fuel_item = pick_fuel(state, need.fuel)
    if not fuel_item then
      fuel_short = true
      -- Besoin d'un carburant, aucun candidat dispo en réserve : liste des couples
      -- ACCEPTÉS (rich-text) pour guider le joueur — c'est ce qu'il doit fournir,
      -- pas la liste complète des carburants du jeu.
      local force = state.entity and state.entity.valid and state.entity.force
      local cands = force
        and preferred_fuels(force, need.fuel.categories, state.fuel_pref) or {}
      local icons = {}
      for _, c in ipairs(cands) do icons[#icons + 1] = qtag(c.name, c.quality) end
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
  for key, n in pairs(items) do
    local name, quality = qsplit(key)
    inv.remove({ name = name, quality = quality, count = n })
  end
  if fuel_item and need.fuel then
    local fname, fquality = qsplit(fuel_item)
    local cap = loco_fuel_capacity(need.fuel.stock, fname)
    if cap > 0 then
      inv.remove({ name = fname, quality = fquality, count = cap })
    end
  end
end

-- Rend les composants + le carburant consommé (annulation). Ce qui ne rentre
-- plus dans la réserve est déversé au sol. `fuel_item` = carburant consommé (nil
-- si aucun).
function builder.refund(state, need, fuel_item)
  local inv = shared_inventory(state)
  local e = state.entity
  local items = need.items or need
  -- Les clés d'un need issu d'une save antérieure au support de la qualité sont
  -- des noms nus : qsplit les rend en qualité normale, ce qui correspond bien à
  -- ce qui avait été prélevé à l'époque.
  local to_refund = {}
  for key, n in pairs(items or {}) do to_refund[key] = n end
  if fuel_item and need.fuel then
    local fname, fquality = qsplit(fuel_item)
    local cap = loco_fuel_capacity(need.fuel.stock, fname)
    if cap > 0 then
      local k = qkey(fname, fquality)
      to_refund[k] = (to_refund[k] or 0) + cap
    end
  end
  for key, n in pairs(to_refund) do
    local name, quality = qsplit(key)
    local inserted = inv and inv.insert({ name = name, quality = quality, count = n }) or 0
    if inserted < n and e and e.valid then
      e.surface.spill_item_stack({
        position = e.position,
        stack = { name = name, quality = quality, count = n - inserted },
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
  local count = 0
  for _, v in ipairs(vehicles) do
    if v.valid then
      count = count + 1
      -- Le véhicule lui-même, dans SA qualité (v.quality est un LuaQualityPrototype).
      qadd(refund, place_item_for(v.name), quality_of(v), 1)
      -- Contenu de tous ses inventaires (fuel, cargo, munitions...).
      for i = 1, v.get_max_inventory_index() do
        local inv = v.get_inventory(i)
        if inv then
          -- get_contents (2.0) = liste de { name, count, quality }.
          for _, it in pairs(inv.get_contents()) do
            qadd(refund, it.name, it.quality, it.count)
          end
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

-- Le CORPS d'une balise capte aussi ce qui suit le nom (",quality=…") : sans cela
-- un tag déjà qualifié ne serait pas reconnu et resterait tel quel, placeholder
-- compris. L'id du paramètre est la partie AVANT la virgule.
local function subst_station(name, params)
  if not (params and name) then return name end
  return (name:gsub("%[([%a%-]+)=([^%]]+)%]", function(kind, body)
    local id = body:match("^([^,]+)") or body
    local p = params[id]
    if p and p.name then
      -- Un fluide n'a jamais de qualité ; un item la porte si elle n'est pas
      -- normale (même règle que les noms de gares STC, comparés byte-à-byte).
      local ptype = RICH_KIND[p.type] or "item"
      local suffix = ""
      if ptype == "item" and p.quality and p.quality ~= NORMAL then
        suffix = ",quality=" .. p.quality
      end
      return "[" .. ptype .. "=" .. p.name .. suffix .. "]"
    end
    return "[" .. kind .. "=" .. body .. "]"
  end))
end

builder.subst_station = subst_station

local function subst_signal(sig, params)
  if params and sig and sig.name and params[sig.name] then
    local p = params[sig.name]
    if p.name then
      -- La qualité du signal choisi est conservée (un SignalID la porte).
      return { type = p.type, name = p.name, quality = p.quality }
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
      quality = quality_of(s),
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
    for key, n in pairs(requested_items(template.stock[i])) do
      local name, quality = qsplit(key)
      local ip = prototypes.item[name]
      local is_fuel = ip and ip.fuel_value and ip.fuel_value > 0
      -- Non-carburant (munitions…) : toujours inséré. Carburant du BP : inséré
      -- UNIQUEMENT en mode BP historique (generic=false) ; en générique le
      -- carburant est géré par fuel_item ci-dessous.
      if (not is_fuel) or (not generic) then
        v.insert({ name = name, quality = quality, count = n })
      end
    end
    -- Remplissage carburant GÉNÉRIQUE seulement (STC / BP option cochée). En mode
    -- BP historique, le carburant vient déjà des item-requests insérées ci-dessus.
    if generic and v.type == "locomotive" then
      local fi = v.get_fuel_inventory()
      if fi then
        if fuel_item then
          -- Plein avec le carburant retenu (déjà payé, on ne retouche pas la réserve).
          local fname, fquality = qsplit(fuel_item)
          local stack = prototypes.item[fname] and prototypes.item[fname].stack_size or 0
          local slots = #fi
          if stack > 0 and slots > 0 then
            fi.insert({ name = fname, quality = fquality, count = stack * slots })
          end
        elseif inv then
          -- Repli : premier carburant compatible dispo en réserve, une pile. Il
          -- reste soumis à la préférence du joueur — sans ce filtre, une fonderie
          -- réglée sur un seul carburant brûlerait quand même le reste de la réserve.
          local bp = v.prototype.burner_prototype
          if bp then
            for _, it in pairs(inv.get_contents()) do
              local ip = prototypes.item[it.name]
              if ip and ip.fuel_category and bp.fuel_categories[ip.fuel_category]
                 and not is_perishable(ip)
                 and fuel_allowed(state.fuel_pref, it.name, quality_of(it)) then
                local count = math.min(it.count, ip.stack_size)
                -- insert ET remove sur le MÊME couple : sans la qualité, le
                -- moteur pourrait retirer une autre pile que celle insérée.
                local q = it.quality
                local inserted = fi.insert({ name = it.name, quality = q, count = count })
                if inserted > 0 then
                  inv.remove({ name = it.name, quality = q, count = inserted })
                end
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

-- Écrit une map (clé composite -> quantité) dans les filtres d'un émetteur.
local function emit(entity, acc)
  if not (entity and entity.valid) then return end
  local cb = entity.get_or_create_control_behavior()
  if not cb then return end
  local section = cb.get_section(1) or cb.add_section()
  if not section then return end
  -- Une section INACTIVE garde ses filtres mais n'émet rien. On force l'activation :
  -- l'entité étant invisible, le joueur n'aurait aucun moyen de la réactiver.
  -- (`is_on` n'existe PAS sur LuaConstantCombinatorControlBehavior — et indexer un
  -- membre absent d'un LuaObject LÈVE une erreur au lieu de rendre nil.)
  if section.active == false then section.active = true end
  local filters = {}
  for key, count in pairs(acc) do
    if count ~= 0 then
      local name, quality = qsplit(key)
      filters[#filters + 1] = {
        value = { type = "item", name = name, quality = quality },
        min = count,
      }
    end
  end
  section.filters = filters
end

-- Met à jour les signaux du circuit. Les DEUX informations sont émises en
-- permanence, chacune sur son fil du poteau :
--   fil ROUGE  -> contenu de la réserve (ce qu'on A)
--   fil VERT   -> composants manquants  (ce qu'on VEUT)
-- Le joueur branche le fil qui l'intéresse, ou les deux. Plus de mode à choisir.
--
-- Deux émetteurs distincts sont nécessaires : un combinateur diffuse la même valeur
-- sur ses deux fils, et rien ne permet de restreindre une section à un fil (voir
-- composite.ensure_circuit). Ils sont invisibles et reliés au poteau par le mod.
function builder.update_circuit(state)
  -- Volet STOCK : tout le contenu de la réserve.
  local stock = {}
  local inv = shared_inventory(state)
  if inv then
    for _, it in pairs(inv.get_contents()) do
      qadd(stock, it.name, it.quality, it.count)
    end
  end

  -- Volet DEMANDES : composants manquants du travail EN ATTENTE uniquement. Un
  -- travail déjà en construction (phase building/ready) a consommé ses composants
  -- dans la réserve → ne PAS les redemander (sinon on réclame le contenu d'un train
  -- déjà en cours).
  local req = {}
  if state.work and state.work.phase == "waiting" and state.work.need then
    local miss = builder.missing(state, state.work.need)
    for key, n in pairs(miss) do req[key] = (req[key] or 0) + n end
    -- Carburant : on demande le PLEIN pour CHAQUE carburant candidat, pour qu'au
    -- moins un arrive par la logistique. Dès qu'un carburant satisfait le plein
    -- (have >= need), la prod part et ce bloc n'est plus atteint.
    for _, f in ipairs(builder.fuel_candidates(state, state.work.need)) do
      if f.have < f.need then
        qadd(req, f.name, f.quality, f.need - f.have)
      end
    end
  end

  -- Un volet ÉTEINT est vidé : son lien au poteau est déjà coupé (ensure_circuit), mais
  -- laisser d'anciens filtres en place rendrait le diagnostic trompeur et ferait
  -- ressortir des signaux périmés si le volet est rallumé avant le tick suivant.
  local cfg_stock = state.emit_stock or {}
  local cfg_req   = state.emit_req or {}
  emit(state.combinator, cfg_stock.on and stock or {})
  emit(state.combinator_req, cfg_req.on and req or {})

  -- Auto-réparation du câblage interne. ensure_circuit ne tourne qu'à la pose et à la
  -- migration : une fonderie migrée par une version antérieure à ce câblage resterait
  -- MUETTE pour toujours (filtres écrits, mais aucune connexion — c'est ce qu'a montré
  -- /tf-debug). On ne répare QUE si un lien est attendu par les réglages et manque
  -- vraiment : sinon, un volet volontairement décoché relancerait ensure_circuit à
  -- chaque tick. Test bon marché : get_wire_connector(_, false) ne crée rien.
  local expect = {
    { state.combinator,     cfg_stock },
    { state.combinator_req, cfg_req },
  }
  for _, x in ipairs(expect) do
    local ent, cfg = x[1], x[2]
    if ent and ent.valid and cfg.on then
      for colour, wire in pairs({
          red   = defines.wire_connector_id.circuit_red,
          green = defines.wire_connector_id.circuit_green }) do
        if cfg[colour] then
          local conn = ent.get_wire_connector(wire, false)
          if not conn or conn.connection_count == 0 then
            composite.ensure_circuit(state)
            return
          end
        end
      end
    end
  end
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
