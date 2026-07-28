-- Contrat de noms — variante BP (« Train Foundry »).
-- Conserve les noms HISTORIQUES du mod mono : aucune migration d'entité, une
-- save 0.6.x reste valide. Le code commun lit UNIQUEMENT ces constantes.
return {
  source      = "bp",
  version     = "0.7.0",                  -- semver canonique (canal 2.0 ; le build dérive +1 pour 2.1)
  mod         = "train-foundry",          -- nom du mod (chemin __<mod>__/graphics)
  building    = "train-foundry",          -- entité-bâtiment (INCHANGÉ)
  rail        = "tf-rail",
  rail_over   = "tf-rail-over",
  input       = "tf-input",
  signal      = "tf-signal",
  combinator  = "tf-combinator",
  wall        = "tf-wall",                  -- enceinte de murs du bâtiment
  gate        = "tf-gate",                  -- portes aux sorties des voies
  track_deco  = "tf-track-deco",           -- [TEST] entité-déco voie de jonction
  bpchest     = "tf-blueprints",
  has_bpchest = true,
  dummy_cat   = "train-foundry-dummy",
  remote      = "train-foundry",          -- interface remote historique
  shortcut    = "tf-open-overview",
}
