-- Migration 0.6.x (mod mono avec radio BP/STC) → 0.7.0 (variante BP dédiée).
-- Le mod BP conserve les noms d'entités historiques : aucune conversion d'entité.
-- Seul nettoyage : le champ state.source_mode (radio supprimé) devient inerte ;
-- une fonderie sauvegardée en mode "stc" n'a plus de sens ici → on la repasse en
-- "bp" (mais le champ n'est plus lu de toute façon). Défensif, sans effet de bord.
if storage and storage.foundries then
  for _, st in pairs(storage.foundries) do
    st.source_mode = nil   -- champ retiré du code
    st.stc_models = nil    -- cache transitoire STC, sans objet côté BP
  end
end
