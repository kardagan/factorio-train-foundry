-- Train Foundry — bootstrap et dispatch des events.
--
-- MODÈLE : le bâtiment visible (assembling-machine "train-foundry", une seule
-- orientation, sortie ouest) est l'entité maîtresse ; à la pose,
-- composite.build crée ses enfants cachés (anneau de points de chargement
-- liés, signal de sortie) et le tout est rangé dans
-- storage.foundries[unit_number]. À la dépose (minage, mort, script),
-- composite.destroy nettoie tout. Aucun état hors storage (déterminisme
-- multijoueur).
--
-- PRODUCTION (M3) : chaque fonderie a une file d'attente (st.queue) et un
-- travail en cours (st.work). La boucle on_nth_tick fait avancer chaque
-- fonderie : attente des composants -> consommation -> construction (durée
-- proportionnelle au nombre de véhicules) -> attente de voie/sortie libre ->
-- spawn du train -> entrée suivante.

local composite = require("scripts.composite")
local blueprint = require("scripts.blueprint")
local builder = require("scripts.builder")
local gui = require("scripts.gui")

local MAIN = "train-foundry"

-- La boucle tourne toutes les 30 ticks (0,5 s).
local TICK_INTERVAL = 30

-- ----------------------------------------------------------------------------
-- Storage : init lazy idempotente, appelée en tête de chaque handler
-- (convention défensive — les vieilles saves passent par là aussi).
-- ----------------------------------------------------------------------------

