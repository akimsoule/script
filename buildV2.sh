#!/bin/bash
set -euo pipefail

# Définition des couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# Configuration initiale
CACHE_DIR="$HOME/.m2/maven-config"

# Configuration du logging
LOG_FILE="$CACHE_DIR/logs/build-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"

# Fonctions de logging
log() {
    local level=$1
    local message=$2
    local color=$3
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${GRAY}${timestamp}${NC} ${color}${level}${NC} $message" | tee -a "$LOG_FILE"
}

info() {
    log "INFO   " "$1" "$BLUE"
}

warn() {
    log "WARNING" "$1" "$YELLOW"
}

error() {
    log "ERROR  " "$1" "$RED"
}

success() {
    log "SUCCESS" "$1" "$GREEN"
}

debug() {
    if [ "${DEBUG:-false}" = "true" ]; then
        log "DEBUG  " "$1" "$CYAN"
    fi
}

SCRIPT_DIR="$(dirname "$0")"

info "Démarrage du script de build..."
debug "Répertoire du script: $SCRIPT_DIR"

# Fonction pour afficher le temps d'exécution
show_execution_time() {
    local end_time=$1
    local start_time=$2
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    echo -e "${BLUE}Temps d'exécution : ${minutes}m ${seconds}s${NC}"
}

# Enregistrer le temps de début
start_time=$(date +%s)
# Vérification des arguments
PROJECT_DIR="${1:-}"
if [ -z "$PROJECT_DIR" ]; then
    error "Aucun répertoire de projet spécifié"
    error "Usage : $0 <project-dir>"
    exit 1
fi

# Vérification de l'existence du projet
if [ ! -d "$PROJECT_DIR" ]; then
    error "Le répertoire du projet n'existe pas : $PROJECT_DIR"
    exit 1
fi

info "Validation du projet : $PROJECT_DIR"

# Configuration initiale
PROJECT_NAME=$(mvn -q -pl . help:evaluate -Dexpression=project.artifactId -DforceStdout)
MAVEN_DEPENDENCY_TREE_FILE="$CACHE_DIR/$PROJECT_NAME/dependency-tree.txt"

mkdir -p "$CACHE_DIR/$PROJECT_NAME"

# Obtenir l'arbre des dépendances si nécessaire
if [ ! -f "$MAVEN_DEPENDENCY_TREE_FILE" ]; then
    warn "Le fichier de l'arbre des dépendances n'existe pas : $MAVEN_DEPENDENCY_TREE_FILE"
    info "Génération de l'arbre des dépendances..."
    mvn dependency:tree | tee "$MAVEN_DEPENDENCY_TREE_FILE"
    success "Arbre des dépendances généré avec succès"
fi

# Cache des fichiers pom.xml et leurs artifactIds
POM_CACHE=""
info "Mise en cache des informations des modules..."
while IFS= read -r pomPath; do
    dirPath=$(dirname "$pomPath")
    if [ -f "$pomPath" ]; then
        artifactId=$(awk '/<artifactId>/{i++} i==2{gsub(/<\/?artifactId>/,""); gsub(/^[ \t]+|[ \t]+$/,""); print; exit}' "$pomPath")
        if [ -n "$artifactId" ]; then
            POM_CACHE+="$artifactId:${dirPath#./}"$'\n'
        fi
    fi
done < <(cd "$PROJECT_DIR" && find . -type f -name "pom.xml")

# Fonction de calcul de hash
calculate_module_hash() {
    local MODULE_PATH="$1"
    local OUTPUT_FILE="$2"

    # Vérification du chemin du module
    if [ ! -d "$MODULE_PATH" ]; then
        error "Le répertoire du module n'existe pas: $MODULE_PATH"
        return 1
    fi

    # Détection de l'outil de hash
    local HASH_CMD=""
    if command -v sha256sum &> /dev/null; then
        HASH_CMD="sha256sum"
        debug "Utilisation de sha256sum pour le calcul des hash"
    elif command -v shasum &> /dev/null; then
        HASH_CMD="shasum -a 256"
        debug "Utilisation de shasum pour le calcul des hash"
    else
        error "Aucun outil de hash disponible (sha256sum ou shasum)"
        return 1
    fi

    # Initialisation du tableau des exclusions
    local EXCLUSIONS=(
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

    # Construction de la commande find avec exclusions
    local FIND_CMD="find \"$MODULE_PATH\" -type f"
    for excl in "${EXCLUSIONS[@]}"; do
        FIND_CMD="$FIND_CMD ! -path \"*/$excl*\""
    done

    # Calcul des hash des fichiers
    info "Calcul des hash pour: $MODULE_PATH"
    eval "$FIND_CMD" | while read -r file; do
        if [ -f "$file" ]; then
            local rel_path="${file#$MODULE_PATH/}"
            local hash=$($HASH_CMD "$file" | cut -d' ' -f1)
            debug "Hash calculé pour $rel_path: $hash"
            echo "hash:$hash:$rel_path"
        fi
    done | sort > "$OUTPUT_FILE"
    success "Hash calculés avec succès pour $MODULE_PATH"
}

# Extraction des artifacts des modules du projet
MODULE_ARTIFACTS=$(sed -n 's/.* @ \([^[:space:]]*\) ---.*/\1/p' "$MAVEN_DEPENDENCY_TREE_FILE" | sort -u)

# Préparation de la liste des modules avec leur profondeur
MODULE_PATH_DEPTH=$(for artifact in $MODULE_ARTIFACTS; do
    if echo "$POM_CACHE" | grep -q "^$artifact:"; then
        path=$(echo "$POM_CACHE" | grep "^$artifact:" | cut -d':' -f2)
        depth=$(echo "$path" | tr -cd '/' | wc -c)
        echo "dep:$artifact:$PROJECT_DIR/$path:$depth"
    fi
done | sort -t: -k4 -n | sed 's/^dep://')

# Pour chaque module, calculer le hash des fichiers
build_needed=false

while IFS=':' read -r module path depth; do
    if [ -d "$path" ]; then
        HASH_OUTPUT="$CACHE_DIR/$module/hash.txt"
        NEW_HASH_OUTPUT="$CACHE_DIR/$module/hash.new.txt"
        mkdir -p "$(dirname "$HASH_OUTPUT")"

        # Si HASH_OUTPUT n'existe pas, on le crée
        if [ ! -f "$HASH_OUTPUT" ]; then
            calculate_module_hash "$path" "$HASH_OUTPUT"
        else
            # Créer le nouveau hash
            calculate_module_hash "$path" "$NEW_HASH_OUTPUT"
            # Faire la comparaison
            # Si les deux hash sont les mêmes
            if diff -q "$HASH_OUTPUT" "$NEW_HASH_OUTPUT" > /dev/null; then
                success "Module '$module' : Aucun changement détecté"
                rm -f "$NEW_HASH_OUTPUT"
                debug "Suppression du fichier temporaire de hash : $NEW_HASH_OUTPUT"
            else
                mv "$NEW_HASH_OUTPUT" "$HASH_OUTPUT"
                warn "Module '$module' : Changements détectés"
                build_needed=true
            fi
        fi
    fi
done <<< "$MODULE_PATH_DEPTH"

# Afficher le temps d'exécution et le résumé
end_time=$(date +%s)
show_execution_time $end_time $start_time

if [ "$build_needed" = true ]; then
    warn "Des changements ont été détectés dans certains modules"
else
    success "Aucun changement détecté dans l'ensemble du projet"
fi

info "Les logs complets sont disponibles dans : $LOG_FILE"