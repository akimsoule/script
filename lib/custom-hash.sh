#!/bin/bash
set -euo pipefail

# Vérification des arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <chemin_module> <fichier_sortie>"
    exit 1
fi

MODULE_PATH="$1"
OUTPUT_FILE="$2"

# Vérification du chemin du module
if [ ! -d "$MODULE_PATH" ]; then
    echo "Le répertoire du module n'existe pas: $MODULE_PATH"
    exit 1
fi

# Détection de l'outil de hash
HASH_CMD=""
if command -v sha256sum &> /dev/null; then
    HASH_CMD="sha256sum"
elif command -v shasum &> /dev/null; then
    HASH_CMD="shasum -a 256"
else
    echo "Aucun outil de hash disponible (sha256sum ou shasum)"
    exit 1
fi

# Initialisation du tableau des exclusions
EXCLUSIONS=(
    "target/"
    ".git/"
    ".idea/"
    ".vscode/"
    "*.class"
    "*.jar"
    "*/node_modules/*"
    "*.js"
    "*.css"
    "*.html"
)
FIND_CMD="find \"$MODULE_PATH\" -type f"

# Ajout des exclusions à la commande find
for excl in "${EXCLUSIONS[@]}"; do
    FIND_CMD="$FIND_CMD ! -path \"*/$excl*\""
done

# Calcul des hash des fichiers
echo "Calcul des hash pour: $MODULE_PATH"

# Calcul des hash pour chaque fichier et écriture directe dans le fichier de sortie
eval "$FIND_CMD" | while read -r file; do
    if [ -f "$file" ]; then
        rel_path="${file#$MODULE_PATH/}"
        hash=$($HASH_CMD "$file" | cut -d' ' -f1)
        echo "hash:$hash:$rel_path"
    fi
done | sort > "$OUTPUT_FILE"

# echo "Hash calculés et sauvegardés dans: $OUTPUT_FILE"
