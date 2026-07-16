-- Train Foundry — construction des trains (M2.5 : spawn immédiat au bouton
-- Go, la file d'attente arrive au milestone 3).
--
-- try_spawn vérifie tout AVANT d'agir : composants dans la réserve partagée,
-- voie interne libre, bloc de sortie libre. Puis il matérialise les véhicules
-- sur la voie interne (tête à l'ouest, vers la sortie), applique les
-- couleurs, consomme les composants, insère du carburant trouvé dans la
-- réserve, applique le schedule du blueprint s'il existe et lâche le train.

local builder = {}

local STOCK_TYPES = { "locomotive", "cargo-wagon", "fluid-wagon",
                      "artillery-wagon" }

-- Géométrie : voie interne sur la rangée +5, utilisable du mur ouest (-16)
-- au bout des rails (+18). Tête du train à l'ouest, véhicules espacés de 7.
local RAIL_Y = 5
local HEAD_X = -12
local SPACING = 7
local MAX_STOCK = 5

local function shared_inventory(state)
  for _, c in ipairs(state.inputs or {}) do
    if c.valid then return c.get_inventory(defines.inventory.chest) end
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

-- Substitution des paramètres de blueprint (BP paramétrés 2.0) : `params`
-- mappe "parameter-N" -> {type=, name=} choisi par le joueur.
local RICH_KIND = { item = "item", fluid = "fluid", virtual = "virtual-signal" }

-- Le placeholder d'un paramètre est l'ID déclaré dans la section parameters
-- du blueprint : selon les cas c'est un "parameter-N" OU l'icône d'origine
-- choisie par le joueur (ex. signal-0). On remplace donc toute balise
-- rich-text et tout signal dont le nom correspond à un paramètre connu.
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

-- Tente de construire le train du template. `params` (optionnel) : valeurs
-- des paramètres du blueprint choisies par le joueur. Retourne :
--   "clé-succès" (spawn-ok-departed / spawn-ok-manual)
--   nil, "clé-erreur"[, détail] sinon (clés [tf-msg]).
function builder.try_spawn(state, template, params)
  local e = state.entity
  if not (e and e.valid) then return nil, "spawn-failed" end
  if #template.stock > MAX_STOCK then return nil, "spawn-too-long" end
  local inv = shared_inventory(state)
  if not inv then return nil, "spawn-failed" end

  -- Composants requis vs réserve partagée.
  local need = {}
  for _, s in ipairs(template.stock) do
    local item = place_item_for(s.name)
    need[item] = (need[item] or 0) + 1
  end
  local missing = {}
  for item, n in pairs(need) do
    local have = inv.get_item_count(item)
    if have < n then
      missing[#missing + 1] = "[item=" .. item .. "]×" .. (n - have)
    end
  end
  if #missing > 0 then
    return nil, "spawn-missing", table.concat(missing, "  ")
  end

  -- Voie interne libre ?
  local area = {
    { e.position.x - 18, e.position.y + RAIL_Y - 1.5 },
    { e.position.x + 18, e.position.y + RAIL_Y + 1.5 },
  }
  if #e.surface.find_entities_filtered({ type = STOCK_TYPES, area = area }) > 0 then
    return nil, "spawn-track-occupied"
  end

  -- Bloc de sortie libre ? (le signal de la porte gouverne le bloc aval)
  if state.signal and state.signal.valid
    and state.signal.signal_state ~= defines.signal_state.open then
    return nil, "spawn-exit-blocked"
  end

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

  -- Consommation des composants (après succès de la pose).
  for item, n in pairs(need) do
    inv.remove({ name = item, count = n })
  end

  -- Carburant : premier item de la réserve compatible avec le brûleur de
  -- chaque locomotive, à hauteur d'une pile par loco.
  for _, v in ipairs(spawned) do
    if v.type == "locomotive" then
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

  -- Schedule du blueprint : s'il existe, on l'applique et le train part
  -- tout seul ; sinon il est livré en manuel sur la voie.
  local train = spawned[1].train
  local departed = false
  local why = "no-schedules-in-template"
  if template.schedules and train then
    local applied, aerr = pcall(function()
      local sc = template.schedules[1] or {}
      local body = sc.schedule or sc
      local records = body.records
      local group = body.group or sc.group
      local interrupts = body.interrupts

      -- Ordre IMPORTANT : itinéraire et interruptions d'abord, groupe en
      -- DERNIER. Écrire train.schedule sort le train de son groupe ; et
      -- inscrire le train dans un groupe inexistant crée ce groupe à
      -- partir du schedule ACTUEL du train (comme en vanilla).
      if not (records and #records > 0) then
        -- BP sans stations : le groupe seul peut suffire s'il existe déjà.
        if group and group ~= "" then
          train.group = subst_station(group, params)
          local s2 = train.schedule
          if s2 and s2.records and #s2.records > 0 then
            train.manual_mode = false
            departed = true
            return
          end
        end
        error("no-records")
      end
      -- Les records issus de l'export JSON peuvent porter des champs que le
      -- setter de schedule refuse : on ne recopie que les champs connus.
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
      if #clean == 0 then
        error("no-station-records")
      end
      train.schedule = { current = 1, records = clean }
      -- Interruptions du BP (best effort).
      if interrupts and #interrupts > 0 then
        pcall(function()
          local ls = train.get_schedule()
          for _, it in ipairs(interrupts) do
            ls.add_interrupt(it)
          end
        end)
      end
      -- Groupe en dernier (voir plus haut).
      if group and group ~= "" then
        pcall(function()
          train.group = subst_station(group, params)
        end)
      end
      train.manual_mode = false
      departed = true
    end)
    if not applied then why = tostring(aerr) end
  end

  if departed then
    return "spawn-ok-departed"
  end
  return "spawn-ok-manual", nil, why
end

return builder
