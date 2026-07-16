-- Train Foundry — bootstrap et dispatch des events.
--
-- MODÈLE : le bâtiment visible (assembling-machine "train-foundry", une seule
-- orientation, sortie ouest) est l'entité maîtresse ; à la pose,
-- composite.build crée ses enfants cachés (rails internes, anneau de points
-- de chargement liés, signal de sortie) et le tout est rangé dans
-- storage.foundries[unit_number]. À la dépose (minage, mort, script),
-- composite.destroy nettoie tout. Aucun état hors storage (déterminisme
-- multijoueur).

local composite = require("scripts.composite")
local blueprint = require("scripts.blueprint")
local builder = require("scripts.builder")
local gui = require("scripts.gui")

local MAIN = "train-foundry"

-- ----------------------------------------------------------------------------
-- Storage : init lazy idempotente, appelée en tête de chaque handler
-- (convention défensive — les vieilles saves passent par là aussi).
-- ----------------------------------------------------------------------------

local function ensure_storage()
  -- unit_number -> { entity, rails = {}, inputs = {}, signal, templates, queue }
  storage.foundries = storage.foundries or {}
end

-- Migration : remplissage des champs manquants des vieux states et nettoyage
-- des fonderies dont l'entité a disparu (changement de prototype, etc.).
local function migrate_all()
  ensure_storage()
  -- Les GUI sont sauvegardées avec la partie : après une mise à jour du mod,
  -- les fenêtres ouvertes ont la structure de l'ancienne version — on les
  -- ferme, le joueur les rouvrira.
  for _, player in pairs(game.players) do
    gui.close(player)
  end
  for un, st in pairs(storage.foundries) do
    st.rails = st.rails or {}
    st.inputs = st.inputs or {}
    st.templates = st.templates or {}
    st.queue = st.queue or {}
    if not (st.entity and st.entity.valid) then
      composite.destroy(st)
      storage.foundries[un] = nil
    else
      -- Répare les signaux détachés (mauvaise direction dans les vieilles
      -- versions : ils clignotaient sans gouverner le bloc).
      composite.repair_signal(st)
    end
  end

  -- Balaye les entités du mod ORPHELINES laissées par d'anciennes versions
  -- (ex. rails d'anciennes géométries) : deux lignes de rails qui se
  -- chevauchent font s'atteler les trains de travers. Tout tf-* non
  -- référencé par un state vivant est détruit.
  local referenced = {}
  local function ref(ent)
    if ent and ent.valid then
      referenced[ent.name .. ":" .. ent.position.x .. ":" .. ent.position.y] = true
    end
  end
  for _, st in pairs(storage.foundries) do
    for _, r in ipairs(st.rails or {}) do ref(r) end
    for _, c in ipairs(st.inputs or {}) do ref(c) end
    ref(st.signal)
  end
  for _, surface in pairs(game.surfaces) do
    for _, ent in pairs(surface.find_entities_filtered({
      name = { "tf-rail", "tf-input", "tf-signal" } })) do
      local key = ent.name .. ":" .. ent.position.x .. ":" .. ent.position.y
      if not referenced[key] then
        ent.destroy()
      end
    end
  end
end

script.on_init(ensure_storage)
script.on_configuration_changed(migrate_all)

-- ----------------------------------------------------------------------------
-- Cycle de vie : pose / dépose
-- ----------------------------------------------------------------------------

-- Annule une pose invalide : l'item revient au joueur (ou est déversé au sol
-- pour une pose robot/script), l'entité est retirée.
local function cancel_build(event, e)
  local player = event.player_index and game.get_player(event.player_index)
  if player then
    player.create_local_flying_text({
      text = { "tf-msg.need-rails" },
      position = e.position,
    })
    player.mine_entity(e, true)
  else
    e.surface.spill_item_stack({
      position = e.position,
      stack = { name = MAIN, count = 1 },
      enable_looted = true,
      force = e.force,
    })
    e.destroy()
  end
end

