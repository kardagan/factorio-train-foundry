-- Contrat de noms — variante STC (« Train Foundry STC »).
-- Noms NEUFS tfstc-* : aucune collision de prototypes si le mod BP est aussi
-- installé (coexistence « 1 de chaque par surface »). Pas de coffre à blueprints.
return {
  source      = "stc",
  version     = "1.0.0",                   -- semver publié (mod Factorio 2.1 uniquement)
  mod         = "train-foundry-stc",       -- nom du mod (chemin __<mod>__/graphics)
  building    = "tfstc-foundry",
  rail        = "tfstc-rail",
  rail_over   = "tfstc-rail-over",
  rail_ext    = "tfstc-rail-ext",           -- rail hors bâtiment : sélectionnable, non-minable
  input       = "tfstc-input",
  signal      = "tfstc-signal",
  combinator  = "tfstc-combinator",
  wall        = "tfstc-wall",               -- enceinte de murs du bâtiment
  gate        = "tfstc-gate",               -- portes aux sorties des voies
  recycle_stop      = "tfstc-recycle-stop", -- gare de recyclage (train-stop)
  recycle_stop_name = "[entity=tfstc-foundry] Train Recycle",  -- backer_name (schedule)
  block_signal      = "tfstc-block-signal", -- signal toujours rouge (anti-marche-arrière)
  block_combi       = "tfstc-block-combi",  -- combinateur constant qui ferme le signal
  deco_top    = "tfstc-deco-top",           -- bande déco haut (entité, ordre de dessin piloté)
  bpchest     = nil,                        -- pas de coffre à blueprints
  has_bpchest = false,
  dummy_cat   = "tfstc-dummy",
  remote      = "train-foundry-stc",
  shortcut    = "tfstc-open-overview",
}
