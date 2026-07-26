-- Train Foundry — lecture des blueprints de trains.
--
-- Lecture PONCTUELLE : uniquement quand le joueur présente un blueprint à la
-- fonderie (slot d'UI au milestone 4, commande /tf-import en attendant).
-- Aucun scan de la bibliothèque ni des blueprints posés en jeu.
--
-- Le template stocke les entités BRUTES du blueprint (tables sérialisables,
-- triées de l'ouest vers l'est / du nord vers le sud) : le milestone 3 y
-- retrouvera tout ce que le BP contient (orientation, couleur, fuel en item
-- requests, filtres...) sans qu'on ait à tout re-modéliser ici.

local builder = require("scripts.builder")

local blueprint = {}

local ROLLING_TYPES = {
  ["locomotive"] = true,
  ["cargo-wagon"] = true,
  ["fluid-wagon"] = true,
  ["artillery-wagon"] = true,
}

-- Entités TOLÉRÉES en plus du train : la voie sur laquelle il est posé
-- (rails, signaux, gares) est naturelle dans un blueprint de train. Toute
-- autre entité (bras, coffres, tapis, poteaux...) rend le BP « impur » et
-- l'import est refusé.
local ALLOWED_EXTRA_TYPES = {
  ["straight-rail"] = true,
  ["curved-rail-a"] = true,
  ["curved-rail-b"] = true,
  ["half-diagonal-rail"] = true,
  ["legacy-straight-rail"] = true,
  ["legacy-curved-rail"] = true,
  ["elevated-straight-rail"] = true,
  ["elevated-curved-rail-a"] = true,
  ["elevated-curved-rail-b"] = true,
  ["elevated-half-diagonal-rail"] = true,
  ["rail-ramp"] = true,
  ["rail-support"] = true,
  ["rail-signal"] = true,
  ["rail-chain-signal"] = true,
  ["train-stop"] = true,
}

-- Compte par type pour les messages ("2 locomotives + 4 wagons").
function blueprint.counts(template)
  local locos, wagons = 0, 0
  for _, e in ipairs(template.stock) do
    local proto = prototypes.entity[e.name]
    if proto and proto.type == "locomotive" then
      locos = locos + 1
    else
      wagons = wagons + 1
    end
  end
  return locos, wagons
end

-- Ce que le joueur a « en main » comme blueprint : soit un vrai item
-- (LuaItemStack, BP de l'inventaire), soit un enregistrement de la
-- BIBLIOTHÈQUE de blueprints (LuaRecord — dans ce cas cursor_stack est
-- VIDE, piège classique de la 2.0).
function blueprint.cursor_source(player)
  local stack = player.cursor_stack
  if stack and stack.valid_for_read and stack.is_blueprint then
    return stack
  end
  local rec = player.cursor_record
  if rec and rec.valid and rec.type == "blueprint" then
    return rec
  end
  return nil
end

-- Lit un blueprint (LuaItemStack OU LuaRecord de la bibliothèque) et en
-- extrait un template de train. Retourne template, nil en cas de succès ;
-- nil, "clé-erreur" sinon (clés de la section [tf-msg] des locales).
-- `capacity` = longueur max autorisée (défaut builder.MAX_STOCK) : dépend de
-- la chaîne d'extensions de la fonderie qui importe.
function blueprint.parse(source, capacity)
  capacity = capacity or builder.MAX_STOCK
  if not (source and source.valid) then
    return nil, "import-not-blueprint"
  end
  local kind = source.object_name
  if kind == "LuaItemStack" then
    if not (source.valid_for_read and source.is_blueprint) then
      return nil, "import-not-blueprint"
    end
  elseif kind == "LuaRecord" then
    if source.type ~= "blueprint" then
      return nil, "import-not-blueprint"
    end
  else
    return nil, "import-not-blueprint"
  end

  -- Accès défensifs : LuaItemStack et LuaRecord partagent ces méthodes,
  -- mais autant survivre aux différences de versions du jeu.
  local ok_setup, setup = pcall(function() return source.is_blueprint_setup() end)
  if ok_setup and setup == false then
    return nil, "import-empty"
  end

  local ok_ents, ents = pcall(function() return source.get_blueprint_entities() end)
  if not ok_ents or not ents then
    return nil, "import-no-train"
  end

  local stock = {}
  local intruders = {}
  for _, e in ipairs(ents) do
    local proto = prototypes.entity[e.name]
    local ptype = proto and proto.type
    if ptype and ROLLING_TYPES[ptype] then
      stock[#stock + 1] = e
    elseif not (ptype and ALLOWED_EXTRA_TYPES[ptype]) then
      -- Entité hors train et hors voie : BP impur.
      intruders["[item=" .. e.name .. "]"] = true
    end
  end
  if #stock == 0 then
    return nil, "import-no-train"
  end
  if next(intruders) then
    local names = {}
    for tag in pairs(intruders) do names[#names + 1] = tag end
    return nil, "import-not-clean", table.concat(names, " ")
  end
  -- Refuse dès l'import un train trop long pour la voie interne (plutôt que
  -- de le lancer et voir les véhicules retomber dans le coffre). La capacité
  -- dépend de la chaîne d'extensions de la fonderie.
  if #stock > capacity then
    return nil, "import-too-long", tostring(capacity)
  end

  -- Le train du blueprint doit être posé sur une voie DROITE : on détecte
  -- l'axe dominant, on exige la colinéarité et l'espacement standard des
  -- attelages (7 tuiles entre centres).
  local minx, maxx = math.huge, -math.huge
  local miny, maxy = math.huge, -math.huge
  for _, e in ipairs(stock) do
    minx = math.min(minx, e.position.x)
    maxx = math.max(maxx, e.position.x)
    miny = math.min(miny, e.position.y)
    maxy = math.max(maxy, e.position.y)
  end
  local horizontal = (maxx - minx) >= (maxy - miny)
  local lateral = horizontal and (maxy - miny) or (maxx - minx)
  if lateral > 1.5 then
    return nil, "import-not-straight"
  end

  table.sort(stock, function(a, b)
    if horizontal then return a.position.x < b.position.x end
    return a.position.y < b.position.y
  end)
  for i = 2, #stock do
    local d
    if horizontal then
      d = stock[i].position.x - stock[i - 1].position.x
    else
      d = stock[i].position.y - stock[i - 1].position.y
    end
    if math.abs(d - 7) > 0.6 then
      return nil, "import-not-straight"
    end
  end

  -- Aucune contrainte de SENS des locomotives : la fonderie peut sortir à gauche
  -- (ouest) et/ou à droite (est) selon la configuration, et le pathfinder route
  -- le train par la sortie ouverte que son schedule atteint. Un blueprint avec
  -- des locos dans n'importe quel sens est donc accepté.

  local template = {
    name = nil,        -- rempli par l'appelant ("Train N")
    stock = stock,     -- entités BP brutes, triées le long de l'axe
    horizontal = horizontal,
    schedules = nil,   -- planning(s) du BP si l'API les expose
    source_kind = kind, -- LuaItemStack / LuaRecord (diagnostic)
    created_tick = game.tick,
  }

  -- Les BP 2.0 embarquent les schedules mais l'API 2.0.77 ne les expose pas
  -- directement (pas de get_blueprint_schedules sur LuaItemStack) : on passe
  -- par l'export JSON du blueprint. Tout en accès défensif — on vivra sans
  -- schedule si aucune voie n'aboutit (le train sera livré en manuel).
  local ok, sched = pcall(function()
    return source.get_blueprint_schedules and source.get_blueprint_schedules()
  end)
  if ok and sched and #sched > 0 then
    template.schedules = sched
  end
  do
    local ok2, json = pcall(function()
      -- export_stack pour un item, export_record pour un blueprint de la
      -- bibliothèque : même format ("0" + base64/zlib du JSON). ATTENTION :
      -- on branche sur le type et PAS avec `source.export_stack and ...` —
      -- indexer un membre inexistant d'un LuaObject LÈVE une erreur (ça
      -- faisait échouer tout le pcall pour les LuaRecord).
      local ex
      if kind == "LuaItemStack" then
        ex = source.export_stack()
      else
        ex = source.export_record()
      end
      return helpers.json_to_table(helpers.decode_string(string.sub(ex, 2)))
    end)
    if ok2 and json and json.blueprint then
      template.schedules = template.schedules or json.blueprint.schedules
      -- Blueprint paramétré : les placeholders (parameter-0, ...) devront
      -- être demandés au joueur avant la construction.
      template.parameters = json.blueprint.parameters
      -- Identité visuelle du blueprint : son nom et ses icônes, affichés
      -- dans le livre de plans de la fonderie.
      template.label = json.blueprint.label
      template.icons = json.blueprint.icons
    end
  end

  return template
end

return blueprint
