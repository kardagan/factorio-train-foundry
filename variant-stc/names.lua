-- Contrat de noms — variante STC (« Train Foundry STC »).
-- Noms NEUFS tfstc-* : aucune collision de prototypes si le mod BP est aussi
-- installé (coexistence « 1 de chaque par surface »). Pas de coffre à blueprints.
return {
  source      = "stc",
  version     = "0.1.0",                   -- nouveau mod : repart de zéro (canal 2.0 ; +1 pour 2.1)
  mod         = "train-foundry-stc",       -- nom du mod (chemin __<mod>__/graphics)
  building    = "tfstc-foundry",
  rail        = "tfstc-rail",
  rail_over   = "tfstc-rail-over",
  input       = "tfstc-input",
  signal      = "tfstc-signal",
  combinator  = "tfstc-combinator",
  wall        = "tfstc-wall",               -- enceinte de murs du bâtiment
  gate        = "tfstc-gate",               -- portes aux sorties des voies
  track_deco  = "tfstc-track-deco",         -- [TEST] entité-déco voie de jonction
  bpchest     = nil,                        -- pas de coffre à blueprints
  has_bpchest = false,
  dummy_cat   = "tfstc-dummy",
  remote      = "train-foundry-stc",
  shortcut    = "tfstc-open-overview",
}
