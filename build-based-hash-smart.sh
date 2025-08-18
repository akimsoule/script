#!/bin/bash
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 /chemin/vers/projet"
  exit 1
fi

PROJECT_DIR="$1"
HASH_DIR="$HOME/based-hashed/$(basename "$PROJECT_DIR")"
HASH_FILE="$HASH_DIR/hashes.txt"
BUILD_DIR="$PROJECT_DIR/build"
TARGET_DIR="$PROJECT_DIR/target"

mkdir -p "$HASH_DIR" "$BUILD_DIR"

# Nettoyer target
[ -d "$TARGET_DIR" ] && rm -rf "$TARGET_DIR"

# Fonction pour trouver le module racine
get_module() {
    local file="$1"
    local dir=$(dirname "$file")
    while [ "$dir" != "$PROJECT_DIR" ] && [ ! -f "$dir/pom.xml" ]; do
        dir=$(dirname "$dir")
    done
    echo "${dir#$PROJECT_DIR/}"
}

# Détecter fichiers modifiés par hash
MODIFIED_FILES="$BUILD_DIR/modified_files.txt"
> "$MODIFIED_FILES"

if [ ! -f "$HASH_FILE" ]; then
    find "$PROJECT_DIR" -type f \( -name "*.java" -o -name "*.xml" -o -name "*.properties" \) > "$MODIFIED_FILES"
else
    declare -A OLD_HASHES
    while read -r line; do
        HASH=$(echo "$line" | awk '{print $1}')
        FILE=$(echo "$line" | awk '{print $2}')
        OLD_HASHES["$FILE"]=$HASH
    done < "$HASH_FILE"

    find "$PROJECT_DIR" -type f \( -name "*.java" -o -name "*.xml" -o -name "*.properties" \) | while read file; do
        HASH=$(md5sum "$file" | awk '{print $1}')
        OLD_HASH=${OLD_HASHES["$file"]}
        [ "$HASH" != "$OLD_HASH" ] && echo "$file" >> "$MODIFIED_FILES"
    done
fi

[ ! -s "$MODIFIED_FILES" ] && echo "Aucun fichier modifié. Build ignoré." && exit 0

# Déterminer modules modifiés
MODIFIED_MODULES=()
while read -r file; do
    module=$(get_module "$file")
    [ -n "$module" ] && MODIFIED_MODULES+=("$module")
done < "$MODIFIED_FILES"
MODIFIED_MODULES=($(printf "%s\n" "${MODIFIED_MODULES[@]}" | sort -u))

# Construire map des dépendances avec une seule commande Maven
echo "Construction de la map des dépendances..."
DEP_TREE_FILE="$BUILD_DIR/dependency_tree.txt"
mvn dependency:tree -DoutputType=dot -q > "$DEP_TREE_FILE"

declare -A DEP_MAP
while read -r line; do
    if [[ "$line" =~ "->" ]]; then
        parent=$(echo "$line" | awk '{print $1}')
        child=$(echo "$line" | awk '{print $2}' | sed 's/;//g')
        DEP_MAP["$child"]+="$parent "
    fi
done < "$DEP_TREE_FILE"

# Modules -am : modifiés + leurs dépendants
AM_MODULES=("${MODIFIED_MODULES[@]}")

# Ajouter tous les modules dépendants
queue=("${MODIFIED_MODULES[@]}")
while [ ${#queue[@]} -gt 0 ]; do
    current="${queue[0]}"
    queue=("${queue[@]:1}")
    for mod in ${DEP_MAP[$current]}; do
        [[ " ${AM_MODULES[*]} " =~ " $mod " ]] && continue
        AM_MODULES+=("$mod")
        queue+=("$mod")
    done
done

# Supprimer doublons
AM_MODULES=($(printf "%s\n" "${AM_MODULES[@]}" | sort -u))

# Modules -amd : non modifiés mais dépendances changées
ALL_MODULES=$(find "$PROJECT_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
AMD_MODULES=()
for mod in $ALL_MODULES; do
    [[ " ${AM_MODULES[*]} " =~ " $mod " ]] && continue
    for dep in ${DEP_MAP[$mod]}; do
        [[ " ${AM_MODULES[*]} " =~ " $dep " ]] && { AMD_MODULES+=("$mod"); break; }
    done
done
AMD_MODULES=($(printf "%s\n" "${AMD_MODULES[@]}" | sort -u))

# Calculer hash pour cache
FILES_HASH_TEMP="$BUILD_DIR/files_hash_temp.txt"
> "$FILES_HASH_TEMP"
find "$PROJECT_DIR" -type f \( -name "*.java" -o -name "*.xml" -o -name "*.properties" \) | while read file; do
    md5sum "$file" >> "$FILES_HASH_TEMP"
done
cp "$FILES_HASH_TEMP" "$HASH_FILE"

# Build Maven avec log détaillé
declare -A MODULE_ACTION

# Modules -am
if [ ${#AM_MODULES[@]} -gt 0 ]; then
    AM_MODULES_STR=$(IFS=, ; echo "${AM_MODULES[*]}")
    echo "Build modules modifiés (-am) : $AM_MODULES_STR"
    mvn install -pl "$AM_MODULES_STR" -am -DskipTests
    for mod in "${AM_MODULES[@]}"; do
        MODULE_ACTION["$mod"]="-am (modifié ou dépendant)"
    done
fi

# Modules -amd
if [ ${#AMD_MODULES[@]} -gt 0 ]; then
    AMD_MODULES_STR=$(IFS=, ; echo "${AMD_MODULES[*]}")
    echo "Build modules dépendants (-amd) : $AMD_MODULES_STR"
    mvn install -pl "$AMD_MODULES_STR" -amd -DskipTests
    for mod in "${AMD_MODULES[@]}"; do
        MODULE_ACTION["$mod"]="-amd (dépendance changée)"
    done
fi

# Log final : tableau clair des modules rebuildés
echo
echo "==========================================="
echo "Résumé du build :"
printf "%-25s %-30s\n" "Module" "Action"
echo "-------------------------------------------"
for mod in "${!MODULE_ACTION[@]}"; do
    printf "%-25s %-30s\n" "$mod" "${MODULE_ACTION[$mod]}"
done
echo "==========================================="

# Nettoyage
rm -rf "$BUILD_DIR"
echo "Build terminé !"
