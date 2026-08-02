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

local names = require("names")
local composite = require("scripts.composite")
local blueprint = names.has_bpchest and require("scripts.blueprint") or nil
local builder = require("scripts.builder")
local gui = require("scripts.gui")
local stc_template = (names.source == "stc") and require("scripts.stc_template") or nil

local MAIN = names.building

-- La boucle tourne toutes les 30 ticks (0,5 s).
local TICK_INTERVAL = 30

-- Le carburant est-il géré en mode GÉNÉRIQUE (meilleur carburant débloqué dispo +
-- interruption Refuel) pour cette fonderie ? Toujours en variante STC (pas de
-- carburant blueprinté à respecter). En variante BP : selon l'option par fonderie
-- state.generic_fuel (défaut false = respecter le carburant du blueprint, 0.5.x).
local function fuel_is_generic(st)
  if names.source == "stc" then return true end
  return st.generic_fuel and true or false
end

-- ----------------------------------------------------------------------------
-- Storage : init lazy idempotente, appelée en tête de chaque handler
-- (convention défensive — les vieilles saves passent par là aussi).
-- ----------------------------------------------------------------------------

local function ensure_storage()
  -- unit_number -> { entity, rails = {}, inputs = {}, signal,
  --                  templates = {}, queue = {}, work = nil }
  storage.foundries = storage.foundries or {}
end

-- Entité du BORD EST d'une chaîne : la dernière extension (rangées ouest -> est)
-- si la chaîne en a, sinon le master lui-même. C'est là que débouche la voie de
-- sortie est. Sert d'ancre à composite.open_east.
local function east_end_entity(master)
  local exts = master and master.extensions or {}
  for i = #exts, 1, -1 do
    local ext = storage.foundries[exts[i]]
    if ext and ext.entity and ext.entity.valid then return ext.entity end
  end
  return master and master.entity
end

