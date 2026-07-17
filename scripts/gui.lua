-- Train Foundry — GUI de la fonderie.
--
-- Disposition (maquette M3) : colonne gauche = bibliothèque de templates
-- (slot d'import + liste) ; colonne droite = file d'attente (nom + icônes
-- des paramètres), travail en cours (composants manquants ou barre de
-- progression), et réserve.
--
-- Fenêtre FLOTTANTE : volontairement PAS enregistrée comme player.opened,
-- sinon ouvrir la bibliothèque de blueprints (B) la fermerait. Échap ne la
-- ferme pas, la croix oui. Les sections dynamiques (file, en cours,
-- réserve) sont rafraîchies par la boucle de production.

local blueprint = require("scripts.blueprint")

local gui = {}

local WINDOW = "tf-window"

local RICH_SPRITE = {
  item = "item", fluid = "fluid", virtual = "virtual-signal",
  ["virtual-signal"] = "virtual-signal", recipe = "recipe",
  entity = "entity", quality = "quality",
  ["space-location"] = "space-location",
}

-- Chemin de sprite VALIDÉ pour un signal {type, name} — nil si inconnu
-- (un chemin invalide dans add{} est une erreur fatale).
local function sprite_of(sig)
  if not (sig and sig.name) then return nil end
  local kind = RICH_SPRITE[sig.type or "item"] or "item"
  local path = kind .. "/" .. sig.name
  if helpers.is_valid_sprite_path(path) then
    return path
  end
  return nil
end

function gui.close(player)
  local w = player.gui.screen[WINDOW]
  if w then w.destroy() end
  local p = player.gui.screen["tf-params"]
  if p then p.destroy() end
  local c = player.gui.screen["tf-circuit-window"]
  if c then c.destroy() end
end

local function body_of(player)
  local w = player.gui.screen[WINDOW]
  if not w then return nil end
  return w["tf-body"]
end

-- Applique l'exclusivité des radios d'émission (le moteur ne le fait pas
-- pour des radiobuttons indépendants) : coche celui du mode, décoche l'autre.
function gui.set_emit_mode(player, mode)
  local w = player.gui.screen["tf-circuit-window"]
  local inner = w and w.valid and w["tf-circuit-inner"]
  if not inner then return end
  for _, name in ipairs({ "stock", "request" }) do
    local rb = inner["tf-emit-" .. name]
    if rb and rb.valid then rb.state = (name == mode) end
  end
end

-- L'unit_number de la fonderie liée à la fenêtre ouverte de ce joueur.
function gui.window_unit_number(player)
  local w = player.gui.screen[WINDOW]
  if not w then return nil end
  return w.tags.unit_number
end

-- ---------------------------------------------------------------------------
-- Sections dynamiques
-- ---------------------------------------------------------------------------

-- Tuile blueprint LARGE : un seul fond bleu "item/blueprint" encadrant les
-- icônes du plan (1 à 4) posées en rangée dessus, à taille standard.
local ICON_SZ = 32
local ICON_GAP = 4
local TILE_PAD = 10

local function bp_wide_tile(parent, sigs, args)
  -- Largeur FIXE (4 icônes) pour que les titres restent alignés d'une ligne
  -- à l'autre, quel que soit le nombre d'icônes du plan.
  local w = TILE_PAD * 2 + 4 * ICON_SZ + 3 * ICON_GAP
  local h = TILE_PAD * 2 + ICON_SZ
  local box = parent.add({ type = "flow", direction = "vertical" })
  box.style.width = w
  box.style.height = h

  -- Bouton cliquable = cadre du slot (fond gris). Le fond bleu blueprint est
  -- une IMAGE étirée sur toute la largeur, posée par-dessus, puis les icônes.
  local button = box.add({
    type = "sprite-button",
    style = "slot_button",
    tooltip = args and args.tooltip or nil,
    tags = args and args.tags or nil,
  })
  button.style.size = { w, h }

  local bg = box.add({ type = "sprite", sprite = "item/blueprint" })
  bg.ignored_by_interaction = true
  bg.style.size = { w - 8, h - 8 }
  bg.style.stretch_image_to_widget_size = true
  bg.style.top_margin = 4 - h
  bg.style.left_margin = 4

  if #sigs > 0 then
    local strip = box.add({ type = "flow", direction = "horizontal" })
    strip.ignored_by_interaction = true
    strip.style.top_margin = TILE_PAD - h
    strip.style.left_margin = TILE_PAD
    strip.style.horizontal_spacing = ICON_GAP
    for _, p in ipairs(sigs) do
      local ic = strip.add({ type = "sprite", sprite = p })
      ic.style.size = ICON_SZ
      ic.style.stretch_image_to_widget_size = true
    end
  end
  return box
end

-- Livre de plans : grille de cases façon UI vanilla. Case pleine = icône et
-- nom du blueprint (clic gauche : file, clic droit : supprimer) ; case vide
-- = cliquer avec un plan en main pour l'ajouter.
function gui.refresh_templates(player, state)
  local body = body_of(player)
  local list = body and body["tf-left"]["tf-templates-scroll"]["tf-templates"]
  if not list then
    gui.close(player)
    return
  end
  list.clear()

  -- Vue LISTE : une ligne par plan. À gauche, jusqu'à 4 slots blueprint
  -- côte à côte (chacun = fond bleu + une icône du plan à taille standard) ;
  -- à droite, le titre. Plus une ligne "ajouter" en fin.
  for i, t in ipairs(state.templates) do
    local locos, wagons = blueprint.counts(t)
    local title = (t.name ~= "") and t.name or { "tf-gui.untitled" }
    local tip = { "", title, "\n", locos, " × [item=locomotive]  ",
                  wagons, " × [item=cargo-wagon]", "\n",
                  { "tf-gui.slot-filled" } }
    local row = list.add({ type = "flow", direction = "horizontal" })
    row.style.vertical_align = "center"
    row.style.bottom_margin = 6  -- espace entre les lignes de la liste

    -- Un seul fond bleu encadrant les icônes du plan (1 à 4) en rangée.
    local sigs = {}
    if t.icons then
      for k = 1, math.min(4, #t.icons) do
        local p = t.icons[k].signal and sprite_of(t.icons[k].signal)
        if p then sigs[#sigs + 1] = p end
      end
    end
    bp_wide_tile(row, sigs, {
      tooltip = tip,
      tags = { tf_action = "template-slot", index = i },
    })

    local label = row.add({ type = "label", caption = t.name })
    label.style.left_margin = 8
    label.style.horizontally_stretchable = true
  end

  -- Ligne d'ajout : case vide pour déposer un plan.
  local add_row = list.add({ type = "flow", direction = "horizontal" })
  add_row.style.vertical_align = "center"
  local add = add_row.add({
    type = "sprite-button",
    style = "slot_button",
    sprite = "utility/add",
    tooltip = { "tf-gui.slot-empty" },
    tags = { tf_action = "empty-slot" },
  })
  add.style.size = 56
  local hint = add_row.add({ type = "label", caption = { "tf-gui.slot-empty" } })
  hint.style.left_margin = 8
  hint.style.single_line = false
  hint.style.maximal_width = 200
end

function gui.refresh_queue(player, state)
  local body = body_of(player)
  local list = body and body["tf-right"]["tf-queue-frame"]
    ["tf-queue-scroll"]["tf-queue"]
  if not list then
    gui.close(player)
    return
  end
  list.clear()
  if #state.queue == 0 then
    list.add({ type = "label", caption = { "tf-gui.queue-empty" } })
    return
  end
  for i, entry in ipairs(state.queue) do
    local row = list.add({ type = "flow", direction = "horizontal" })
    row.style.vertical_align = "center"
    local num = row.add({ type = "label", caption = i .. "." })
    num.style.minimal_width = 18
    local label = row.add({ type = "label", caption = entry.name })
    label.style.minimal_width = 100
    local icons = row.add({ type = "flow", direction = "horizontal" })
    icons.style.horizontally_stretchable = true
    if entry.params then
      for _, p in pairs(entry.params) do
        local path = sprite_of(p)
        if path then
          icons.add({ type = "sprite", sprite = path })
        end
      end
    end
    row.add({
      type = "sprite-button",
      style = "tool_button_red",
      sprite = "utility/trash",
      tooltip = { "tf-gui.cancel-queued" },
      tags = { tf_action = "cancel-queued", index = i },
    })
  end
end

function gui.refresh_work(player, state)
  local body = body_of(player)
  local flow = body and body["tf-right"]["tf-work-frame"]["tf-work"]
  if not flow then
    gui.close(player)
    return
  end
  flow.clear()
  local work = state.work
  if not work then
    flow.add({ type = "label", caption = { "tf-gui.work-idle" } })
    return
  end
  -- 1) Titre + poubelle.
  local head = flow.add({ type = "flow", direction = "horizontal" })
  head.style.vertical_align = "center"
  local title = head.add({ type = "label", caption = work.entry.name })
  title.style.font = "default-bold"
  title.style.horizontally_stretchable = true
  head.add({
    type = "sprite-button",
    style = "tool_button_red",
    sprite = "utility/trash",
    tooltip = { "tf-gui.cancel-work" },
    tags = { tf_action = "cancel-work" },
  })

  -- 2) Barre de progression pleine largeur + %.
  local prog_row = flow.add({ type = "flow", direction = "horizontal" })
  prog_row.style.vertical_align = "center"
  local progress = 0
  if work.phase == "building" then
    progress = work.progress
  elseif work.phase == "ready" then
    progress = 1
  end
  local bar = prog_row.add({ type = "progressbar", value = progress })
  bar.style.horizontally_stretchable = true
  bar.style.top_margin = 4
  bar.style.bottom_margin = 4
  local pct = prog_row.add({
    type = "label",
    caption = math.floor(progress * 100) .. "%",
  })
  pct.style.minimal_width = 36
  pct.style.left_margin = 6

  -- 3) Composants : VERT si la réserve a la quantité, ROUGE s'il en manque
  -- (le nombre affiché = le manque ; sinon la quantité requise).
  local comps = flow.add({ type = "flow", direction = "horizontal" })
  for item, n in pairs(work.need or {}) do
    local miss = work.phase == "waiting" and work.missing
      and work.missing[item] or 0
    comps.add({
      type = "sprite-button",
      style = (miss > 0) and "tf_slot_missing" or "tf_slot_ok",
      sprite = "item/" .. item,
      number = (miss > 0) and miss or n,
      ignored_by_interaction = true,
    })
  end

  -- État sous les composants : uniquement l'attente de voie (le manque de
  -- composants est déjà lisible sur les slots rouges).
  if (work.phase == "waiting" and not (work.missing and next(work.missing)))
    or work.phase == "ready" then
    flow.add({ type = "label", caption = { "tf-gui.work-ready" } })
  end
