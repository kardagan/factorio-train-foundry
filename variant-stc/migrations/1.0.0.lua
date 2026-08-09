-- Migration 0.1.0 → 1.0.0 : le parvis a été réagencé (coffre de réserve désormais
-- 1×2, et coffre / combinateur / signal de sortie déplacés). Les fonctions ensure_*
-- ne REPOSITIONNENT pas un enfant déjà présent → sur une vieille save ils resteraient
-- à l'ancienne place (désalignés, gênant l'autre voie). On DÉTRUIT donc ces enfants
-- et on remet les champs à nil : on_configuration_changed (migrate_all, qui tourne
-- juste après) les recrée aux NOUVELLES positions via ensure_input /
-- ensure_combinator / repair_signal, et refresh_chain_track recomble les jonctions.
-- (bpchest n'existe pas côté STC ; le nil-er est sans effet.)
if storage and storage.foundries then
  for _, st in pairs(storage.foundries) do
    for _, key in ipairs({ "input", "combinator", "bpchest", "signal", "signal_east" }) do
      local ent = st[key]
      if ent and ent.valid then ent.destroy() end
      st[key] = nil
    end
  end
end
