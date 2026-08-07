#!/usr/bin/env bash
#
# build.sh — packaging Train Foundry en DEUX variantes (BP / STC), chacune pour
# Factorio 2.0 ET 2.1, depuis une SOURCE UNIQUE.
#
# Deux dimensions :
#   - VARIANTE : "bp" (train-foundry, coffre à blueprints) ou "stc"
#     (train-foundry-stc, modèles Smart Train Combinator, pas de coffre BP).
#   - CANAL de jeu : 2.0 et 2.1 (seul info.json diffère : factorio_version + base).
#
# Assemblage d'un paquet = common/ (code partagé) + variant-<v>/ (spécifique),
# aplatis à la racine du zip, plus un data.lua généré qui require les deux
# étages de prototypes. Ainsi le code commun vit en UN exemplaire dans le repo,
# jamais dupliqué en source ; c'est le build qui le recopie dans chaque paquet.
#
# Chaque paquet est AUTONOME : aucun mod "core" à installer. Le joueur prend
# train-foundry (BP) et/ou train-foundry-stc.
#
# Convention de version (identique à avant) :
#   info.json porte le semver canonique = la release Factorio 2.0.
#   La release 2.1 reprend le même code avec le MINOR +1.
#
# Usage :
#   ./build.sh package            # 4 zips : bp 2.0/2.1 + stc 2.0/2.1
#   ./build.sh link bp            # lien dev de la variante BP dans ~/.factorio/mods
#   ./build.sh link stc           # lien dev de la variante STC
#   ./build.sh unlink [bp|stc]    # retire le(s) lien(s) dev
#   ./build.sh clean              # supprime dist/
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"

# Nom de mod par variante.
mod_name() { case "$1" in bp) echo "train-foundry";; stc) echo "train-foundry-stc";; *) echo "?";; esac; }

VARIANTS=(bp stc)

# Fichiers/dossiers PARTAGÉS embarqués dans chaque zip (hors common/ et variant-*/,
# assemblés à part). Le changelog, le thumbnail et le README ne sont PAS partagés :
# chacun est propre à la variante (variant-<v>/), car BP et STC ont des versions,
# un historique, une vignette et une page portail distincts. Jamais tmp/, dist/,
# .git, .claude, build.sh, CLAUDE.md.
SHARED=(
  LICENSE
  graphics
  locale
)

# Cibles de canal : "gamever:base_min:minor_offset"
TARGETS=(
  "2.0:2.0.0:0"
  "2.1:2.1.0:1"
)

# Semver canonique d'une VARIANTE = champ `version` de son names.lua (canal 2.0 ;
# le build dérive +1 pour le 2.1). Lu par regex (pas d'interpréteur Lua ici).
mod_version() {
  local variant="$1"
  python3 - "variant-${variant}/names.lua" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', t)
if not m:
    sys.exit("version introuvable dans " + sys.argv[1])
print(m.group(1))
PY
}

# Réécrit name + version + factorio_version + borne base d'un info.json, et
# n'ajoute la dépendance optionnelle smart-train-combinator QUE pour la variante stc.
rewrite_info() {
  local file="$1" name="$2" modver="$3" gamever="$4" base_min="$5" variant="$6"
  python3 - "$file" "$name" "$modver" "$gamever" "$base_min" "$variant" <<'PY'
import json, sys
path, name, modver, gamever, base_min, variant = sys.argv[1:7]
with open(path) as f:
    data = json.load(f)
data["name"] = name
data["version"] = modver
data["factorio_version"] = gamever
if variant == "stc":
    data["title"] = "Train Foundry for Smart Train Combinator"
    data["description"] = ("A large train foundry that assembles complete trains from Smart Train "
                           "Combinator models: pick a train shape, choose its resource, and the "
                           "finished train fuels up and drives off onto your rail network on its own. "
                           "Requires Smart Train Combinator.")
else:
    data["title"] = "Train Foundry"
    data["description"] = ("A large train foundry building that assembles complete trains from "
                           "blueprint templates: import a train blueprint, queue it, feed the parts "
                           "with inserters, and watch the finished train fuel up and drive off onto "
                           "your rail network on its own.")
deps = []
for d in data.get("dependencies", []):
    s = d.strip()
    if s.startswith("base"):
        deps.append(f"base >= {base_min}")
    elif "smart-train-combinator" in s:
        pass  # retiré ici, ré-ajouté seulement pour stc ci-dessous
    else:
        deps.append(d)
if variant == "stc":
    deps.append("(?) smart-train-combinator >= 1.6.0")
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

# Assemble une variante dans un dossier `dest` (aplati). Ne réécrit PAS info.json
# (fait par l'appelant selon le canal). Copie common + variant + partagés + génère
# data.lua.
assemble() {
  local variant="$1" dest="$2"
  mkdir -p "$dest"
  # Code commun (control.lua, data-common.lua, scripts/…)
  cp -r common/. "$dest/"
  # Spécifique variante (names.lua, data-variant.lua, scripts/… — fusionne scripts/)
  cp -r "variant-${variant}/." "$dest/"
  # data.lua généré : deux étages de prototypes.
  cat > "$dest/data.lua" <<'LUA'
require("data-common")
require("data-variant")
LUA
  # Migrations si présentes pour la variante (BP : conversion depuis mono-mod).
  [ -d "variant-${variant}/migrations" ] && cp -r "variant-${variant}/migrations" "$dest/"
  # Partagés.
  for item in "${SHARED[@]}"; do
    [ -e "$item" ] && cp -r "$item" "$dest/"
  done
  # info.json de base (le gabarit à la racine).
  cp info.json "$dest/info.json"
}

package() {
  rm -rf "$DIST"
  mkdir -p "$DIST"

  for variant in "${VARIANTS[@]}"; do
    local name; name="$(mod_name "$variant")"
    local base; base="$(mod_version "$variant")"   # version propre à la variante
    for target in "${TARGETS[@]}"; do
      IFS=':' read -r gamever base_min offset <<<"$target"
      local modver; modver="$(bump_minor "$base" "$offset")"
      local stage="$DIST/${name}_${modver}"

      assemble "$variant" "$stage"
      rewrite_info "$stage/info.json" "$name" "$modver" "$gamever" "$base_min" "$variant"

      ( cd "$DIST" && zip -rq "${name}_${modver}.zip" "${name}_${modver}" )
      rm -rf "$stage"
      echo "  → dist/${name}_${modver}.zip   (Factorio ${gamever}, canonique ${base})"
    done
  done
  echo "Packaging OK."
}

# Dev : assemble UNE variante dans dist/link-<v>/ et symlink dans mods/.
# (Le repo n'étant plus "plat", on ne peut pas symlinker le repo directement.)
link_dev() {
  local variant="${1:-}"
  [ -n "$variant" ] || { echo "Usage: $0 link {bp|stc}" >&2; exit 1; }
  local name; name="$(mod_name "$variant")"
  [ "$name" != "?" ] || { echo "Variante inconnue: $variant" >&2; exit 1; }
  local mods="$HOME/.factorio/mods"
  [ -d "$mods" ] || { echo "Dossier mods introuvable: $mods" >&2; exit 1; }

  local base; base="$(mod_version "$variant")"
  local stage="$DIST/link-${variant}"
  rm -rf "$stage"
  assemble "$variant" "$stage"
  # info.json en factorio_version 2.0 (chargeable en jeu 2.0), name = variante.
  rewrite_info "$stage/info.json" "$name" "$base" "2.0" "2.0.0" "$variant"

  rm -f "$mods/${name}_"*.zip
  ln -sfn "$stage" "$mods/$name"
  echo "Lien dev : $mods/$name -> $stage"
  echo "(zips ${name}_*.zip retirés de mods/ pour ne pas masquer le lien)"
  echo "NB : après édition du code, relance ./build.sh link $variant pour ré-assembler."
}

# Dev "chaud" : au lieu de COPIER les sources dans dist/link-<v>/, on les
# SYMLINKE fichier par fichier. Éditer une source (common/scripts/composite.lua,
# etc.) mets à jour le mod EN TEMPS RÉEL — plus besoin de ré-assembler.
# Seuls data.lua et info.json sont générés (fichiers réels, pas des liens).
# ATTENTION : game.reload_mods() ne recharge que le CONTROL-stage (control.lua +
# require). Un changement de DATA-stage (data-common.lua, prototypes, collision)
# exige toujours un REDÉMARRAGE COMPLET de Factorio.
devlink() {
  local variant="${1:-}"
  local channel="${2:-2.0}"   # canal de jeu ciblé : 2.0 (défaut) ou 2.1
  [[ -n "$variant" ]] || { echo "Usage: $0 devlink {bp|stc} [2.0|2.1]" >&2; exit 2; }
  [[ "$channel" == "2.0" || "$channel" == "2.1" ]] || {
    echo "Canal inconnu: $channel (attendu 2.0 ou 2.1)" >&2; exit 2; }
  local name; name="$(mod_name "$variant")"
  [[ "$name" != "?" ]] || { echo "Variante inconnue: $variant" >&2; exit 2; }
  local mods="$HOME/.factorio/mods"
  [[ -d "$mods" ]] || { echo "Dossier mods introuvable: $mods" >&2; exit 1; }

  local stage="$DIST/devlink-${variant}"
  rm -rf "$stage"
  mkdir -p "$stage/scripts"

  # Lie un fichier source (absolu) vers une cible dans le stage.
  local link_file
  link_file() { ln -sfn "$ROOT/$1" "$stage/$2"; }

  # Code commun (aplati à la racine + scripts/).
  link_file "common/control.lua"          "control.lua"
  link_file "common/data-common.lua"       "data-common.lua"
  link_file "common/scripts/builder.lua"   "scripts/builder.lua"
  link_file "common/scripts/composite.lua" "scripts/composite.lua"
  link_file "common/scripts/gui.lua"       "scripts/gui.lua"

  # Spécifique variante (aplati). scripts/ de la variante fusionné.
  link_file "variant-${variant}/names.lua"        "names.lua"
  link_file "variant-${variant}/data-variant.lua" "data-variant.lua"
  local f
  for f in "variant-${variant}"/scripts/*.lua; do
    [[ -e "$f" ]] && ln -sfn "$ROOT/$f" "$stage/scripts/$(basename "$f")"
  done

  # Partagés (dossiers) : liens directs.
  local item
  for item in "${SHARED[@]}"; do
    [[ -e "$item" ]] && ln -sfn "$ROOT/$item" "$stage/$item"
  done
  # Migrations (dossier) si présentes.
  [[ -d "variant-${variant}/migrations" ]] && \
    ln -sfn "$ROOT/variant-${variant}/migrations" "$stage/migrations"
  # Changelog + thumbnail + README propres à la variante.
  [[ -e "variant-${variant}/changelog.txt" ]] && \
    ln -sfn "$ROOT/variant-${variant}/changelog.txt" "$stage/changelog.txt"
  [[ -e "variant-${variant}/thumbnail.png" ]] && \
    ln -sfn "$ROOT/variant-${variant}/thumbnail.png" "$stage/thumbnail.png"
  [[ -e "variant-${variant}/README.md" ]] && \
    ln -sfn "$ROOT/variant-${variant}/README.md" "$stage/README.md"

  # data.lua + info.json = GÉNÉRÉS (fichiers réels, jamais liés).
  cat > "$stage/data.lua" <<'LUA'
require("data-common")
require("data-variant")
LUA
  cp info.json "$stage/info.json"
  local base; base="$(mod_version "$variant")"
  # Résout gamever + base_min + offset depuis TARGETS selon le canal demandé, puis
  # dérive le semver (minor +offset) — même logique que package.
  local gamever base_min offset target
  for target in "${TARGETS[@]}"; do
    IFS=':' read -r gamever base_min offset <<<"$target"
    [[ "$gamever" == "$channel" ]] && break
  done
  local modver; modver="$(bump_minor "$base" "$offset")"
  rewrite_info "$stage/info.json" "$name" "$modver" "$gamever" "$base_min" "$variant"

  # Le dossier stage (rempli de liens) est lui-même symlinké dans mods/.
  rm -f "$mods/${name}_"*.zip
  ln -sfn "$stage" "$mods/$name"
  echo "Devlink : $mods/$name -> $stage (liens vers les sources)"
  echo "→ Édite une source, puis en jeu : /c game.reload_mods()  (control-stage)."
  echo "  Changement data-stage (prototypes/collision) : redémarrage complet requis."
}

unlink_dev() {
  local mods="$HOME/.factorio/mods"
  local variants=("${1:-}")
  [ -n "${1:-}" ] || variants=(bp stc)
  for variant in "${variants[@]}"; do
    local name; name="$(mod_name "$variant")"
    if [ -L "$mods/$name" ]; then
      rm -f "$mods/$name"; echo "Lien dev retiré : $mods/$name"
    fi
  done
}

case "${1:-package}" in
  package) package ;;
  link)    link_dev "${2:-}" ;;
  devlink) devlink "${2:-}" "${3:-2.0}" ;;
  unlink)  unlink_dev "${2:-}" ;;
  clean)   rm -rf "$DIST"; echo "dist/ supprimé." ;;
  *) echo "Usage: $0 {package|link {bp|stc}|devlink {bp|stc}|unlink [bp|stc]|clean}" >&2; exit 2 ;;
esac
