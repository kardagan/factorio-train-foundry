-- Train Foundry — GUI de la fonderie.
--
-- Disposition : colonne gauche = livre de plans (reflet en direct du coffre à
-- blueprints, clic = mise en file) ; colonne droite = file d'attente (nom +
-- icônes des paramètres), travail en cours (composants manquants ou barre de
-- progression), et réserve.
--
-- Fenêtre CLASSIQUE (player.opened) : Échap et clic ailleurs la ferment
-- nativement. Le conflit historique avec la bibliothèque de blueprints (B) a
-- disparu : on ne prend plus de plan EN MAIN, on les dépose dans le coffre à
-- blueprints. Les sections dynamiques (livre, file, en cours, réserve) sont
-- rafraîchies par la boucle de production.

local blueprint = require("scripts.blueprint")

local gui = {}

local WINDOW = "tf-window"
-- Fenêtre FLOTTANTE de gestion du coffre à blueprints (ouverte au clic sur le
-- coffre). Flottante = B (bibliothèque) ne la ferme pas → on peut prendre un
-- plan en main et le déposer. Fermeture par la croix.
local BP_WINDOW = "tf-bp-window"

local RICH_SPRITE = {
  item = "item", fluid = "fluid", virtual = "virtual-signal",
  ["virtual-signal"] = "virtual-signal", recipe = "recipe",
  entity = "entity", quality = "quality",
  ["space-location"] = "space-location",
  ["asteroid-chunk"] = "asteroid-chunk",
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

-- Tuile CARRÉE compacte pour la grille du coffre : un slot cliquable (fond
-- bleu blueprint) et, superposées, jusqu'à 4 icônes du plan (2×2).
-- args = { tooltip, tags } ; sigs = liste de chemins de sprites (0 à 4).
-- Les enfants d'un sprite-button IGNORENT les marges (ancrés au coin) : on
-- superpose donc la grille dans un FLOW parent, via marges négatives — même
-- technique que bp_wide_tile, qui respecte bien le padding.
local SQ = 64          -- taille du slot
local SQ_ICON = 20     -- taille d'une mini-icône
local SQ_PAD = 8       -- retrait des icônes par rapport au bord du slot
local function bp_square_tile(parent, sigs, args)
  local box = parent.add({ type = "flow", direction = "vertical" })
  box.style.width = SQ
  box.style.height = SQ

  local button = box.add({
    type = "sprite-button",
    style = "slot_button",
    sprite = "item/blueprint",
    tooltip = args and args.tooltip or nil,
    tags = args and args.tags or nil,
  })
  button.style.size = { SQ, SQ }

  if #sigs > 0 then
    -- Grille 2×2 posée PAR-DESSUS le bouton (top_margin négatif = remonte sur
    -- le bouton), avec un retrait SQ_PAD depuis le coin haut-gauche.
    local grid = box.add({ type = "table", column_count = 2 })
    grid.ignored_by_interaction = true
    grid.style.horizontal_spacing = 2
    grid.style.vertical_spacing = 2
    grid.style.top_margin = SQ_PAD - SQ
    grid.style.left_margin = SQ_PAD
    for k = 1, math.min(4, #sigs) do
      local ic = grid.add({ type = "sprite", sprite = sigs[k] })
      ic.style.size = SQ_ICON
      ic.style.stretch_image_to_widget_size = true
    end
  end
  return box
end

-- Livre de plans : reflet EN DIRECT du coffre à blueprints. Une ligne par
-- plan déposé — icône + nom (clic gauche : mise en file). Un plan non conforme
-- (autre qu'un train, trop long, pas sur voie droite) apparaît en rouge, non
-- cliquable, avec la raison en infobulle. La suppression se fait en retirant
-- le BP du coffre, pas ici.
function gui.refresh_templates(player, state)
  local body = body_of(player)
  local list = body and body["tf-left"]["tf-templates-scroll"]["tf-templates"]
  if not list then
    gui.close(player)
    return
  end
  list.clear()

  -- L'accès au coffre à plans est le petit « + » de l'en-tête (voir gui.open) ;
  -- pas de ligne dédiée ici.
  if #state.templates == 0 then
    local hint = list.add({
      type = "label",
      caption = { "tf-gui.book-empty" },
    })
    hint.style.single_line = false
    hint.style.maximal_width = 340
    return
  end

  for i, t in ipairs(state.templates) do
    local title = (t.name ~= "") and t.name or { "tf-gui.untitled" }
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

    local tip
    if t.invalid then
      tip = { "", title, "\n[color=255,80,80]",
              { "tf-msg." .. t.invalid, t.invalid_detail or "" },
              "[/color]" }
    else
      local locos, wagons = blueprint.counts(t)
      tip = { "", title, "\n", locos, " × [item=locomotive]  ",
              wagons, " × [item=cargo-wagon]", "\n",
              { "tf-gui.slot-filled-queue" } }
    end

    bp_wide_tile(row, sigs, {
      tooltip = tip,
      -- Un plan invalide n'est PAS enfilable : pas de tag d'action.
      tags = (not t.invalid)
        and { tf_action = "template-slot", index = i } or nil,
    })

    -- Colonne de droite : nom (+ ⚠ si rejeté) puis, en dessous, les compteurs
    -- loco/wagon (plan valide) ou la raison du rejet (plan invalide).
    local info = row.add({ type = "flow", direction = "vertical" })
    info.style.left_margin = 8
    info.style.horizontally_stretchable = true
    info.style.vertical_align = "center"

    local head = info.add({ type = "flow", direction = "horizontal" })
    head.style.vertical_align = "center"
    if t.invalid then
      -- Triangle d'alerte : on choisit le 1er sprite utility valide (les noms
      -- varient selon versions ; un chemin invalide dans add{} plante).
      local warn_sprite
      for _, p in ipairs({ "utility/warning_icon", "utility/danger_icon",
                           "utility/achievement_warning" }) do
        if helpers.is_valid_sprite_path(p) then warn_sprite = p break end
      end
      if warn_sprite then
        local warn = head.add({ type = "sprite", sprite = warn_sprite })
        warn.style.size = 16
        warn.style.stretch_image_to_widget_size = true
        warn.style.right_margin = 4
      end
    end
    local name = head.add({
      type = "label",
      caption = t.invalid and { "tf-gui.book-invalid" } or title,
    })
    name.style.font = "default-semibold"
    if t.invalid then name.style.font_color = { 1, 0.4, 0.4 } end

    if t.invalid then
      local why = info.add({
        type = "label",
        caption = { "tf-msg." .. t.invalid, t.invalid_detail or "" },
      })
      why.style.font_color = { 1, 0.4, 0.4 }
      why.style.single_line = false
      why.style.maximal_width = 200
    else
      local locos, wagons = blueprint.counts(t)
      local counts = info.add({ type = "flow", direction = "horizontal" })
      counts.style.vertical_align = "center"
      counts.style.top_margin = 2
      local lc = counts.add({
        type = "label",
        caption = { "", "[item=locomotive] ", locos, "    ",
                    "[item=cargo-wagon] ", wagons },
      })
      lc.style.font_color = { 0.8, 0.8, 0.8 }
    end
  end
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

  -- 3) Composants : un slot par ingrédient, VERT si la réserve couvre le
  -- besoin, ROUGE sinon. Sous chaque slot, le ratio disponible/requis (façon
  -- maquette) : « 4/4 » vert avec ✓, « 1/4 » rouge s'il en manque.
  local comps = flow.add({ type = "flow", direction = "horizontal" })
  comps.style.horizontal_spacing = 4
  for item, n in pairs(work.need or {}) do
    local miss = work.phase == "waiting" and work.missing
      and work.missing[item] or 0
    local have = math.max(0, n - miss)
    local col = comps.add({ type = "flow", direction = "vertical" })
    col.style.vertical_align = "center"
    col.style.horizontal_align = "center"
    col.add({
      type = "sprite-button",
      style = (miss > 0) and "tf_slot_missing" or "tf_slot_ok",
      sprite = "item/" .. item,
      ignored_by_interaction = true,
    })
    local ratio = col.add({
      type = "label",
      caption = have .. "/" .. n,
    })
    ratio.style.font = "default-small-semibold"
    ratio.style.font_color = (miss > 0) and { 1, 0.4, 0.4 } or { 0.5, 1, 0.5 }
    ratio.style.top_margin = 1
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

-- Sections rafraîchies en continu par la boucle de production (file, en cours,
-- réserve). Le LIVRE n'en fait PAS partie : il reflète le coffre à blueprints
-- mais on ne le reconstruit que quand son contenu change réellement (sinon le
-- survol/les infobulles clignoteraient à chaque demi-seconde).
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
  -- Bouton d'ouverture de la fenêtre déportée "Configuration" (circuit + sorties).
  titlebar.add({
    type = "sprite-button",
    name = "tf-circuit-toggle",
    style = "frame_action_button",
    sprite = "utility/circuit_network_panel",
    tooltip = { "tf-gui.config-title" },
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
  -- En-tête : titre à gauche + petit « + » collé au bord DROIT (ouvre le
  -- coffre à plans). Un empty-widget extensible entre les deux pousse le
  -- bouton contre le bord droit (technique des titlebars — plus fiable qu'un
  -- label stretchable).
  local lhead = left.add({ type = "flow", direction = "horizontal" })
  lhead.style.vertical_align = "center"
  lhead.style.horizontally_stretchable = true
  lhead.add({
    type = "label",
    caption = { "tf-gui.templates-title" },
    style = "caption_label",
  })
  local spacer = lhead.add({ type = "empty-widget" })
  spacer.style.horizontally_stretchable = true
  local addbtn = lhead.add({
    type = "sprite-button",
    name = "tf-open-bpchest",
    style = "tool_button",
    sprite = "utility/add",
    tooltip = { "tf-gui.open-bpchest" },
  })
  addbtn.style.size = 24
  lhead.style.bottom_margin = 8  -- espace entre l'en-tête et la liste des plans
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
  local qhead = qframe.add({ type = "flow", direction = "horizontal" })
  qhead.style.vertical_align = "center"
  local qtitle = qhead.add({
    type = "label",
    caption = { "tf-gui.queue-title" },
    style = "caption_label",
  })
  qtitle.style.horizontally_stretchable = true
  qhead.add({
    type = "sprite-button",
    name = "tf-queue-clear",
    style = "tool_button_red",
    sprite = "utility/trash",
    tooltip = { "tf-gui.queue-clear" },
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
  wflow.style.height = 130

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
  -- Fenêtre CLASSIQUE : player.opened → Échap et clic ailleurs la ferment
  -- nativement (on_gui_closed). Plus de conflit avec la bibliothèque de BP :
  -- on ne prend plus de plan EN MAIN, on les dépose dans le coffre à
  -- blueprints. La réserve, elle, se remplit aux bras.
  player.opened = frame
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
    caption = { "tf-gui.config-title" },
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

  -- Côtés de sortie du train : cases INDÉPENDANTES (gauche et/ou droite). Gauche
  -- ouverte par défaut ; cocher droite pose la voie + le signal est.
  inner.add({
    type = "label",
    caption = { "tf-gui.exit-title" },
    style = "caption_label",
  })
  for _, s in ipairs({ { "left", "tf-gui.exit-left", state.exit_left },
                       { "right", "tf-gui.exit-right", state.exit_right } }) do
    inner.add({
      type = "checkbox",
      name = "tf-exit-" .. s[1],
      caption = { s[2] },
      state = s[3] and true or false,
      tags = { tf_exit_side = s[1] },
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
    -- On garde la SIGNATURE du plan (pas seulement l'index) : le livre reflète
    -- le coffre et peut se réindexer entre l'ouverture du dialogue et la
    -- validation. La signature identifie le bon template quoi qu'il arrive.
    tags = {
      unit_number = state.entity.unit_number,
      index = index,
      signature = template.signature,
    },
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
  return params, frame.tags.unit_number, frame.tags.index,
    frame.tags.signature
end

-- ---------------------------------------------------------------------------
-- Fenêtre FLOTTANTE de gestion du coffre à blueprints
-- ---------------------------------------------------------------------------

-- L'unit_number de la fonderie liée à la fenêtre BP ouverte (ou nil).
function gui.bp_window_unit_number(player)
  local w = player.gui.screen[BP_WINDOW]
  if not w then return nil end
  return w.tags.unit_number
end

function gui.close_bp(player)
  local w = player.gui.screen[BP_WINDOW]
  if w then w.destroy() end
end

-- Chemins de sprites des icônes d'un blueprint (1 à 4), pour poser dessus la
-- tuile bleue. Vide si le plan n'a pas d'icône exploitable.
local function bp_stack_sigs(stack)
  local sigs = {}
  -- 2.0 : la propriété s'appelle preview_icons (ex-blueprint_icons en 1.1).
  local ok, icons = pcall(function() return stack.preview_icons end)
  if ok and icons then
    for k = 1, math.min(4, #icons) do
      local p = icons[k].signal and sprite_of(icons[k].signal)
      if p then sigs[#sigs + 1] = p end
    end
  end
  return sigs
end

-- (Re)remplit la grille de slots depuis l'inventaire du coffre. Slot occupé =
-- tuile bleue + icônes du plan (clic = le reprendre en main) ; slot vide =
-- case cliquable (clic avec un plan en main = le déposer).
function gui.refresh_bp(player, state)
  local w = player.gui.screen[BP_WINDOW]
  local grid = w and w.valid and w["tf-bp-inner"]
    and w["tf-bp-inner"]["tf-bp-scroll"]
    and w["tf-bp-inner"]["tf-bp-scroll"]["tf-bp-grid"]
  if not grid then return end
  grid.clear()

  local chest = (state.bpchest and state.bpchest.valid) and state.bpchest
  local inv = chest and chest.get_inventory(defines.inventory.chest)
  if not inv then return end

  for i = 1, #inv do
    local stack = inv[i]
    if stack.valid_for_read then
      local tip = (stack.label and stack.label ~= "" and stack.label)
        or { "tf-gui.bp-slot-filled" }
      bp_square_tile(grid, bp_stack_sigs(stack), {
        tooltip = tip,
        tags = { tf_action = "bp-slot", index = i },
      })
    else
      local empty = grid.add({
        type = "sprite-button",
        style = "slot_button",
        tooltip = { "tf-gui.bp-slot-empty" },
        tags = { tf_action = "bp-slot", index = i },
      })
      empty.style.size = { SQ, SQ }
    end
  end
end

function gui.open_bp(player, state)
  gui.close_bp(player)

  local frame = player.gui.screen.add({
    type = "frame",
    name = BP_WINDOW,
    direction = "vertical",
    tags = { unit_number = state.entity.unit_number },
  })

  local titlebar = frame.add({ type = "flow", direction = "horizontal" })
  titlebar.add({
    type = "label",
    caption = { "tf-gui.bp-title" },
    style = "frame_title",
    ignored_by_interaction = true,
  })
  local drag = titlebar.add({ type = "empty-widget",
    style = "draggable_space_header" })
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.drag_target = frame
  titlebar.add({
    type = "sprite-button",
    name = "tf-bp-close",
    style = "frame_action_button",
    sprite = "utility/close",
  })

  local inner = frame.add({
    type = "frame",
    name = "tf-bp-inner",
    style = "inside_shallow_frame_with_padding",
    direction = "vertical",
  })
  inner.add({
    type = "label",
    caption = { "tf-gui.bp-hint" },
    style = "caption_label",
  })
  local scroll = inner.add({
    type = "scroll-pane", name = "tf-bp-scroll",
    horizontal_scroll_policy = "never",
  })
  scroll.style.height = 300
  scroll.style.width = 440
  local grid = scroll.add({
    type = "table", name = "tf-bp-grid", column_count = 6,
  })
  grid.style.horizontal_spacing = 4
  grid.style.vertical_spacing = 4

  frame.auto_center = true
  gui.refresh_bp(player, state)
end

gui.WINDOW = WINDOW
gui.BP_WINDOW = BP_WINDOW

return gui