-- Liste ORDONNÉE ouest->est des entités valides d'une chaîne : master puis ses
-- extensions dans l'ordre. Sert d'entrée à composite.rebuild_chain_track.
local function chain_entities(master)
  local list = {}
  if master and master.entity and master.entity.valid then
    list[#list + 1] = master.entity
  end
  for _, un in ipairs(master and master.extensions or {}) do
    local ext = storage.foundries[un]
    if ext and ext.entity and ext.entity.valid then
      list[#list + 1] = ext.entity
    end
  end
  return list
end

-- Comme chain_entities mais retourne les STATES ordonnés (master + extensions
-- valides, ouest→est). Utilisé pour les murs de chaîne (composite n'a pas accès
-- à storage, on lui passe les states).
local function chain_states(master)
  local list = {}
  if master and master.entity and master.entity.valid then
    list[#list + 1] = master
  end
  for _, un in ipairs(master and master.extensions or {}) do
    local ext = storage.foundries[un]
    if ext and ext.entity and ext.entity.valid then
      list[#list + 1] = ext
    end
  end
  return list
end

-- Reconstruit toute la voie de la chaîne (jonctions + sortie est ré-ancrée) ET
-- les murs de chaîne (haut/bas par module, côté ouest sur le master, côté est sur
-- le dernier module, hall continu entre modules) — à appeler à chaque ajout/
-- retrait d'extension. Centralise le nettoyage pour éviter rails orphelins.
local function refresh_chain_track(master)
  if not master then return end
  composite.rebuild_chain_track(master, chain_entities(master))
  composite.rebuild_chain_walls(master, chain_states(master))
  composite.rebuild_deco_track(master, chain_states(master))  -- voie recyclage si deco
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
    -- Vieilles saves : toutes les fonderies étaient des maîtres autonomes.
    st.role = st.role or "master"
    -- Migration de l'ancien couple de booléens vers emit_mode.
    if st.emit_mode == nil then
      st.emit_mode = st.emit_request and "request" or "stock"
      st.emit_stock, st.emit_request = nil, nil
    end
    -- Côtés de sortie (ajoutés avec la sortie est). Vieille save = gauche seule.
    if st.exit_left == nil then st.exit_left = true end
    if st.exit_right == nil then st.exit_right = false end
    -- Voie de recyclage (optionnelle, off par défaut) + ses côtés.
    if st.deco == nil then st.deco = false end
    if st.deco_left == nil then st.deco_left = true end
    if st.deco_right == nil then st.deco_right = false end
    -- Carburant générique (0.7.x) : défaut false = comportement 0.5.x (respecte
    -- le carburant du blueprint), pour ne pas surprendre une save existante.
    if st.generic_fuel == nil then st.generic_fuel = false end
    -- Ancien champ chain_sprites = rendus LuaRendering (au-dessus des roues)
    -- d'anciennes versions de test. Purge-les, sinon ils resteraient affichés.
    if st.chain_sprites then
      for _, id in ipairs(st.chain_sprites) do
        if id and id.valid then id.destroy() end
      end
      st.chain_sprites = nil
    end
    if not (st.entity and st.entity.valid) then
      composite.destroy(st)
      storage.foundries[un] = nil
    elseif st.role == "extension" then
      -- Extension : pas de coffres/signal, juste sa voie + ses murs.
      st.master = st.master  -- (conservé tel quel)
      -- Champs murs (ajoutés avec les extensions murées) : init défensive. Les
      -- murs seront (re)posés par rebuild_chain_walls via refresh_chain_track du
      -- master (déclenché plus bas dans cette même migration).
      st.walls_static = st.walls_static or {}
      st.side_west = st.side_west or {}
      st.side_east = st.side_east or {}
      -- Sol pavé (ajouté après) : posé si absent.
      if not (st.floor_saved and #st.floor_saved > 0) then
        st.floor_saved = {}
        composite.lay_floor(st)
      end
    else
      -- MAÎTRE : champs de production + enfants.
      st.templates = st.templates or {}
      st.queue = st.queue or {}
      st.extensions = st.extensions or {}
      st.recycle_stops = st.recycle_stops or {}
      -- Champ st.source_mode supprimé (chaque variante est mono-source) ; on le
      -- purge des vieilles saves. st.stc_fuel reste inerte, laissé tel quel.
      st.source_mode = nil
      -- Répare les signaux détachés (mauvaise direction dans les vieilles
      -- versions : ils clignotaient sans gouverner le bloc).
      composite.repair_signal(st)
      -- Crée les enfants manquants sur les fonderies d'avant leur ajout
      -- (réserve, connecteur circuit, coffre à blueprints) : mise à jour EN
      -- PLACE, sans que le joueur ait à miner puis reposer la fonderie.
      composite.ensure_input(st)
      composite.ensure_combinator(st)
      if names.has_bpchest then composite.ensure_bpchest(st) end
      -- Sol pavé (ajouté après) : posé si absent.
      if not (st.floor_saved and #st.floor_saved > 0) then
        st.floor_saved = {}
        composite.lay_floor(st)
      end
      -- Enceinte de murs (statique + colonnes). La 2e voie (recyclage) est gérée
      -- par refresh_chain_track (rebuild_deco_track) selon st.deco, appelé plus bas.
      st.rails_deco = st.rails_deco or {}
      composite.ensure_walls(st)
      -- Raccord ouest en RAIL_OVER (écrase le mur) : les vieilles fonderies
      -- l'avaient en rail normal. On le reconstruit au bon calque si la sortie
      -- gauche est ouverte ; sinon on s'assure qu'il est bien retiré.
      if st.exit_left then
        composite.close_west(st)
        composite.open_west(st)
      else
        composite.close_west(st)
      end
      -- Reconstruit toute la voie de la chaîne : comble les jonctions (trou d'une
      -- tuile entre modules sur les vieilles saves) et ré-ancre la sortie est (si
      -- active) sur le bon bord. Remplace l'ancienne réparation séparée du signal.
      refresh_chain_track(st)
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
    for _, r in ipairs(st.rails_east or {}) do ref(r) end
    for _, r in ipairs(st.rails_junction or {}) do ref(r) end
    for _, r in ipairs(st.rails_deco or {}) do ref(r) end
    for _, w in ipairs(st.walls_static or {}) do ref(w) end
    for _, w in ipairs(st.side_west or {}) do ref(w) end
    for _, w in ipairs(st.side_east or {}) do ref(w) end
    for _, s in ipairs(st.recycle_stops or {}) do ref(s) end
    ref(st.input)
    ref(st.bpchest)
    ref(st.signal)
    ref(st.signal_east)
    ref(st.combinator)
    -- Legacy : anneau de quais + 4 combinators d'anciennes versions.
    for _, c in ipairs(st.inputs or {}) do ref(c) end
    for _, c in ipairs(st.combinators or {}) do ref(c) end
  end
  local child_names = { names.rail, names.rail_over, names.rail_ext, names.input,
                        names.signal, names.combinator, names.wall, names.gate,
                        names.recycle_stop, names.block_signal, names.block_combi }
  if names.has_bpchest then child_names[#child_names + 1] = names.bpchest end
  for _, surface in pairs(game.surfaces) do
    for _, ent in pairs(surface.find_entities_filtered({
      name = child_names })) do
      local key = ent.name .. ":" .. ent.position.x .. ":" .. ent.position.y
      if not referenced[key] then
        ent.destroy()
      end
    end
  end

  -- Recalcule le verrou de minage des chaînes (après rechargement du mod) :
  -- master minable seulement sans extension ; parmi les extensions, seule la
  -- dernière (est) est minable — la chaîne se démonte de droite à gauche.
  for _, st in pairs(storage.foundries) do
    if st.role == "master" and st.entity and st.entity.valid then
      local exts = st.extensions or {}
      st.entity.minable_flag = (#exts == 0)
      for i, un in ipairs(exts) do
        local ext = storage.foundries[un]
        if ext and ext.entity and ext.entity.valid then
          ext.entity.minable_flag = (i == #exts)
        end
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

-- Remonte à la tête (master) d'une chaîne depuis un state quelconque.
local function master_of(st)
  if not st then return nil end
  if st.role == "master" then return st end
  return st.master and storage.foundries[st.master] or nil
end

-- Verrouille le minage le long d'une chaîne pour qu'elle se démonte de DROITE
-- à GAUCHE, sans jamais laisser de trou dans la voie :
--  - le master n'est minable que s'il n'a aucune extension ;
--  - parmi les extensions (rangées ouest -> est), seule la DERNIÈRE (est) est
--    minable ; les autres sont verrouillées.
-- minable_flag (2.0.26+) bloque main-mining, robots et planner d'un coup.
local function refresh_chain_minable(master)
  if not (master and master.entity and master.entity.valid) then return end
  local exts = master.extensions or {}
  master.entity.minable_flag = (#exts == 0)
  for i, un in ipairs(exts) do
    local ext = storage.foundries[un]
    if ext and ext.entity and ext.entity.valid then
      ext.entity.minable_flag = (i == #exts)  -- seule la dernière (est)
    end
  end
end

local function on_built(event)
  ensure_storage()
  local e = event.entity or event.created_entity
  if not (e and e.valid) then return end
  if e.name ~= MAIN then return end

  -- Un module accolé à l'OUEST d'une fonderie existante devient une EXTENSION
  -- de sa chaîne (allonge la voie et la capacité, sans coffres ni signal).
  local west = composite.adjacent_west(e, storage.foundries)
  if west then
    local master = master_of(west)
    if not master then
      cancel_build(event, e, "extension-need-master")
      return
    end
    local st = composite.build_extension(e, master.entity.unit_number)
    storage.foundries[e.unit_number] = st
    master.extensions = master.extensions or {}
    master.extensions[#master.extensions + 1] = e.unit_number
    refresh_chain_minable(master)  -- nouvelle extension = seule minable
    -- Reconstruit toute la voie de la chaîne : comble les jonctions (RAIL_OVER)
    -- et ré-ancre la sortie est sur le nouveau bord. Centralisé => pas d'orphelin
    -- ni de jonction cassée.
    refresh_chain_track(master)
    return
  end

  -- Sinon c'est un nouveau MAÎTRE : une seule chaîne (un master) par surface.
  for _, st in pairs(storage.foundries) do
    if st.role == "master" and st.entity and st.entity.valid
      and st.entity.surface == e.surface then
      cancel_build(event, e, "one-per-surface")
      return
    end
  end
  -- Plus d'exigence de rail préparé à la pose : la fonderie pose elle-même sa
  -- voie interne (et donc son raccord de sortie ouest) via composite.build. Le
  -- joueur raccorde son réseau à la voie de sortie après coup ; la sortie est
  -- (droite) s'active à la demande depuis la fenêtre.
  storage.foundries[e.unit_number] = composite.build(e)
end

local function on_removed(event)
  ensure_storage()
  local e = event.entity
  if not (e and e.valid) then return end
  if e.name ~= MAIN then return end
  local st = storage.foundries[e.unit_number]
  if not st then return end

  -- Détache une EXTENSION de sa chaîne (met à jour la liste du master).
  if st.role == "extension" then
    local master = st.master and storage.foundries[st.master]
    if master and master.extensions then
      for i = #master.extensions, 1, -1 do
        if master.extensions[i] == e.unit_number then
          table.remove(master.extensions, i)
        end
      end
    end
    -- Ordre IMPORTANT : détruire l'extension AVANT de reconstruire la chaîne,
    -- pour libérer ses positions (sinon rebuild reposerait des rails-over dessus).
    composite.destroy(st)
    storage.foundries[e.unit_number] = nil
    if master then
      refresh_chain_minable(master)  -- l'avant-dernière devient minable
      -- Reconstruit la voie sur la chaîne réduite : purge les rails de jonction
      -- (plus d'orphelins) et ré-ancre la sortie est sur le nouveau bord.
      refresh_chain_track(master)
    end
    return
  end

  -- Rend les composants (+ carburant) d'une construction en cours avant le nettoyage.
  if st.work and st.work.phase ~= "waiting" and st.work.need then
    builder.refund(st, st.work.need, st.work.fuel_item)
  end

  -- Le master disparaît alors qu'il a des extensions (mort par biters,
  -- artillerie, script...) : le minage à la main est bloqué (minable_flag),
  -- mais une destruction non-minage passe outre. On nettoie toute la chaîne
  -- pour ne pas laisser d'extensions orphelines (states + rails). L'item de
  -- chaque extension est rendu au sol (le joueur l'avait payé).
  for _, ext_un in ipairs(st.extensions or {}) do
    local ext = storage.foundries[ext_un]
    if ext then
      composite.destroy(ext)
      if ext.entity and ext.entity.valid then
        ext.entity.surface.spill_item_stack({
          position = ext.entity.position,
          stack = { name = MAIN, count = 1 },
          enable_looted = true,
          force = ext.entity.force,
        })
        ext.entity.destroy()
      end
      storage.foundries[ext_un] = nil
    end
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

-- La gare de recyclage est SÉLECTIONNABLE (pour être ciblable dans un schedule),
-- donc le joueur peut la renommer. On FIGE son nom : tout renommage manuel d'une
-- gare de recyclage est annulé en re-forçant le backer_name. (by_script exclu pour
-- ne pas boucler sur notre propre pose.)
script.on_event(defines.events.on_entity_renamed, function(event)
  if event.by_script then return end
  local e = event.entity
  if e and e.valid and e.name == names.recycle_stop then
    e.backer_name = names.recycle_stop_name
  end
end)

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

  -- Capacité courante de la chaîne (base + extensions) : sert à refuser un
  -- train trop long à l'import. Change si on ajoute/retire une extension.
  local capacity = builder.capacity(state)

  -- Si la capacité a changé (extension ajoutée/retirée), on invalide le cache
  -- par signature pour re-parser : un plan « trop long » peut redevenir valide
  -- (et inversement).
  local old_by_sig = {}
  if state.last_capacity == capacity then
    for _, t in ipairs(state.templates) do
      if t.signature then old_by_sig[t.signature] = t end
    end
  end
  state.last_capacity = capacity

  local templates = {}
  for i = 1, #inv do
    local stack = inv[i]
    local sig = slot_signature(stack)
    if sig then
      local existing = old_by_sig[sig]
      if existing then
        templates[#templates + 1] = existing
      else
        local template, err, detail = blueprint.parse(stack, capacity)
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
    -- Générique si le mode l'exige (STC / case cochée) OU si le BP n'a AUCUN
    -- carburant (rien à respecter → on remplit au meilleur carburant dispo). On le
    -- FIGE sur le travail (comme need/fuel_item) : recalculer à chaque tick ferait
    -- diverger consume (waiting) et spawn (ready) si le joueur bascule l'option en
    -- cours de construction → carburant perdu ou dupliqué.
    if work.generic == nil then
      work.generic = fuel_is_generic(st) or not builder.template_has_bp_fuel(template)
    end
    -- Attente des composants + carburant (et d'une voie libre pour le châssis).
    work.need = work.need or builder.compute_need(template, work.generic)
    local miss, _, fuel_item, fuel_short, fuel_caption = builder.missing(st, work.need)
    work.missing = miss
    work.fuel_item = fuel_item        -- carburant retenu (nil si aucun/pas de besoin)
    work.fuel_caption = fuel_caption  -- rich-text des carburants acceptés (si manquant)
    if next(miss) then
      work.blocked = "components"
    elseif fuel_short then
      work.blocked = "fuel"
    elseif not builder.track_free(st) then
      work.blocked = "track"
    else
      work.blocked = nil
      builder.consume(st, work.need, work.fuel_item)
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
      local ok = builder.spawn(st, template, work.entry.params, work.fuel_item, work.generic)
      if not ok then
        -- Échec dur de la pose (voie obstruée...) : on rend les composants + le
        -- carburant consommé plutôt que de bloquer la file.
        builder.refund(st, work.need, work.fuel_item)
      end
      st.work = nil
    end
  end
end

script.on_nth_tick(TICK_INTERVAL, function()
  ensure_storage()
  -- unit_number -> le livre a-t-il changé ce tick (coffre modifié) ?
  -- Seuls les MAÎTRES portent file/travail/coffres : on ignore les extensions
  -- (elles n'apportent que voie et capacité).
  local book_changed = {}
  for un, st in pairs(storage.foundries) do
    if st.role ~= "extension" and st.entity and st.entity.valid then
      if names.has_bpchest then book_changed[un] = sync_templates(st) end
      process_foundry(st)
      builder.update_circuit(st)
      builder.check_recycle(st)  -- déconstruit un train arrêté à la gare de recyclage
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
    if names.has_bpchest then
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
  if names.has_bpchest and e.name == names.bpchest then
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
    -- Clic sur une EXTENSION → on ouvre la fenêtre de son MAÎTRE (transparent
    -- pour le joueur : toute la chaîne se pilote depuis une seule fenêtre).
    st = master_of(storage.foundries[e.unit_number])
  elseif e.name == names.combinator then
    for _, s in pairs(storage.foundries) do
      if s.combinator == e then st = s break end
    end
  end
  if not st then return end
  -- Lit le coffre à blueprints avant d'afficher le livre (à jour dès
  -- l'ouverture, sans attendre le prochain tick de la boucle).
  if names.has_bpchest then sync_templates(st) end
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
    if st.role ~= "extension" and st.entity and st.entity.valid
      and st.entity.surface == surface then
      if names.has_bpchest then sync_templates(st) end
      gui.open(player, st)
      return
    end
  end
  player.print({ "tf-msg.no-foundry-here" })
end

script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name ~= names.shortcut then return end
  local player = game.get_player(event.player_index)
  if player then open_overview(player) end
end)

script.on_event(names.shortcut, function(event)
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
  if not (el and el.valid and el.tags) then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  local un = gui.window_unit_number(player)
  if not un then return end
  ensure_storage()
  local st = storage.foundries[un]
  if not (st and st.entity and st.entity.valid) then return end

  -- Mode d'émission circuit (radios exclusifs).
  if el.tags.tf_emit_mode then
    st.emit_mode = el.tags.tf_emit_mode
    gui.set_emit_mode(player, st.emit_mode)
    builder.update_circuit(st)
    return
  end

  -- Carburant générique (variante BP) : bascule le mode de carburant. Un travail
  -- déjà en attente recalcule son besoin au prochain tick (work.need est reconstruit
  -- si on le remet à nil).
  if el.tags.tf_generic_fuel then
    st.generic_fuel = el.state and true or false
    -- Un travail EN ATTENTE recalcule mode + besoin au prochain tick (on invalide
    -- work.generic ET work.need). Un travail déjà en construction garde son mode
    -- figé (changer en cours fausserait le comptage carburant).
    if st.work and st.work.phase == "waiting" then
      st.work.generic = nil
      st.work.need = nil
    end
    return
  end

  -- Côtés de sortie (cases indépendantes). On interdit de fermer les DEUX côtés
  -- (le train n'aurait plus de sortie) : la dernière case cochée se re-coche.
  if el.tags.tf_exit_side then
    local side = el.tags.tf_exit_side
    local want = el.state
    if not want and not (side == "left" and st.exit_right)
                and not (side == "right" and st.exit_left) then
      -- Tentative de tout fermer : on annule, la case reste cochée.
      el.state = true
      return
    end
    if side == "left" then
      st.exit_left = want
      -- Ouest : (re)pose ou retire le raccord de voie + signal ouest.
      if want then composite.open_west(st) else composite.close_west(st) end
    else
      st.exit_right = want
      -- Est : géré par refresh_chain_track (rebuild_chain_track appelle open_east/
      -- close_east sur le dernier module selon exit_right).
    end
    -- Recalcule murs + voie de la chaîne : côté ouest sur le master, côté est sur
    -- le DERNIER module. refresh_chain_track gère master seul ET chaîne.
    refresh_chain_track(st)
    return
  end

  -- Voie de RECYCLAGE : case parent (active/désactive la 2e voie + ses portes).
  if el.tags.tf_deco then
    st.deco = el.state and true or false
    -- Les portes de recyclage dépendent de deco : recalcule les murs de la chaîne.
    refresh_chain_track(st)
    -- Rafraîchit la fenêtre Config (fermer + rouvrir) pour griser/dégriser les
    -- côtés de la voie de recyclage.
    gui.toggle_circuit(player, st)  -- ferme (elle est ouverte)
    gui.toggle_circuit(player, st)  -- rouvre à jour
    return
  end

  -- Côté d'entrée de la voie de recyclage = RADIO EXCLUSIF (cul-de-sac : une seule
  -- entrée, gauche OU droite). Cliquer un côté l'active et désactive l'autre.
  if el.tags.tf_deco_side then
    local side = el.tags.tf_deco_side
    st.deco_left = (side == "left")
    st.deco_right = (side == "right")
    refresh_chain_track(st)
    -- Rafraîchit la fenêtre pour que l'autre radio se décoche visuellement.
    gui.toggle_circuit(player, st)
    gui.toggle_circuit(player, st)
    return
  end
end)

script.on_event(defines.events.on_gui_click, function(event)
  local el = event.element
  if not (el and el.valid) then return end
  local player = game.get_player(event.player_index)
  if not player then return end

  -- Slot d'ingrédient/carburant : clic → Factoriopedia de l'item (le tooltip
  -- affiche déjà son nom). Protégé (API 2.1 ; item pouvant avoir disparu).
  if el.tags and el.tags.tf_ipedia then
    local item = prototypes.item[el.tags.tf_ipedia]
    if item and player.open_factoriopedia_gui then
      pcall(function() player.open_factoriopedia_gui(item) end)
    end
    return
  end

  if el.name == "tf-close" then
    gui.close(player)
    return
  end

  if names.has_bpchest and el.name == "tf-bp-close" then
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
  if names.has_bpchest and el.name == "tf-open-bpchest" then
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
  if names.has_bpchest and el.tags and el.tags.tf_action == "bp-slot" then
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
    local frame = player.gui.screen[gui.PARAMS_WINDOW]
    if frame then frame.destroy() end
    return
  end
  if el.name == "tf-params-go" then
    ensure_storage()
    local params, p_un, p_index, p_sig, p_stc = gui.collect_params(player)
    local frame = player.gui.screen[gui.PARAMS_WINDOW]
    if frame then frame.destroy() end
    if not params then return end
    local p_st = storage.foundries[p_un]
    if not p_st then return end
    local t
    if p_stc and names.source == "stc" and stc_template then
      -- Modèle STC : on reconstruit le template synthétique depuis la forme mise
      -- en cache (state.stc_models) au dernier rafraîchissement du livre.
      local m = p_st.stc_models and p_st.stc_models[p_stc]
      if not m then return end
      t = stc_template.build(m)
    else
      -- Blueprint : résolution par SIGNATURE d'abord (le livre a pu se réindexer
      -- depuis l'ouverture du dialogue), repli sur l'index.
      if p_sig then
        for _, cand in ipairs(p_st.templates) do
          if cand.signature == p_sig then t = cand break end
        end
      end
      t = t or p_st.templates[p_index]
    end
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

  if names.has_bpchest and el.tags and el.tags.tf_action == "template-slot" then
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
  elseif names.source == "stc" and stc_template
      and el.tags and el.tags.tf_action == "stc-model" then
    -- Modèle STC : on construit le template synthétique et on demande la
    -- ressource (toujours paramétré via parameter-0). La forme sera relue à la
    -- validation depuis st.stc_models pour reconstruire le template.
    local m = st.stc_models and st.stc_models[el.tags.index]
    if not m then return end
    local t = stc_template.build(m)
    -- On connaît le kind (item/fluid) → picker de ressource restreint à ce type.
    gui.open_params(player, st, el.tags.index, t, el.tags.index, m.kind)
  elseif el.tags and el.tags.tf_action == "cancel-queued" then
    table.remove(st.queue, el.tags.index)
    gui.refresh_queue(player, st)
  elseif el.tags and el.tags.tf_action == "cancel-work" then
    if st.work then
      if st.work.phase ~= "waiting" and st.work.need then
        builder.refund(st, st.work.need, st.work.fuel_item)
      end
      st.work = nil
      gui.refresh_dynamic(player, st)
    end
  elseif el.tags and el.tags.tf_action == "clear-track" then
    -- Détruit + rembourse le train coincé sur la voie interne (débloque la prod).
    local n = builder.clear_track(st)
    if n > 0 then gui.refresh_dynamic(player, st) end
  end
end)

-- ----------------------------------------------------------------------------
-- Interface remote : utilisée par les tests automatisés (et utilisable par
-- d'autres mods). Mêmes chemins de code que la GUI.
-- ----------------------------------------------------------------------------

local remote_iface = {
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
}

if names.has_bpchest then
  -- Dépose `stack` (LuaItemStack blueprint) dans le coffre à blueprints de la
  -- fonderie et resynchronise les templates. Retourne "ok:<nb véhicules>",
  -- "invalid:<clé>" si le plan est refusé, ou une clé d'erreur.
  remote_iface.import_blueprint = function(stack, unit_number)
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
  end
  -- Construction immédiate (contourne la file) — tests/regression.
  remote_iface.spawn_template = function(unit_number, index)
    ensure_storage()
    local st = storage.foundries[unit_number]
    if not st then return "import-no-foundry" end
    local t = st.templates[index]
    if not t then return "import-no-foundry" end
    local ok, err, detail = builder.try_spawn(st, t,
      fuel_is_generic(st) or not builder.template_has_bp_fuel(t))
    return (ok or err) .. (detail and (" | " .. detail) or "")
  end
  -- Résumé des templates d'une fonderie ("Train 1(6), Train 2(3)").
  remote_iface.templates = function(unit_number)
    ensure_storage()
    local st = storage.foundries[unit_number]
    if not st then return "import-no-foundry" end
    local out = {}
    for _, t in ipairs(st.templates) do
      out[#out + 1] = t.name .. "(" .. #t.stock .. ")"
    end
    return table.concat(out, ", ")
  end
end

remote.add_interface(names.remote, remote_iface)

-- ----------------------------------------------------------------------------
-- Diagnostic : /tf-scan liste tous les rails et véhicules autour de la voie
-- de la fonderie survolée (positions, directions, orientations).
-- ----------------------------------------------------------------------------

commands.add_command(names.mod .. "-scan", "Scanne la voie de la fonderie survolée", function(cmd)
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

commands.add_command(names.mod .. "-debug", "État de la Train Foundry survolée", function(cmd)
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

