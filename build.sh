#!/usr/bin/env bash
#
# build.sh — packaging Train Foundry pour Factorio 2.0 ET 2.1.
#
# Source unique : le code (control.lua/data*.lua/scripts/graphics/locale) est
# identique pour les deux versions du jeu. Seul info.json change
# (factorio_version + borne base + numéro). On dérive donc deux zips d'un même
# code.
#
# Convention de version :
#   info.json porte le semver canonique = la release Factorio 2.0 (ex. 0.1.0).
#   La release Factorio 2.1 reprend le même code avec le MINOR +1 (ex. 0.2.0).
#   Une nouvelle version se fait en avançant le minor canonique d'AU MOINS 2
#   (0.1.0 -> 0.3.0), pour que le 2.1 dérivé (0.4.0) ne réutilise jamais un
#   minor déjà sorti. Le patch reste libre pour les correctifs (0.1.0 -> 0.1.1
#   côté 2.0, dérivé 0.2.1 côté 2.1). La nature feature/fix est portée par
#   changelog.txt, pas par le numéro.
#
# Usage :
#   ./build.sh package        # génère dist/...-_1.0.0.zip (2.0) et _1.1.0.zip (2.1)
#   ./build.sh link           # lien symbolique dev: ~/.factorio/mods/<mod> -> ce repo
#   ./build.sh unlink         # retire le lien dev
#   ./build.sh install        # package, puis copie le zip 2.0 dans ~/.factorio/mods/
#   ./build.sh clean          # supprime dist/
#
# Dev recommandé : `link` une fois, puis on édite le code et on recharge Factorio
# (le repo est en factorio_version 2.0, donc chargeable tel quel dans le jeu 2.0).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

MOD_NAME="train-foundry"
DIST="$ROOT/dist"

# Fichiers/dossiers embarqués dans le zip (allowlist : on ne ship JAMAIS tmp/,
# dist/, .git, .claude, le script de build, etc.).
CONTENTS=(
  info.json
  control.lua
  data.lua
  changelog.txt
  thumbnail.png
  LICENSE
  scripts
  graphics
  locale
)

# Cibles : "gamever:base_min:minor_offset"
TARGETS=(
  "2.0:2.0.0:0"
  "2.1:2.1.0:1"
)

# Semver canonique lu dans info.json (= la release 2.0).
mod_version() {
  python3 -c "import json;print(json.load(open('info.json'))['version'])"
}

# Réécrit version + factorio_version + borne base dans un info.json donné.
# Les autres dépendances (optionnelles, ...) sont préservées.
rewrite_info() {
  local file="$1" modver="$2" gamever="$3" base_min="$4"
  python3 - "$file" "$modver" "$gamever" "$base_min" <<'PY'
import json, sys
path, modver, gamever, base_min = sys.argv[1:5]
with open(path) as f:
    data = json.load(f)
data["version"] = modver
data["factorio_version"] = gamever
deps = []
for d in data.get("dependencies", []):
    s = d.strip()
    if s.startswith("base"):
        deps.append(f"base >= {base_min}")
    else:
        deps.append(d)
data["dependencies"] = deps
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

# X.Y.Z + offset sur le minor -> X.(Y+offset).Z
bump_minor() {
  local ver="$1" offset="$2"
  local maj="${ver%%.*}" rest="${ver#*.}"
  local min="${rest%%.*}" pat="${rest#*.}"
  echo "${maj}.$((min + offset)).${pat}"
}

package() {
  local base; base="$(mod_version)"
  rm -rf "$DIST"
  mkdir -p "$DIST"

  for target in "${TARGETS[@]}"; do
    IFS=':' read -r gamever base_min offset <<<"$target"
    local modver; modver="$(bump_minor "$base" "$offset")"
    local stage="$DIST/${MOD_NAME}_${modver}"

    mkdir -p "$stage"
    for item in "${CONTENTS[@]}"; do
      [ -e "$item" ] && cp -r "$item" "$stage/"
    done
    rewrite_info "$stage/info.json" "$modver" "$gamever" "$base_min"

    ( cd "$DIST" && zip -rq "${MOD_NAME}_${modver}.zip" "${MOD_NAME}_${modver}" )
    rm -rf "$stage"
    echo "  → dist/${MOD_NAME}_${modver}.zip   (Factorio ${gamever})"
  done
  echo "Packaging OK (semver canonique=${base})."
}

install_local() {
  package
  local base; base="$(mod_version)"
  local mods="$HOME/.factorio/mods"
  local zip="$DIST/${MOD_NAME}_${base}.zip"   # le zip 2.0 = version canonique
  if [ ! -d "$mods" ]; then
    echo "Dossier mods introuvable: $mods" >&2; exit 1
  fi
  cp "$zip" "$mods/"
  echo "Installé $zip dans $mods (Factorio prendra la version la plus haute présente)."
}

# Dev: symlink the repo into the mods folder so edits are live (no rebuild).
# Removes any packaged zip of this mod from mods/ first, so it can't shadow the
# link (a zip with a higher version would win over the unversioned link folder).
link_dev() {
  local mods="$HOME/.factorio/mods"
  [ -d "$mods" ] || { echo "Dossier mods introuvable: $mods" >&2; exit 1; }
  rm -f "$mods/${MOD_NAME}_"*.zip
  ln -sfn "$ROOT" "$mods/$MOD_NAME"
  echo "Lien dev : $mods/$MOD_NAME -> $ROOT"
  echo "(zips ${MOD_NAME}_*.zip retirés de mods/ pour ne pas masquer le lien)"
}

unlink_dev() {
  local mods="$HOME/.factorio/mods"
  if [ -L "$mods/$MOD_NAME" ]; then
    rm -f "$mods/$MOD_NAME"; echo "Lien dev retiré : $mods/$MOD_NAME"
  else
    echo "Aucun lien dev à retirer."
  fi
}

case "${1:-package}" in
  package) package ;;
  link)    link_dev ;;
  unlink)  unlink_dev ;;
  install) install_local ;;
  clean)   rm -rf "$DIST"; echo "dist/ supprimé." ;;
  *) echo "Usage: $0 {package|link|unlink|install|clean}" >&2; exit 1 ;;
esac
