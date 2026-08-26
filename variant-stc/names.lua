-- Contrat de noms — variante STC (« Train Foundry STC »).
-- Noms NEUFS tfstc-* : aucune collision de prototypes si le mod BP est aussi
-- installé (coexistence « 1 de chaque par surface »). Pas de coffre à blueprints.
return {
  source      = "stc",
  version     = "1.3.0",                   -- semver publié (mod Factorio 2.1 uniquement)
  mod         = "train-foundry-stc",       -- nom du mod (chemin __<mod>__/graphics)
  building    = "tfstc-foundry",
  rail        = "tfstc-rail",
  rail_over   = "tfstc-rail-over",
  rail_ext    = "tfstc-rail-ext",           -- rail hors bâtiment : sélectionnable, non-minable
  input       = "tfstc-input",
  signal      = "tfstc-signal",
  combinator  = "tfstc-combinator",          -- émetteur du STOCK (fil rouge du poteau)
  combinator_req = "tfstc-combinator-req",   -- émetteur des DEMANDES (fil vert du poteau)
  pole        = "tfstc-pole",                 -- poteau : seul point d'accroche câble + alim.
  wall        = "tfstc-wall",               -- enceinte de murs du bâtiment
  gate        = "tfstc-gate",               -- portes aux sorties des voies
  blocker     = "tfstc-blocker",            -- collision invisible bande basse (perso bloqué)
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
  -- Prérequis de la TECHNO. La variante STC ne fonctionne pas sans Smart Train
  -- Combinator (dépendance obligatoire) : sa techno suit donc celle de STC, ce
  -- qui rend la filiation lisible dans l'arbre. Les prérequis de STC lui-même
  -- (combinateurs avancés, transport ferroviaire automatisé) sont hérités par
  -- transitivité — les répéter n'ajouterait que du bruit dans l'arbre.
  -- Nullius : STC renomme sa techno en nullius-* dans son data stage, chargé
  -- avant le nôtre (dépendance), donc le nom est déjà à jour quand on le lit.
  tech_prereq         = { "smart-train-combinator" },
  tech_prereq_nullius = { "nullius-smart-train-combinator" },
}
