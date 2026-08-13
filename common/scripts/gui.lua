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

local names = require("names")
local builder = require("scripts.builder")

local gui = {}

-- Les fenêtres TOP-LEVEL vivent dans player.gui.screen, PARTAGÉ entre tous les
-- mods : deux mods qui nommeraient leur fenêtre "tf-window" entreraient en
-- collision dans le même écran (symptôme : la fenêtre s'ouvre puis se referme
-- aussitôt, chaque mod détruisant/écrasant celle de l'autre). On PRÉFIXE donc
-- chaque nom de fenêtre top-level par la variante (names.mod, unique). Les
-- éléments ENFANTS (tf-body, tf-left...) vivent dans le sous-arbre du frame,
-- propre à chaque mod → pas besoin de les préfixer.
local P = names.mod .. "-"           -- ex "train-foundry-" / "train-foundry-stc-"
local WINDOW = P .. "window"
-- Hauteur figée du corps de la fenêtre principale : la colonne droite (file +
-- en-cours + réserve) la remplit exactement, la colonne gauche (liste des plans)
-- s'étire pour la même hauteur (scroll interne au-delà).
local WINDOW_BODY_HEIGHT = 785
-- Largeurs des deux colonnes (utilisées à la fois par gui.open pour dimensionner
-- et par reposition_circuit pour coller la fenêtre Config à droite — une seule
-- source de vérité, sinon la fenêtre déportée se replace mal après un resize).
local LEFT_WIDTH  = 420
local RIGHT_WIDTH = 448
-- Nombre de slots carburant par rangée dans le panneau « en cours ». Un slot fait
-- 40 px + 4 px d'espacement ; on retire ~32 px de marges du cadre à RIGHT_WIDTH.
local FUEL_COLS = math.floor((RIGHT_WIDTH - 32) / 44)
-- Fenêtre FLOTTANTE de gestion du coffre à blueprints.
local BP_WINDOW = P .. "bp-window"
-- Fenêtres déportées (circuit) et dialogue paramètres : top-level → préfixées.
local CIRCUIT_WINDOW = P .. "circuit-window"
-- Fenêtre autonome des carburants acceptés (grille carburants × qualités).
local FUEL_WINDOW = P .. "fuel-window"
-- Largeur du tableau des carburants : colonne des noms + une colonne par qualité.
-- Calculée sur le nombre RÉEL de qualités (un mod peut en ajouter), sinon le tableau
-- déborderait de son conteneur.
-- La colonne des noms garde une largeur MINIMALE mais s'étire : sans le mod Quality il
-- n'y a qu'une colonne de cases, et une largeur figée à 190 px laissait la fenêtre trop
-- étroite pour l'afficher.
local FUEL_NAME_COL = 190
-- 58 et non 52 : la colonne de la qualité NORMALE porte un bouton TEXTE (« Normal »)
-- là où les autres ont une pastille de 24 px, et il débordait de sa cellule. Le bouton
-- est en plus borné à la largeur de la colonne (voir refresh_fuel_pref).
local FUEL_QUAL_COL = 58
-- Largeur plancher de la fenêtre : en dessous, la phrase d'explication se replie sur
-- trop de lignes et comprime le tableau.
local FUEL_MIN_BODY = 300
-- Padding gauche+droite d'une rangée (styles tf_row_*, 6+6) + gouttière de la barre de
-- scroll verticale : sans cette marge la dernière colonne de qualité était coupée.
local FUEL_ROW_PAD = 12 + 14
-- Supplément de padding DROIT du style de rangée (tf_row_*, 16 à droite contre 6 à
-- gauche) : à compter dans la largeur, sinon la dernière colonne est rognée. C'est lui
-- qui fait respirer la dernière colonne, une right_margin sur la cellule restant sans
-- effet.
local FUEL_TAIL_PAD = 10
local function fuel_table_width(n_qualities)
  return math.max(FUEL_MIN_BODY,
                  FUEL_NAME_COL + n_qualities * FUEL_QUAL_COL
                  + FUEL_ROW_PAD + FUEL_TAIL_PAD)
end
local PARAMS_WINDOW = P .. "params"

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
  local p = player.gui.screen[PARAMS_WINDOW]
  if p then p.destroy() end
  local c = player.gui.screen[CIRCUIT_WINDOW]
  if c then c.destroy() end
  local f = player.gui.screen[FUEL_WINDOW]
  if f then f.destroy() end
end

local function body_of(player)
  local w = player.gui.screen[WINDOW]
  if not w then return nil end
  return w["tf-body"]
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

-- Badge de qualité posé sur le coin bas-gauche d'une icône de tuile. Le chemin
-- est VALIDÉ (un sprite invalide ne plante qu'à l'AFFICHAGE, pas au chargement) et
-- mis en cache ; nil pour la qualité normale, qui ne s'affiche pas.
local QUALITY_BADGE = 13
local quality_sprite_cache = {}

-- Sprite d'une qualité, ou nil s'il n'existe pas. La NORMALE en a un dès que le mod
-- Quality est chargé (base n'en fournit pas) : on ne l'exclut donc pas ici, ce sont les
-- appelants qui décident. Chemin VALIDÉ (un sprite invalide ne plante qu'à l'AFFICHAGE,
-- pas au chargement) et mis en cache.
local function quality_icon(quality)
  if not quality then return nil end
  local hit = quality_sprite_cache[quality]
  if hit ~= nil then return hit or nil end
  local path = "quality/" .. quality
  local ok = helpers.is_valid_sprite_path(path) and path or false
  quality_sprite_cache[quality] = ok
  return ok or nil
end

-- Badge posé sur le coin bas-gauche d'une icône de tuile : nil pour la NORMALE, dont
-- l'absence de badge est voulue (une tuile de qualité normale reste identique à ce
-- qu'elle était avant le support de la qualité).
local function quality_sprite(quality)
  if quality == "normal" then return nil end
  return quality_icon(quality)
end

-- Un style de mod n'existe qu'après un passage du DATA STAGE : après une mise à
-- jour, une partie simplement RECHARGÉE (sans relancer le jeu) tourne encore avec
-- les anciens styles, et add() LÈVE sur un style inconnu ("Unknown style ..."),
-- donc un crash non récupérable. On sonde une fois par style et on retombe sur un
-- style de base. Le résultat n'est pas mis en cache : il change au relancement.
-- `el_type` doit être le type d'élément réellement visé : un style ne s'applique
-- qu'au type auquel il correspond (un table_style sur un frame échouerait aussi).
local function style_or(parent, el_type, wanted, fallback)
  local ok, probe = pcall(function()
    return parent.add({ type = el_type, style = wanted })
  end)
  if ok and probe and probe.valid then
    probe.destroy()
    return wanted
  end
  return fallback
end

local TILE_ICONS = 5   -- largeur FIXE en icônes (loco + wagon + 2 chiffres + storage)
local function bp_wide_tile(parent, sigs, args)
  -- Largeur FIXE (TILE_ICONS icônes) pour que les titres restent alignés d'une
  -- ligne à l'autre, quel que soit le nombre d'icônes.
  local w = TILE_PAD * 2 + TILE_ICONS * ICON_SZ + (TILE_ICONS - 1) * ICON_GAP
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

  -- Fond bleu "blueprint" — en mode plain (ex. modèles STC : ce ne sont pas des
  -- plans), on remplace l'image bleue par un widget vide de MÊME géométrie, pour
  -- que la rangée d'icônes garde le même décalage : seul le visuel bleu disparaît,
  -- pas la mise en page.
  local bg
  if args and args.plain then
    bg = box.add({ type = "empty-widget" })
  else
    bg = box.add({ type = "sprite", sprite = "item/blueprint" })
    bg.style.stretch_image_to_widget_size = true
  end
  bg.ignored_by_interaction = true
  bg.style.size = { w - 8, h - 8 }
  bg.style.top_margin = 4 - h
  bg.style.left_margin = 4

  if #sigs > 0 then
    local strip = box.add({ type = "flow", direction = "horizontal" })
    strip.ignored_by_interaction = true
    strip.style.top_margin = TILE_PAD - h
    strip.style.left_margin = TILE_PAD
    strip.style.horizontal_spacing = ICON_GAP
    for _, p in ipairs(sigs) do
      -- Une entrée est soit un chemin de sprite, soit {sprite=, quality=} : le
      -- badge de qualité est un SECOND sprite posé sur le coin du premier (un
      -- élément `sprite` n'a pas de propriété `quality`, contrairement aux boutons).
      local path = (type(p) == "table") and p.sprite or p
      local cell = strip.add({ type = "flow", direction = "vertical" })
      cell.style.width = ICON_SZ
      cell.style.height = ICON_SZ
      local ic = cell.add({ type = "sprite", sprite = path })
      ic.style.size = ICON_SZ
      ic.style.stretch_image_to_widget_size = true
      local qpath = (type(p) == "table") and quality_sprite(p.quality) or nil
      if qpath then
        local badge = cell.add({ type = "sprite", sprite = qpath })
        badge.style.size = QUALITY_BADGE
        badge.style.stretch_image_to_widget_size = true
        badge.style.top_margin = -QUALITY_BADGE   -- remonte sur l'icône
      end
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
      local p = sigs[k]
      local path = (type(p) == "table") and p.sprite or p
      local cell = grid.add({ type = "flow", direction = "vertical" })
      cell.style.width = SQ_ICON
      cell.style.height = SQ_ICON
      local ic = cell.add({ type = "sprite", sprite = path })
      ic.style.size = SQ_ICON
      ic.style.stretch_image_to_widget_size = true
      local qpath = (type(p) == "table") and quality_sprite(p.quality) or nil
      if qpath then
        local badge = cell.add({ type = "sprite", sprite = qpath })
        badge.style.size = QUALITY_BADGE
        badge.style.stretch_image_to_widget_size = true
        badge.style.top_margin = -QUALITY_BADGE
      end
    end
  end
  return box
end

-- Compteurs du matériel roulant d'un template : « [icône]×N » par couple
-- (item, qualité). Les icônes sont celles du plan (pas des génériques) et le
-- rich-text porte la qualité, qui s'affiche nativement en chevron — deux trains
-- de même forme et de qualités ≠ sont autrement identiques à l'écran.
-- Tag rich-text d'un type de matériel roulant, qualité comprise. Passe par
-- l'ITEM de placement (le tag [item=…] accepte la qualité et c'est la forme que
-- pose le sélecteur rich-text) ; repli sur [entity=…] pour un wagon moddé qui ne
-- déclare pas d'item.
local function wagon_tag(entity_name, quality)
  local proto = prototypes.entity[entity_name]
  local place = proto and proto.items_to_place_this
  local item = place and place[1] and (place[1].item or place[1].name)
  if item then return builder.qtag(item, quality) end
  return "[entity=" .. entity_name .. "]"
end

-- Qualité COMMUNE à tout le matériel roulant d'un template, ou nil si le train
-- est normal ou mélange les qualités. Sert au badge des tuiles, qui ne peut porter
-- qu'une seule qualité.
local function uniform_quality(template)
  local groups = builder.template_stock_groups(template)
  local q = nil
  for _, g in ipairs(groups) do
    if q == nil then q = g.quality
    elseif q ~= g.quality then return nil end
  end
  if q == "normal" then return nil end
  return q
end

-- Une chaîne localisée n'accepte que 20 paramètres : on concatène en Lua (les
-- tags rich-text n'ont pas besoin d'être des paramètres séparés) pour qu'un train
-- long et hétérogène ne fasse pas déborder la limite.
local function stock_caption(template)
  local parts = {}
  for _, g in ipairs(builder.template_stock_groups(template)) do
    parts[#parts + 1] = builder.qtag(g.item, g.quality) .. " " .. g.count
  end
  return table.concat(parts, "  ")
end

-- Chemin de sprite d'un type de matériel roulant (entité), avec repli si le
-- prototype n'a pas de sprite direct (rare). nil si rien de valide.
local function rolling_stock_sprite(entity_name)
  local path = "entity/" .. entity_name
  if helpers.is_valid_sprite_path(path) then return path end
  -- repli : l'item de placement, s'il existe (en 2.0 le champ est .item, pas .name).
  local proto = prototypes.entity[entity_name]
  local place = proto and proto.items_to_place_this
  local item = place and place[1] and place[1].item
  if item then
    local ip = "item/" .. item
    if helpers.is_valid_sprite_path(ip) then return ip end
  end
  return nil
end

-- Locomotive déduite d'un type de wagon (même heuristique que stc_template :
-- cargo/fluid-wagon → locomotive, repli 1ʳᵉ locomotive du jeu). Sert à afficher
-- l'icône loco sur la tuile du modèle.
local function loco_of(wagon_type)
  local cand = (wagon_type or ""):gsub("cargo%-wagon", "locomotive")
                                 :gsub("fluid%-wagon", "locomotive")
  local proto = prototypes.entity[cand]
  if proto and proto.type == "locomotive" then return cand end
  for name, p in pairs(prototypes.entity) do
    if p.type == "locomotive" then return name end
  end
  return cand
end

-- Nombre N rendu en signaux-chiffres [virtual-signal=signal-D] (un par chiffre).
-- Ex. 8 → { signal-8 } ; 12 → { signal-1, signal-2 }. Chemins validés.
local function digit_sprites(n)
  local out = {}
  for d in tostring(math.max(0, n)):gmatch("%d") do
    local p = "virtual-signal/signal-" .. d
    if helpers.is_valid_sprite_path(p) then out[#out + 1] = p end
  end
  return out
end

-- Mode STC : la source des trains est la liste des « formes » (modèles) que
-- Smart Train Combinator expose pour la surface, via remote.call. Une tuile par
-- forme distincte ; le clic met en file en demandant d'abord la ressource. Les
-- modèles sont mis en cache dans state.stc_models pour être relus au clic.
function gui.refresh_stc_models(player, state, list)
  state.stc_models = nil
  if not remote.interfaces["smart-train-combinator"] then
    local hint = list.add({ type = "label", caption = { "tf-gui.stc-absent" } })
    hint.style.single_line = false
    hint.style.maximal_width = 340
    return
  end

  local models = remote.call("smart-train-combinator", "get_models",
    state.entity.surface.index) or {}
  state.stc_models = models

  if #models == 0 then
    local hint = list.add({ type = "label", caption = { "tf-gui.stc-empty" } })
    hint.style.single_line = false
    hint.style.maximal_width = 340
    return
  end

  for i, m in ipairs(models) do
    -- Garde défensive : un modèle sans type de wagon n'est pas affichable.
    local nw = m.wagons or 1
    if m.wagon_type then
    local row = list.add({ type = "flow", direction = "horizontal" })
    row.style.vertical_align = "center"
    row.style.bottom_margin = 6

    -- Icônes de la tuile : loco + 1 wagon + le nombre N en signaux-chiffres
    -- (signal-0..9, un par chiffre) + le marqueur storage. Une seule icône wagon
    -- (le compte est porté par les chiffres), donc lisible quel que soit N.
    -- Loco et wagon portent le badge de la qualité du modèle ; les chiffres et le
    -- marqueur storage sont des signaux, donc sans qualité.
    local sigs = {}
    local lsprite = rolling_stock_sprite(loco_of(m.wagon_type))
    if lsprite then
      sigs[#sigs + 1] = { sprite = lsprite, quality = m.wagon_quality }
    end
    local wsprite = rolling_stock_sprite(m.wagon_type)
    if wsprite then
      sigs[#sigs + 1] = { sprite = wsprite, quality = m.wagon_quality }
    end
    for _, d in ipairs(digit_sprites(nw)) do sigs[#sigs + 1] = d end
    if m.storage and helpers.is_valid_sprite_path("virtual-signal/stc2-storage") then
      sigs[#sigs + 1] = "virtual-signal/stc2-storage"
    end

    local kind_lbl = (m.kind == "fluid") and { "tf-gui.stc-fluid" } or { "tf-gui.stc-solid" }
    local storage_suffix = m.storage and { "tf-gui.stc-storage-suffix" } or ""
    local tip = { "tf-gui.stc-model-tip", kind_lbl, nw, storage_suffix }

    bp_wide_tile(row, sigs, {
      tooltip = tip,
      plain = true,  -- pas de fond bleu blueprint : ce ne sont pas des BP
      tags = { tf_action = "stc-model", index = i },
    })

    local info = row.add({ type = "flow", direction = "vertical" })
    info.style.left_margin = 8
    info.style.horizontally_stretchable = true
    info.style.vertical_align = "center"
    local name = info.add({
      type = "label",
      caption = { "tf-gui.stc-model-name", kind_lbl, nw, storage_suffix },
    })
    name.style.font = "default-semibold"
    -- Même ligne de compteurs qu'en mode BP (loco COMPRISE, chacune avec sa
    -- qualité) : c'est le matériel réellement demandé à la réserve. On la dérive
    -- du stock synthétique du modèle, pour ne pas réinventer la composition ici.
    local m_stock = { { name = loco_of(m.wagon_type), quality = m.wagon_quality } }
    for _ = 1, nw do
      m_stock[#m_stock + 1] = { name = m.wagon_type, quality = m.wagon_quality }
    end
    local sub = info.add({
      type = "label",
      caption = stock_caption({ stock = m_stock }),
    })
    sub.style.font_color = { 0.8, 0.8, 0.8 }
    end  -- if m.wagon_type
  end
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

  -- Mode STC : la source n'est plus le coffre de plans mais les modèles lus chez
  -- Smart Train Combinator. Rendu et clic distincts (voir refresh_stc_models).
  -- La variante est mono-source : names.source tranche une fois pour toutes.
  if names.source == "stc" then
    gui.refresh_stc_models(player, state, list)
    return
  end

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

    -- Un seul fond bleu encadrant les icônes du plan (1 à 4) en rangée. Les icônes
    -- du plan ne portent pas de qualité : on badge avec celle du MATÉRIEL ROULANT,
    -- la seule qui compte ici, et seulement si le train est homogène (un plan
    -- mélangeant les qualités n'a pas de badge unique honnête — le détail est sur
    -- la ligne de compteurs).
    local sigs = {}
    local tq = uniform_quality(t)
    if t.icons then
      for k = 1, math.min(4, #t.icons) do
        local p = t.icons[k].signal and sprite_of(t.icons[k].signal)
        if p then sigs[#sigs + 1] = { sprite = p, quality = tq } end
      end
    end

    local tip
    if t.invalid then
      tip = { "", title, "\n[color=255,80,80]",
              { "tf-msg." .. t.invalid, t.invalid_detail or "" },
              "[/color]" }
    else
      tip = { "", title, "\n", stock_caption(t), "\n",
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
      local counts = info.add({ type = "flow", direction = "horizontal" })
      counts.style.vertical_align = "center"
      counts.style.top_margin = 2
      local lc = counts.add({
        type = "label",
        caption = stock_caption(t),
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
    -- Aucune construction en cours. Si un train est coincé sur la voie interne
    -- (ne part pas : sortie bloquée, no-path), proposer un bouton pour le nettoyer
    -- (le détruire + rembourser). Sinon simple label au repos.
    if not builder.track_free(state) then
      local row = flow.add({ type = "flow", direction = "horizontal" })
      row.style.vertical_align = "center"
      local lbl = row.add({ type = "label", caption = { "tf-gui.track-stuck" } })
      lbl.style.horizontally_stretchable = true
      row.add({
        type = "sprite-button",
        style = "tool_button_red",
        sprite = "utility/trash",
        tooltip = { "tf-gui.clear-track" },
        tags = { tf_action = "clear-track" },
      })
    else
      flow.add({ type = "label", caption = { "tf-gui.work-idle" } })
    end
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
  -- need.items = composants (map item->count). Compat : un ancien need plat reste
  -- itérable tel quel.
  local need_items = (work.need and work.need.items) or work.need or {}
  for key, n in pairs(need_items) do
    -- Les clés sont composites (item, qualité) ; un need d'une save antérieure
    -- porte des noms nus, que qsplit rend en qualité normale.
    local item, quality = builder.qsplit(key)
    local miss = work.phase == "waiting" and work.missing
      and work.missing[key] or 0
    local have = math.max(0, n - miss)
    local col = comps.add({ type = "flow", direction = "vertical" })
    col.style.vertical_align = "center"
    col.style.horizontal_align = "center"
    local btn = col.add({
      type = "sprite-button",
      style = (miss > 0) and "tf_slot_missing" or "tf_slot_ok",
      sprite = "item/" .. item,
      quality = quality,
      tooltip = prototypes.item[item] and prototypes.item[item].localised_name or item,
      tags = { tf_ipedia = item },  -- clic → Factoriopedia
    })
    btn.elem_tooltip = { type = "item-with-quality", name = item, quality = quality }
    local ratio = col.add({
      type = "label",
      caption = have .. "/" .. n,
    })
    ratio.style.font = "default-small-semibold"
    ratio.style.font_color = (miss > 0) and { 1, 0.4, 0.4 } or { 0.5, 1, 0.5 }
    ratio.style.top_margin = 1
  end

  -- Ligne carburant : un slot par carburant candidat (débloqué compatible), avec
  -- ratio dispo/plein. Vert si CE carburant satisfait le plein à lui seul, rouge
  -- sinon. Affichée dès qu'il y a un besoin carburant (need.fuel) — un seul
  -- carburant plein suffit à lancer la prod (les autres restent rouges, normal).
  local fuel_cands = (work.phase == "waiting")
    and builder.fuel_candidates(state, work.need) or {}
  if #fuel_cands > 0 then
    local flabel = flow.add({ type = "label", caption = { "tf-gui.fuel-title" } })
    flabel.style.font = "default-small-semibold"
    flabel.style.top_margin = 4
    -- Une TABLE dans un SCROLL, pas un flow : depuis que le joueur peut accepter
    -- plusieurs qualités par carburant, les candidats se comptent en dizaines et une
    -- rangée unique débordait de la colonne (slots hors cadre). Le scroll s'étire sur
    -- toute la hauteur libre du panneau et prend le relais au-delà.
    local fscroll = flow.add({
      type = "scroll-pane",
      horizontal_scroll_policy = "never",
      vertical_scroll_policy = "auto",
    })
    fscroll.style.minimal_height = 62
    fscroll.style.vertically_stretchable = true
    fscroll.style.horizontally_stretchable = true
    local frow = fscroll.add({ type = "table", column_count = FUEL_COLS })
    frow.style.horizontal_spacing = 4
    frow.style.vertical_spacing = 2
    for _, f in ipairs(fuel_cands) do
      local ok = f.have >= f.need
      local col = frow.add({ type = "flow", direction = "vertical" })
      col.style.vertical_align = "center"
      col.style.horizontal_align = "center"
      local fbtn = col.add({
        type = "sprite-button",
        style = ok and "tf_slot_ok" or "tf_slot_missing",
        sprite = "item/" .. f.name,
        quality = f.quality,
        tooltip = prototypes.item[f.name] and prototypes.item[f.name].localised_name or f.name,
        tags = { tf_ipedia = f.name },  -- clic → Factoriopedia
      })
      fbtn.elem_tooltip = { type = "item-with-quality", name = f.name,
                            quality = f.quality }
      local ratio = col.add({
        type = "label",
        caption = math.min(f.have, f.need) .. "/" .. f.need,
      })
      ratio.style.font = "default-small-semibold"
      ratio.style.font_color = ok and { 0.5, 1, 0.5 } or { 1, 0.4, 0.4 }
      ratio.style.top_margin = 1
    end
  elseif work.phase == "waiting" and work.blocked == "fuel" then
    -- Bloqué sur le carburant mais AUCUN candidat à afficher : le joueur a tout
    -- décoché dans la liste des carburants acceptés. Sans ce message, le train
    -- resterait en attente sans rien à l'écran pour l'expliquer.
    local warn = flow.add({ type = "label", caption = { "tf-gui.fuel-none-allowed" } })
    warn.style.font = "default-small-semibold"
    warn.style.font_color = { 1, 0.4, 0.4 }
    warn.style.top_margin = 4
    warn.style.single_line = false
    warn.style.maximal_width = RIGHT_WIDTH - 24
  end

  -- État sous les composants : attente de voie (les manques composants/carburant
  -- sont déjà lisibles sur les slots).
  if (work.phase == "waiting" and not work.blocked)
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

  -- Affiche les cases RÉELLES de l'inventaire (vides comprises), 10 par ligne,
  -- scroll au-delà. Lecture seule : le remplissage se fait aux bras (inserters sur
  -- n'importe quel bord du bâtiment).
  local table_el = grid.add({ type = "table", column_count = 10,
                              style = "slot_table" })
  -- Réserve la gouttière de la barre de scroll verticale : sinon la dernière
  -- colonne de slots passe SOUS la scrollbar (100 slots → scroll actif).
  table_el.style.right_margin = 12
  for i = 1, #inv do
    local stack = inv[i]
    if stack.valid_for_read then
      local q = builder.quality_of(stack)
      local slot = table_el.add({
        type = "sprite-button",
        style = "inventory_slot",
        sprite = "item/" .. stack.name,
        quality = q,
        number = stack.count,
        ignored_by_interaction = true,
      })
      slot.elem_tooltip = { type = "item-with-quality", name = stack.name, quality = q }
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
    caption = { "entity-name." .. names.building },
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
  left.style.width = LEFT_WIDTH
  -- En-tête : titre à gauche + petit « + » collé au bord DROIT (ouvre le
  -- coffre à plans). Un empty-widget extensible entre les deux pousse le
  -- bouton contre le bord droit (technique des titlebars — plus fiable qu'un
  -- label stretchable).
  local lhead = left.add({ type = "flow", direction = "horizontal" })
  lhead.style.vertical_align = "center"
  lhead.style.horizontally_stretchable = true
  lhead.add({
    type = "label",
    -- Titre de la colonne gauche : « Blueprints » (variante BP) ou « Modèles de
    -- train » (variante STC — pas de blueprint ici).
    caption = { names.source == "stc" and "tf-gui.stc-list-title" or "tf-gui.templates-title" },
    style = "caption_label",
  })
  local spacer = lhead.add({ type = "empty-widget" })
  spacer.style.horizontally_stretchable = true
  -- Le « + » n'ouvre le coffre à plans que dans la variante qui en a un (BP).
  if names.has_bpchest then
    local addbtn = lhead.add({
      type = "sprite-button",
      name = "tf-open-bpchest",
      style = "tool_button",
      sprite = "utility/add",
      tooltip = { "tf-gui.open-bpchest" },
    })
    addbtn.style.size = 24
  end
  lhead.style.bottom_margin = 8  -- espace entre l'en-tête et la liste des plans
  -- Hauteur FIXE : la fenêtre ne grandit pas avec le nombre de plans.
  local tscroll = left.add({
    type = "scroll-pane", name = "tf-templates-scroll",
    horizontal_scroll_policy = "never",
  })
  -- Hauteur FIXE de la fenêtre : la colonne gauche (liste des plans) s'étire pour
  -- remplir toute la hauteur de la colonne droite (WINDOW_BODY_HEIGHT), quel que
  -- soit le nombre de plans (scroll interne au-delà).
  tscroll.style.height = WINDOW_BODY_HEIGHT
  tscroll.style.horizontally_stretchable = true
  tscroll.add({ type = "flow", name = "tf-templates", direction = "vertical" })

  -- Colonne droite : file, en cours, réserve. Hauteur figée = référence pour la
  -- colonne gauche.
  local right = body.add({
    type = "flow", name = "tf-right", direction = "vertical",
  })
  right.style.width = RIGHT_WIDTH  -- + gouttière de scroll de la réserve
  right.style.height = WINDOW_BODY_HEIGHT

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
  -- « En cours » ABSORBE la hauteur restante de la colonne (file et réserve ont des
  -- hauteurs fixes) : le reliquat va à la zone carburant, dont le nombre de slots
  -- explose dès que plusieurs qualités sont acceptées. Minimum garanti pour la barre
  -- + la rangée composants + une rangée de carburant.
  wframe.style.vertically_stretchable = true
  local wflow = wframe.add({
    type = "flow", name = "tf-work", direction = "vertical",
  })
  wflow.style.minimal_height = 235
  wflow.style.vertically_stretchable = true

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
  sscroll.style.height = 200
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

-- CIRCUIT_WINDOW est défini en tête (préfixé par variante) ; on l'expose pour control.
gui.CIRCUIT_WINDOW = CIRCUIT_WINDOW

-- Recale la fenêtre circuit contre le bord droit de la principale.
function gui.reposition_circuit(player)
  local base = player.gui.screen[WINDOW]
  local side = player.gui.screen[CIRCUIT_WINDOW]
  if not (base and base.valid and side and side.valid) then return end
  local scale = player.display_scale or 1
  -- Largeur de la principale = colonne gauche + colonne droite + marges du frame
  -- (padding gauche/droite + espacement des deux colonnes ≈ 24 px). Dérivée des
  -- constantes de colonnes pour rester juste si on redimensionne.
  local base_w = LEFT_WIDTH + RIGHT_WIDTH + 24
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
  -- 280 et non 240 : la ligne de titre d'un volet circuit porte le libellé PLUS trois
  -- cases (activation + R + V), et le texte était tronqué à 240.
  local CONFIG_WIDTH = 280
  inner.style.width = CONFIG_WIDTH

  -- Le panneau est découpé en BLOCS encadrés, à la manière des panneaux vanilla 2.1
  -- (« Input » / « Output ») : un cadre par sujet, titre en tête. En liste plate les
  -- réglages se mélangeaient et on ne savait plus à quoi se rattachait chaque case.
  -- bordered_frame ne dessine que par son champ `border` (graphical_set vide) : c'est
  -- le style qui n'avait RIEN rendu dans la fenêtre des carburants. Si le cadre ne
  -- ressort pas ici non plus, remplacer par "inside_shallow_frame_with_padding", qui
  -- a un fond plein.
  -- `block` renvoie DEUX conteneurs : la ligne de titre (où l'on peut poser des
  -- widgets à droite du libellé, comme le « Input [x] R [x] G » vanilla) et le corps.
  -- Le bandeau de titre est un frame TEINTÉ (tf_block_head) et non un simple flow :
  -- bordered_frame ne peint pas le fond de son titre, la bande noire attendue
  -- n'apparaissait donc pas. Repli sur un flow nu si le style manque (partie rechargée
  -- sans relancer le jeu).
  local HEADST = style_or(inner, "frame", "tf_block_head", nil)
  local function block(title)
    local f = inner.add({ type = "frame", style = "bordered_frame",
                          direction = "vertical" })
    f.style.horizontally_stretchable = true
    f.style.bottom_margin = 4
    f.style.padding = 0
    -- Le bandeau teinté est un FRAME, mais horizontal_spacing/vertical_align ne
    -- s'appliquent qu'à une table ou un flow (« Expected Table or Flow ... but was
    -- Frame ») : on met donc un flow À L'INTÉRIEUR du frame et on l'aligne, lui.
    local head
    if HEADST then
      local band = f.add({ type = "frame", style = HEADST, direction = "horizontal" })
      -- L'ÉTIREMENT suffit à faire traverser la bande : une largeur calculée
      -- (CONFIG_WIDTH moins la bordure) débordait du cadre, la bordure de
      -- bordered_frame n'étant pas exactement celle que j'avais estimée.
      band.style.horizontally_stretchable = true
      head = band.add({ type = "flow", direction = "horizontal" })
    else
      head = f.add({ type = "flow", direction = "horizontal" })
    end
    head.style.vertical_align = "center"
    head.style.horizontal_spacing = 4
    head.style.horizontally_stretchable = true
    if title then
      head.add({ type = "label", caption = { title }, style = "caption_label" })
      -- Un ESPACEUR pousse les widgets suivants à droite. Étirer le LABEL lui-même le
      -- faisait compresser par les cases, d'où un titre tronqué (« Missing compo… »).
      local spacer = head.add({ type = "empty-widget" })
      spacer.style.horizontally_stretchable = true
    end
    -- Corps séparé : le titre est une bande pleine largeur, le contenu vient dessous
    -- avec sa propre marge (le padding du cadre est mis à 0 pour que la bande touche
    -- bien les bords).
    local body = f.add({ type = "flow", direction = "vertical" })
    body.style.padding = 6
    body.style.horizontally_stretchable = true
    return body, head
  end

  -- ---- Bloc CIRCUIT : UN seul bloc contenant les deux volets, une ligne chacun. Les
  -- deux peuvent être actifs en même temps (c'est l'intérêt des deux fils) ; tout
  -- décocher coupe le signal.
  local circuit = block("tf-gui.emit-title")
  for _, v in ipairs({
    { "stock", "tf-gui.emit-stock", state.emit_stock },
    { "req",   "tf-gui.emit-request", state.emit_req },
  }) do
    local key, cap, cfg = v[1], v[2], v[3] or {}
    local row = circuit.add({ type = "flow", direction = "horizontal" })
    row.style.vertical_align = "center"
    row.style.horizontal_spacing = 4
    row.style.horizontally_stretchable = true
    -- La case d'activation PORTE le libellé du volet ; les cases de fil sont poussées
    -- à droite par un espaceur (étirer le label le ferait compresser par les cases).
    row.add({
      type = "checkbox",
      caption = { cap },
      state = cfg.on and true or false,
      tags = { tf_emit_on = key },
    })
    local spacer = row.add({ type = "empty-widget" })
    spacer.style.horizontally_stretchable = true
    -- Cases de fil GRISÉES et DÉCOCHÉES tant que le volet est éteint : une case cochée
    -- mais grisée laissait croire que le fil émettait. À l'activation du volet elles
    -- repartent décochées — le joueur choisit lui-même la couleur, on n'envoie jamais
    -- de signaux sur un fil sans qu'il l'ait demandé.
    for _, w in ipairs({ { "red", "tf-gui.wire-red" },
                         { "green", "tf-gui.wire-green" } }) do
      row.add({
        type = "checkbox",
        caption = { w[2] },
        state = (cfg.on and cfg[w[1]]) and true or false,
        enabled = cfg.on and true or false,
        tags = { tf_emit_wire = key, tf_wire = w[1] },
      })
    end
  end

  -- ---- Bloc SORTIES : côtés de la voie d'assemblage. Cases indépendantes, les deux
  -- peuvent être ouvertes ; on interdit seulement de fermer les DEUX (voir le handler).
  local exits = block("tf-gui.exit-title")
  for _, s in ipairs({ { "left", "tf-gui.exit-left", state.exit_left },
                       { "right", "tf-gui.exit-right", state.exit_right } }) do
    exits.add({
      type = "checkbox",
      name = "tf-exit-" .. s[1],
      caption = { s[2] },
      state = s[3] and true or false,
      tags = { tf_exit_side = s[1] },
    })
  end

  -- ---- Bloc RECYCLAGE : la case d'activation vit sur la ligne de titre, ses côtés
  -- en dessous. Côté d'entrée = RADIO (exclusif) : la voie est un CUL-DE-SAC, une seule
  -- entrée (gauche OU droite). Le bout opposé est fermé (mur+gare) → le train y bute et
  -- ne peut pas repartir. Grisés tant que la recyclage n'est pas active.
  local deco, deco_head = block("tf-gui.deco-title")
  deco_head.add({
    type = "checkbox",
    name = "tf-deco",
    state = state.deco and true or false,
    tags = { tf_deco = true },
  })
  for _, s in ipairs({ { "left", "tf-gui.exit-left", state.deco_left },
                       { "right", "tf-gui.exit-right", state.deco_right } }) do
    deco.add({
      type = "radiobutton",
      name = "tf-deco-" .. s[1],
      caption = { s[2] },
      state = s[3] and true or false,
      enabled = state.deco and true or false,
      tags = { tf_deco_side = s[1] },
    })
  end

  -- ---- Bloc CARBURANT : la roue crantée (fenêtre des carburants acceptés) vit sur la
  -- ligne de titre ; en variante BP seulement, le mode générique est en dessous.
  local fuel, fuel_head = block("tf-gui.fuel-block-title")
  local fbtn = fuel_head.add({
    type = "sprite-button",
    name = "tf-fuel-pref-open",
    style = "tool_button",
    sprite = "utility/preset",
    tooltip = { "tf-gui.fuel-pref-tip" },
  })
  fbtn.style.size = 24

  -- Carburant générique — variante BP seulement (en STC c'est toujours le cas).
  -- Décoché (défaut) : le train utilise le carburant du blueprint (0.5.x). Coché :
  -- remplissage au meilleur carburant débloqué dispo + interruption Refuel.
  if names.has_bpchest then
    fuel.add({
      type = "checkbox",
      name = "tf-generic-fuel",
      caption = { "tf-gui.generic-fuel" },
      tooltip = { "tf-gui.generic-fuel-tip" },
      state = state.generic_fuel and true or false,
      tags = { tf_generic_fuel = true },
    })
  end

  gui.reposition_circuit(player)
end

-- ---------------------------------------------------------------------------
-- Fenêtre « Carburants acceptés »
-- ---------------------------------------------------------------------------
-- Fenêtre AUTONOME et centrée : la grille (N carburants × N qualités) ne tient
-- pas dans la colonne de la fenêtre Configuration. Un couple coché = un
-- carburant que la fonderie s'autorise à brûler ; l'ordre de préférence est
-- déduit (fuel_value puis qualité décroissante) et n'est pas réglable ici.
gui.FUEL_WINDOW = FUEL_WINDOW

function gui.close_fuel(player)
  local w = player.gui.screen[FUEL_WINDOW]
  if w then w.destroy() end
end

-- L'unit_number porté par la fenêtre carburant elle-même. Elle est déplaçable et
-- vit sa propre vie : ses clics ne doivent pas dépendre de la fenêtre principale.
function gui.fuel_window_unit_number(player)
  local w = player.gui.screen[FUEL_WINDOW]
  if not (w and w.valid) then return nil end
  return w.tags.unit_number
end

function gui.open_fuel(player, state)
  local existing = player.gui.screen[FUEL_WINDOW]
  if existing then
    existing.destroy()
    return
  end

  local frame = player.gui.screen.add({
    type = "frame",
    name = FUEL_WINDOW,
    direction = "vertical",
    tags = { unit_number = state.entity.unit_number },
  })

  local titlebar = frame.add({ type = "flow", direction = "horizontal" })
  titlebar.drag_target = frame
  titlebar.add({
    type = "label",
    caption = { "tf-gui.fuel-pref-title" },
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
    name = "tf-fuel-close",
    style = "frame_action_button",
    sprite = "utility/close",
  })

  -- Structure calquée sur le moniteur de Smart Train Combinator, dont le tableau se
  -- rend correctement : frame à LARGEUR FIXE → inside_shallow_frame (padding 12) →
  -- flow de contenu (minimal_width = largeur - 32) → table. Le tableau doit vivre
  -- dans un conteneur de largeur connue, sinon son odd_row_graphical_set s'étire en
  -- bande verticale au lieu de zébrer les lignes.
  local body_w = fuel_table_width(#builder.quality_levels())
  frame.style.width = body_w + 32

  local inner = frame.add({
    type = "frame",
    name = "tf-fuel-inner",
    style = "inside_shallow_frame",
    direction = "vertical",
  })
  inner.style.padding = 12

  local hint = inner.add({ type = "label", caption = { "tf-gui.fuel-pref-hint" } })
  hint.style.single_line = false
  hint.style.maximal_width = body_w
  hint.style.bottom_margin = 6

  local bar = inner.add({ type = "flow", direction = "horizontal" })
  bar.style.vertical_align = "center"
  bar.style.bottom_margin = 6
  bar.style.horizontal_spacing = 4
  -- Raccourcis : sans eux, cocher une qualité sur 15 carburants Space Age demanderait
  -- 15 clics. Boutons NORMAUX et non `mini_button` : ce style est carré et réduisait
  -- « All »/« None » à un « A »/« N » illisible.
  for _, b in ipairs({
    { "tf-fuel-pref-all",  "tf-gui.fuel-pref-all",  "tf-gui.fuel-pref-all-tip" },
    { "tf-fuel-pref-none", "tf-gui.fuel-pref-none", "tf-gui.fuel-pref-none-tip" },
  }) do
    local btn = bar.add({
      type = "button",
      name = b[1],
      caption = { b[2] },
      tooltip = { b[3] },
    })
    btn.style.minimal_width = 0
    btn.style.height = 26
    btn.style.padding = { 0, 8 }
  end

  -- Le scroll ne sert que de garde-fou vertical (une quinzaine de carburants tient
  -- sans lui, un mod peut en ajouter) : sa largeur est FIGÉE sur celle du contenu,
  -- pour que le tableau reste dans un conteneur de largeur connue.
  local scroll = inner.add({
    type = "scroll-pane",
    name = "tf-fuel-pref",
    horizontal_scroll_policy = "never",
    vertical_scroll_policy = "auto",
  })
  scroll.style.maximal_height = 640
  scroll.style.width = body_w
  gui.refresh_fuel_pref(scroll, state)

  frame.force_auto_center()
end

-- (Re)peuple la grille des carburants. `scroll` = le scroll-pane tf-fuel-pref.
function gui.refresh_fuel_pref(scroll, state)
  if not (scroll and scroll.valid) then return end
  scroll.clear()

  local force = state.entity and state.entity.valid and state.entity.force
  if not force then return end
  local fuels = builder.unlocked_fuels(force, builder.all_loco_fuel_categories())
  if #fuels == 0 then
    scroll.add({ type = "label", caption = { "tf-gui.fuel-pref-empty" } })
    return
  end
  local qualities = builder.quality_levels()
  local pref = state.fuel_pref

  -- Rendu du tableau : une RANGÉE = un frame à fond plein, teinte alternée, dans
  -- lequel les cellules sont posées à largeur fixe. C'est le zébrage qui donne la
  -- grille, pas une bordure : `bordered_table` et son odd_row_graphical_set n'ont
  -- jamais rien dessiné ici, quelle que soit la géométrie, alors qu'une teinte unie
  -- ne dépend d'aucun atlas. Les styles viennent du DATA STAGE, donc absents après un
  -- simple rechargement de partie → style_or retombe sur "frame" (rangées sans
  -- zébrage) plutôt que de faire lever add().
  local HEAD = style_or(scroll, "frame", "tf_row_head", "frame")
  local EVEN = style_or(scroll, "frame", "tf_row_even", "frame")
  local ODD  = style_or(scroll, "frame", "tf_row_odd", "frame")

  -- La colonne des NOMS prend la largeur restante (la fenêtre a un plancher, voir
  -- fuel_table_width) : les colonnes de qualité gardent ainsi leur largeur fixe et
  -- restent alignées sur leur en-tête, quel que soit le nombre de qualités.
  local qual_w = FUEL_QUAL_COL
  -- FUEL_TAIL_PAD n'est PAS retiré ici : en le laissant à la colonne des noms, les
  -- colonnes de qualité se décalent d'autant vers la gauche et la dernière se décolle
  -- du bord droit. Le right_padding du style de rangée, lui, tombe hors du cadre (la
  -- rangée se dimensionne sur son contenu) — c'est le seul levier qui agit vraiment.
  local name_w = fuel_table_width(#qualities) - FUEL_ROW_PAD
                 - #qualities * qual_w

  local holder = scroll.add({ type = "flow", direction = "vertical" })
  holder.style.vertical_spacing = 1

  -- Une cellule de qualité : largeur fixe, contenu centré. Utilisée par l'en-tête et
  -- par chaque rangée, pour que les colonnes tombent exactement les unes sur les autres.
  -- `h` (optionnel) impose une hauteur : l'en-tête s'en sert pour que la pastille de
  -- qualité ne soit pas rognée par une cellule calée sur un contenu plus court.
  -- La marge de droite vient du right_padding du STYLE de rangée (tf_row_*), pas d'une
  -- marge posée ici : une right_margin sur la dernière cellule restait sans effet.
  local function qual_cell(row, h)
    local cell = row.add({ type = "flow", direction = "horizontal" })
    cell.style.width = qual_w
    if h then cell.style.height = h end
    cell.style.horizontal_align = "center"
    cell.style.vertical_align = "center"
    return cell
  end

  -- En-tête : libellé de colonne + une pastille de qualité par colonne (nom en
  -- tooltip). La qualité normale n'a pas de badge → son nom sert de repère.
  local head = holder.add({ type = "frame", style = HEAD, direction = "horizontal" })
  head.style.vertical_align = "center"
  -- Hauteur MINIMALE explicite : sans elle la rangée se cale sur la hauteur du label et
  -- les pastilles de qualité sont rognées en haut. 34 px = pastille de 16 + les 2×4 px
  -- de padding de la rangée + une marge, 28 ne suffisait pas.
  head.style.minimal_height = 34
  local h0 = head.add({ type = "label", caption = { "tf-gui.fuel-pref-col-fuel" },
                        style = "caption_label" })
  h0.style.width = name_w
  -- L'en-tête de qualité est CLIQUABLE : il bascule toute sa colonne, pendant de
  -- l'icône de carburant qui bascule sa ligne. D'où un sprite-BUTTON (un `sprite` ne
  -- reçoit pas les clics) et, pour la qualité normale qui n'a pas de badge, un bouton
  -- portant son nom.
  for _, q in ipairs(qualities) do
    -- `quality-name.normal` n'est PAS défini dans base : c'est le mod Quality qui
    -- l'apporte. Sans lui, localised_name affiche la clé brute. On passe donc par un
    -- repli maison, avec la locale du jeu en premier choix quand elle existe.
    local qname = (q.name == "normal")
      and { "?", { "quality-name.normal" }, { "tf-gui.quality-normal" } }
      or prototypes.quality[q.name].localised_name
    local cell = qual_cell(head, 24)
    -- quality_icon et non quality_sprite : ici on VEUT l'icône de la qualité normale
    -- quand elle existe (le mod Quality la fournit), c'est plus lisible qu'un libellé
    -- texte et ça aligne la colonne sur les autres. Sans le mod, repli sur le nom.
    local pip_path = quality_icon(q.name)
    if pip_path then
      local pip = cell.add({
        type = "sprite-button",
        style = "frame_action_button",
        sprite = pip_path,
        tooltip = { "tf-gui.fuel-col-toggle", qname },
        tags = { tf_fuel_col = q.name },
      })
      pip.style.size = 24
    else
      -- Style DISCRET (tool_button, qui porte du texte contrairement au
      -- frame_action_button prévu pour une icône) : un bouton standard ressortait en
      -- jaune vif au milieu de l'en-tête.
      local btn = cell.add({
        type = "button",
        style = "tool_button",
        caption = qname,
        tooltip = { "tf-gui.fuel-col-toggle", qname },
        tags = { tf_fuel_col = q.name },
      })
      btn.style.minimal_width = 0
      -- Borné à la cellule : sans maximal_width le libellé pousse le bouton hors de sa
      -- colonne et décale l'en-tête par rapport aux cases du dessous.
      btn.style.maximal_width = qual_w - 4
      btn.style.height = 24
      btn.style.padding = { 0, 4 }
      btn.style.font = "default-small-semibold"
    end
  end

  for i, f in ipairs(fuels) do
    local proto = prototypes.item[f.name]
    local row = holder.add({
      type = "frame",
      style = (i % 2 == 0) and EVEN or ODD,
      direction = "horizontal",
    })
    row.style.vertical_align = "center"

    local name_cell = row.add({ type = "flow", direction = "horizontal" })
    name_cell.style.width = name_w
    name_cell.style.vertical_align = "center"
    -- Clic sur l'icône = bascule TOUTE la ligne (plus utile ici que d'ouvrir la
    -- Factoriopedia : un carburant se coche le plus souvent dans toutes ses qualités
    -- d'un coup). Le nom reste lisible en tooltip.
    local icon = name_cell.add({
      type = "sprite-button",
      style = "slot_button",
      sprite = "item/" .. f.name,
      tooltip = { "tf-gui.fuel-row-toggle" },
      tags = { tf_fuel_row = f.name },
    })
    icon.style.size = 20
    icon.style.right_margin = 6
    name_cell.add({
      type = "label",
      caption = proto and proto.localised_name or f.name,
    })

    for qi, q in ipairs(qualities) do
      local cb = qual_cell(row).add({
        type = "checkbox",
        state = builder.fuel_allowed(pref, f.name, q.name),
        tags = { tf_fuel_pref = builder.qkey(f.name, q.name) },
      })
      cb.elem_tooltip = { type = "item-with-quality", name = f.name,
                          quality = q.name }
    end
  end
end

-- ---------------------------------------------------------------------------
-- Dialogue des paramètres d'un blueprint paramétré (à la mise en file)
-- ---------------------------------------------------------------------------

-- `stc_index` (optionnel) : quand il est fourni, le dialogue est pour un modèle
-- STC (state.stc_models[stc_index]) et non un plan du coffre ; la validation
-- reconstruira le template synthétique au lieu de le relire dans st.templates.
-- `res_kind` (optionnel) : "item" ou "fluid" — en mode STC on CONNAÎT le kind du
-- modèle, donc on restreint le choix de ressource au bon type (picker item OU
-- fluid) au lieu d'un picker signal générique. nil (BP) → picker signal.
function gui.open_params(player, state, index, template, stc_index, res_kind)
  local old = player.gui.screen[PARAMS_WINDOW]
  if old then old.destroy() end
  local frame = player.gui.screen.add({
    type = "frame",
    name = PARAMS_WINDOW,
    direction = "vertical",
    caption = { "tf-gui.params-title" },
    -- On garde la SIGNATURE du plan (pas seulement l'index) : le livre reflète
    -- le coffre et peut se réindexer entre l'ouverture du dialogue et la
    -- validation. La signature identifie le bon template quoi qu'il arrive.
    tags = {
      unit_number = state.entity.unit_number,
      index = index,
      signature = template.signature,
      stc_index = stc_index,
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
      -- Picker restreint au kind connu (STC) sinon signal générique (BP). Pour un
      -- ITEM on prend « item-with-quality » : le picker « item » nu ne permet pas
      -- de CHOISIR une qualité, or elle entre dans le nom de gare substitué.
      local elem_type = res_kind or "signal"
      if elem_type == "item" then elem_type = "item-with-quality" end
      row.add({
        type = "choose-elem-button",
        elem_type = elem_type,
        tags = { tf_param = p.id or ("parameter-" .. (i - 1)),
                 tf_param_kind = res_kind },
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
  local frame = player.gui.screen[PARAMS_WINDOW]
  if not frame then return nil end
  local params = {}
  for _, row in pairs(frame["tf-params-rows"].children) do
    for _, el in pairs(row.children) do
      if el.type == "choose-elem-button" and el.tags.tf_param then
        local v = el.elem_value
        if v then
          -- Picker signal → v = {type,name} ; item-with-quality → v = {name,quality}
          -- (sans type, d'où le repli "item") ; picker fluide → v = nom (string),
          -- le type vient alors du kind du bouton. La QUALITÉ choisie est conservée :
          -- elle entre dans les noms de gares substitués, qui doivent matcher ceux
          -- de STC au byte près.
          if type(v) == "table" then
            params[el.tags.tf_param] = { type = v.type or "item", name = v.name,
                                         quality = builder.quality_of(v) }
          else
            params[el.tags.tf_param] = { type = el.tags.tf_param_kind or "item", name = v }
          end
        end
      end
    end
  end
  return params, frame.tags.unit_number, frame.tags.index,
    frame.tags.signature, frame.tags.stc_index
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
local function bp_stack_sigs(stack, quality)
  local sigs = {}
  -- 2.0 : la propriété s'appelle preview_icons (ex-blueprint_icons en 1.1).
  local ok, icons = pcall(function() return stack.preview_icons end)
  if ok and icons then
    for k = 1, math.min(4, #icons) do
      local p = icons[k].signal and sprite_of(icons[k].signal)
      if p then sigs[#sigs + 1] = { sprite = p, quality = quality } end
    end
  end
  return sigs
end

-- Matériel roulant d'un plan du coffre (nil si le plan n'en contient pas). Lit les
-- entités du plan, pas le template : la grille du coffre reflète le coffre, y
-- compris les plans non encore importés.
local ROLLING = { locomotive = true, ["cargo-wagon"] = true,
                  ["fluid-wagon"] = true, ["artillery-wagon"] = true }
local function bp_stack_stock(stack)
  local ok, ents = pcall(function() return stack.get_blueprint_entities() end)
  if not (ok and ents) then return nil end
  local stock = {}
  for _, e in ipairs(ents) do
    local proto = prototypes.entity[e.name]
    if proto and ROLLING[proto.type] then stock[#stock + 1] = e end
  end
  if #stock == 0 then return nil end
  return stock
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
      -- Les slots du coffre n'ont pas de place pour un libellé : le matériel du
      -- plan (icônes qualifiées) passe par le tooltip, et la qualité du train
      -- badge les icônes de la tuile.
      local bstock = bp_stack_stock(stack)
      if bstock then
        tip = { "", tip, "\n", stock_caption({ stock = bstock }) }
      end
      local bq = bstock and uniform_quality({ stock = bstock }) or nil
      bp_square_tile(grid, bp_stack_sigs(stack, bq), {
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
gui.PARAMS_WINDOW = PARAMS_WINDOW
gui.BP_WINDOW = BP_WINDOW

return gui
