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

local names = require("names")

local composite = {}

local RAIL       = names.rail
local RAIL_OVER  = names.rail_over  -- rail dessiné par-dessus le mur (sortie est)
local RAIL_EXT   = names.rail_ext   -- rail hors bâtiment : sélectionnable, extensible
local RECYCLE_STOP = names.recycle_stop  -- gare de recyclage (train-stop)
local BLOCK_SIGNAL = names.block_signal  -- signal toujours rouge (anti-marche-arrière)
local BLOCK_COMBI  = names.block_combi   -- combinateur qui ferme le signal de blocage
local INPUT      = names.input
local SIGNAL     = names.signal
local COMBINATOR = names.combinator
local BPCHEST    = names.bpchest
local WALL       = names.wall
local GATE       = names.gate
local DECO_TOP   = names.deco_top   -- bande déco haut (entité, ordre de dessin piloté)

-- Réserve (coffre de fer), coffre à blueprints et connecteur circuit, posés
-- sur le PARVIS ouest, dans la zone libre hors collision (x < -18) : de
-- vraies entités que les bras et l'outil fil savent cibler. Un peu à l'écart
-- de la voie de sortie (rangée +5) pour rester accessibles.
-- Enfants du parvis ouest REMONTÉS dans la moitié HAUTE du hall (Y négatif) :
-- les 2 voies occupent Y≈0..+2 (recyclage) et Y≈+4..+6 (assemblage), donc on
-- libère cette bande. Les signaux, eux, restent près des voies qu'ils gouvernent.
local INPUT_OFFSET      = { -19.5, -5.5 }  -- coffre de fer (réserve)
local COMBINATOR_OFFSET = { -19.5, -3.5 }  -- connecteur circuit
local BPCHEST_OFFSET    = { -19.5, -7.5 }  -- coffre à blueprints

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

