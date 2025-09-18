#!/usr/bin/env bash
###############################################################################
# Script : reorganize-file.sh
# Objectif : Réorganiser automatiquement les fichiers d'un projet selon
#            des bonnes pratiques de structuration (src, tests, docs, config...)
#
# Par défaut : dry-run (aucun déplacement réel)
#
# Règles par défaut (ext → dossier cible) :
#  Code      : .js .ts .mjs .cjs .jsx .tsx -> src/
#  Shell     : .sh -> scripts/
#  Python    : .py -> src/
#  Swift     : .swift -> src/
#  Markdown  : .md -> docs/
#  Texte     : .txt -> docs/
#  YAML/JSON : .yml .yaml .json -> config/
#  Env       : .env (et variantes) -> config/
#  Docker    : Dockerfile docker-compose.* -> docker/
#  SQL       : .sql -> db/
#  Images    : .png .jpg .jpeg .gif .svg .webp -> assets/images/
#  Archives  : .zip .tar .gz .tgz .bz2 .7z -> archives/
#  Logs      : .log -> logs/
#  Licence   : licence / license* -> . (inchangé)
#
# Options :
#  --apply             Effectuer réellement les déplacements
#  --dry-run           (défaut) Afficher les actions sans déplacer
#  -v, --verbose       Sortie détaillée
#  -i, --interactive   Confirmer chaque déplacement
#  -m, --mapping FILE  Fichier mapping personnalisé (format: EXT=target/dir)
#  -e, --exclude PATH  Exclure un chemin (peut être répété)
#      --only-ext LIST Limiter aux extensions listées (séparateur: ,)
#  -h, --help          Afficher l'aide
#
# Fichier mapping exemple :
#   js=frontend/js
#   css=frontend/css
#   png=assets/img
#   md=documents
#
# Sécurité : n'écrase pas un fichier existant (alerte et saute) sauf si
#            --force (TODO non implémenté volontairement)
###############################################################################
set -euo pipefail
IFS=$'\n\t'

DRY_RUN=1
VERBOSE=0
INTERACTIVE=0
MAPPING_FILE=""
declare -a EXCLUDES=()
ONLY_EXT_LIST=""
ROOT="${1-}" # premier argument positionnel éventuellement ignoré si option avant

usage() {
	sed -n '1,120p' "$0" | grep -v '^set -euo' | sed '/^$/q'
	cat <<'USAGE'
Utilisation : reorganize-file.sh [options] [dossier]

Options :
	--apply              Applique les déplacements (sinon dry-run)
	--dry-run            Force le mode simulation
	-v, --verbose        Plus de détails
	-i, --interactive    Confirmer chaque déplacement
	-m, --mapping FILE   Fichier de mapping personnalisé EXT=dir
	-e, --exclude PATH   Exclure un chemin (repeatable)
			--only-ext LIST  Limiter aux extensions (ex: js,ts,md)
	-h, --help           Aide

Exemple :
	reorganize-file.sh --apply --exclude node_modules --exclude .git
	reorganize-file.sh -m custom.map --only-ext js,ts,md
USAGE
}

log() { [[ $VERBOSE -eq 1 ]] && echo "$*" >&2; }

confirm() {
	if [[ $INTERACTIVE -eq 1 ]]; then
		read -r -p "$1 [y/N] " ans || ans=""
		[[ $ans =~ ^[Yy]$ ]] || return 1
	fi
	return 0
}

CUSTOM_MAP_FILE=""

load_default_map() { :; }

# lookup_map EXT -> directory (default set)
lookup_map() {
	case "$1" in
		js|ts|mjs|cjs|jsx|tsx|py|swift) echo src ;;
		sh) echo scripts ;;
		md|txt) echo docs ;;
		yml|yaml|json|env|env.local|env.example) echo config ;;
		sql) echo db ;;
		png|jpg|jpeg|gif|svg|webp) echo assets/images ;;
		zip|tar|gz|tgz|bz2|7z) echo archives ;;
		log) echo logs ;;
		*) echo '' ;;
	esac
}

apply_custom_map() {
	local file="$1"
	CUSTOM_MAP_FILE="$file"
}

