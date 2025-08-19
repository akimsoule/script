#!/bin/bash
set -euo pipefail

# Répertoire où on garde le cache
CONFIG_DIR=".maven-config"
CACHE_FILE="$CONFIG_DIR/dependency-tree.txt"

mkdir -p "$CONFIG_DIR"

# --- 1. Génération du dependency:tree si inexistant ---
if [[ ! -f "$CACHE_FILE" ]]; then
  echo ">> Génération initiale du dependency:tree"
  mvn dependency:tree -DoutputFile="$CACHE_FILE" -DoutputType=text
fi

# --- 2. Vérification des modules modifiés ---
echo ">> Détection des modules modifiés"
CHANGED_MODULES=$(mvn -q -pl . help:evaluate -Dexpression=project.modules | grep -v '^\[')

TO_BUILD=()

for module in $CHANGED_MODULES; do
  if git diff --quiet HEAD~1 HEAD -- "$module"; then
    echo "   - $module : pas de changement"
  else
    echo "   - $module : changé"
    TO_BUILD+=("$module")
  fi
done

# --- 3. Construction des modules concernés ---
if [[ ${#TO_BUILD[@]} -eq 0 ]]; then
  echo ">> Aucun module à recompiler"
else
  echo ">> Compilation des modules impactés : ${TO_BUILD[*]}"
  mvn clean install -pl "${TO_BUILD[*]}" -am -amd
fi