-- 2e voie (déconstruction), rangée y = +1 (impair, comme la voie d'assemblage).
-- 4 tuiles d'écart avec la voie d'assemblage (y=+5) → place pour une gare entre
-- les deux. Géométrie issue de la maquette (blueprint) du joueur.
local DECO_RAIL_Y = 1

-- Sol PAVÉ (stone-path) posé sous la bande des 2 voies (Y=0..+6 : recyclage +
-- assemblage + l'espace entre). Purement visuel/sol ; sur toute la largeur
-- intérieure du module (X -17..+17). Le sol d'origine est mémorisé (floor_saved)
-- pour être restauré à la dépose.
local FLOOR_TILE = "stone-path"
local FLOOR_X_MIN, FLOOR_X_MAX = -17, 18  -- +18 : le pavé va jusqu'au mur est (+19)
local FLOOR_Y_MIN, FLOOR_Y_MAX = 0, 6

-- Enceinte de murs : pourtour du footprint. Le bâtiment fait 40×22 (collision
-- box [-18,-10.7]..[19.7,10.7]). Les murs vivent sur les tuiles ENTIÈRES : on
-- pose une bande sur X entiers -18..+19 et Y entiers -10..+10, sur le seul
-- PÉRIMÈTRE (pas l'intérieur). Les ouvertures pour les voies sont laissées aux
-- extrémités des voies actives (gérées par rebuild_side).
local WALL_X_MIN, WALL_X_MAX = -18, 19
local WALL_Y_MIN, WALL_Y_MAX = -10, 10

-- Portes : posées DANS l'alignement du mur du bord (x=-18 ouest / +19 est),
-- orientées VERTICALEMENT (direction north, comme le mur) là où une voie traverse
-- le mur. Elles remplacent le segment de mur troué par la voie et s'ouvrent au
-- passage du train (barrière verticale, trafic horizontal). Posées seulement du
-- côté d'une sortie ACTIVE (voir rebuild_side).
local GATE_X_WEST, GATE_X_EAST = -18, 19
local GATE_DIRECTION = defines.direction.north

-- Aménagement de la voie de RECYCLAGE, par côté d'entrée. Chaque côté est une
-- LISTE d'éléments à poser (structure déclarative unifiée) :
--  - kind="stop"   : gare de recyclage (train-stop nommé), au bout FERMÉ.
--  - kind="signal" : rail-signal de blocage. `wired=true` → relié au combinateur
--    du même côté et forcé ROUGE (close_signal). Les autres signaux sont juste
--    posés (couvrent l'autre sens sur une voie bidirectionnelle).
--  - kind="combi"  : constant-combinator qui émet signal-A=1 (alimente le signal
--    wired via un fil rouge).
-- La liste WEST est utilisée quand l'entrée est à GAUCHE (deco_left), EAST quand
-- l'entrée est à DROITE (deco_right). X relatif au module porteur, Y au centre.
-- Positions VALIDÉES en jeu par le joueur.
local RECYCLE_ROAD = {
  -- `anchor` = sur quel module poser l'élément : "entry" (module côté entrée) ou
  -- "far" (module du bout fermé, opposé). Dans une chaîne : entrée gauche → entry=
  -- master, far=dernière extension ; entrée droite → l'inverse.
  west = {  -- entrée à GAUCHE : gare au fond EST, blocage à l'entrée OUEST
    { kind = "stop",   anchor = "far",   x = 17, y = 2, dir = defines.direction.east },
    { kind = "signal", anchor = "entry", x = -17, y = -1, dir = defines.direction.east, wired = true },
    { kind = "signal", anchor = "entry", x = -17, y =  2, dir = defines.direction.west },
    { kind = "combi",  anchor = "entry", x = -15, y = -1 },
  },
  east = {  -- entrée à DROITE : gare au fond OUEST, blocage à l'entrée EST
    { kind = "stop",   anchor = "far",   x = -15, y = DECO_RAIL_Y - 2, dir = defines.direction.west },
    { kind = "signal", anchor = "entry", x = 18, y =  2, dir = defines.direction.west, wired = true },
    { kind = "signal", anchor = "entry", x = 18, y = -1, dir = defines.direction.east },
    { kind = "combi",  anchor = "entry", x = 16, y = 2 },
  },
}



-- Les DEUX voies traversant les colonnes latérales, chacune décrite par :
--  - center : Y central du rail
--  - tiles  : les 2 tuiles ENTIÈRES qu'elle occupe (center-1, center)
--  - gates  : les 2 Y demi-entiers des portes (center±0.5), couvrant la largeur
--  - kind   : "assembly" (sorties exit_left/right) ou "deco" (parent state.deco
--             + deco_left/right)
-- Une porte 1×1 par tuile → 2 portes/voie. (Positions calées sur la maquette.)
local TRACKS = {
  { kind = "assembly", center = RAIL_Y,
    tiles = { RAIL_Y - 1, RAIL_Y },
    gates = { RAIL_Y - 0.5, RAIL_Y + 0.5 } },
  { kind = "deco", center = DECO_RAIL_Y,
    tiles = { DECO_RAIL_Y - 1, DECO_RAIL_Y },
    gates = { DECO_RAIL_Y - 0.5, DECO_RAIL_Y + 0.5 } },
}

-- Une voie est-elle OUVERTE de ce côté ? (assemblage : exit_left/right ;
-- recyclage : nécessite state.deco ET deco_left/right).
local function track_open(state, track, side)
  if track.kind == "assembly" then
    if side == "west" then return state.exit_left else return state.exit_right end
  else
    if not state.deco then return false end
    if side == "west" then return state.deco_left else return state.deco_right end
  end
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
-- sur une rangée Y (défaut RAIL_Y = voie d'assemblage). Réutilise un rail déjà
-- présent (pose par-dessus une voie). Ajoute les rails créés à `bucket`
-- (défaut state.rails). Utilisé pour la voie d'assemblage (RAIL_Y, state.rails)
-- ET pour la 2e voie de déconstruction (DECO_RAIL_Y, state.rails_deco).
local function lay_rails(state, entity, x_from, x_to, y, bucket)
  y = y or RAIL_Y
  bucket = bucket or state.rails
  for x = x_from, x_to, 2 do
    local pos = { entity.position.x + x, entity.position.y + y }
    local occupied = false
    for _, ex in ipairs(entity.surface.find_entities_filtered({
      type = "straight-rail", position = pos, radius = 0.2 })) do
      if ex.direction % 8 == defines.direction.east % 8 then
        occupied = true
        break
      end
    end
    if not occupied then
      local r = place(entity, RAIL, { x, y }, defines.direction.east)
      if r then bucket[#bucket + 1] = r end
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
    -- La jonction tombe SOUS les murs accolés des deux modules : un rail normal y
    -- serait MASQUÉ par le sprite du bâtiment (testé : trou visuel). On y met donc
    -- un RAIL_OVER (dessiné au-dessus du sprite). Effet de bord connu et assumé
    -- (temporaire) : le rail-over passe aussi au-dessus des roues des wagons, qui
    -- sont donc masquées à la jonction — aucun calque n'existe entre le sprite et
    -- les roues pour l'éviter. IMPORTANT : deux straight-rail ne coexistent pas —
    -- un tf-rail normal déjà présent est détruit puis remplacé par le rail-over.
    local has_over = false
    for _, ex in ipairs(surface.find_entities_filtered({
      type = "straight-rail", position = pos, radius = 0.2 })) do
      if ex.direction % 8 == defines.direction.east % 8 then
        if ex.name == RAIL_OVER then
          has_over = true
        elseif ex.name == RAIL then
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
    rails_deco = {},   -- 2e voie (déconstruction), rangée DECO_RAIL_Y
    walls_static = {}, -- murs haut+bas (statiques, jamais retouchés)
    side_west = {},    -- colonne ouest : murs + portes (selon exit_left)
    side_east = {},    -- colonne est : murs + portes (selon exit_right / extension)
    recycle_stops = {},-- gares de recyclage (train-stop, bord opposé à l'entrée)
    deco_top_ent = nil,-- bande déco haut (entité ; Y décalé selon voisin pour l'ordre)
    floor_saved = {},  -- sol d'origine écrasé par les pavés (pour restauration)
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
    -- Côtés de sortie de la voie d'ASSEMBLAGE (Y=RAIL_Y). Gauche ouverte par
    -- défaut, droite opt-in. Au moins une des deux reste ouverte.
    exit_left = true,
    exit_right = false,
    -- Voie de RECYCLAGE (Y=DECO_RAIL_Y), OPTIONNELLE (case parent, off par défaut).
    -- Ses propres côtés (indépendants de l'assemblage) : gauche par défaut.
    deco = false,
    deco_left = true,
    deco_right = false,
    -- La source des trains n'est plus un choix runtime : elle est fixée par la
    -- VARIANTE du mod (BP ou STC via names.source). Plus de champ source_mode.
    -- Carburant générique (variante BP uniquement, case dans Configuration) :
    -- false = respecter le carburant du blueprint (défaut, 0.5.x) ; true = remplir
    -- au meilleur carburant débloqué dispo + interruption Refuel. En STC toujours
    -- générique quel que soit ce champ.
    generic_fuel = false,
  }

  -- Voie interne du master : -13..+17 (impairs), zone d'assemblage. Le raccord
  -- ouest (-17,-15, qui traverse le mur) est posé séparément par open_west en
  -- RAIL_OVER, pour un seul chemin cohérent (défaut sortie gauche ouverte).
  -- Voie d'ASSEMBLAGE interne (-13..+17) + raccord ouest (open_west). Les tronçons
  -- qui dépassent le bâtiment sont posés en RAIL_EXT (sélectionnables). La 2e voie
  -- (RECYCLAGE) n'est PAS posée ici : elle n'existe que si state.deco est actif
  -- (posée/retirée par rebuild_deco_track via refresh_chain_track).
  lay_rails(state, entity, -13, 17)
  composite.open_west(state)

  -- Sol pavé sous la bande des voies.
  composite.lay_floor(state)

  -- Enceinte de murs : statique (haut/bas) + colonnes latérales (murs pleins ou
  -- ouvertures+portes selon exit_left/exit_right). Voir ensure_walls_static /
  -- rebuild_side. Les portes vivent dans state.side_west / state.side_east.
  composite.ensure_walls(state)

  state.input = place(entity, INPUT, INPUT_OFFSET, defines.direction.north)
  state.combinator = place(entity, COMBINATOR, COMBINATOR_OFFSET,
    defines.direction.north)
  if names.has_bpchest then
    state.bpchest = place(entity, BPCHEST, BPCHEST_OFFSET, defines.direction.north)
    composite.set_bpchest_filters(state)
  end

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
    -- Murs de l'extension : haut/bas (statique) posés ci-dessous ; les colonnes
    -- latérales sont pilotées par rebuild_chain_walls (est sur le dernier module,
    -- ouest vidé car accolé au master). Listes pour le tracking/destruction.
    walls_static = {},
    side_west = {},
    side_east = {},
    floor_saved = {},
  }
  -- Rails de l'extension : on pose GÉNÉREUSEMENT de -23 à +17 (impairs). Le
  -- chevauchement à gauche comble le trou entre le dernier rail du module
  -- précédent et ce module, quel que soit l'écart de snap (38 ou 40) — un rail
  -- déjà présent est réutilisé (lay_rails saute les positions occupées), donc
  -- pas de doublon.
  lay_rails(state, entity, -23, 17)
  -- Sol pavé sous la bande des voies de l'extension.
  composite.lay_floor(state)
  -- Par défaut non minable : l'appelant (refresh_chain_minable) rendra minable
  -- uniquement la dernière extension de la chaîne. Évite qu'une extension du
  -- milieu soit minable une fraction de temps avant le recalcul.
  entity.minable_flag = false
  return state
end

-- Détecte, à la pose de `entity`, la fonderie dont le bord EST est ACCOLÉ au
-- bord OUEST de `entity` (voisin à l'ouest, même rangée). Deux modules accolés
-- ont leurs centres espacés d'EXACTEMENT dx=36 quand ils sont COLLÉS (jonction
-- propre : sol/déco/voie continus, murs qui se touchent). Le bâtiment snappe sur la
-- grille PAIRE (build_grid_size=2), donc les seules distances possibles sont 34, 36,
-- 38… : à 38+ il reste un TROU visible (sol martien, voie flottante). On n'accepte
-- donc l'accolage que TRÈS PRÈS de 36 (35..37) — au-delà ce n'est pas une extension,
-- la pose est refusée + remboursée (voir on_built). 34 exclu aussi (chevauchement).
function composite.adjacent_west(entity, foundries)
  local px, py = entity.position.x, entity.position.y
  local best, best_dx
  for _, st in pairs(foundries) do
    local e = st.entity
    if e and e.valid and e ~= entity and e.surface == entity.surface then
      local dx = px - e.position.x  -- >0 si le voisin est à l'OUEST
      if math.abs(e.position.y - py) < 1.0 and dx >= 35 and dx <= 37 then
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
  if not names.bpchest then return nil end
  if state.bpchest and state.bpchest.valid then return state.bpchest end
  return nil
end

-- Filtre le coffre à blueprints pour n'accepter que des blueprints (tous les
-- slots filtrés sur l'item "blueprint").
function composite.set_bpchest_filters(state)
  if not names.bpchest then return end
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
  if not names.bpchest then return end
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
    -- Position sous le mur est (x<=18) → RAIL_OVER ; qui DÉPASSE (x>18) → RAIL_EXT
    -- (sélectionnable, prolongeable à la main).
    local proto = (x > 18) and RAIL_EXT or RAIL_OVER
    local has_it = false
    for _, ex in ipairs(surface.find_entities_filtered({
      type = "straight-rail", position = pos, radius = 0.2 })) do
      if ex.direction % 8 == defines.direction.east % 8 then
        if ex.name == RAIL_OVER or ex.name == RAIL_EXT then
          has_it = true
        elseif ex.name == RAIL then
          -- Rail normal résiduel : le retirer (des rails du master si présent)
          -- pour libérer la position.
          for i = #(state.rails or {}), 1, -1 do
            if state.rails[i] == ex then table.remove(state.rails, i) end
          end
          ex.destroy()
        end
      end
    end
    if not has_it then
      local r = place(anchor, proto, { x, RAIL_Y }, defines.direction.east)
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
  -- (0) NETTOYAGE GÉOMÉTRIQUE des rails ORPHELINS à l'est de la chaîne réduite :
  -- au retrait d'extension(s), des tf-rail/tf-rail-over de la voie d'une extension
  -- disparue peuvent rester (positions "réutilisées" non trackées dans une seule
  -- liste). On détruit tout rail interne sur la rangée RAIL_Y au-delà du bord est
  -- légitime du dernier module (centre + EAST_RAIL_X_TO). Fiable quel que soit
  -- l'ordre de retrait, indépendant du tracking par liste.
  local last = chain[#chain]
  if last and last.valid then
    local ry = last.position.y + RAIL_Y
    local x_min = last.position.x + EAST_RAIL_X_TO + 1  -- au-delà de la sortie est légitime
    for _, r in ipairs(last.surface.find_entities_filtered({
      type = "straight-rail",
      area = { { x_min, ry - 0.5 }, { x_min + 4 * MODULE_WIDTH, ry + 0.5 } },
    })) do
      if r.valid and (r.name == RAIL or r.name == RAIL_OVER) then r.destroy() end
    end
  end

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
      -- Position sous le mur (|x|<=18) → RAIL_OVER (interne, non-sélectionnable).
      -- Position qui DÉPASSE le bâtiment (|x|>18) → RAIL_EXT (sélectionnable, pour
      -- que le joueur prolonge la voie à la main).
      local proto = (math.abs(x) > 18) and RAIL_EXT or RAIL_OVER
      local r = place(e, proto, { x, RAIL_Y }, defines.direction.east)
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

-- Enceinte de murs : (re)pose le pourtour du footprint. Idempotent — réutilise
-- un mur déjà présent. On laisse les OUVERTURES aux extrémités des voies actives
-- (les tuiles des rangées de voie sur les côtés est/ouest ne reçoivent pas de
-- mur si la sortie correspondante est ouverte ; les portes s'y posent).
-- Murs HAUT + BAS (toute la largeur, coins inclus) : STATIQUES, posés une fois au
-- build, jamais retouchés (indépendants des sorties). Rangés dans state.walls_static.
function composite.ensure_walls_static(state)
  local e = state.entity
  if not (e and e.valid) then return end
  -- IDEMPOTENT et RÉPARATEUR : repose chaque mur haut/bas MANQUANT (ne duplique
  -- pas — réutilise celui déjà en place). Nécessaire car le balayage par zone de
  -- composite.destroy d'une extension DÉBORDE sur le master voisin (footprints qui
  -- se chevauchent, dx≈38 < 40) et peut manger des murs statiques du master : on
  -- doit pouvoir les recréer au rebuild suivant (retrait d'extension).
  state.walls_static = {}
  -- Le stone-wall (footprint 1×1) se snappe au CENTRE de case le plus proche =
  -- coordonnée .5. Viser des positions ENTIÈRES faisait arrondir deux offsets
  -- voisins (ex. -38 et -37) vers le MÊME centre (-37.5) → un mur sur deux perdu.
  -- On vise donc directement les centres de case en .5, espacés de 1, sur toute
  -- la largeur (bord gauche du bâtiment WALL_X_MIN à WALL_X_MAX).
  for xi = WALL_X_MIN, WALL_X_MAX do
    for _, y in ipairs({ WALL_Y_MIN, WALL_Y_MAX }) do
      -- position ABSOLUE du centre de case (floor + 0.5 garantit le .5 attendu)
      local px = math.floor(e.position.x + xi) + 0.5
      local py = math.floor(e.position.y + y) + 0.5
      -- Réutilise le mur déjà en place (idempotent) ; sinon (re)pose via
      -- create_entity (JAMAIS can_place_entity : trop strict sur sol pavé).
      -- Recherche par aire d'UNE case (±0.4) centrée sur le vrai centre .5.
      local w = e.surface.find_entities_filtered({
        name = WALL, area = { { px - 0.4, py - 0.4 }, { px + 0.4, py + 0.4 } },
      })[1]
      if not w then
        w = e.surface.create_entity({
          name = WALL, position = { px, py },
          direction = defines.direction.north, force = e.force })
        if w then w.destructible = false end
      end
      if w then state.walls_static[#state.walls_static + 1] = w end
    end
  end
end

-- Patch de jonction d'UN module. La bande déco NORMALE (haut+bas) est un
-- working_visualisation du bâtiment (toujours affiché). Ce patch n'existe QUE si le
-- module a une extension à droite (`has_right`) : posé au centre du bâtiment (son
-- sprite porte le shift +X vers le bord droit), il recouvre les structures qui se
-- chevaucheraient à la jonction par la moitié droite de la variante (fond continu).
-- has_right faux → on retire le patch éventuel (module redevenu dernier de chaîne).
-- Bande déco du HAUT d'UN module : entité DECO_TOP posée au centre du bâtiment
-- (le sprite porte son shift). Idempotente. L'ORDRE DE DESSIN (idée du joueur) est
-- piloté par un décalage Y infime : un module suivi d'une extension à droite
-- (`has_right`) est posé 0.05 tuile plus BAS → Factorio le dessine PAR-DESSUS le
-- voisin (à render_layer égal, le plus au sud gagne), donc son bord droit (fond)
-- recouvre les structures du bord gauche du voisin → jonction propre. Le décalage
-- est compensé dans le shift interne (rien ne bouge à l'écran). Le BAS est un
-- working_visualisation du bâtiment (géré ailleurs).
-- Bande déco haut d'UN module : entité DECO_TOP posée au centre du bâtiment,
-- idempotente. Sa VARIATION dépend du voisin de droite (fiable, contrairement à
-- l'ordre de dessin) :
--   has_right → variation 2 (variante : bord droit fondu en sol → jonction propre)
--   sinon     → variation 1 (normal : structures jusqu'au bord)
function composite.ensure_facade(state, has_right)
  local e = state.entity
  if not (e and e.valid) then return end
  local surf = e.surface
  local pos = { e.position.x, e.position.y }
  if not (state.deco_top_ent and state.deco_top_ent.valid) then
    state.deco_top_ent = surf.find_entities_filtered({
      name = DECO_TOP, position = pos, radius = 0.6 })[1]
      or surf.create_entity({ name = DECO_TOP, position = pos, force = e.force })
    if state.deco_top_ent then state.deco_top_ent.destructible = false end
  end
  if state.deco_top_ent and state.deco_top_ent.valid then
    state.deco_top_ent.graphics_variation = has_right and 2 or 1
  end
end

-- Pose le sol PAVÉ (FLOOR_TILE) sous la bande des voies d'UN module. Mémorise le
-- sol écrasé dans state.floor_saved (liste de { name, x, y } en coords ABSOLUES)
-- pour restauration à la dépose. Idempotent : posé une fois par module au build.
function composite.lay_floor(state)
  local e = state.entity
  if not (e and e.valid) then return end
  state.floor_saved = state.floor_saved or {}
  local surf = e.surface
  local set = {}
  for x = FLOOR_X_MIN, FLOOR_X_MAX do
    for y = FLOOR_Y_MIN, FLOOR_Y_MAX do
      local ax, ay = e.position.x + x, e.position.y + y
      local old = surf.get_tile(ax, ay)
      if old and old.valid and old.name ~= FLOOR_TILE then
        state.floor_saved[#state.floor_saved + 1] =
          { name = old.name, x = ax, y = ay }
        set[#set + 1] = { name = FLOOR_TILE, position = { ax, ay } }
      end
    end
  end
  if #set > 0 then surf.set_tiles(set) end
end

-- Restaure le sol d'origine mémorisé (à la dépose du module). `surface` peut être
-- fourni si l'entité est déjà invalide (cas du minage) ; sinon on lit celle de
-- l'entité. Les coords sauvegardées sont ABSOLUES (indépendantes de l'entité).
function composite.remove_floor(state, surface)
  if not (state.floor_saved and #state.floor_saved > 0) then return end
  local surf = surface
  if not surf then
    local e = state.entity
    surf = e and e.valid and e.surface
  end
  if not surf then state.floor_saved = nil; return end
  local set = {}
  for _, t in ipairs(state.floor_saved) do
    set[#set + 1] = { name = t.name, position = { t.x, t.y } }
  end
  surf.set_tiles(set)
  state.floor_saved = nil
end

-- VIDE une colonne latérale (side) : détruit la liste state[field] ET tout
-- mur/porte PHYSIQUE de la colonne (balayage par zone). Marge X ±0.9 : une GATE
-- posée à x=-18 est snappée à -17.5 par le moteur — marge étroite = ratée.
-- NE TOUCHE PAS aux RAILS (gérés par lay_rails/open_west/lay_east_rails) : un rail
-- de raccord à x=-17 sous la porte était mangé ici puis jamais reposé → trou.
-- Utilisé pour purger avant de reposer, ET pour ouvrir un flanc (jonction de
-- chaîne : le côté est du master / le côté ouest d'une extension = hall continu).
function composite.clear_side(state, side)
  local e = state.entity
  if not (e and e.valid) then return end
  local field = (side == "west") and "side_west" or "side_east"
  local x = (side == "west") and WALL_X_MIN or WALL_X_MAX
  for _, ent in ipairs(state[field] or {}) do
    if ent.valid then ent.destroy() end
  end
  for _, ent in ipairs(e.surface.find_entities_filtered({
    name = { WALL, GATE },
    area = { { e.position.x + x - 0.9, e.position.y + WALL_Y_MIN + 1 },
             { e.position.x + x + 0.9, e.position.y + WALL_Y_MAX - 1 } },
  })) do
    if ent.valid then ent.destroy() end
  end
  state[field] = {}
end

-- Reconstruit UNE colonne latérale (side = "west" ou "east") sur la hauteur
-- INTÉRIEURE (les coins appartiennent au statique haut/bas). La géométrie et le
-- rangement se font sur `state` (state.entity, state.side_*), mais les FLAGS de
-- sortie (exit_*, deco*) sont lus sur `flags_state` (défaut = state). Ce
-- découplage permet de poser le côté est sur l'entité de la DERNIÈRE extension
-- tout en lisant les sorties du MASTER (une extension n'a pas ces flags).
-- Décision par voie : tuile d'une voie ouverte de ce côté → porte ; sinon → mur.
function composite.rebuild_side(state, side, flags_state)
  local e = state.entity
  if not (e and e.valid) then return end
  flags_state = flags_state or state
  local x = (side == "west") and WALL_X_MIN or WALL_X_MAX
  local field = (side == "west") and "side_west" or "side_east"

  composite.clear_side(state, side)

  -- Tuiles à laisser OUVERTES = celles des voies ouvertes de ce côté (une porte
  -- y sera posée). Les autres tuiles reçoivent un mur plein.
  local open_tiles = {}
  for _, track in ipairs(TRACKS) do
    if track_open(flags_state, track, side) then
      for _, ty in ipairs(track.tiles) do open_tiles[ty] = true end
    end
  end
  for y = WALL_Y_MIN + 1, WALL_Y_MAX - 1 do
    if not open_tiles[y] then
      local w = place(e, WALL, { x, y }, defines.direction.north)
      if w then state[field][#state[field] + 1] = w end
    end
  end

  -- Portes (2 par voie ouverte de ce côté).
  for _, track in ipairs(TRACKS) do
    if track_open(flags_state, track, side) then
      for _, gy in ipairs(track.gates) do
        local g = place(e, GATE, { x, gy }, GATE_DIRECTION)
        if g then state[field][#state[field] + 1] = g end
      end
    end
  end
end

-- (Re)construit tout le pourtour d'UN module isolé : statique + 2 colonnes + déco.
-- Module isolé = pas d'extension à droite → façade en variation 1 (normal).
function composite.ensure_walls(state)
  composite.ensure_walls_static(state)
  composite.rebuild_side(state, "west")
  composite.rebuild_side(state, "east")
  composite.ensure_facade(state, false)
end

-- Murs d'une CHAÎNE de modules. `chain` = liste ORDONNÉE des STATES (master en
-- [1], extensions ensuite, ouest→est). Règles :
--  - chaque module pose ses murs haut/bas (statique, idempotent) ;
--  - côté OUEST = seulement le master (chain[1]) ; les autres ont leur ouest VIDÉ
--    (hall continu vers le voisin ouest) ;
--  - côté EST = seulement le DERNIER module (chain[#chain]), en lisant les FLAGS
--    du master ; les autres ont leur est VIDÉ.
-- Un module seul (chain de 1) : master porte ouest ET est, rien à vider.
function composite.rebuild_chain_walls(master_state, chain)
  if not (chain and #chain > 0) then return end
  local n = #chain
  for i, st in ipairs(chain) do
    composite.ensure_walls_static(st)
    -- OUEST : le master le porte, les autres l'ouvrent (hall continu).
    if i == 1 then
      composite.rebuild_side(st, "west", master_state)
    else
      composite.clear_side(st, "west")
    end
    -- EST : le dernier module le porte (flags du master), les autres l'ouvrent.
    if i == n then
      composite.rebuild_side(st, "east", master_state)
    else
      composite.clear_side(st, "east")
    end
    -- Bande déco haut : variation 2 (variante, bord droit en fond) si ce module a un
    -- voisin à droite (i < n), sinon variation 1 (normal). graphics_variation est
    -- fiable, contrairement à l'ordre de dessin.
    composite.ensure_facade(st, i < n)
  end
  composite.rebuild_recycle_stops(master_state, chain)
end

-- Aménagement de la voie de RECYCLAGE (gare + signaux de blocage + combinateur),
-- décrit par la structure déclarative RECYCLE_ROAD. `chain` = liste ordonnée des
-- STATES (master en [1], dernier module en [#chain]). Selon le côté d'ENTRÉE actif
-- (deco_left → road.west ; deco_right → road.east), on pose chaque élément de la
-- liste sur son ancre ("entry" = module côté entrée ; "far" = bout fermé opposé).
-- Tout est rangé dans master_state.recycle_stops (détruit avec la fonderie).
function composite.rebuild_recycle_stops(master_state, chain)
  if not (chain and #chain > 0) then return end
  -- Purge les éléments existants.
  for _, s in ipairs(master_state.recycle_stops or {}) do
    if s.valid then s.destroy() end
  end
  master_state.recycle_stops = {}
  if not master_state.deco then return end  -- voie de recyclage inactive

  local function keep(s)
    if s then master_state.recycle_stops[#master_state.recycle_stops + 1] = s end
    return s
  end

  -- Pose une LISTE d'éléments (RECYCLE_ROAD.west / .east). `entry_state` = module
  -- côté entrée, `far_state` = module du bout fermé.
  local function place_road(elems, entry_state, far_state)
    local wired_signal, combi  -- pour relier le signal wired au combinateur après
    for _, el in ipairs(elems) do
      local anchor = (el.anchor == "far") and far_state or entry_state
      local e = anchor and anchor.entity
      if e and e.valid then
        local pos = { e.position.x + el.x, e.position.y + el.y }
        if el.kind == "stop" then
          local s = e.surface.create_entity({
            name = RECYCLE_STOP, position = pos, direction = el.dir, force = e.force })
          if s then s.destructible = false; s.backer_name = names.recycle_stop_name
            keep(s) end
        elseif el.kind == "signal" then
          local sig = e.surface.create_entity({
            name = BLOCK_SIGNAL, position = pos, direction = el.dir, force = e.force })
          if sig then
            sig.destructible = false; keep(sig)
            if el.wired then wired_signal = sig end
          end
        elseif el.kind == "combi" then
          combi = e.surface.create_entity({
            name = BLOCK_COMBI, position = pos, force = e.force })
          if combi then combi.destructible = false; keep(combi) end
        end
      end
    end
    -- Câblage : le combinateur émet signal-A=1, relié au signal `wired` (fil rouge),
    -- qui est forcé ROUGE (close_signal quand signal-A > 0 → toujours vrai).
    if wired_signal and combi then
      local ccb = combi.get_or_create_control_behavior()
      local sec = ccb and ccb.get_section(1)
      if sec then
        sec.set_slot(1, {
          value = { type = "virtual", name = "signal-A", quality = "normal" }, min = 1 })
      end
      local sc = wired_signal.get_wire_connector(defines.wire_connector_id.circuit_red, true)
      local cc = combi.get_wire_connector(defines.wire_connector_id.circuit_red, true)
      if sc and cc then sc.connect_to(cc) end
      local scb = wired_signal.get_or_create_control_behavior()
      if scb then
        scb.close_signal = true
        scb.circuit_condition = {
          comparator = ">", first_signal = { type = "virtual", name = "signal-A" },
          constant = 0 }
      end
    end
  end

  -- Entrée à GAUCHE (deco_left) : entry = master (chain[1]), far = dernière ext.
  if master_state.deco_left then
    place_road(RECYCLE_ROAD.west, chain[1], chain[#chain])
  end
  -- Entrée à DROITE (deco_right) : entry = dernière ext, far = master.
  if master_state.deco_right then
    place_road(RECYCLE_ROAD.east, chain[#chain], chain[1])
  end
end

-- (Les portes sont désormais gérées PAR CÔTÉ dans composite.rebuild_side : elles
-- vivent dans state.side_west / state.side_east avec les murs de leur colonne.)

-- 2e voie (RECYCLAGE) sur DECO_RAIL_Y : posée SEULEMENT si state.deco actif.
-- Chaque module pose sa portion interne (-17..+17). La voie DÉBOUCHE (raccord
-- externe qui sort du mur) uniquement du côté de l'ENTRÉE :
--  - deco_left (entrée gauche) → raccord OUEST (-19/-21) sur le master ; la voie
--    sort à gauche, le train y entre. Bout est fermé (gare à droite).
--  - deco_right (entrée droite) → raccord EST (+19/+21) sur la dernière extension.
-- Appelée par refresh_chain_track (ajout/retrait d'extension, bascule Config).
function composite.rebuild_deco_track(master_state, chain)
  if not (chain and #chain > 0) then return end
  -- Repart de zéro (purge la voie déco) : sinon un raccord externe du mauvais côté
  -- survit quand on change l'entrée. lay_rails saute une position déjà occupée.
  for _, r in ipairs(master_state.rails_deco or {}) do
    if r.valid then r.destroy() end
  end
  master_state.rails_deco = {}
  if not master_state.deco then return end

  -- Le côté FERMÉ (opposé à l'entrée) s'arrête 1 tuile plus tôt (-15 / +15) pour ne
  -- pas coller au mur (effet de "sortie"). Le côté ENTRÉE va jusqu'à -17/+17 puis
  -- le raccord externe. Un module au milieu garde -17..+17.
  local n = #chain
  for i, st in ipairs(chain) do
    local e = st.entity
    if e and e.valid then
      -- Voie interne jusqu'aux bords -17..+17 (la gare du bout fermé est à ±17).
      lay_rails(master_state, e, -17, 17, DECO_RAIL_Y, master_state.rails_deco)
    end
  end
  -- Raccord EXTERNE (le bout qui dépasse le mur) du côté de l'entrée, en RAIL_EXT
  -- (sélectionnable, prolongeable). -19/-21 ouest sur le master ; +19/+21 est sur
  -- la dernière extension.
  local function ext(anchor_state, xs)
    local e = anchor_state.entity
    if not (e and e.valid) then return end
    for _, x in ipairs(xs) do
      local pos = { e.position.x + x, e.position.y + DECO_RAIL_Y }
      local occupied = false
      for _, r in ipairs(e.surface.find_entities_filtered({
        type = "straight-rail", position = pos, radius = 0.2 })) do
        if r.direction % 8 == defines.direction.east % 8 then occupied = true break end
      end
      if not occupied then
        local r = place(e, RAIL_EXT, { x, DECO_RAIL_Y }, defines.direction.east)
        if r then master_state.rails_deco[#master_state.rails_deco + 1] = r end
      end
    end
  end
  if master_state.deco_left then ext(chain[1], { -19, -21 }) end
  if master_state.deco_right then ext(chain[#chain], { 19, 21 }) end
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

  -- Capture surface + position AVANT de détruire (l'entité principale peut
  -- devenir invalide) pour le balayage par zone des murs/portes.
  local surf, cx, cy
  if state.entity and state.entity.valid then
    surf, cx, cy = state.entity.surface, state.entity.position.x, state.entity.position.y
  end

  spill_chest(composite.reserve(state))
  if names.has_bpchest then
    spill_chest(composite.bp_chest(state))
  end
  if state.input and state.input.valid then
    state.input.destroy()
  end
  if names.has_bpchest then
    if state.bpchest and state.bpchest.valid then
      state.bpchest.destroy()
    end
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
  -- 2e voie (déconstruction).
  for _, r in ipairs(state.rails_deco or {}) do
    if r.valid then r.destroy() end
  end
  -- Gares de recyclage.
  for _, s in ipairs(state.recycle_stops or {}) do
    if s.valid then s.destroy() end
  end
  -- Enceinte de murs + portes (statique + 2 colonnes latérales) puis balayage par
  -- ZONE du footprint (au cas où une liste serait désynchronisée) → aucun mur/porte
  -- orphelin ne survit au minage.
  for _, grp in ipairs({ state.walls_static, state.side_west, state.side_east }) do
    for _, ent in ipairs(grp or {}) do
      if ent.valid then ent.destroy() end
    end
  end
  -- Bande déco haut de CE module.
  if state.deco_top_ent and state.deco_top_ent.valid then
    state.deco_top_ent.destroy()
  end
  if surf then
    for _, ent in ipairs(surf.find_entities_filtered({
      name = { WALL, GATE, RECYCLE_STOP, DECO_TOP },
      area = { { cx + WALL_X_MIN - 1, cy + WALL_Y_MIN - 1 },
               { cx + WALL_X_MAX + 1, cy + WALL_Y_MAX + 1 } },
    })) do
      if ent.valid then ent.destroy() end
    end
  end
  -- Restaure le sol d'origine sous les pavés (surf capturé au début, l'entité
  -- peut être déjà invalide au minage).
  composite.remove_floor(state, surf)
end

return composite
