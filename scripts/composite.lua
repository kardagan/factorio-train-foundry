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

local RAIL   = "tf-rail"
local INPUT  = "tf-input"
local SIGNAL = "tf-signal"

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

-- Points de chargement : un linked-container par tuile du pourtour intérieur
-- de la PARTIE BÂTIE (x ≥ -17.5 : le parvis ouest hors collision n'en a
-- pas), sauf les tuiles de la voie. Tous partagent le même inventaire via
-- link_id = unit_number : un bras qui insère n'importe où sur le bord
-- alimente la réserve unique de la fonderie.
local INPUT_OFFSETS = {}
for i = 0, 37 do
  local x = -17.5 + i
  INPUT_OFFSETS[#INPUT_OFFSETS + 1] = { x, -10.5 }
  INPUT_OFFSETS[#INPUT_OFFSETS + 1] = { x, 10.5 }
end
for i = 0, 19 do
  local y = -9.5 + i
  INPUT_OFFSETS[#INPUT_OFFSETS + 1] = { 19.5, y }
  if y < 3.5 or y > 6.5 then
    INPUT_OFFSETS[#INPUT_OFFSETS + 1] = { -17.5, y }
  end
end

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
    inputs = {},
    signal = nil,
    templates = {},  -- milestone 2 : templates de blueprints
    queue = {},      -- milestone 3 : file de construction
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

  for _, offset in ipairs(INPUT_OFFSETS) do
    local c = place(entity, INPUT, offset, defines.direction.north)
    if c then
      c.link_id = entity.unit_number
      state.inputs[#state.inputs + 1] = c
    end
  end

  return state
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

-- Détruit proprement toutes les entités cachées. L'inventaire (partagé entre
-- tous les points de chargement) est déversé au sol pour ne rien perdre.
function composite.destroy(state)
  if not state then return end

  local first = nil
  for _, c in ipairs(state.inputs or {}) do
    if c.valid then first = c break end
  end
  if first then
    local inv = first.get_inventory(defines.inventory.chest)
    if inv and not inv.is_empty() then
      for i = 1, #inv do
        local stack = inv[i]
        if stack.valid_for_read then
          first.surface.spill_item_stack({
            position = first.position,
            stack = stack,
            enable_looted = true,
            force = first.force,
          })
        end
      end
    end
  end
  for _, c in ipairs(state.inputs or {}) do
    if c.valid then c.destroy() end
  end

  -- Champ legacy des vieilles saves (l'ancien coffre requester tf-chest).
  if state.chest and state.chest.valid then
    state.chest.destroy()
  end

  if state.signal and state.signal.valid then
    state.signal.destroy()
  end

  for _, r in ipairs(state.rails or {}) do
    if r.valid then r.destroy() end
  end
end

return composite
