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
  bpchest     = nil,                        -- pas de coffre à blueprints
  has_bpchest = false,
  dummy_cat   = "tfstc-dummy",
  remote      = "train-foundry-stc",
  shortcut    = "tfstc-open-overview",
}
