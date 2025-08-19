#!/bin/bash
# filepath: /Volumes/DEV/projects/script/build-based-hash-smart.sh

set -euo pipefail

# Configuration par défaut
SCRIPT_NAME="build-based-hash-smart.sh"
VERSION="1.1.4-timeout-protection"
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
FORCE_BUILD=false
MODULE_SIZES=() # Tableau associatif pour stocker la taille de chaque module

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

Usage: ${SCRIPT_NAME} [options] <project_path>

Description:
  Script intelligent pour builder des projets Maven avec cache basé sur le hash des fichiers sources.
  Les petits modules et ceux dont dépendent d'autres modules sont buildés en priorité.
  
Arguments:
  project_path    Chemin vers le projet Maven (simple ou multi-module)

Options:
  --force         Force le build même si aucun changement n'est détecté

Exemples:
  ${SCRIPT_NAME} /path/to/simple-project
  ${SCRIPT_NAME} --force /path/to/multi-module-project

Fichiers de configuration:
  ~/.m2/based-hashed/global-exclude.txt    Exclusions globales
  <projet>/.build-exclude                  Exclusions spécifiques au projet

EOF
}

# Détection du système d'exploitation
detect_os() {
    local os_name
    if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
        os_name="Windows (Git Bash)"
    elif [[ "$(uname -s)" == Darwin* ]]; then
        os_name="macOS"
    elif [[ "$(uname -s)" == Linux* ]]; then
        os_name="Linux"
    else
        os_name="Inconnu"
    fi
    echo "$os_name"
}

