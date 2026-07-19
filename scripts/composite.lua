-- Train Foundry — composite : les entités cachées qui vivent sous le bâtiment
-- (rails internes, points de chargement liés, signal de sortie), la
-- validation du raccord, la création et la destruction propre.
--
-- Le bâtiment n'a qu'UNE orientation (not-rotatable, sortie à l'ouest) :
-- tous les offsets sont des constantes depuis le centre de l'entité.
-- Footprint 40×22 (dont 2 tuiles de parvis ouest hors collision box), voie
-- sur la rangée lateral +5, hangar à l'est.
--
-- Exigence de pose : UN rail droit est-ouest existant à la position de
-- raccord (-19, +5), dans la bande de parvis hors collision — on pose la
-- porte de la fonderie sur l'extrémité d'une voie. Le reste du bâtiment
-- collisionne normalement avec tout. La fonderie crée ensuite ses propres
-- rails internes, détruits avec elle ; le rail de raccord reste au joueur.

local composite = {}

local RAIL       = "tf-rail"
local RAIL_OVER  = "tf-rail-over"  -- rail dessiné par-dessus le mur (sortie est)
local INPUT      = "tf-input"
local SIGNAL     = "tf-signal"
local COMBINATOR = "tf-combinator"
local BPCHEST    = "tf-blueprints"

-- Réserve (coffre de fer), coffre à blueprints et connecteur circuit, posés
-- sur le PARVIS ouest, dans la zone libre hors collision (x < -18) : de
-- vraies entités que les bras et l'outil fil savent cibler. Un peu à l'écart
-- de la voie de sortie (rangée +5) pour rester accessibles.
local INPUT_OFFSET      = { -19.5, -1.5 }  -- coffre de fer (réserve)
local COMBINATOR_OFFSET = { -19.5,  1.5 }  -- connecteur circuit
local BPCHEST_OFFSET    = { -19.5, -3.5 }  -- coffre à blueprints

-- Les rails du jeu vivent sur les coordonnées IMPAIRES, alors que le
-- bâtiment (build_grid_size = 2) est snappé sur les PAIRES — vérifié
-- expérimentalement : un rail demandé en (86,56) est déplacé en (87,57)
-- par le moteur. Rangée de voie y = +5 ; rails internes aux x impairs
-- -17..+17 (du parvis jusqu'à 2 tuiles avant le mur est).
local RAIL_Y = 5
local RAIL_XS = {}
for x = -17, 17, 2 do
  RAIL_XS[#RAIL_XS + 1] = x
end

-- Rail de raccord (au joueur, requis à la pose) : sous le parvis ouest,
-- hors collision box, sa box (jusqu'à -18.01) ne touche pas la nôtre
-- (depuis -18.0).
local JUNCTION_RAIL_OFFSET = { -19, 5 }

-- Signal de sortie : sur le parvis, côté NORD de la voie (main droite des
-- trains sortant vers l'ouest), orienté EST. Sémantique 2.0 vérifiée
-- expérimentalement : un signal ne s'attache que si sa direction "fait
-- face" au trafic gouverné — côté nord ↔ direction est (gouverne les
-- westbound), côté sud ↔ direction ouest. Toute autre combinaison créée
-- par script reste détachée et CLIGNOTE. Il s'accroche au rail de raccord,
-- garanti présent par l'exigence de pose.
local SIGNAL_OFFSET = { -19.5, 3.5 }
local SIGNAL_DIRECTION = defines.direction.east

-- Sortie EST optionnelle (le train peut sortir à DROITE) : miroir de la sortie
-- ouest. On pose du RAIL_OVER de +15 à +21 : +15/+17 tombent SOUS le mur est du
-- bâtiment (le rail interne normal y est masqué → cassure visuelle), donc on les
-- couvre en rail-over comme le raccord ouest couvre -15..-21 ; +19/+21 prolongent
-- la voie dehors pour rejoindre le réseau du joueur. Symétrique de WEST_CONNECT_XS.
local EAST_RAIL_X_FROM = 15   -- couvre le rail sous le mur est (sinon cassure)
local EAST_RAIL_X_TO   = 21   -- dernière tuile (raccord externe est)

-- Signal de sortie EST : sémantique 2.0 INVERSE de l'ouest. Le trafic sortant
-- est est eastbound → par la règle (côté nord ↔ direction est / côté sud ↔
-- direction ouest), il faut un signal côté SUD (y=+6.5, sous la voie +5) orienté
-- OUEST. Posé à x=+21.5, AU-DELÀ du bord est du bâtiment (+20) : sinon il est
-- masqué sous le sprite du mur est. Il s'accroche à la voie est (posée +19..+21).
local SIGNAL_EAST_OFFSET = { 21.5, 6.5 }
local SIGNAL_EAST_DIRECTION = defines.direction.west


-- Le rail de raccord est-il présent ? (exigence de pose)
function composite.has_junction_rail(entity)
  local pos = { entity.position.x + JUNCTION_RAIL_OFFSET[1],
                entity.position.y + JUNCTION_RAIL_OFFSET[2] }
  for _, r in ipairs(entity.surface.find_entities_filtered({
    type = "straight-rail", position = pos, radius = 0.2 })) do
    if r.direction % 8 == defines.direction.east % 8 then
      return true
    end
  end
  return false
end

local function place(entity, name, offset, direction)
  local child = entity.surface.create_entity({
    name = name,
    position = { entity.position.x + offset[1], entity.position.y + offset[2] },
    direction = direction,
    force = entity.force,
  })
  if child then
    child.destructible = false
  end
  return child
end

-- Largeur d'un module en tuiles (tile_width) : deux fonderies accolées ont
-- leurs centres espacés de MODULE_WIDTH sur X (même Y).
local MODULE_WIDTH = 40

-- Pose les rails internes d'un module sur une plage de X relatifs (impairs),
-- rangée RAIL_Y. Réutilise un rail déjà présent (pose par-dessus une voie).
-- Ajoute les rails créés à state.rails.
local function lay_rails(state, entity, x_from, x_to)
  for x = x_from, x_to, 2 do
    local pos = { entity.position.x + x, entity.position.y + RAIL_Y }
    local occupied = false
    for _, ex in ipairs(entity.surface.find_entities_filtered({
      type = "straight-rail", position = pos, radius = 0.2 })) do
      if ex.direction % 8 == defines.direction.east % 8 then
        occupied = true
        break
      end
    end
    if not occupied then
      local r = place(entity, RAIL, { x, RAIL_Y }, defines.direction.east)
      if r then state.rails[#state.rails + 1] = r end
    end
  end
end

-- Comble la voie entre deux X monde ABSOLUS (rangée +5 de l'ancre), sur toutes
-- les positions impaires — indépendamment de la parité des centres des modules
-- (master et extension peuvent snapper sur des parités différentes, laissant un
-- trou d'une tuile à la jonction). La jonction tombe SOUS les murs accolés des
-- deux modules : la voie doit donc y être en RAIL_OVER (dessinée au-dessus des
-- murs), sinon elle est masquée. IMPORTANT : deux straight-rail ne peuvent PAS
-- coexister à la même position — un tf-rail normal déjà présent est donc DÉTRUIT
-- (et retiré de master_state.rails) puis remplacé par un RAIL_OVER. Les rails
-- créés vont dans `bucket` (rails_junction). `ref` = une entité de la chaîne.
local function fill_track_abs(master_state, ref, bucket, x_from_abs, x_to_abs)
  local surface = ref.surface
  local ry = ref.position.y + RAIL_Y
  -- Aligne les bornes sur la grille IMPAIRE (les rails vivent sur coords impaires).
  local x0 = math.floor(math.min(x_from_abs, x_to_abs))
  local x1 = math.ceil(math.max(x_from_abs, x_to_abs))
  if x0 % 2 == 0 then x0 = x0 - 1 end
  for x = x0, x1, 2 do
    local pos = { x, ry }
    local has_over = false
    for _, ex in ipairs(surface.find_entities_filtered({
      type = "straight-rail", position = pos, radius = 0.2 })) do
      if ex.direction % 8 == defines.direction.east % 8 then
        if ex.name == RAIL_OVER then
          has_over = true
        elseif ex.name == RAIL then
          -- Rail normal masqué par le mur : le retirer (des rails du master si
          -- présent) pour libérer la position au RAIL_OVER (pas de coexistence).
          for i = #(master_state.rails or {}), 1, -1 do
            if master_state.rails[i] == ex then table.remove(master_state.rails, i) end
          end
          ex.destroy()
        end
      end
    end
    if not has_over then
      local r = surface.create_entity({
        name = RAIL_OVER, position = pos,
        direction = defines.direction.east, force = ref.force })
      if r then r.destructible = false; bucket[#bucket + 1] = r end
    end
  end
end

-- Détruit tous les rails de jonction (rails_junction) et vide la liste.
local function destroy_junction_rails(state)
  for _, r in ipairs(state.rails_junction or {}) do
    if r.valid then r.destroy() end
  end
  state.rails_junction = {}
end
composite.destroy_junction_rails = destroy_junction_rails

-- Crée le composite d'un bâtiment MAÎTRE fraîchement posé (et validé) et
-- retourne le state à ranger dans storage.foundries[unit_number].
function composite.build(entity)
  local state = {
    entity = entity,
    role = "master",   -- master (coffres/signal/GUI) vs extension
    extensions = {},   -- unit_numbers des extensions accolées (ouest -> est)
    rails = {},
    input = nil,       -- coffre de fer (réserve) sur le parvis
    bpchest = nil,     -- coffre à blueprints sur le parvis
    signal = nil,
    signal_east = nil, -- signal de sortie est (créé seulement si exit_right)
    combinator = nil,  -- connecteur circuit sur le parvis
    templates = {},  -- milestone 2 : templates de blueprints
    queue = {},      -- milestone 3 : file de construction
    -- Mode d'émission circuit : "stock" ou "request" (par défaut le stock ;
    -- pour ne rien émettre, ne pas brancher de câble).
    emit_mode = "stock",
    -- Côtés de sortie. Gauche (ouest) toujours ouverte à la pose (voie interne
    -- posée par lay_rails). Droite (est) opt-in via la fenêtre → open_east.
    exit_left = true,
    exit_right = false,
  }

  -- Voie interne du master : -13..+17 (impairs), zone d'assemblage. Le raccord
  -- ouest (-17,-15, qui traverse le mur) est posé séparément par open_west en
  -- RAIL_OVER, pour un seul chemin cohérent (défaut sortie gauche ouverte).
  lay_rails(state, entity, -13, 17)
  composite.open_west(state)  -- pose le raccord ouest + le signal de sortie ouest

  state.input = place(entity, INPUT, INPUT_OFFSET, defines.direction.north)
  state.combinator = place(entity, COMBINATOR, COMBINATOR_OFFSET,
    defines.direction.north)
  state.bpchest = place(entity, BPCHEST, BPCHEST_OFFSET, defines.direction.north)
  composite.set_bpchest_filters(state)

  -- Master neuf = minable (aucune extension) ; explicite pour ne pas dépendre
  -- du défaut du prototype. Se verrouille dès qu'une extension est accolée.
  entity.minable_flag = true

  return state
end

-- Crée le composite d'une EXTENSION (module accolé à droite d'une chaîne) :
-- uniquement ses rails, prolongeant la voie du master. Pas de coffres, pas de
-- signal, pas de GUI propre. `master_un` = l'unit_number du master de la
-- chaîne à laquelle elle se rattache.
function composite.build_extension(entity, master_un)
  local state = {
    entity = entity,
    role = "extension",
    master = master_un,
    rails = {},
  }
  -- Rails de l'extension : on pose GÉNÉREUSEMENT de -23 à +17 (impairs). Le
  -- chevauchement à gauche comble le trou entre le dernier rail du module
  -- précédent et ce module, quel que soit l'écart de snap (38 ou 40) — un rail
  -- déjà présent est réutilisé (lay_rails saute les positions occupées), donc
  -- pas de doublon.
  lay_rails(state, entity, -23, 17)
  -- Par défaut non minable : l'appelant (refresh_chain_minable) rendra minable
  -- uniquement la dernière extension de la chaîne. Évite qu'une extension du
  -- milieu soit minable une fraction de temps avant le recalcul.
  entity.minable_flag = false
  return state
end

-- Détecte, à la pose de `entity`, la fonderie dont le bord EST est ACCOLÉ au
-- bord OUEST de `entity` (voisin à l'ouest, même rangée). L'écart de centres de
-- deux modules réellement accolés vaut EXACTEMENT 38 (mesuré en jeu) : bord est
-- +19.7 touchant bord ouest -18.0, snappé sur la grille paire (build_grid_size=2).
-- La plage est SERRÉE (37..39) : au moindre espace entre les deux (dx >= 40), ce
-- ne sont plus des modules chaînés (sinon la jonction comblerait le vide par une
-- voie flottante au-dessus du terrain).
function composite.adjacent_west(entity, foundries)
  local px, py = entity.position.x, entity.position.y
  local best, best_dx
  for _, st in pairs(foundries) do
    local e = st.entity
    if e and e.valid and e ~= entity and e.surface == entity.surface then
      local dx = px - e.position.x  -- >0 si le voisin est à l'OUEST
      if math.abs(e.position.y - py) < 1.0 and dx >= 37 and dx <= 39 then
        if not best_dx or dx < best_dx then
          best, best_dx = st, dx
        end
      end
    end
  end
  return best
end

composite.MODULE_WIDTH = MODULE_WIDTH

-- Le coffre de réserve (ou nil).
function composite.reserve(state)
  if state.input and state.input.valid then return state.input end
  return nil
end

-- Le coffre à blueprints (ou nil).
function composite.bp_chest(state)
  if state.bpchest and state.bpchest.valid then return state.bpchest end
  return nil
end

-- Filtre le coffre à blueprints pour n'accepter que des blueprints (tous les
-- slots filtrés sur l'item "blueprint").
function composite.set_bpchest_filters(state)
  local c = state.bpchest
  if not (c and c.valid) then return end
  local inv = c.get_inventory(defines.inventory.chest)
  if not inv or not inv.supports_filters() then return end
  for i = 1, #inv do
    pcall(function() inv.set_filter(i, "blueprint") end)
  end
end

-- Coffre à blueprints : (re)crée-le pour les fonderies d'avant cette version.
function composite.ensure_bpchest(state)
  if state.bpchest and state.bpchest.valid then return end
  local e = state.entity
  if not (e and e.valid) then return end
  local pos = { e.position.x + BPCHEST_OFFSET[1], e.position.y + BPCHEST_OFFSET[2] }
  state.bpchest = e.surface.find_entities_filtered({
    name = BPCHEST, position = pos, radius = 1 })[1]
    or place(e, BPCHEST, BPCHEST_OFFSET, defines.direction.north)
  composite.set_bpchest_filters(state)
end

-- Répare le signal de sortie d'un state existant : un signal absent, invalide
-- ou DÉTACHÉ (créé avec une mauvaise direction par une vieille version — il
-- clignote) est détruit et recréé avec la bonne orientation.
function composite.repair_signal(state)
  local e = state.entity
  if not (e and e.valid) then return end
  if state.signal and state.signal.valid then
    if #state.signal.get_connected_rails() > 0 then return end
    state.signal.destroy()
    state.signal = nil
  end
  state.signal = place(e, SIGNAL, SIGNAL_OFFSET, SIGNAL_DIRECTION)
end

-- Pose les rails est relativement à `anchor` (le module du BORD EST de la chaîne :
-- master seul, ou dernière extension), en les rangeant dans state.rails_east
-- (liste séparée pour ne pas les confondre avec la voie interne lors du
-- re-ancrage). Un tf-rail NORMAL résiduel à ces positions (ex. rail de l'ancienne
-- extension retirée, ou de jonction) est DÉTRUIT (pas de coexistence de deux
-- straight-rail) pour laisser place au RAIL_OVER ; un rail-over déjà là est gardé.
local function lay_east_rails(state, anchor)
  state.rails_east = state.rails_east or {}
  local surface = anchor.surface
  for x = EAST_RAIL_X_FROM, EAST_RAIL_X_TO, 2 do
    local pos = { anchor.position.x + x, anchor.position.y + RAIL_Y }
    local has_over = false
    for _, ex in ipairs(surface.find_entities_filtered({
      type = "straight-rail", position = pos, radius = 0.2 })) do
      if ex.direction % 8 == defines.direction.east % 8 then
        if ex.name == RAIL_OVER then
          has_over = true
        elseif ex.name == RAIL then
          -- Rail normal résiduel : le retirer (des rails du master si présent)
          -- pour libérer la position au RAIL_OVER.
          for i = #(state.rails or {}), 1, -1 do
            if state.rails[i] == ex then table.remove(state.rails, i) end
          end
          ex.destroy()
        end
      end
    end
    if not has_over then
      local r = place(anchor, RAIL_OVER, { x, RAIL_Y }, defines.direction.east)
      if r then state.rails_east[#state.rails_east + 1] = r end
    end
  end
end

-- Détruit les rails est propres à la sortie (rails_east) et vide la liste. Ne
-- touche PAS la voie interne (state.rails).
local function destroy_east_rails(state)
  for _, r in ipairs(state.rails_east or {}) do
    if r.valid then r.destroy() end
  end
  state.rails_east = {}
end

-- Ouvre la sortie EST : prolonge la voie au-delà du bord est de la chaîne et pose
-- le signal est. `anchor` = l'entité du dernier module (calculée par l'appelant
-- via east_end_entity). Idempotent. Re-ancrable : on repart d'une voie est propre
-- pour suivre un changement de longueur de chaîne.
function composite.open_east(state, anchor)
  anchor = anchor or state.entity
  if not (anchor and anchor.valid) then return end
  -- Repart propre : détruit une éventuelle voie/signal est d'un ancrage précédent
  -- (chaîne allongée/raccourcie) avant de reposer au bon endroit.
  destroy_east_rails(state)
  if state.signal_east and state.signal_east.valid then
    state.signal_east.destroy()
  end
  lay_east_rails(state, anchor)
  state.signal_east = place(anchor, SIGNAL, SIGNAL_EAST_OFFSET, SIGNAL_EAST_DIRECTION)
end

-- Ferme la sortie EST : détruit le signal est et les rails est (+15..+21 en
-- rail-over). Puis RESTAURE la voie interne normale aux positions INTERNES
-- (+15/+17, sous le mur est) : sinon la voie interne aurait un trou après
-- fermeture. Les positions externes (+19/+21) restent vides (elles n'existaient
-- que pour la sortie). `anchor` = bord est courant (comme pour open_east).
function composite.close_east(state, anchor)
  anchor = anchor or state.entity
  if state.signal_east and state.signal_east.valid then
    state.signal_east.destroy()
  end
  state.signal_east = nil
  destroy_east_rails(state)
  -- Restaure la voie interne aux positions couvertes par le mur est (+15,+17).
  if anchor and anchor.valid then
    for _, x in ipairs({ 15, 17 }) do
      local pos = { anchor.position.x + x, anchor.position.y + RAIL_Y }
      local present = false
      for _, ex in ipairs(anchor.surface.find_entities_filtered({
        type = "straight-rail", position = pos, radius = 0.2 })) do
        if ex.direction % 8 == defines.direction.east % 8 then present = true break end
      end
      if not present then
        local r = place(anchor, RAIL, { x, RAIL_Y }, defines.direction.east)
        if r then state.rails[#state.rails + 1] = r end
      end
    end
  end
end

-- Écart de centres max entre deux modules ADJACENTS (accolés ~38, cf.
-- adjacent_west). Au-delà, il y a un trou : on ne comble PAS (sinon voie
-- flottante). Marge à 42 pour tolérer le snap sans jamais atteindre un module
-- manquant (~76).
local ADJ_MAX = 42

-- Reconstruit TOUTE la voie de la chaîne de façon idempotente — à appeler à
-- CHAQUE ajout/retrait d'extension. `chain` = liste ordonnée ouest->est des
-- entités valides de la chaîne (master.entity, ext1.entity, ...). Étapes :
--   1. purge les rails de jonction (rails_junction) — évite orphelins (retrait)
--      et doublons/décalages (ajout), et surtout retire les rail-over de jonction
--      résiduels AVANT de reposer la sortie est (sinon lay_east_rails les voit
--      "occupés" puis la purge les détruit → trou aux positions +15/+17) ;
--   2. recomble chaque jonction entre modules RÉELLEMENT adjacents (RAIL_OVER
--      par-dessus les murs), en absolu (robuste au snap). Un écart > ADJ_MAX
--      (module du milieu détruit par biters/artillerie) n'est PAS comblé : pas
--      de voie flottante au-dessus du vide ;
--   3. ré-ancre EN DERNIER la sortie est (si active) sur le bord est courant :
--      détruit/recrée rails_east + signal_east proprement, par-dessus une voie
--      de jonction déjà stabilisée.
function composite.rebuild_chain_track(master_state, chain)
  -- (1) PURGE TOTALE des rail-over dynamiques (jonctions + sortie est) : on repart
  -- d'un état propre pour éviter qu'un rail-over d'une zone (ex. ancienne sortie
  -- est) soit vu comme "déjà présent" par une autre (jonction) puis détruit,
  -- laissant un trou. Le signal est est aussi retiré (recréé en (3) si besoin).
  destroy_junction_rails(master_state)
  master_state.rails_junction = master_state.rails_junction or {}
  for _, r in ipairs(master_state.rails_east or {}) do
    if r.valid then r.destroy() end
  end
  master_state.rails_east = {}
  if master_state.signal_east and master_state.signal_east.valid then
    master_state.signal_east.destroy()
  end
  master_state.signal_east = nil
  -- (2) comblement des jonctions adjacentes
  for i = 1, #chain - 1 do
    local w, e = chain[i], chain[i + 1]
    if w and w.valid and e and e.valid and (e.position.x - w.position.x) <= ADJ_MAX then
      -- Du centre du module ouest +15 (dans sa voie) au centre du module est -15
      -- (dans la sienne) : couvre largement la zone de jointure sous les murs.
      fill_track_abs(master_state, w, master_state.rails_junction,
        w.position.x + 15, e.position.x - 15)
    end
  end
  -- (3) bord est courant. Si la sortie est est active : open_east (voie est +
  -- signal). SINON : close_east, qui RESTAURE la voie interne normale à +15/+17
  -- — indispensable car le comblement de jonction (étape 2) a pu convertir ces
  -- tuiles en rail-over puis les purger, laissant un trou. Sans restauration, un
  -- train pleine longueur (jusqu'à +16) ne peut plus être posé (spawn-failed).
  if master_state.exit_right then
    composite.open_east(master_state, chain[#chain])
  else
    composite.close_east(master_state, chain[#chain])
  end
end

-- x relatif des rails de RACCORD ouest (le bout de voie interne qui dépasse le
-- mur ouest, à l'ouest de la tête du train à HEAD_X=-12) : retirés quand la
-- sortie gauche est fermée, reposés quand elle est rouverte.
-- Le raccord ouest va jusqu'à -21 (2 tuiles au-delà du bord ouest -20), pour que
-- la voie sorte aussi loin qu'à l'est (+21) et rejoigne le réseau du joueur. Les
-- tuiles -15/-17 sont dans le bâtiment, -19/-21 dehors (en RAIL_OVER, elles
-- écrasent le mur puis prolongent la voie).
local WEST_CONNECT_XS = { -15, -17, -19, -21 }

-- Ferme la sortie OUEST : détruit les rails de raccord ouest (-17, -15) de la
-- voie interne ET le signal de sortie ouest (sinon il reste visible/actif alors
-- que la sortie est fermée). Le reste de la voie (assemblage) est préservé.
function composite.close_west(state)
  local e = state.entity
  if not (e and e.valid) then return end
  if state.signal and state.signal.valid then
    state.signal.destroy()
  end
  state.signal = nil
  local kept = {}
  for _, r in ipairs(state.rails or {}) do
    local rx = r.valid and (r.position.x - e.position.x)
    -- Tolérance 0.6 : les rails vivent sur coords impaires, la comparaison
    -- relative peut porter un léger reste.
    local matched = false
    if rx then
      for _, x in ipairs(WEST_CONNECT_XS) do
        if math.abs(rx - x) < 0.6 then matched = true break end
      end
    end
    if matched then
      r.destroy()
    else
      kept[#kept + 1] = r
    end
  end
  state.rails = kept
end

-- Ouvre la sortie OUEST : repose les rails de raccord ouest manquants (réutilise
-- un rail déjà là) et recrée le signal de sortie ouest.
function composite.open_west(state)
  local e = state.entity
  if not (e and e.valid) then return end
  for _, x in ipairs(WEST_CONNECT_XS) do
    local pos = { e.position.x + x, e.position.y + RAIL_Y }
    local occupied = false
    for _, ex in ipairs(e.surface.find_entities_filtered({
      type = "straight-rail", position = pos, radius = 0.2 })) do
      if ex.direction % 8 == defines.direction.east % 8 then
        occupied = true
        break
      end
    end
    if not occupied then
      -- RAIL_OVER : le raccord ouest écrase le mur (symétrique de la sortie est).
      local r = place(e, RAIL_OVER, { x, RAIL_Y }, defines.direction.east)
      if r then state.rails[#state.rails + 1] = r end
    end
  end
  if not (state.signal and state.signal.valid) then
    state.signal = place(e, SIGNAL, SIGNAL_OFFSET, SIGNAL_DIRECTION)
  end
end

-- Connecteur circuit : (re)crée-le pour les fonderies d'avant cette version.
function composite.ensure_combinator(state)
  if state.combinator and state.combinator.valid then return end
  local e = state.entity
  if not (e and e.valid) then return end
  local pos = { e.position.x + COMBINATOR_OFFSET[1],
                e.position.y + COMBINATOR_OFFSET[2] }
  state.combinator = e.surface.find_entities_filtered({
    name = COMBINATOR, position = pos, radius = 1 })[1]
    or place(e, COMBINATOR, COMBINATOR_OFFSET, defines.direction.north)
end

-- Coffre de réserve : (re)crée-le pour les fonderies d'avant cette version.
function composite.ensure_input(state)
  if state.input and state.input.valid then return end
  local e = state.entity
  if not (e and e.valid) then return end
  local pos = { e.position.x + INPUT_OFFSET[1], e.position.y + INPUT_OFFSET[2] }
  state.input = e.surface.find_entities_filtered({
    name = INPUT, position = pos, radius = 1 })[1]
    or place(e, INPUT, INPUT_OFFSET, defines.direction.north)
end

-- Déverse le contenu d'un coffre au sol (pour ne rien perdre à la dépose).
local function spill_chest(chest)
  if not (chest and chest.valid) then return end
  local inv = chest.get_inventory(defines.inventory.chest)
  if not inv or inv.is_empty() then return end
  for i = 1, #inv do
    local stack = inv[i]
    if stack.valid_for_read then
      chest.surface.spill_item_stack({
        position = chest.position,
        stack = stack,
        enable_looted = true,
        force = chest.force,
      })
    end
  end
end

-- Détruit proprement toutes les entités enfants. Le contenu des coffres
-- (réserve + blueprints) est déversé au sol pour ne rien perdre.
function composite.destroy(state)
  if not state then return end

  spill_chest(composite.reserve(state))
  spill_chest(composite.bp_chest(state))
  if state.input and state.input.valid then
    state.input.destroy()
  end
  if state.bpchest and state.bpchest.valid then
    state.bpchest.destroy()
  end
  -- Champs legacy des vieilles saves (anneau de quais, ancien coffre).
  for _, c in ipairs(state.inputs or {}) do
    if c.valid then c.destroy() end
  end
  if state.chest and state.chest.valid then
    state.chest.destroy()
  end

  if state.signal and state.signal.valid then
    state.signal.destroy()
  end

  if state.signal_east and state.signal_east.valid then
    state.signal_east.destroy()
  end

  if state.combinator and state.combinator.valid then
    state.combinator.destroy()
  end
  -- Legacy : ancien tableau de 4 combinators.
  for _, c in ipairs(state.combinators or {}) do
    if c.valid then c.destroy() end
  end

  for _, r in ipairs(state.rails or {}) do
    if r.valid then r.destroy() end
  end
  for _, r in ipairs(state.rails_east or {}) do
    if r.valid then r.destroy() end
  end
  for _, r in ipairs(state.rails_junction or {}) do
    if r.valid then r.destroy() end
  end
end

return composite
