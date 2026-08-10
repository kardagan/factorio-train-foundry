-- Migration 1.0.0 → 1.1.0 : support de la QUALITÉ. Les besoins (work.need.items)
-- et les manques (work.missing) sont désormais indexés par une clé composite
-- "item\0qualité" au lieu du nom d'item nu.
--
-- Seul un travail en phase WAITING est réinitialisé : son need n'est qu'un devis,
-- rien n'a encore été prélevé (consume n'intervient qu'au passage en building), et
-- control.lua le recalcule au tick suivant (work.need = work.need or compute_need).
--
-- Un travail en building/ready est au contraire LAISSÉ INTACT : son need est la
-- FACTURE de ce qui a déjà été consommé et sert au remboursement en cas
-- d'annulation. Le relire à l'ancienne forme est correct — builder.qsplit lit une
-- clé sans séparateur comme qualité normale, ce qui est exactement ce qui avait
-- été prélevé à l'époque.
if storage and storage.foundries then
  for _, st in pairs(storage.foundries) do
    if st.work and st.work.phase == "waiting" then
      st.work.need = nil
      st.work.missing = nil
      st.work.fuel_item = nil
      st.work.fuel_caption = nil
    end
  end
end