local function ensure_storage()
  -- unit_number -> { entity, rails = {}, inputs = {}, signal,
  --                  templates = {}, queue = {}, work = nil }
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
    gui.close_bp(player)
  end
  for un, st in pairs(storage.foundries) do
    st.rails = st.rails or {}
    st.templates = st.templates or {}
    st.queue = st.queue or {}
    -- Migration de l'ancien couple de booléens vers emit_mode.
    if st.emit_mode == nil then
      st.emit_mode = st.emit_request and "request" or "stock"
      st.emit_stock, st.emit_request = nil, nil
    end
    if not (st.entity and st.entity.valid) then
      composite.destroy(st)
      storage.foundries[un] = nil
    else
      -- Répare les signaux détachés (mauvaise direction dans les vieilles
      -- versions : ils clignotaient sans gouverner le bloc).
      composite.repair_signal(st)
      -- Crée les enfants manquants sur les fonderies d'avant leur ajout
      -- (réserve, connecteur circuit, coffre à blueprints) : mise à jour EN
      -- PLACE, sans que le joueur ait à miner puis reposer la fonderie.
      composite.ensure_input(st)
      composite.ensure_combinator(st)
      composite.ensure_bpchest(st)
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
    ref(st.input)
    ref(st.bpchest)
    ref(st.signal)
    ref(st.combinator)
    -- Legacy : anneau de quais + 4 combinators d'anciennes versions.
    for _, c in ipairs(st.inputs or {}) do ref(c) end
    for _, c in ipairs(st.combinators or {}) do ref(c) end
  end
  for _, surface in pairs(game.surfaces) do
    for _, ent in pairs(surface.find_entities_filtered({
      name = { "tf-rail", "tf-input", "tf-signal", "tf-combinator",
               "tf-blueprints" } })) do
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
-- pour une pose robot/script), l'entité est retirée. `msg_key` = clé du
-- message affiché (section [tf-msg]).
local function cancel_build(event, e, msg_key)
  local player = event.player_index and game.get_player(event.player_index)
  if player then
    player.create_local_flying_text({
      text = { "tf-msg." .. (msg_key or "need-rails") },
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
  -- Limite : UNE fonderie par surface (planète / plateforme spatiale).
  for _, st in pairs(storage.foundries) do
    if st.entity and st.entity.valid and st.entity.surface == e.surface then
      cancel_build(event, e, "one-per-surface")
      return
    end
  end
  -- Exigence de pose : un rail droit est-ouest existant à la position de
  -- raccord, sous le parvis ouest (la porte se pose sur l'extrémité d'une
  -- voie). Le reste des collisions est géré par le moteur (mask par défaut).
  if not composite.has_junction_rail(e) then
    cancel_build(event, e, "need-rails")
    return
  end
  storage.foundries[e.unit_number] = composite.build(e)
end

local function on_removed(event)
  ensure_storage()
  local e = event.entity
  if not (e and e.valid) then return end
  if e.name ~= MAIN then return end
  local st = storage.foundries[e.unit_number]
  -- Rend les composants d'une construction en cours avant le nettoyage.
  if st and st.work and st.work.phase ~= "waiting" and st.work.need then
    builder.refund(st, st.work.need)
  end
  composite.destroy(st)
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
-- Coffre à blueprints : la BOÎTE D'ENTRÉE. On y dépose des blueprints, et la
-- fonderie en dérive ses templates. La lecture se fait à la volée (aucun
-- « import » manuel) : la validation d'un BP (train pur, longueur, voie
-- droite) a lieu au moment où on le lit, donc AVANT tout lancement.
-- ----------------------------------------------------------------------------

-- Signature d'un slot : identifie un BP pour ne le re-parser que s'il a changé
-- (perf + stabilité des paramètres déjà saisis). Label + nombre d'entités
-- suffit à repérer un remplacement dans un slot donné.
local function slot_signature(stack)
  if not (stack and stack.valid_for_read and stack.is_blueprint
          and stack.is_blueprint_setup()) then
    return nil
  end
  local ents = stack.get_blueprint_entities()
  return (stack.label or "") .. "#" .. (ents and #ents or 0)
end

-- Resynchronise state.templates depuis le contenu du coffre. Un template par
-- slot occupé, dans l'ordre du coffre. Un BP non conforme est conservé comme
-- template INVALIDE (affiché en rouge, non enfilable) — le joueur voit que son
-- plan n'est pas bon sans qu'on le lui renvoie.
local function sync_templates(state)
  local chest = composite.bp_chest(state)
  if not chest then return end
  local inv = chest.get_inventory(defines.inventory.chest)
  if not inv then return end

  local old_by_sig = {}
  for _, t in ipairs(state.templates) do
    if t.signature then old_by_sig[t.signature] = t end
  end

  local templates = {}
  for i = 1, #inv do
    local stack = inv[i]
    local sig = slot_signature(stack)
    if sig then
      local existing = old_by_sig[sig]
      if existing then
        templates[#templates + 1] = existing
      else
        local template, err, detail = blueprint.parse(stack)
        if template then
          template.name = (template.label and template.label ~= ""
            and template.label) or ""
          template.signature = sig
          template.invalid = nil
          templates[#templates + 1] = template
        else
          templates[#templates + 1] = {
            name = (stack.label and stack.label ~= "" and stack.label) or "",
            signature = sig,
            invalid = err or "import-not-clean",
            invalid_detail = detail,
            icons = (function()
              -- 2.0 : preview_icons (ex-blueprint_icons).
              local ok, ic = pcall(function() return stack.preview_icons end)
              return ok and ic or nil
            end)(),
            stock = {},
          }
        end
      end
    end
  end
  state.templates = templates

  -- Empreinte du livre = signatures dans l'ordre. Sert à ne reconstruire la
  -- section livre de la fenêtre QUE quand le coffre change réellement.
  local fp = {}
  for _, t in ipairs(templates) do fp[#fp + 1] = t.signature end
  local new_fp = table.concat(fp, "|")
  local changed = (new_fp ~= state.book_fingerprint)
  state.book_fingerprint = new_fp
  return changed
end

-- ----------------------------------------------------------------------------
-- Boucle de production : file d'attente -> composants -> construction ->
-- sortie. Une passe par fonderie toutes les TICK_INTERVAL ticks.
-- ----------------------------------------------------------------------------

local function process_foundry(st)
  local work = st.work
  if not work then
    if #st.queue == 0 then return end
    work = {
      entry = table.remove(st.queue, 1),
      phase = "waiting",
      progress = 0,
    }
    st.work = work
  end
  local template = work.entry.template

  if work.phase == "waiting" then
    -- Attente des composants (et d'une voie libre pour poser le châssis).
    work.need = work.need or builder.compute_need(template)
    local miss = builder.missing(st, work.need)
    work.missing = miss
    if next(miss) then
      work.blocked = "components"
    elseif not builder.track_free(st) then
      work.blocked = "track"
    else
      work.blocked = nil
      builder.consume(st, work.need)
      work.phase = "building"
      work.progress = 0
      work.total_ticks = #template.stock * builder.TICKS_PER_VEHICLE
    end
  elseif work.phase == "building" then
    work.progress = math.min(1,
      work.progress + TICK_INTERVAL / work.total_ticks)
    if work.progress >= 1 then
      work.phase = "ready"
    end
  elseif work.phase == "ready" then
    -- Sortie : voie interne libre (le train précédent est parti) et bloc
    -- de sortie ouvert.
    if builder.track_free(st) and builder.exit_open(st) then
      local ok = builder.spawn(st, template, work.entry.params)
      if not ok then
        -- Échec dur de la pose : on rend les composants plutôt que de
        -- bloquer la file.
        builder.refund(st, work.need)
      end
      st.work = nil
    end
  end
end

script.on_nth_tick(TICK_INTERVAL, function()
  ensure_storage()
  -- unit_number -> le livre a-t-il changé ce tick (coffre modifié) ?
  local book_changed = {}
  for un, st in pairs(storage.foundries) do
    if st.entity and st.entity.valid then
      book_changed[un] = sync_templates(st)
      process_foundry(st)
      builder.update_circuit(st)
    end
  end
  -- Rafraîchit les fenêtres ouvertes : sections dynamiques à chaque tick, et
  -- le livre uniquement si le coffre de cette fonderie a changé.
  for _, player in pairs(game.connected_players) do
    local un = gui.window_unit_number(player)
    if un then
      local st = storage.foundries[un]
      if st and st.entity and st.entity.valid then
        gui.refresh_dynamic(player, st)
        if book_changed[un] then
          gui.refresh_templates(player, st)
        end
      else
        gui.close(player)
      end
    end
    -- Fenêtre coffre à blueprints (indépendante) : la resynchroniser si son
    -- coffre a changé (dépôt/retrait aux bras pendant qu'elle est ouverte).
    local bp_un = gui.bp_window_unit_number(player)
    if bp_un then
      local st = storage.foundries[bp_un]
      if st and st.bpchest and st.bpchest.valid then
        if book_changed[bp_un] then gui.refresh_bp(player, st) end
      else
        gui.close_bp(player)
      end
    end
  end
end)

-- ----------------------------------------------------------------------------
-- GUI : ouverture, file d'attente.
-- ----------------------------------------------------------------------------

-- Met un template en file (avec ses paramètres éventuels).
local function enqueue(state, template, params)
  state.queue[#state.queue + 1] = {
    name = template.name,
    template = template,
    params = params,
  }
end

-- Clic sur un slot de la fenêtre coffre à blueprints :
--  - un PLAN en main (item d'inventaire OU record de bibliothèque) → on le
--    dépose dans le coffre (l'item est transféré ; un record est exporté puis
--    réimporté dans un blueprint vierge du coffre) ;
--  - sinon, si le slot est PLEIN et la main VIDE → on reprend le plan en main.
local function handle_bp_slot(player, state, index)
  local chest = state.bpchest
  local inv = chest.get_inventory(defines.inventory.chest)
  if not inv then return end

  local cursor = player.cursor_stack
  local record = player.cursor_record

  -- 1) Dépôt d'un ITEM blueprint tenu en main.
  if cursor and cursor.valid_for_read and cursor.is_blueprint then
    if inv.can_insert(cursor) then
      inv.insert(cursor)
      cursor.clear()
    else
      player.create_local_flying_text({
        text = { "tf-msg.bp-chest-full" }, position = chest.position })
    end
    return
  end

  -- 2) Dépôt d'un blueprint de la BIBLIOTHÈQUE (record : pas d'item, on crée un
  --    blueprint vierge dans le coffre puis on y importe la chaîne exportée).
  if record and record.valid and record.type == "blueprint" then
    local n = inv.insert({ name = "blueprint" })
    if n == 0 then
      player.create_local_flying_text({
        text = { "tf-msg.bp-chest-full" }, position = chest.position })
      return
    end
    -- Retrouve le blueprint vierge qu'on vient d'insérer (dernier occupé).
    local target
    for i = #inv, 1, -1 do
      local s = inv[i]
      if s.valid_for_read and s.is_blueprint and not s.is_blueprint_setup() then
        target = s
        break
      end
    end
    local ok = false
    if target then
      local okc, str = pcall(function() return record.export_record() end)
      if okc and str then
        ok = (target.import_stack(str) ~= 1)  -- 0 = ok, -1 = ok avec pertes
      end
    end
    if not ok then
      -- Import raté : on retire le blueprint vierge pour ne pas polluer.
      if target and target.valid_for_read then target.clear() end
      player.create_local_flying_text({
        text = { "tf-msg.import-not-blueprint" }, position = chest.position })
    end
    return
  end

  -- 3) Main vide : on reprend le plan du slot cliqué (s'il est plein).
  if not (cursor and cursor.valid_for_read) then
    local stack = inv[index]
    if stack and stack.valid_for_read then
      if cursor and cursor.can_set_stack(stack) then
        cursor.set_stack(stack)
        stack.clear()
      else
        -- Repli : dans l'inventaire du joueur.
        player.insert(stack)
        stack.clear()
      end
    end
  end
end

script.on_event(defines.events.on_gui_opened, function(event)
  if event.gui_type ~= defines.gui_type.entity then return end
  local e = event.entity
  if not (e and e.valid) then return end
  ensure_storage()
  local player = game.get_player(event.player_index)
  if not player then return end

  -- Aiguillage selon l'entité cliquée :
  --  - bâtiment / combinateur → fenêtre principale (CLASSIQUE, player.opened,
  --    Échap la ferme) ;
  --  - coffre à blueprints → fenêtre FLOTTANTE dédiée (B ne la ferme pas, on
  --    peut y déposer un plan) ; on neutralise sa GUI vanilla ;
  --  - coffre de réserve → GUI vanilla conservée (dépôt de composants).
  if e.name == "tf-blueprints" then
    for _, s in pairs(storage.foundries) do
      if s.bpchest == e then
        gui.open_bp(player, s)
        -- Ferme la GUI vanilla du coffre : la nôtre (flottante) la remplace.
        player.opened = nil
        break
      end
    end
    return
  end

  local st
  if e.name == MAIN then
    st = storage.foundries[e.unit_number]
  elseif e.name == "tf-combinator" then
    for _, s in pairs(storage.foundries) do
      if s.combinator == e then st = s break end
    end
  end
  if not st then return end
  -- Lit le coffre à blueprints avant d'afficher le livre (à jour dès
  -- l'ouverture, sans attendre le prochain tick de la boucle).
  sync_templates(st)
  -- gui.open pose lui-même player.opened = frame (fenêtre classique) : NE PAS
  -- remettre player.opened = nil ensuite, ça fermerait notre fenêtre.
  gui.open(player, st)
end)

-- Raccourci (barre du bas + touche) : ouvre directement l'UI de la fonderie
-- de la surface courante — le but du mod : la piloter sans se déplacer
-- jusqu'à elle. (Une seule fonderie par surface.)
local function open_overview(player)
  ensure_storage()
  local surface = player.physical_surface or player.surface
  for _, st in pairs(storage.foundries) do
    if st.entity and st.entity.valid and st.entity.surface == surface then
      gui.open(player, st)
      return
    end
  end
  player.print({ "tf-msg.no-foundry-here" })
end

script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name ~= "tf-open-overview" then return end
  local player = game.get_player(event.player_index)
  if player then open_overview(player) end
end)

script.on_event("tf-open-overview", function(event)
  local player = game.get_player(event.player_index)
  if player then open_overview(player) end
end)

-- Fenêtre classique : Échap (ou clic ailleurs) déclenche on_gui_closed sur
-- notre frame → on nettoie tout (fenêtre principale + déportées).
script.on_event(defines.events.on_gui_closed, function(event)
  local el = event.element
  if el and el.valid and el.name == gui.WINDOW then
    local player = game.get_player(event.player_index)
    if player then gui.close(player) end
  end
end)

-- Recale la fenêtre circuit déportée quand on déplace la principale.
script.on_event(defines.events.on_gui_location_changed, function(event)
  local el = event.element
  if el and el.valid and el.name == gui.WINDOW then
    local player = game.get_player(event.player_index)
    if player then gui.reposition_circuit(player) end
  end
end)

-- Radios du circuit : émettre le stock OU les requests (exclusif).
script.on_event(defines.events.on_gui_checked_state_changed, function(event)
  local el = event.element
  if not (el and el.valid and el.tags and el.tags.tf_emit_mode) then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  local un = gui.window_unit_number(player)
  if not un then return end
  ensure_storage()
  local st = storage.foundries[un]
  if not (st and st.entity and st.entity.valid) then return end
  st.emit_mode = el.tags.tf_emit_mode
  -- Radios exclusifs : décoche l'autre bouton.
  gui.set_emit_mode(player, st.emit_mode)
  builder.update_circuit(st)
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

  if el.name == "tf-bp-close" then
    gui.close_bp(player)
    return
  end

  -- « Vider la file » : retire toutes les entrées en attente (ne touche pas au
  -- travail en cours).
  if el.name == "tf-queue-clear" then
    local un = gui.window_unit_number(player)
    local st = un and storage.foundries[un]
    if st and st.entity and st.entity.valid then
      st.queue = {}
      gui.refresh_queue(player, st)
    end
    return
  end

  -- « + » du livre : ferme la fenêtre principale et ouvre le coffre à plans.
  if el.name == "tf-open-bpchest" then
    local un = gui.window_unit_number(player)
    local st = un and storage.foundries[un]
    if st and st.bpchest and st.bpchest.valid then
      gui.close(player)
      gui.open_bp(player, st)
    end
    return
  end

  -- Slot de la fenêtre coffre à blueprints : dépose (plan en main) ou reprend
  -- (slot plein). Clic GUI pur — aucun risque de « stamper » le blueprint sur
  -- le monde, contrairement à un clic-monde.
  if el.tags and el.tags.tf_action == "bp-slot" then
    local un = gui.bp_window_unit_number(player)
    ensure_storage()
    local st = un and storage.foundries[un]
    if not (st and st.bpchest and st.bpchest.valid) then
      gui.close_bp(player)
      return
    end
    handle_bp_slot(player, st, el.tags.index)
    gui.refresh_bp(player, st)
    sync_templates(st)
    -- Rafraîchit le livre de la fenêtre principale UNIQUEMENT si elle est
    -- ouverte sur cette même fonderie (sinon refresh_templates la fermerait).
    if gui.window_unit_number(player) == un then
      gui.refresh_templates(player, st)
    end
    return
  end

  if el.name == "tf-circuit-toggle" then
    local un = gui.window_unit_number(player)
    local st = un and storage.foundries[un]
    if st and st.entity and st.entity.valid then
      gui.toggle_circuit(player, st)
    end
    return
  end
  if el.name == "tf-circuit-close" then
    local w = player.gui.screen[gui.CIRCUIT_WINDOW]
    if w then w.destroy() end
    return
  end

  if el.name == "tf-params-cancel" then
    local frame = player.gui.screen["tf-params"]
    if frame then frame.destroy() end
    return
  end
  if el.name == "tf-params-go" then
    ensure_storage()
    local params, p_un, p_index, p_sig = gui.collect_params(player)
    local frame = player.gui.screen["tf-params"]
    if frame then frame.destroy() end
    if not params then return end
    local p_st = storage.foundries[p_un]
    if not p_st then return end
    -- Résolution par SIGNATURE d'abord (le livre a pu se réindexer depuis
    -- l'ouverture du dialogue), repli sur l'index.
    local t
    if p_sig then
      for _, cand in ipairs(p_st.templates) do
        if cand.signature == p_sig then t = cand break end
      end
    end
    t = t or p_st.templates[p_index]
    if not t or t.invalid then return end
    enqueue(p_st, t, params)
    gui.refresh_queue(player, p_st)
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

  if el.tags and el.tags.tf_action == "template-slot" then
    -- Le livre reflète le coffre à blueprints ; on ne supprime pas d'ici (on
    -- retire le BP du coffre). Clic = mise en file (paramètres demandés si le
    -- BP en a). Un plan invalide n'a pas de tag d'action, on n'arrive pas ici.
    local t = st.templates[el.tags.index]
    if not t or t.invalid then return end
    if t.parameters and #t.parameters > 0 then
      gui.open_params(player, st, el.tags.index, t)
      return
    end
    enqueue(st, t, nil)
    gui.refresh_queue(player, st)
  elseif el.tags and el.tags.tf_action == "cancel-queued" then
    table.remove(st.queue, el.tags.index)
    gui.refresh_queue(player, st)
  elseif el.tags and el.tags.tf_action == "cancel-work" then
    if st.work then
      if st.work.phase ~= "waiting" and st.work.need then
        builder.refund(st, st.work.need)
      end
      st.work = nil
      gui.refresh_dynamic(player, st)
    end
  end
end)

-- ----------------------------------------------------------------------------
-- Interface remote : utilisée par les tests automatisés (et utilisable par
-- d'autres mods). Mêmes chemins de code que la GUI.
-- ----------------------------------------------------------------------------

remote.add_interface("train-foundry", {
  -- Dépose `stack` (LuaItemStack blueprint) dans le coffre à blueprints de la
  -- fonderie et resynchronise les templates. Retourne "ok:<nb véhicules>",
  -- "invalid:<clé>" si le plan est refusé, ou une clé d'erreur.
  import_blueprint = function(stack, unit_number)
    ensure_storage()
    local st = storage.foundries[unit_number]
    if not st then return "import-no-foundry" end
    local chest = composite.bp_chest(st)
    if not chest then return "import-no-foundry" end
    local inv = chest.get_inventory(defines.inventory.chest)
    if not (inv and inv.insert(stack) > 0) then return "import-not-blueprint" end
    sync_templates(st)
    local last = st.templates[#st.templates]
    if not last then return "import-not-blueprint" end
    if last.invalid then return "invalid:" .. last.invalid end
    return "ok:" .. #last.stock
  end,
  -- Construction immédiate (contourne la file) — tests/regression.
  spawn_template = function(unit_number, index)
    ensure_storage()
    local st = storage.foundries[unit_number]
    if not st then return "import-no-foundry" end
    local t = st.templates[index]
    if not t then return "import-no-foundry" end
    local ok, err, detail = builder.try_spawn(st, t)
    return (ok or err) .. (detail and (" | " .. detail) or "")
  end,
  -- Met un template en file d'attente.
  enqueue_template = function(unit_number, index)
    ensure_storage()
    local st = storage.foundries[unit_number]
    if not st then return "import-no-foundry" end
    local t = st.templates[index]
    if not t then return "import-no-foundry" end
    enqueue(st, t, nil)
    return "ok:" .. #st.queue
  end,
  -- État de la production ("queue=N work=<phase> progress=P").
  queue_state = function(unit_number)
    ensure_storage()
    local st = storage.foundries[unit_number]
    if not st then return "import-no-foundry" end
    local w = st.work
    return string.format("queue=%d work=%s progress=%.2f",
      #st.queue, w and w.phase or "-", w and w.progress or 0)
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

-- ----------------------------------------------------------------------------
-- Diagnostic : /tf-scan liste tous les rails et véhicules autour de la voie
-- de la fonderie survolée (positions, directions, orientations).
-- ----------------------------------------------------------------------------

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
  local rails_ok = 0
  for _, r in ipairs(st.rails) do
    if r.valid then rails_ok = rails_ok + 1 end
  end
  local stock = "MANQUANT"
  if st.input and st.input.valid then
    local inv = st.input.get_inventory(defines.inventory.chest)
    stock = inv and (tostring(inv.get_item_count()) .. " items") or "?"
  end
  local signal = "MANQUANT"
  if st.signal and st.signal.valid then
    signal = "ok (signal_state=" .. tostring(st.signal.signal_state) .. ")"
  end
  local w = st.work
  player.print(string.format(
    "[tf-debug] rails=%d/%d raccord=%s coffre=%s combi=%s signal=%s "
    .. "templates=%d queue=%d work=%s",
    rails_ok, #st.rails,
    composite.has_junction_rail(e) and "ok" or "MANQUANT",
    stock,
    (st.combinator and st.combinator.valid) and "ok" or "MANQUANT",
    signal, #st.templates, #st.queue, w and w.phase or "-"))
end)
