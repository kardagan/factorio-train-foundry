-- Contrat de noms — variante BP (« Train Foundry »).
-- Conserve les noms HISTORIQUES du mod mono : aucune migration d'entité, une
-- save 0.6.x reste valide. Le code commun lit UNIQUEMENT ces constantes.
return {
  source      = "bp",
  version     = "1.0.0",                  -- semver publié (mod désormais Factorio 2.1 uniquement)
  mod         = "train-foundry",          -- nom du mod (chemin __<mod>__/graphics)
  building    = "train-foundry",          -- entité-bâtiment (INCHANGÉ)
  rail        = "tf-rail",
  rail_over   = "tf-rail-over",
  rail_ext    = "tf-rail-ext",             -- rail hors bâtiment : sélectionnable, non-minable
  input       = "tf-input",
  signal      = "tf-signal",
  combinator  = "tf-combinator",
  wall        = "tf-wall",                  -- enceinte de murs du bâtiment
  gate        = "tf-gate",                  -- portes aux sorties des voies
  blocker     = "tf-blocker",               -- collision invisible bande basse (perso bloqué)
  recycle_stop      = "tf-recycle-stop",    -- gare de recyclage (train-stop)
  recycle_stop_name = "[entity=train-foundry] Train Recycle",  -- backer_name (schedule)
  block_signal      = "tf-block-signal",    -- signal toujours rouge (anti-marche-arrière)
  block_combi       = "tf-block-combi",     -- combinateur constant qui ferme le signal
  deco_top    = "tf-deco-top",             -- bande déco haut (entité, ordre de dessin piloté)
  bpchest     = "tf-blueprints",
  has_bpchest = true,
  dummy_cat   = "train-foundry-dummy",
  remote      = "train-foundry",          -- interface remote historique
  shortcut    = "tf-open-overview",
}
