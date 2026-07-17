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
local INPUT      = "tf-input"
local SIGNAL     = "tf-signal"
local COMBINATOR = "tf-combinator"

-- Réserve (coffre de fer visible) et connecteur circuit (combinator visible),
-- posés sur le PARVIS ouest, dans la zone libre hors collision (x < -18) :
-- de vraies entités que les bras et l'outil fil savent cibler. Un peu à
-- l'écart de la voie de sortie (rangée +5) pour rester accessibles.
local INPUT_OFFSET      = { -19.5, -1.5 }  -- coffre de fer (réserve)
local COMBINATOR_OFFSET = { -19.5,  1.5 }  -- connecteur circuit

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

-- Crée toutes les entités cachées d'un bâtiment fraîchement posé (et validé)
-- et retourne le state à ranger dans storage.foundries[unit_number].
function composite.build(entity)
  local state = {
    entity = entity,
    rails = {},
    input = nil,       -- coffre de fer (réserve) sur le parvis
    signal = nil,
    combinator = nil,  -- connecteur circuit sur le parvis
    templates = {},  -- milestone 2 : templates de blueprints
    queue = {},      -- milestone 3 : file de construction
    -- Mode d'émission circuit : "stock" ou "request" (par défaut le stock ;
    -- pour ne rien émettre, ne pas brancher de câble).
    emit_mode = "stock",
  }

  for _, x in ipairs(RAIL_XS) do
    local pos = { entity.position.x + x, entity.position.y + RAIL_Y }
    -- Défensif : si un rail existe déjà à cette position (pose par script
    -- par-dessus une voie), on le réutilise tel quel au lieu de le doubler.
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

  state.signal = place(entity, SIGNAL, SIGNAL_OFFSET, SIGNAL_DIRECTION)
  state.input = place(entity, INPUT, INPUT_OFFSET, defines.direction.north)
  state.combinator = place(entity, COMBINATOR, COMBINATOR_OFFSET,
    defines.direction.north)

  return state
end

-- Le coffre de réserve (ou nil).
function composite.reserve(state)
  if state.input and state.input.valid then return state.input end
  return nil
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

-- Détruit proprement toutes les entités enfants. Le contenu du coffre de
-- réserve est déversé au sol pour ne rien perdre.
function composite.destroy(state)
  if not state then return end

  local chest = composite.reserve(state)
  if chest then
    local inv = chest.get_inventory(defines.inventory.chest)
    if inv and not inv.is_empty() then
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
  end
  if state.input and state.input.valid then
    state.input.destroy()
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
end

return composite
