#!/bin/bash
# filepath: /Volumes/DEV/projects/script/build-based-hash-smart.sh

set -euo pipefail

# Configuration par défaut
SCRIPT_NAME="build-based-hash-smart.sh"
VERSION="1.0.0"
CACHE_DIR="$HOME/.m2/based-hashed"
GLOBAL_EXCLUDE_FILE="$CACHE_DIR/global-exclude.txt"
PROJECT_EXCLUDE_FILE=".build-exclude"
HASH_FILE="hashes.txt"
TEMP_HASH_FILE="temp-hashes.txt"
LOCK_FILE=".build.lock"

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Variables globales
PROJECT_PATH=""
PROJECT_NAME=""
PROJECT_CACHE_DIR=""
BUILD_START_TIME=""
TOTAL_SAVED_TIME=0
MODULES_INFO=()

# Fonction d'affichage avec couleurs
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_cached() {
    echo -e "${CYAN}[CACHED]${NC} $1"
}

log_built() {
    echo -e "${GREEN}[BUILT]${NC} $1"
}

# Fonction d'aide
show_help() {
    cat << EOF
${SCRIPT_NAME} v${VERSION}

Usage: ${SCRIPT_NAME} <project_path>

Description:
  Script intelligent pour builder des projets Maven avec cache basé sur le hash des fichiers sources.
  
Arguments:
  project_path    Chemin vers le projet Maven (simple ou multi-module)

Exemples:
  ${SCRIPT_NAME} /path/to/simple-project
  ${SCRIPT_NAME} /path/to/multi-module-project

Fichiers de configuration:
  ~/.m2/based-hashed/global-exclude.txt    Exclusions globales
  <projet>/.build-exclude                  Exclusions spécifiques au projet

EOF
}

# Validation des prérequis
check_prerequisites() {
    log_info "Vérification des prérequis..."
    
    # Vérifier Maven
    if ! command -v mvn &> /dev/null; then
        log_error "Maven n'est pas installé ou pas dans le PATH"
        exit 1
    fi
    
    # Vérifier Java
    if ! command -v java &> /dev/null; then
        log_error "Java n'est pas installé ou pas dans le PATH"
        exit 1
    fi
    
    # Vérifier les outils de hash selon l'OS
    if command -v sha256sum &> /dev/null; then
        HASH_CMD="sha256sum"
    elif command -v shasum &> /dev/null; then
        HASH_CMD="shasum -a 256"
    else
        log_error "Aucun outil de hash disponible (sha256sum ou shasum)"
        exit 1
    fi
    
    # Vérifier find
    if ! command -v find &> /dev/null; then
        log_error "La commande 'find' n'est pas disponible"
        exit 1
    fi
    
    log_success "Tous les prérequis sont satisfaits"
}

# Initialisation du cache
init_cache() {
    log_info "Initialisation du cache..."
    
    # Créer le répertoire de cache
    mkdir -p "$CACHE_DIR"
    
    # Créer le fichier d'exclusions globales s'il n'existe pas
    if [[ ! -f "$GLOBAL_EXCLUDE_FILE" ]]; then
        cat > "$GLOBAL_EXCLUDE_FILE" << 'EOF'
# Exclusions globales pour build-based-hash-smart
.idea/
.vscode/
.eclipse/
.mvn/
target/
*.class
.git/
.svn/
*.tmp
*.log
.DS_Store
Thumbs.db
EOF
        log_info "Fichier d'exclusions globales créé: $GLOBAL_EXCLUDE_FILE"
    fi
    
    # Créer le répertoire de cache du projet
    PROJECT_CACHE_DIR="$CACHE_DIR/$PROJECT_NAME"
    mkdir -p "$PROJECT_CACHE_DIR"
    
    log_success "Cache initialisé"
}

# Gestion des locks
acquire_lock() {
    local lock_file="$PROJECT_CACHE_DIR/$LOCK_FILE"
    local timeout=300 # 5 minutes
    local wait_time=0
    
    while [[ -f "$lock_file" ]]; do
        if [[ $wait_time -ge $timeout ]]; then
            log_error "Timeout: impossible d'acquérir le lock après ${timeout}s"
            exit 1
        fi
        
        log_warning "Build en cours sur ce projet, attente..."
        sleep 5
        wait_time=$((wait_time + 5))
    done
    
    echo $$ > "$lock_file"
    
    # Nettoyage du lock à la sortie
    trap "release_lock" EXIT INT TERM
}

release_lock() {
    local lock_file="$PROJECT_CACHE_DIR/$LOCK_FILE"
    [[ -f "$lock_file" ]] && rm -f "$lock_file"
}