end

function gui.refresh_stock(player, state)
  local body = body_of(player)
  local sframe = body and body["tf-right"]["tf-stock-frame"]
  local grid = sframe and sframe["tf-stock-scroll"]
    and sframe["tf-stock-scroll"]["tf-stock"]
  if not grid then
    gui.close(player)
    return
  end
  grid.clear()

  local inv = state.input and state.input.valid
    and state.input.get_inventory(defines.inventory.chest)
  if not inv then return end

  -- Affiche les 20 cases RÉELLES de l'inventaire (vides comprises), 10 par
  -- ligne. Lecture seule : le remplissage se fait aux bras (inserters sur
  -- n'importe quel bord du bâtiment).
  local table_el = grid.add({ type = "table", column_count = 10,
                              style = "slot_table" })
  for i = 1, #inv do
    local stack = inv[i]
    if stack.valid_for_read then
      table_el.add({
        type = "sprite-button",
        style = "inventory_slot",
        sprite = "item/" .. stack.name,
        number = stack.count,
        ignored_by_interaction = true,
      })
    else
      table_el.add({
        type = "sprite-button",
        style = "inventory_slot",
        ignored_by_interaction = true,
      })
    end
  end
end

-- Sections rafraîchies en continu par la boucle de production.
function gui.refresh_dynamic(player, state)
  gui.refresh_queue(player, state)
  gui.refresh_work(player, state)
  gui.refresh_stock(player, state)
end

function gui.refresh(player, state)
  gui.refresh_templates(player, state)
  gui.refresh_dynamic(player, state)
end

-- ---------------------------------------------------------------------------
-- Construction de la fenêtre
-- ---------------------------------------------------------------------------

function gui.open(player, state)
  gui.close(player)

  local frame = player.gui.screen.add({
    type = "frame",
    name = WINDOW,
    direction = "vertical",
    tags = { unit_number = state.entity.unit_number },
  })

  -- Barre de titre draggable avec bouton fermer.
  local titlebar = frame.add({ type = "flow", direction = "horizontal" })
  titlebar.add({
    type = "label",
    caption = { "entity-name.train-foundry" },
    style = "frame_title",
    ignored_by_interaction = true,
  })
  local drag = titlebar.add({ type = "empty-widget", style = "draggable_space_header" })
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.drag_target = frame
  -- Bouton d'ouverture de la fenêtre déportée "Réseau de circuit".
  titlebar.add({
    type = "sprite-button",
    name = "tf-circuit-toggle",
    style = "frame_action_button",
    sprite = "utility/circuit_network_panel",
    tooltip = { "tf-gui.circuit-title" },
  })
  titlebar.add({
    type = "sprite-button",
    name = "tf-close",
    style = "frame_action_button",
    sprite = "utility/close",
  })

  local body = frame.add({
    type = "flow", name = "tf-body", direction = "horizontal",
  })

  -- Colonne gauche : import + bibliothèque de templates.
  local left = body.add({
    type = "frame",
    name = "tf-left",
    style = "inside_shallow_frame_with_padding",
    direction = "vertical",
  })
  -- Vue liste : 4 slots de 40 + titre + scrollbar.
  left.style.width = 380
  left.add({
    type = "label",
    caption = { "tf-gui.templates-title" },
    style = "caption_label",
  })
  -- Hauteur FIXE : la fenêtre ne grandit pas avec le nombre de plans.
  local tscroll = left.add({
    type = "scroll-pane", name = "tf-templates-scroll",
    horizontal_scroll_policy = "never",
  })
  tscroll.style.height = 470
  tscroll.style.horizontally_stretchable = true
  tscroll.add({ type = "flow", name = "tf-templates", direction = "vertical" })

  -- Colonne droite : file, en cours, réserve.
  local right = body.add({
    type = "flow", name = "tf-right", direction = "vertical",
  })
  right.style.width = 430

  local qframe = right.add({
    type = "frame",
    name = "tf-queue-frame",
    style = "inside_shallow_frame_with_padding",
    direction = "vertical",
  })
  qframe.add({
    type = "label",
    caption = { "tf-gui.queue-title" },
    style = "caption_label",
  })
  local qscroll = qframe.add({
    type = "scroll-pane", name = "tf-queue-scroll",
    horizontal_scroll_policy = "never",
  })
  qscroll.style.height = 190
  qscroll.style.horizontally_stretchable = true
  qscroll.add({ type = "flow", name = "tf-queue", direction = "vertical" })

  local wframe = right.add({
    type = "frame",
    name = "tf-work-frame",
    style = "inside_shallow_frame_with_padding",
    direction = "vertical",
  })
  wframe.add({
    type = "label",
    caption = { "tf-gui.work-title" },
    style = "caption_label",
  })
  local wflow = wframe.add({
    type = "flow", name = "tf-work", direction = "vertical",
  })
  wflow.style.height = 110

  local sframe = right.add({
    type = "frame",
    name = "tf-stock-frame",
    style = "inside_shallow_frame_with_padding",
    direction = "vertical",
  })
  local stock_header = sframe.add({ type = "flow", direction = "horizontal" })
  stock_header.style.vertical_align = "center"
  local stock_title = stock_header.add({
    type = "label",
    caption = { "tf-gui.stock-title" },
    style = "caption_label",
  })
  stock_title.style.horizontally_stretchable = true
  local sscroll = sframe.add({
    type = "scroll-pane", name = "tf-stock-scroll",
    horizontal_scroll_policy = "never",
  })
  sscroll.style.height = 110
  sscroll.style.horizontally_stretchable = true
  sscroll.add({ type = "flow", name = "tf-stock", direction = "vertical" })

  frame.auto_center = true
  -- Fenêtre FLOTTANTE : pas player.opened (sinon ouvrir la bibliothèque de
  -- BP avec B la fermerait). Fermeture par la croix. Remplissage de la
  -- réserve aux bras uniquement.
  gui.refresh(player, state)
end

-- ---------------------------------------------------------------------------
-- Fenêtre déportée "Réseau de circuit" : collée à droite de la principale,
-- ouverte par le bouton de sa titlebar. Choix du signal de sortie.
-- ---------------------------------------------------------------------------

local CIRCUIT_WINDOW = "tf-circuit-window"
gui.CIRCUIT_WINDOW = CIRCUIT_WINDOW

-- Recale la fenêtre circuit contre le bord droit de la principale.
function gui.reposition_circuit(player)
  local base = player.gui.screen[WINDOW]
  local side = player.gui.screen[CIRCUIT_WINDOW]
  if not (base and base.valid and side and side.valid) then return end
  local scale = player.display_scale or 1
  -- Largeur de la principale ~ 380 (gauche) + 430 (droite) + marges ≈ 840.
  local base_w = 840
  side.location = {
    x = base.location.x + math.floor(base_w * scale),
    y = base.location.y,
  }
end

function gui.circuit_is_open(player)
  local w = player.gui.screen[CIRCUIT_WINDOW]
  return w ~= nil and w.valid
end

function gui.toggle_circuit(player, state)
  local existing = player.gui.screen[CIRCUIT_WINDOW]
  if existing then
    existing.destroy()
    return
  end

  local frame = player.gui.screen.add({
    type = "frame",
    name = CIRCUIT_WINDOW,
    direction = "vertical",
    tags = { unit_number = state.entity.unit_number },
  })
  -- Titlebar (collée à la principale, non draggable indépendamment).
  local titlebar = frame.add({ type = "flow", direction = "horizontal" })
  titlebar.add({
    type = "label",
    caption = { "tf-gui.circuit-title" },
    style = "frame_title",
    ignored_by_interaction = true,
  })
  local drag = titlebar.add({ type = "empty-widget",
    style = "draggable_space_header" })
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  titlebar.add({
    type = "sprite-button",
    name = "tf-circuit-close",
    style = "frame_action_button",
    sprite = "utility/close",
  })

  local inner = frame.add({
    type = "frame",
    name = "tf-circuit-inner",
    style = "inside_shallow_frame_with_padding",
    direction = "vertical",
  })
  inner.style.width = 240
  inner.add({
    type = "label",
    caption = { "tf-gui.emit-title" },
    style = "caption_label",
  })
  local mode = state.emit_mode or "stock"
  for _, m in ipairs({ { "stock", "tf-gui.emit-stock" },
                       { "request", "tf-gui.emit-request" } }) do
    inner.add({
      type = "radiobutton",
      name = "tf-emit-" .. m[1],
      caption = { m[2] },
      state = (mode == m[1]),
      tags = { tf_emit_mode = m[1] },
    })
  end

  gui.reposition_circuit(player)
end

-- ---------------------------------------------------------------------------
-- Dialogue des paramètres d'un blueprint paramétré (à la mise en file)
-- ---------------------------------------------------------------------------

function gui.open_params(player, state, index, template)
  local old = player.gui.screen["tf-params"]
  if old then old.destroy() end
  local frame = player.gui.screen.add({
    type = "frame",
    name = "tf-params",
    direction = "vertical",
    caption = { "tf-gui.params-title" },
    tags = { unit_number = state.entity.unit_number, index = index },
  })
  local rows = frame.add({
    type = "flow", name = "tf-params-rows", direction = "vertical",
  })
  for i, p in ipairs(template.parameters) do
    if p.type == "id" then
      local row = rows.add({ type = "flow", direction = "horizontal" })
      row.style.vertical_align = "center"
      local label = row.add({
        type = "label",
        caption = (p.name and p.name ~= "" and p.name) or ("#" .. i),
      })
      label.style.horizontally_stretchable = true
      label.style.minimal_width = 120
      row.add({
        type = "choose-elem-button",
        elem_type = "signal",
        tags = { tf_param = p.id or ("parameter-" .. (i - 1)) },
      })
    end
  end
  local buttons = frame.add({ type = "flow", direction = "horizontal" })
  buttons.add({
    type = "button", name = "tf-params-go",
    caption = { "tf-gui.params-build" }, style = "confirm_button",
  })
  buttons.add({
    type = "button", name = "tf-params-cancel",
    caption = { "tf-gui.params-cancel" },
  })
  frame.auto_center = true
end

-- Récupère les valeurs choisies dans le dialogue des paramètres.
function gui.collect_params(player)
  local frame = player.gui.screen["tf-params"]
  if not frame then return nil end
  local params = {}
  for _, row in pairs(frame["tf-params-rows"].children) do
    for _, el in pairs(row.children) do
      if el.type == "choose-elem-button" and el.tags.tf_param then
        local v = el.elem_value
        if v then
          params[el.tags.tf_param] = { type = v.type or "item", name = v.name }
        end
      end
    end
  end
  return params, frame.tags.unit_number, frame.tags.index
end

gui.WINDOW = WINDOW

return gui
