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
local HEAD_X = -12
local SPACING = 7
local MAX_STOCK = 5

-- Durée de construction : 4 s par véhicule.
builder.TICKS_PER_VEHICLE = 240

-- Inventaire de la réserve : le coffre de fer sur le parvis.
local function shared_inventory(state)
  local chest = state.input
  if chest and chest.valid then
    return chest.get_inventory(defines.inventory.chest)
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

-- Items requis par le template : les véhicules eux-mêmes + tout ce que le
-- blueprint demande dedans (carburant si le train a été blueprinté avec le
-- plein, munitions...).
function builder.compute_need(template)
  local need = {}
  for _, s in ipairs(template.stock) do
    local item = place_item_for(s.name)
    need[item] = (need[item] or 0) + 1
    for name, n in pairs(requested_items(s)) do
      need[name] = (need[name] or 0) + n
    end
  end
  return need
end

-- Ce qui manque dans la réserve : map item -> quantité manquante, plus une
-- chaîne rich-text prête à afficher ("" si rien ne manque).
function builder.missing(state, need)
  local inv = shared_inventory(state)
  local miss, parts = {}, {}
  for item, n in pairs(need) do
    local have = inv and inv.get_item_count(item) or 0
    if have < n then
      miss[item] = n - have
      parts[#parts + 1] = "[item=" .. item .. "]×" .. (n - have)
    end
  end
  return miss, table.concat(parts, "  ")
end

function builder.consume(state, need)
  local inv = shared_inventory(state)
  if not inv then return end
  for item, n in pairs(need) do
    inv.remove({ name = item, count = n })
  end
end

-- Rend les composants (annulation d'une construction en cours). Ce qui ne
-- rentre plus dans la réserve est déversé au sol.
function builder.refund(state, need)
  local inv = shared_inventory(state)
  local e = state.entity
  for item, n in pairs(need or {}) do
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

-- La voie interne est-elle libre de tout véhicule ?
function builder.track_free(state)
  local e = state.entity
  if not (e and e.valid) then return false end
  local area = {
    { e.position.x - 18, e.position.y + RAIL_Y - 1.5 },
    { e.position.x + 18, e.position.y + RAIL_Y + 1.5 },
  }
  return #e.surface.find_entities_filtered({
    type = STOCK_TYPES, area = area }) == 0
end

-- Le bloc de sortie (gouverné par le signal de la porte) est-il libre ?
function builder.exit_open(state)
  if state.signal and state.signal.valid then
    return state.signal.signal_state == defines.signal_state.open
  end
  return true
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
function builder.spawn(state, template, params)
  local e = state.entity
  if not (e and e.valid) then return nil, "spawn-failed" end
  if #template.stock > MAX_STOCK then return nil, "spawn-too-long" end
  local inv = shared_inventory(state)

  -- Pose des véhicules. Le template est trié tête (ouest/nord du BP) vers
  -- queue : la tête sort en premier. Mapping des orientations BP -> voie
  -- est-ouest : BP horizontal conservé tel quel, BP vertical tourné d'un
  -- quart (nord -> ouest).
  local spawned = {}
  for i, s in ipairs(template.stock) do
    local o = s.orientation or (template.horizontal and 0.75 or 0)
    local dir
    if template.horizontal then
      dir = (math.abs(o - 0.25) < 0.26) and defines.direction.east
        or defines.direction.west
    else
      dir = (math.abs(o - 0.5) < 0.26) and defines.direction.east
        or defines.direction.west
    end
    local v = e.surface.create_entity({
      name = s.name,
      position = { e.position.x + HEAD_X + (i - 1) * SPACING,
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
    spawned[#spawned + 1] = v
  end

  -- Remplissage : les item requests du blueprint (carburant, munitions...)
  -- ont déjà été consommés de la réserve avec les composants — on les
  -- insère dans chaque véhicule (LuaEntity.insert choisit le bon
  -- inventaire : fuel, munitions, soute). Pour un véhicule SANS requests,
  -- repli : premier carburant compatible trouvé dans la réserve, une pile
  -- par locomotive.
  for i, v in ipairs(spawned) do
    local reqs = requested_items(template.stock[i])
    if next(reqs) then
      for name, n in pairs(reqs) do
        v.insert({ name = name, count = n })
      end
    elseif v.type == "locomotive" and inv then
      local bp = v.prototype.burner_prototype
      local fi = v.get_fuel_inventory()
      if bp and fi then
        for _, it in pairs(inv.get_contents()) do
          local ip = prototypes.item[it.name]
          if ip and ip.fuel_category and bp.fuel_categories[ip.fuel_category] then
            local count = math.min(it.count, ip.stack_size)
            local inserted = fi.insert({ name = it.name, count = count })
            if inserted > 0 then
              inv.remove({ name = it.name, count = inserted })
            end
            break
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
        if group and group ~= "" then
          train.group = subst_station(group, params)
          local s2 = train.schedule
          if s2 and s2.records and #s2.records > 0 then
            train.manual_mode = false
            departed = true
          end
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
    -- Composants manquants du travail en cours + de toute la file.
    local pending = {}
    if state.work and state.work.need then
      local miss = builder.missing(state, state.work.need)
      for item, n in pairs(miss) do pending[item] = (pending[item] or 0) + n end
    end
    for item, n in pairs(pending) do acc[item] = (acc[item] or 0) + n end
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
-- composants, la voie et la sortie, consomme puis pose.
function builder.try_spawn(state, template, params)
  if #template.stock > MAX_STOCK then return nil, "spawn-too-long" end
  local need = builder.compute_need(template)
  local miss, miss_str = builder.missing(state, need)
  if next(miss) then return nil, "spawn-missing", miss_str end
  if not builder.track_free(state) then return nil, "spawn-track-occupied" end
  if not builder.exit_open(state) then return nil, "spawn-exit-blocked" end
  builder.consume(state, need)
  local ok, err = builder.spawn(state, template, params)
  if not ok then
    builder.refund(state, need)
    return nil, err
  end
  return ok
end

return builder