# Validation des prérequis
check_prerequisites() {
    log_info "Vérification des prérequis..."
    
    # Détecter l'OS
    local os_name
    os_name=$(detect_os)
    log_info "Système d'exploitation détecté: $os_name"
    
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
    
    # Vérifier timeout (disponible par défaut sur la plupart des systèmes Unix modernes)
    if ! command -v timeout &> /dev/null; then
        log_warning "La commande 'timeout' n'est pas disponible, certaines protections anti-blocage seront désactivées"
        # Créer une fonction de remplacement simple qui exécute la commande sans timeout
        timeout() {
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                shift # Ignorer le premier argument (le timeout)
            fi
            "$@" # Exécuter la commande sans timeout
        }
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

# Fonction pour vérifier si un processus existe (compatible Windows/Git Bash)
process_exists() {
    local pid=$1
    
    # Sous Windows/Git Bash, ps ne fonctionne pas de la même façon
    if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
        # Approche Windows/Git Bash
        tasklist.exe 2>/dev/null | grep -q "$pid"
        return $?
    else
        # Approche Unix/Linux/macOS
        ps -p "$pid" &>/dev/null
        return $?
    fi
}

# Gestion des locks
acquire_lock() {
    local lock_file="$PROJECT_CACHE_DIR/$LOCK_FILE"
    local timeout=300 # 5 minutes
    local wait_time=0
    
    while [[ -f "$lock_file" ]]; do
        local pid
        pid=$(cat "$lock_file" 2>/dev/null || echo "")
        
        # Si le PID du lock n'existe plus, on peut supprimer le lock
        if [[ -n "$pid" ]] && ! process_exists "$pid"; then
            log_warning "Lock trouvé mais processus $pid inactif, suppression du lock"
            rm -f "$lock_file"
            break
        fi
        
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

# Fonction pour nettoyer les chemins (/ et \ selon l'OS)
normalize_path() {
    local path="$1"
    if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
        # Sur Windows, remplacer / par \
        echo "${path//\//\\}"
    else
        # Sur Unix, garder /
        echo "$path"
    fi
}

# Construction de la commande find avec exclusions
build_find_command() {
    local base_path="$1"
    local exclude_patterns
    exclude_patterns=$(build_exclude_patterns)
    
    local find_cmd="find \"$base_path\" -type f"
    
    # Ajouter les exclusions
    while IFS= read -r pattern; do
        if [[ -n "$pattern" ]]; then
            # Échapper les caractères spéciaux dans le pattern pour éviter les erreurs
            local escaped_pattern
            escaped_pattern=$(echo "$pattern" | sed 's/[][()\.^$?*+]/\\&/g')
            find_cmd+=" ! -path \"*/${escaped_pattern}*\""
        fi
    done <<< "$exclude_patterns"
    
    echo "$find_cmd"
}

# Calcul des hash des fichiers
calculate_hashes() {
    local target_dir="$1"
    local output_file="$2"
    
    log_info "Calcul des hash des fichiers dans $target_dir..."
    
    # Ajouter une limite de temps pour éviter les blocages
    local timeout=300 # 5 minutes
    
    # Créer un fichier temporaire pour stocker les résultats intermédiaires
    local temp_output=$(mktemp)
    
    # Construire la commande find
    local find_cmd
    find_cmd=$(build_find_command "$target_dir")
    
    # Exécuter la commande find avec timeout et gérer les erreurs
    local find_result=""
    find_result=$(eval "timeout $timeout $find_cmd" 2>/dev/null || echo "")
    
    if [[ $? -eq 124 ]]; then
        log_warning "Calcul des hash interrompu après $timeout secondes pour $target_dir (trop de fichiers)"
        echo "timeout:$target_dir/TIMEOUT" > "$output_file"
        return 0
    fi
    
    # Traiter chaque fichier trouvé
    echo "$find_result" | while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            # Toujours utiliser des séparateurs / dans les chemins relatifs (pour compatibilité)
            local rel_path
            rel_path=$(echo "${file#$PROJECT_PATH/}" | sed 's/\\/\//g')
            
            # Calculer le hash du fichier avec timeout pour éviter les blocages sur les gros fichiers
            local hash
            hash=$(timeout 10 $HASH_CMD "$file" 2>/dev/null | cut -d' ' -f1 || echo "timeout")
            
            if [[ "$hash" == "timeout" || -z "$hash" ]]; then
                # Si le calcul du hash prend trop de temps, utiliser la taille et le nom du fichier à la place
                local size=$(stat -f "%z" "$file" 2>/dev/null || stat -c "%s" "$file" 2>/dev/null || echo "0")
                hash="size${size}_$(basename "$file")"
            fi
            
            echo "$hash:$rel_path" >> "$temp_output"
        fi
    done
    
    # Trier et finaliser le résultat
    sort "$temp_output" > "$output_file"
    rm -f "$temp_output"
}

# Comparaison des hash
compare_hashes() {
    local current_hash_file="$1"
    local cached_hash_file="$2"
    local max_files=10 # Nombre maximum de fichiers à afficher
    
    # Si l'option --force est activée, toujours indiquer un build nécessaire
    if [[ "$FORCE_BUILD" == "true" ]]; then
        log_warning "Option --force activée, build forcé"
        return 1
    fi
    
    if [[ ! -f "$cached_hash_file" ]]; then
        log_info "Aucun cache trouvé, build nécessaire"
        return 1
    fi
    
    # Vérifier si le calcul des hash a été interrompu par timeout
    if grep -q "^timeout:" "$current_hash_file"; then
        log_warning "Calcul des hash interrompu par timeout, on considère qu'un build est nécessaire"
        return 1
    fi
    
    # Utiliser diff pour trouver les différences et les stocker
    local diff_output
    if ! diff_output=$(diff "$current_hash_file" "$cached_hash_file" 2>/dev/null); then
        log_info "Changements détectés, build nécessaire"
        
        # Extraire les lignes ajoutées (fichiers modifiés ou ajoutés)
        local changed_files=()
        local file_count=0
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^[\>\<] ]]; then
                # Extraire le nom du fichier (après le ':')
                local file_path=$(echo "$line" | cut -d':' -f2-)
                if [[ -n "$file_path" ]]; then
                    changed_files+=("$file_path")
                    file_count=$((file_count + 1))
                    
                    if [[ $file_count -ge $max_files ]]; then
                        break
                    fi
                fi
            fi
        done <<< "$diff_output"
        
        # Afficher les fichiers modifiés
        if [[ ${#changed_files[@]} -gt 0 ]]; then
            log_warning "Fichiers modifiés (max $max_files affichés):"
            for file in "${changed_files[@]}"; do
                log_warning "  - $file"
            done
            
            if [[ $file_count -ge $max_files ]]; then
                local total_changes=$(echo "$diff_output" | grep -E '^[\>\<]' | wc -l)
                local remaining=$((total_changes - max_files))
                if [[ $remaining -gt 0 ]]; then
                    log_warning "  ... et $remaining autres fichiers"
                fi
            fi
        fi
        
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
    local temp_modules_file=$(mktemp)
    
    # Lire les modules depuis le pom.xml parent
    if [[ -f "$PROJECT_PATH/pom.xml" ]]; then
        # Extraction des modules compatible avec tous les grep
        local module_lines
        module_lines=$(grep -o '<module>[^<]*</module>' "$PROJECT_PATH/pom.xml" 2>/dev/null || echo "")
        if [[ -n "$module_lines" ]]; then
            echo "$module_lines" | while IFS= read -r line; do
                local module
                module=$(echo "$line" | sed -E 's/<module>(.*)<\/module>/\1/')
                # Vérifier que le module existe et contient un pom.xml
                if [[ -n "$module" && -d "$PROJECT_PATH/$module" && -f "$PROJECT_PATH/$module/pom.xml" ]]; then
                    echo "$module" >> "$temp_modules_file"
                fi
            done
        fi
    fi
    
    # Si aucun module trouvé via le pom, chercher tous les dossiers avec pom.xml
    if [[ ! -s "$temp_modules_file" ]]; then
        find "$PROJECT_PATH" -name "pom.xml" -not -path "$PROJECT_PATH/pom.xml" | while IFS= read -r pom_file; do
            local module_dir
            module_dir=$(dirname "${pom_file#$PROJECT_PATH/}")
            if [[ "$module_dir" != "." ]]; then
                echo "$module_dir" >> "$temp_modules_file"
            fi
        done
    fi
    
    # Sortir le contenu du fichier et le nettoyer
    cat "$temp_modules_file" | sort -u
    rm -f "$temp_modules_file"
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
    
    # Les changements sont déjà affichés par compare_hashes
    
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
    
    # Vérifier que le module existe
    if [[ ! -d "$module_path" || ! -f "$module_path/pom.xml" ]]; then
        log_warning "Le module '$module' n'existe pas ou n'est pas un module Maven valide, ignoré"
        return 0
    fi
    
    log_info "Analyse du module: $module"
    
    local module_cache_dir="$CACHE_DIR/$module"
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
    
    # Les changements sont déjà affichés par compare_hashes
    
    # Build du module
    log_info "[$module] Build en cours..."
    
    cd "$PROJECT_PATH"
    
    # Utiliser le chemin absolu du pom.xml au lieu du nom du module
    local module_pom="$module_path/pom.xml"
    log_info "[$module] Utilisation du POM: $module_pom"
    
    # Ajouter un timeout pour éviter les blocages
    local timeout=1800 # 30 minutes max par module
    if timeout $timeout mvn clean install -f "$module_pom" -am -q; then
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
    
    # Trier les modules par taille (du plus petit au plus grand)
    log_info "Tri des modules par taille pour une optimisation du build..."
    
    # Capturer la sortie dans une variable temporaire
    local temp_sorted_file=$(mktemp)
    calculate_module_sizes "$modules" > "$temp_sorted_file"
    
    # Filtrer les modules valides
    local valid_modules_file=$(mktemp)
    while IFS= read -r module; do
        # Vérifier si le module existe
        if [[ -d "$PROJECT_PATH/$module" || -f "$PROJECT_PATH/$module" ]]; then
            echo "$module" >> "$valid_modules_file"
        fi
    done < "$temp_sorted_file"
    
    # Lire les modules valides
    local sorted_modules
    sorted_modules=$(<"$valid_modules_file")
    
    # Afficher l'ordre de build optimisé
    log_info "Ordre de build optimisé (du plus petit au plus grand):"
    while IFS= read -r module; do
        log_info "  - $module"
    done <<< "$sorted_modules"
    
    # Nettoyer les fichiers temporaires
    rm -f "$temp_sorted_file" "$valid_modules_file"
    
    local total_start_time
    total_start_time=$(date +%s)
    local modules_built=0
    local modules_cached=0
    local build_failed=false
    
    # Build de chaque module dans l'ordre optimisé
    while IFS= read -r module; do
        if build_module "$module"; then
            # Vérifier si le module a été réellement buildé ou mis en cache
            if [[ -f "$CACHE_DIR/$module/$HASH_FILE" ]]; then
                modules_built=$((modules_built + 1))
            else
                modules_cached=$((modules_cached + 1))
            fi
        else
            build_failed=true
            break
        fi
    done <<< "$sorted_modules"
    
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

# Fonction realpath compatible avec Windows/Git Bash
realpath_portable() {
    local path="$1"
    # Si realpath est disponible, l'utiliser
    if command -v realpath &>/dev/null; then
        realpath "$path"
    else
        # Sinon, utiliser une alternative
        cd "$(dirname "$path")" &>/dev/null || exit 1
        local abs_path="$(pwd -P)/$(basename "$path")"
        cd - &>/dev/null || exit 1
        echo "$abs_path"
    fi
}

# Calcul de la taille des modules et des dépendances pour les trier
calculate_module_sizes() {
    local modules="$1"
    
    # Rediriger les logs vers le fichier d'erreur standard pour éviter de polluer la sortie standard
    exec 3>&2  # Sauvegarder stderr
    
    # Créer un fichier temporaire pour stocker les tailles et informations de dépendances
    local size_file=$(mktemp)
    local log_file=$(mktemp)
    
    {
        echo "Calcul de la taille des modules et analyse des dépendances..." >> "$log_file"
        
        # Première passe : analyser les dépendances et calculer la taille des sources
        while IFS= read -r module; do
            local module_path="$PROJECT_PATH/$module"
            local module_size=0
            local dependency_count=0
            
            # Vérifier si le module existe et contient un pom.xml
            if [[ ! -d "$module_path" || ! -f "$module_path/pom.xml" ]]; then
                echo "  - $module: ignoré (n'existe pas ou pas de pom.xml)" >> "$log_file"
                continue
            fi
            
            # Compter le nombre de fichiers source
            if [[ -d "$module_path/src" ]]; then
                local find_cmd
                find_cmd=$(build_find_command "$module_path/src")
                module_size=$(eval "$find_cmd" | wc -l)
            fi
            
            # Compter le nombre de modules qui dépendent de celui-ci
            if [[ -f "$module_path/pom.xml" ]]; then
                local artifactId
                artifactId=$(grep -o '<artifactId>[^<]*</artifactId>' "$module_path/pom.xml" | head -1 | sed -E 's/<artifactId>(.*)<\/artifactId>/\1/')
                local groupId
                groupId=$(grep -o '<groupId>[^<]*</groupId>' "$module_path/pom.xml" | head -1 | sed -E 's/<groupId>(.*)<\/groupId>/\1/')
                
                # Si groupId est vide, utiliser le groupId du parent
                if [[ -z "$groupId" ]]; then
                    groupId=$(grep -o '<groupId>[^<]*</groupId>' "$PROJECT_PATH/pom.xml" | head -1 | sed -E 's/<groupId>(.*)<\/groupId>/\1/')
                fi
                
                if [[ -n "$artifactId" && -n "$groupId" ]]; then
                    # Compter les références dans les autres pom.xml
                    dependency_count=$(grep -r --include="pom.xml" "<artifactId>$artifactId</artifactId>" "$PROJECT_PATH" | grep -v "$module_path/pom.xml" | wc -l)
                fi
            fi
            
            # Formule de score : taille - (dépendants * facteur)
            # Plus un module a de dépendants, plus sa priorité est élevée
            local dep_factor=10
            local score=$((module_size - (dependency_count * dep_factor)))
            
            echo "$module:$score:$module_size:$dependency_count" >> "$size_file"
            echo "  - $module: $module_size fichiers, $dependency_count dépendants, score: $score" >> "$log_file"
        done <<< "$modules"
    } >&3  # Rediriger la sortie vers stderr d'origine
    
    # Trier les modules par score (du plus petit au plus grand)
    local sorted_modules
    sorted_modules=$(sort -t: -k2,2n "$size_file" | cut -d: -f1)
    
    # Afficher les logs
    log_info "Calcul de la taille des modules et analyse des dépendances..."
    cat "$log_file" | while IFS= read -r line; do
        log_info "$line"
    done
    
    # Nettoyer les fichiers temporaires
    rm -f "$size_file" "$log_file"
    
    # Retourner uniquement les noms de modules triés
    echo "$sorted_modules"
}

# Fonction principale
main() {
    BUILD_START_TIME=$(date +%s)
    
    echo -e "${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}    ${CYAN}Build Based Hash Smart${NC} v${VERSION}            ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}"
    echo
    
    # Traitement des options
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                FORCE_BUILD=true
                log_warning "Mode force activé: le build sera exécuté même sans changements"
                shift
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    
    # Vérification des arguments restants
    if [[ ${#args[@]} -ne 1 ]]; then
        show_help
        exit 1
    fi
    
    PROJECT_PATH=$(realpath_portable "${args[0]}")
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