custom_lookup() {
	local ext="$1"
	[[ -n $CUSTOM_MAP_FILE ]] || { lookup_map "$ext"; return; }
	local line k v
	while IFS='=' read -r k v; do
		[[ -z ${k// /} || $k == '#'* ]] && continue
		k="${k#.}"; v="${v%/}"
		if [[ $k == "$ext" ]]; then
			echo "$v"; return
		fi
	done < "$CUSTOM_MAP_FILE"
	lookup_map "$ext"
}

parse_args() {
	local positional=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--apply) DRY_RUN=0; shift;;
			--dry-run) DRY_RUN=1; shift;;
			-v|--verbose) VERBOSE=1; shift;;
			-i|--interactive) INTERACTIVE=1; shift;;
			-m|--mapping)
				MAPPING_FILE="${2-}"; [[ -z $MAPPING_FILE ]] && { echo "--mapping requiert un fichier" >&2; exit 2; }; shift 2;;
			--mapping=*) MAPPING_FILE="${1#*=}"; shift;;
			-e|--exclude)
				EXCLUDES+=("${2-}"); [[ -z ${2-} ]] && { echo "--exclude requiert un chemin" >&2; exit 2; }; shift 2;;
			--exclude=*) EXCLUDES+=("${1#*=}"); shift;;
			--only-ext) ONLY_EXT_LIST="${2-}"; [[ -z $ONLY_EXT_LIST ]] && { echo "--only-ext requiert une liste" >&2; exit 2; }; shift 2;;
			--only-ext=*) ONLY_EXT_LIST="${1#*=}"; shift;;
			-h|--help) usage; exit 0;;
			--) shift; break;;
			-*) echo "Option inconnue: $1" >&2; usage; exit 2;;
			*) positional+=("$1"); shift;;
		esac
	done
	if [[ ${#positional[@]} -gt 0 ]]; then
		ROOT="${positional[0]}"
	else
		ROOT="${ROOT:-.}"
	fi
}

is_excluded() {
	local p="$1"
	for ex in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
		[[ $p == *"$ex"* ]] && return 0
	done
	return 1
}

should_limit_ext() { [[ -n $ONLY_EXT_LIST ]]; }

ext_in_only_list() {
	local e="$1"; [[ ",$ONLY_EXT_LIST," == *",$e,"* ]] || return 1
	return 0
}

target_dir_for() {
	local f="$1" base ext
	base="${f##*/}"
	case "$base" in
		Dockerfile|docker-compose.*) echo docker; return 0;;
		license|LICENSE|LICENCE|licence*) echo .; return 0;;
	esac
	ext="${base##*.}"
	[[ $base == *.* ]] || { echo ''; return 0; } # aucun point
	# gérer variantes .env.*
	if [[ $base == .env || $base == .env.* ]]; then echo config; return 0; fi
	# extension composite .env.local déjà traitée ci-dessus
		custom_lookup "$ext"
}

plan_moves() {
	local file rel tgt dest
	while IFS= read -r -d '' file; do
		rel="${file#$ROOT/}"
		is_excluded "$rel" && continue
		# Traiter aussi certains dossiers (images, docs isolés etc.)
		if [[ -d $file ]]; then
			case "$rel" in
				images|img)
					# déplacer tout le dossier vers assets/images (si pas déjà dedans)
					[[ $rel == assets/images* ]] && continue
					tgt="assets/images"
					dest="$ROOT/$tgt"
					echo "$file|$dest" 
					continue;;
				documentation)
					[[ $rel == docs* ]] && continue
					tgt="docs"
					dest="$ROOT/$tgt/$rel" # merge inside docs
					echo "$file|$dest"
					continue;;
				test|tests)
					[[ $rel == tests* ]] && continue
					tgt="tests"
					dest="$ROOT/$tgt"
					echo "$file|$dest"
					continue;;
			esac
		fi
		[[ -f $file ]] || continue
		# ignorer déjà dans dossiers cibles connus
		[[ $rel == src/* || $rel == docs/* || $rel == config/* || $rel == scripts/* || $rel == assets/* || $rel == logs/* || $rel == docker/* || $rel == db/* || $rel == archives/* ]] && continue
		tgt=$(target_dir_for "$rel")
		[[ -z $tgt ]] && continue
		if should_limit_ext; then
			ext="${rel##*.}"; ext_in_only_list "$ext" || continue
		fi
		dest="$ROOT/$tgt/$rel"
		# dest final = dossier cible + chemin relatif (sans sous-rép additionnels?) -> on stocke juste sous dossier cible même nom fichier
		dest="$ROOT/$tgt/${rel##*/}"
		echo "$file|$dest"
	done < <(find "$ROOT" -mindepth 1 -maxdepth 8 -type f -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/dist/*' -print0)
}

execute_moves() {
	local line src dest dir
	local total=0 done=0 skipped=0
	while IFS= read -r line; do
		((total++)) || true
		src="${line%%|*}"; dest="${line#*|}"; dir="${dest%/*}"
		[[ -e $src ]] || { log "Source disparue: $src"; ((skipped++)); continue; }
		[[ -e $dest ]] && { echo "SKIP (existe) : $dest"; ((skipped++)); continue; }
		if ! confirm "Déplacer $src -> $dest"; then
			echo "SKIP (refus) : $src"; ((skipped++)); continue
		fi
		if [[ $DRY_RUN -eq 1 ]]; then
			echo "DRY  $src -> $dest"
			((done++))
		else
			mkdir -p "$dir"
			mv "$src" "$dest"
			echo "MOVE $src -> $dest"
			((done++))
		fi
	done
	echo "Résumé: $done déplacé(s), $skipped ignoré(s), total planifié $total" >&2
}

main() {
	parse_args "$@"
	[[ -d $ROOT ]] || { echo "Dossier cible introuvable: $ROOT" >&2; exit 2; }
		load_default_map
		[[ -n $MAPPING_FILE ]] && apply_custom_map "$MAPPING_FILE"
	log "Racine: $ROOT"
	log "Mode: $([[ $DRY_RUN -eq 1 ]] && echo DRY-RUN || echo APPLY)"
		# Afficher exclusions seulement si définies
		if [[ ${EXCLUDES+x} ]] && [[ ${#EXCLUDES[@]} -gt 0 ]]; then
			log "Exclusions: ${EXCLUDES[*]}"
		fi
	[[ -n $ONLY_EXT_LIST ]] && log "Extensions limitées: $ONLY_EXT_LIST"
	plan_moves | execute_moves
	if [[ $DRY_RUN -eq 1 ]]; then
		echo "(Simulation terminée. Relancer avec --apply pour appliquer.)" >&2
	fi
}

main "$@"