local function on_built(event)
  ensure_storage()
  local e = event.entity or event.created_entity
  if not (e and e.valid) then return end
  if e.name ~= MAIN then return end
  -- Exigence de pose : un rail droit est-ouest existant à la position de
  -- raccord, sous le parvis ouest (la porte se pose sur l'extrémité d'une
  -- voie). Le reste des collisions est géré par le moteur (mask par défaut).
  if not composite.has_junction_rail(e) then
    cancel_build(event, e)
    return
  end
  storage.foundries[e.unit_number] = composite.build(e)
end

local function on_removed(event)
  ensure_storage()
  local e = event.entity
  if not (e and e.valid) then return end
  if e.name ~= MAIN then return end
  composite.destroy(storage.foundries[e.unit_number])
  storage.foundries[e.unit_number] = nil
end

local built_filters = { { filter = "name", name = MAIN } }
script.on_event(defines.events.on_built_entity, on_built, built_filters)
script.on_event(defines.events.on_robot_built_entity, on_built, built_filters)
script.on_event(defines.events.on_space_platform_built_entity, on_built,
  built_filters)
-- Pas de filter sur les events script_raised : le handler re-teste e.name.
script.on_event(defines.events.script_raised_built, on_built)
script.on_event(defines.events.script_raised_revive, on_built)

local removed_filters = { { filter = "name", name = MAIN } }
script.on_event(defines.events.on_player_mined_entity, on_removed,
  removed_filters)
script.on_event(defines.events.on_robot_mined_entity, on_removed,
  removed_filters)
script.on_event(defines.events.on_space_platform_mined_entity, on_removed,
  removed_filters)
script.on_event(defines.events.on_entity_died, on_removed, removed_filters)
script.on_event(defines.events.script_raised_destroy, on_removed)

-- Clonage (éditeur, mods type Space Exploration) : l'entité clonée arrive
-- sans enfants — on lui construit son propre composite.
script.on_event(defines.events.on_entity_cloned, function(event)
  ensure_storage()
  local e = event.destination
  if not (e and e.valid and e.name == MAIN) then return end
  storage.foundries[e.unit_number] = composite.build(e)
end)

-- ----------------------------------------------------------------------------
-- GUI : au clic sur la fonderie, on remplace la fenêtre vanilla d'assembleur
-- (vide, la machine n'a pas de recette) par notre fenêtre : slot de dépôt de
-- blueprint + liste des templates.
-- ----------------------------------------------------------------------------

-- Lit le blueprint et l'enregistre comme template de la fonderie. Le BP est
-- lu à ce moment-là uniquement, et reste au joueur.
local function import_into(state, stack)
  local template, err = blueprint.parse(stack)
  if not template then return nil, err end
  template.name = "Train " .. (#state.templates + 1)
  state.templates[#state.templates + 1] = template
  return template
end

script.on_event(defines.events.on_gui_opened, function(event)
  if event.gui_type ~= defines.gui_type.entity then return end
  local e = event.entity
  if not (e and e.valid and e.name == MAIN) then return end
  ensure_storage()
  local player = game.get_player(event.player_index)
  if not player then return end
  local st = storage.foundries[e.unit_number]
  if not st then return end
  gui.open(player, st)
  -- Referme la GUI vanilla d'assembleur qui s'ouvrait (notre fenêtre est
  -- flottante et vit sa vie indépendamment de player.opened).
  player.opened = nil
end)

script.on_event(defines.events.on_gui_click, function(event)
  local el = event.element
  if not (el and el.valid) then return end
  local player = game.get_player(event.player_index)
  if not player then return end

  if el.name == "tf-close" then
    gui.close(player)
    return
  end

  if el.name == "tf-params-cancel" then
    local frame = player.gui.screen["tf-params"]
    if frame then frame.destroy() end
    return
  end
  if el.name == "tf-params-go" then
    ensure_storage()
    local params, p_un, p_index = gui.collect_params(player)
    local frame = player.gui.screen["tf-params"]
    if frame then frame.destroy() end
    if not params then return end
    local p_st = storage.foundries[p_un]
    local t = p_st and p_st.templates[p_index]
    if not t then return end
    local ok, err, detail = builder.try_spawn(p_st, t, params)
    if ok then
      player.print({ "tf-msg." .. ok, t.name })
      if ok == "spawn-ok-manual" and detail then
        player.print("[tf] schedule: " .. detail)
      end
    elseif detail then
      player.print({ "tf-msg." .. err, detail })
    else
      player.print({ "tf-msg." .. err })
    end
    return
  end

  local un = gui.window_unit_number(player)
  if not un then return end
  ensure_storage()
  local st = storage.foundries[un]
  if not (st and st.entity and st.entity.valid) then
    gui.close(player)
    return
  end

  if el.name == "tf-open-stock" then
    -- Ouvre le coffre natif de la réserve (UI vanilla avec l'inventaire du
    -- joueur en face) ; notre fenêtre flottante reste ouverte à côté.
    for _, c in ipairs(st.inputs or {}) do
      if c.valid then
        player.opened = c
        break
      end
    end
  elseif el.name == "tf-bp-slot" then
    -- Dépôt : cliquer sur le slot avec le blueprint en main (item de
    -- l'inventaire OU blueprint de la bibliothèque — cursor_record). Le BP
    -- est lu à ce moment-là uniquement, puis reste en main.
    local template, err = import_into(st,
      blueprint.cursor_source(player) or player.cursor_stack)
    if not template then
      player.print({ "tf-msg." .. err })
      return
    end
    local locos, wagons = blueprint.counts(template)
    local has_sched = template.schedules and #template.schedules > 0
    local key = has_sched and "tf-msg.import-ok" or "tf-msg.import-ok-nosched"
    player.print({ key, template.name, locos, wagons })
    -- Diagnostics temporaires.
    if not has_sched then
      player.print("[tf] source: " .. tostring(template.source_kind))
    end
    if template.parameters and #template.parameters > 0 then
      player.print("[tf] params: " .. serpent.line(template.parameters))
      local sc = template.schedules and template.schedules[1]
      local rec = sc and ((sc.schedule and sc.schedule.records) or sc.records)
      if rec and rec[1] then
        player.print("[tf] station[1]: " .. tostring(rec[1].station))
      end
    end
    gui.refresh(player, st)
  elseif el.tags and el.tags.tf_action == "delete-template" then
    table.remove(st.templates, el.tags.index)
    gui.refresh(player, st)
  elseif el.tags and el.tags.tf_action == "spawn-template" then
    local t = st.templates[el.tags.index]
    if not t then return end
    -- Blueprint paramétré : demander les valeurs avant de construire.
    if t.parameters and #t.parameters > 0 then
      gui.open_params(player, st, el.tags.index, t)
      return
    end
    local ok, err, detail = builder.try_spawn(st, t)
    if ok then
      player.print({ "tf-msg." .. ok, t.name })
      -- Diagnostic temporaire : pourquoi le train est resté en manuel.
      if ok == "spawn-ok-manual" and detail then
        player.print("[tf] schedule: " .. detail)
      end
    elseif detail then
      player.print({ "tf-msg." .. err, detail })
    else
      player.print({ "tf-msg." .. err })
    end
  end
end)

-- Rafraîchit la section Réserve des fenêtres ouvertes (1×/seconde) : on voit
-- les bras alimenter la fonderie en direct.
script.on_nth_tick(60, function()
  ensure_storage()
  for _, player in pairs(game.connected_players) do
    local un = gui.window_unit_number(player)
    if un then
      local st = storage.foundries[un]
      if st and st.entity and st.entity.valid then
        gui.refresh_stock(player, st)
      else
        gui.close(player)
      end
    end
  end
end)

-- ----------------------------------------------------------------------------
-- Interface remote : utilisée par les tests automatisés (et utilisable par
-- d'autres mods). Mêmes chemins de code que la GUI.
-- ----------------------------------------------------------------------------
remote.add_interface("train-foundry", {
  -- Importe `stack` (LuaItemStack blueprint) dans la fonderie unit_number.
  -- Retourne "ok:<nb véhicules>" ou la clé d'erreur.
  import_blueprint = function(stack, unit_number)
    ensure_storage()
    local st = storage.foundries[unit_number]
    if not st then return "import-no-foundry" end
    local template, err = import_into(st, stack)
    if not template then return err end
    return "ok:" .. #template.stock
  end,
  -- Construit le train du template `index` de la fonderie. Retourne la clé
  -- de message ("spawn-ok-departed", "spawn-missing", ...) + détail éventuel.
  spawn_template = function(unit_number, index)
    ensure_storage()
    local st = storage.foundries[unit_number]
    if not st then return "import-no-foundry" end
    local t = st.templates[index]
    if not t then return "import-no-foundry" end
    local ok, err, detail = builder.try_spawn(st, t)
    return (ok or err) .. (detail and (" | " .. detail) or "")
  end,
  -- Résumé des templates d'une fonderie ("Train 1(6), Train 2(3)").
  templates = function(unit_number)
    ensure_storage()
    local st = storage.foundries[unit_number]
    if not st then return "import-no-foundry" end
    local out = {}
    for _, t in ipairs(st.templates) do
      out[#out + 1] = t.name .. "(" .. #t.stock .. ")"
    end
    return table.concat(out, ", ")
  end,
})

-- Diagnostic : /tf-scan liste tous les rails et véhicules autour de la voie
-- de la fonderie survolée (positions, directions, orientations) — pour
-- comprendre les attelages de travers.
commands.add_command("tf-scan", "Scanne la voie de la fonderie survolée", function(cmd)
  ensure_storage()
  local player = game.get_player(cmd.player_index)
  if not player then return end
  local e = player.selected
  if not (e and e.valid and e.name == MAIN) then
    player.print("[tf-scan] survole la fonderie.")
    return
  end
  local area = { { e.position.x - 22, e.position.y + 1 },
                 { e.position.x + 22, e.position.y + 9 } }
  for _, r in pairs(e.surface.find_entities_filtered({
    type = { "straight-rail", "curved-rail-a", "curved-rail-b",
             "half-diagonal-rail", "legacy-straight-rail",
             "legacy-curved-rail", "elevated-straight-rail", "rail-ramp" },
    area = area })) do
    player.print(string.format("[rail] %s @%.1f,%.1f dir=%d",
      r.name, r.position.x - e.position.x, r.position.y - e.position.y,
      r.direction))
  end
  for _, v in pairs(e.surface.find_entities_filtered({
    type = { "locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon" },
    area = area })) do
    player.print(string.format("[train] %s @%.2f,%.2f o=%.4f",
      v.name, v.position.x - e.position.x, v.position.y - e.position.y,
      v.orientation))
  end
end)

-- ----------------------------------------------------------------------------
-- Debug : /tf-debug imprime l'état de la foundry survolée (n'invalide pas
-- les achievements, contrairement à /c).
-- ----------------------------------------------------------------------------

commands.add_command("tf-debug", "État de la Train Foundry survolée", function(cmd)
  ensure_storage()
  local player = game.get_player(cmd.player_index)
  if not player then return end
  local e = player.selected
  if not (e and e.valid and e.name == MAIN) then
    player.print("[tf-debug] survole une Train Foundry d'abord.")
    return
  end
  local st = storage.foundries[e.unit_number]
  if not st then
    player.print("[tf-debug] AUCUN state pour cette entité (bug !).")
    return
  end
  local rails_ok, inputs_ok = 0, 0
  for _, r in ipairs(st.rails) do
    if r.valid then rails_ok = rails_ok + 1 end
  end
  for _, c in ipairs(st.inputs) do
    if c.valid then inputs_ok = inputs_ok + 1 end
  end
  local stock = "vide"
  for _, c in ipairs(st.inputs) do
    if c.valid then
      local inv = c.get_inventory(defines.inventory.chest)
      if inv then stock = tostring(inv.get_item_count()) .. " items" end
      break
    end
  end
  local signal = "MANQUANT"
  if st.signal and st.signal.valid then
    signal = "ok (signal_state=" .. tostring(st.signal.signal_state) .. ")"
  end
  player.print(string.format(
    "[tf-debug] rails=%d/%d raccord=%s inputs=%d/%d stock=%s signal=%s templates=%d",
    rails_ok, #st.rails,
    composite.has_junction_rail(e) and "ok" or "MANQUANT",
    inputs_ok, #st.inputs, stock, signal, #st.templates))
end)