# Construction des patterns d'exclusion
build_exclude_patterns() {
    local exclude_patterns=()
    
    # Exclusions globales
    if [[ -f "$GLOBAL_EXCLUDE_FILE" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" && ! "$line" =~ ^# ]] && exclude_patterns+=("$line")
        done < "$GLOBAL_EXCLUDE_FILE"
    fi
    
    # Exclusions du projet
    local project_exclude="$PROJECT_PATH/$PROJECT_EXCLUDE_FILE"
    if [[ -f "$project_exclude" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" && ! "$line" =~ ^# ]] && exclude_patterns+=("$line")
        done < "$project_exclude"
    fi
    
    # Intégration du .gitignore
    local gitignore="$PROJECT_PATH/.gitignore"
    if [[ -f "$gitignore" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" && ! "$line" =~ ^# ]] && exclude_patterns+=("$line")
        done < "$gitignore"
    fi
    
    printf '%s\n' "${exclude_patterns[@]}"
}

# Construction de la commande find avec exclusions
build_find_command() {
    local base_path="$1"
    local exclude_patterns
    exclude_patterns=$(build_exclude_patterns)
    
    local find_cmd="find \"$base_path\" -type f"
    
    # Ajouter les exclusions
    while IFS= read -r pattern; do
        [[ -n "$pattern" ]] && find_cmd+=" ! -path \"*/${pattern}*\""
    done <<< "$exclude_patterns"
    
    echo "$find_cmd"
}

# Calcul des hash des fichiers
calculate_hashes() {
    local target_dir="$1"
    local output_file="$2"
    
    log_info "Calcul des hash des fichiers dans $target_dir..."
    
    local find_cmd
    find_cmd=$(build_find_command "$target_dir")
    
    # Exécuter la commande find et calculer les hash
    eval "$find_cmd" | while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            local rel_path="${file#$PROJECT_PATH/}"
            local hash
            hash=$($HASH_CMD "$file" | cut -d' ' -f1)
            echo "$hash:$rel_path"
        fi
    done | sort > "$output_file"
}

# Comparaison des hash
compare_hashes() {
    local current_hash_file="$1"
    local cached_hash_file="$2"
    
    if [[ ! -f "$cached_hash_file" ]]; then
        log_info "Aucun cache trouvé, build nécessaire"
        return 1
    fi
    
    if ! diff -q "$current_hash_file" "$cached_hash_file" &> /dev/null; then
        log_info "Changements détectés, build nécessaire"
        return 1
    fi
    
    log_cached "Aucun changement détecté"
    return 0
}

# Détection du type de projet
detect_project_type() {
    local pom_files
    pom_files=$(find "$PROJECT_PATH" -name "pom.xml" -type f)
    local pom_count
    pom_count=$(echo "$pom_files" | wc -l)
    
    if [[ $pom_count -eq 1 && -f "$PROJECT_PATH/pom.xml" ]]; then
        echo "simple"
    elif [[ $pom_count -gt 1 ]]; then
        echo "multi-module"
    else
        log_error "Aucun fichier pom.xml trouvé ou structure invalide"
        exit 1
    fi
}

# Détection des modules Maven
detect_modules() {
    local modules=()
    
    # Lire les modules depuis le pom.xml parent
    if [[ -f "$PROJECT_PATH/pom.xml" ]]; then
        # Extraction simple des modules (peut être améliorée avec xmlstarlet si disponible)
        while IFS= read -r module; do
            [[ -n "$module" && -d "$PROJECT_PATH/$module" ]] && modules+=("$module")
        done < <(grep -oP '<module>\K[^<]+' "$PROJECT_PATH/pom.xml" 2>/dev/null || true)
    fi
    
    # Si aucun module trouvé via le pom, chercher tous les dossiers avec pom.xml
    if [[ ${#modules[@]} -eq 0 ]]; then
        while IFS= read -r pom_file; do
            local module_dir
            module_dir=$(dirname "${pom_file#$PROJECT_PATH/}")
            [[ "$module_dir" != "." ]] && modules+=("$module_dir")
        done < <(find "$PROJECT_PATH" -name "pom.xml" -not -path "$PROJECT_PATH/pom.xml")
    fi
    
    printf '%s\n' "${modules[@]}"
}

# Build d'un projet simple
build_simple_project() {
    local project_dir="$1"
    local start_time
    start_time=$(date +%s)
    
    log_info "Analyse du projet simple: $project_dir"
    
    local temp_hash_file="$PROJECT_CACHE_DIR/$TEMP_HASH_FILE"
    local cached_hash_file="$PROJECT_CACHE_DIR/$HASH_FILE"
    
    # Calculer les hash actuels
    calculate_hashes "$project_dir" "$temp_hash_file"
    
    # Comparer avec le cache
    if compare_hashes "$temp_hash_file" "$cached_hash_file"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_cached "Projet non modifié (${duration}s)"
        rm -f "$temp_hash_file"
        return 0
    fi
    
    # Build nécessaire
    log_info "Build du projet en cours..."
    
    cd "$project_dir"
    if mvn clean install -q; then
        # Sauvegarder le nouveau cache
        mv "$temp_hash_file" "$cached_hash_file"
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_built "Projet buildé avec succès (${duration}s)"
        return 0
    else
        log_error "Échec du build"
        rm -f "$temp_hash_file"
        return 1
    fi
}

# Build d'un module spécifique
build_module() {
    local module="$1"
    local module_path="$PROJECT_PATH/$module"
    local start_time
    start_time=$(date +%s)
    
    log_info "Analyse du module: $module"
    
    local module_cache_dir="$PROJECT_CACHE_DIR/modules/$module"
    mkdir -p "$module_cache_dir"
    
    local temp_hash_file="$module_cache_dir/$TEMP_HASH_FILE"
    local cached_hash_file="$module_cache_dir/$HASH_FILE"
    
    # Calculer les hash actuels du module
    calculate_hashes "$module_path" "$temp_hash_file"
    
    # Comparer avec le cache
    if compare_hashes "$temp_hash_file" "$cached_hash_file"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_cached "[$module] Aucun changement (${duration}s)"
        rm -f "$temp_hash_file"
        return 0
    fi
    
    # Build du module
    log_info "[$module] Build en cours..."
    
    cd "$PROJECT_PATH"
    if mvn clean install -pl "$module" -am -q; then
        # Sauvegarder le nouveau cache
        mv "$temp_hash_file" "$cached_hash_file"
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_built "[$module] Build réussi (${duration}s)"
        return 0
    else
        log_error "[$module] Échec du build"
        rm -f "$temp_hash_file"
        return 1
    fi
}

# Build d'un projet multi-module
build_multi_module_project() {
    log_info "Analyse du projet multi-module"
    
    local modules
    modules=$(detect_modules)
    
    if [[ -z "$modules" ]]; then
        log_warning "Aucun module détecté, traitement comme projet simple"
        build_simple_project "$PROJECT_PATH"
        return $?
    fi
    
    log_info "Modules détectés:"
    while IFS= read -r module; do
        log_info "  - $module"
    done <<< "$modules"
    
    local total_start_time
    total_start_time=$(date +%s)
    local modules_built=0
    local modules_cached=0
    local build_failed=false
    
    # Build de chaque module
    while IFS= read -r module; do
        if build_module "$module"; then
            # Vérifier si le module a été réellement buildé ou mis en cache
            if [[ -f "$PROJECT_CACHE_DIR/modules/$module/$HASH_FILE" ]]; then
                modules_built=$((modules_built + 1))
            else
                modules_cached=$((modules_cached + 1))
            fi
        else
            build_failed=true
            break
        fi
    done <<< "$modules"
    
    local total_end_time
    total_end_time=$(date +%s)
    local total_duration=$((total_end_time - total_start_time))
    
    if [[ "$build_failed" == "true" ]]; then
        log_error "Échec du build multi-module"
        return 1
    fi
    
    log_success "Build multi-module terminé:"
    log_success "  - Modules buildés: $modules_built"
    log_success "  - Modules en cache: $modules_cached"
    log_success "  - Temps total: ${total_duration}s"
    
    return 0
}

# Fonction principale
main() {
    BUILD_START_TIME=$(date +%s)
    
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}    ${CYAN}Build Based Hash Smart${NC} v${VERSION}            ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    echo
    
    # Vérification des arguments
    if [[ $# -ne 1 ]]; then
        show_help
        exit 1
    fi
    
    PROJECT_PATH=$(realpath "$1")
    PROJECT_NAME=$(basename "$PROJECT_PATH")
    
    # Vérification que le projet existe
    if [[ ! -d "$PROJECT_PATH" ]]; then
        log_error "Le répertoire $PROJECT_PATH n'existe pas"
        exit 1
    fi
    
    # Vérification qu'il s'agit d'un projet Maven
    if [[ ! -f "$PROJECT_PATH/pom.xml" ]]; then
        log_error "Aucun fichier pom.xml trouvé dans $PROJECT_PATH"
        exit 1
    fi
    
    log_info "Projet: $PROJECT_NAME"
    log_info "Chemin: $PROJECT_PATH"
    
    # Initialisation
    check_prerequisites
    init_cache
    acquire_lock
    
    # Détection du type de projet et build
    local project_type
    project_type=$(detect_project_type)
    log_info "Type de projet: $project_type"
    
    local build_success=false
    case "$project_type" in
        "simple")
            build_simple_project "$PROJECT_PATH" && build_success=true
            ;;
        "multi-module")
            build_multi_module_project && build_success=true
            ;;
        *)
            log_error "Type de projet non supporté: $project_type"
            exit 1
            ;;
    esac
    
    # Affichage du résumé final
    local build_end_time
    build_end_time=$(date +%s)
    local total_time=$((build_end_time - BUILD_START_TIME))
    
    echo
    if [[ "$build_success" == "true" ]]; then
        log_success "Build terminé avec succès en ${total_time}s"
    else
        log_error "Build échoué après ${total_time}s"
        exit 1
    fi
}

# Gestion des signaux
cleanup() {
    log_warning "Interruption détectée, nettoyage en cours..."
    release_lock
    exit 130
}

trap cleanup INT TERM

# Point d'entrée
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi