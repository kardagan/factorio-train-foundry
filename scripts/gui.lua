-- Train Foundry — GUI minimale (première brique du milestone 4).
--
-- Une fenêtre par joueur, ouverte au clic sur la fonderie : un slot de dépôt
-- de blueprint (cliquer sur le slot avec le BP en main) et la liste des
-- templates enregistrés. Le reste (file d'attente, paramètres, icône livre)
-- viendra enrichir cette fenêtre plus tard.

local blueprint = require("scripts.blueprint")

local gui = {}

local WINDOW = "tf-window"

function gui.close(player)
  local w = player.gui.screen[WINDOW]
  if w then w.destroy() end
end

-- Reconstruit la section "Réserve" (contenu du stock partagé). Appelée
-- aussi périodiquement tant que la fenêtre est ouverte, pour voir les bras
-- alimenter la fonderie en direct.
function gui.refresh_stock(player, state)
  local w = player.gui.screen[WINDOW]
  if not w then return end
  -- Fenêtre d'une version précédente du mod (les GUI sont sauvegardées avec
  -- la partie) : structure inconnue, on la ferme plutôt que de planter.
  local inner = w["tf-inner"]
  local grid = inner and inner["tf-stock"]
  if not grid then
    gui.close(player)
    return
  end
  grid.clear()

  local inv = nil
  for _, c in ipairs(state.inputs or {}) do
    if c.valid then
      inv = c.get_inventory(defines.inventory.chest)
      break
    end
  end
  local totals, order = {}, {}
  if inv then
    for _, it in pairs(inv.get_contents()) do
      if not totals[it.name] then
        order[#order + 1] = it.name
        totals[it.name] = 0
      end
      totals[it.name] = totals[it.name] + it.count
    end
  end

  if #order == 0 then
    grid.add({ type = "label", caption = { "tf-gui.stock-empty" } })
    return
  end
  local table_el = grid.add({ type = "table", column_count = 10 })
  for _, name in ipairs(order) do
    table_el.add({
      type = "sprite-button",
      style = "slot_button",
      sprite = "item/" .. name,
      number = totals[name],
      ignored_by_interaction = true,
    })
  end
end

-- Reconstruit la liste des templates dans la fenêtre ouverte.
function gui.refresh(player, state)
  gui.refresh_stock(player, state)
  local w = player.gui.screen[WINDOW]
  if not w then return end
  local inner = w["tf-inner"]
  local list = inner and inner["tf-templates"]
  if not list then
    gui.close(player)
    return
  end
  list.clear()
  if #state.templates == 0 then
    list.add({ type = "label", caption = { "tf-gui.no-templates" } })
    return
  end
  for i, t in ipairs(state.templates) do
    local locos, wagons = blueprint.counts(t)
    local row = list.add({ type = "flow", direction = "horizontal" })
    row.style.vertical_align = "center"
    local label = row.add({
      type = "label",
      caption = { "tf-gui.template-row", t.name, locos, wagons },
    })
    label.style.horizontally_stretchable = true
    row.add({
      type = "sprite-button",
      style = "tool_button_green",
      sprite = "utility/check_mark",
      tooltip = { "tf-gui.spawn-template" },
      tags = { tf_action = "spawn-template", index = i },
    })
    row.add({
      type = "sprite-button",
      style = "tool_button_red",
      sprite = "utility/trash",
      tooltip = { "tf-gui.delete-template" },
      tags = { tf_action = "delete-template", index = i },
    })
  end
end

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
  titlebar.add({
    type = "sprite-button",
    name = "tf-close",
    style = "frame_action_button",
    sprite = "utility/close",
  })

  local inner = frame.add({
    type = "frame",
    name = "tf-inner",
    style = "inside_shallow_frame_with_padding",
    direction = "vertical",
  })

  local import_row = inner.add({ type = "flow", direction = "horizontal" })
  import_row.style.vertical_align = "center"
  import_row.add({
    type = "sprite-button",
    name = "tf-bp-slot",
    style = "slot_button",
    sprite = "item/blueprint",
    tooltip = { "tf-gui.slot-tooltip" },
  })
  local hint = import_row.add({ type = "label", caption = { "tf-gui.drop-hint" } })
  hint.style.single_line = false
  hint.style.maximal_width = 260

  inner.add({ type = "line" })
  inner.add({
    type = "label",
    caption = { "tf-gui.templates-title" },
    style = "caption_label",
  })
  inner.add({ type = "flow", name = "tf-templates", direction = "vertical" })

  inner.add({ type = "line" })
  local stock_header = inner.add({ type = "flow", direction = "horizontal" })
  stock_header.style.vertical_align = "center"
  local stock_title = stock_header.add({
    type = "label",
    caption = { "tf-gui.stock-title" },
    style = "caption_label",
  })
  stock_title.style.horizontally_stretchable = true
  stock_header.add({
    type = "button",
    name = "tf-open-stock",
    caption = { "tf-gui.open-stock" },
  })
  inner.add({ type = "flow", name = "tf-stock", direction = "vertical" })

  frame.auto_center = true
  -- Fenêtre FLOTTANTE : volontairement PAS enregistrée comme player.opened,
  -- sinon ouvrir la bibliothèque de blueprints (B) la fermerait — or tout
  -- l'intérêt est d'aller y chercher un BP pendant qu'elle est ouverte.
  -- Conséquence assumée : Échap ne la ferme pas, la croix oui.
  gui.refresh(player, state)
end

-- Dialogue des paramètres d'un blueprint paramétré : un sélecteur de signal
-- par paramètre, à valider avant la construction du train.
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

-- L'unit_number de la fonderie liée à la fenêtre ouverte de ce joueur.
function gui.window_unit_number(player)
  local w = player.gui.screen[WINDOW]
  if not w then return nil end
  return w.tags.unit_number
end

gui.WINDOW = WINDOW

return gui
