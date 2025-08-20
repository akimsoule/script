#!/bin/bash
set -euo pipefail


# Le premier argument est le répertoire du projet
PROJECT_DIR="${1:-}"
if [ -z "$PROJECT_DIR" ]; then
    echo "Erreur : Aucun répertoire de projet spécifié" >&2
    echo "Usage : $0 <project-dir>" >&2
    exit 1
fi

# Vérification de l'existence du répertoire du projet
if [ ! -d "$PROJECT_DIR" ]; then
    echo "Le répertoire du projet n'existe pas : $PROJECT_DIR" >&2
    echo "Usage : $0 <project-dir>" >&2
    exit 1
fi

PROJECT_DIR_NAME=$(basename "$PROJECT_DIR")
MAVEN_DEPENDENCY_TREE_FILE="$HOME/.m2/maven-config/$PROJECT_DIR_NAME/dependency-tree.txt"

# Fonction pour générer l'arbre des dépendances
generate_dependency_tree() {
    local tree_file="$1"
    local project_dir="$2"
    
    mkdir -p "$(dirname "$tree_file")"
    echo "Génération de l'arbre des dépendances Maven..." >&2
    
    if [ ! -f "$tree_file" ] || [ ! -s "$tree_file" ]; then
        (cd "$project_dir" && mvn -B dependency:tree > "$tree_file") || {
            echo "Erreur lors de la génération de l'arbre des dépendances" >&2
            rm -f "$tree_file"
            exit 1
        }
    fi
}

# Génération de l'arbre des dépendances
generate_dependency_tree "$MAVEN_DEPENDENCY_TREE_FILE" "$PROJECT_DIR"

# Cache des fichiers pom.xml et leurs artifactIds
POM_CACHE=""
echo "Mise en cache des informations des modules..." >&2
while IFS= read -r pomPath; do
    dirPath=$(dirname "$pomPath")
    if [ -f "$pomPath" ]; then
        artifactId=$(awk '/<artifactId>/{i++} i==2{gsub(/<\/?artifactId>/,""); gsub(/^[ \t]+|[ \t]+$/,""); print; exit}' "$pomPath")
        if [ -n "$artifactId" ]; then
            POM_CACHE+="$artifactId:${dirPath#./}"$'\n'
        fi
    fi
done < <(cd "$PROJECT_DIR" && find . -type f -name "pom.xml")

echo " POM_CACHE : $POM_CACHE"

# Extraction de l'artefact des modules du projet
MODULE_ARTIFACTS=$(sed -n 's/.* @ \([^[:space:]]*\) ---.*/\1/p' "$MAVEN_DEPENDENCY_TREE_FILE" | sort -u)



# Fonction pour calculer la profondeur maximale d'un module
get_max_depth() {
    local mod="$1"
    local tree_file="$2"
    grep ":${mod}:" "$tree_file" | \
    awk '
    {
        # Supprime [INFO] 
        sub(/\[INFO\] */, "");
        # Extrait les caractères d indentation
        match($0, /^[| +-]*/);
        # Calcule la profondeur (longueur/3)
        depth = int(RLENGTH/3);
        print depth
    }' | sort -nr | head -1 || echo "0"
}

# Traitement des modules et construction du résultat
DEP_DEPTHS=""
for MOD in $MODULE_ARTIFACTS; do
    if [ -n "$MOD" ]; then
        MAX_DEPTH=$(get_max_depth "$MOD" "$MAVEN_DEPENDENCY_TREE_FILE")
        # Récupération du chemin du module
        MOD_PATH=$(echo "$POM_CACHE" | grep -E "^$MOD:" | cut -d: -f2-)
        
        # Construction de la ligne de sortie
        DEP_DEPTHS+="dep:$MOD:$MOD_PATH:$MAX_DEPTH"$'\n'
    fi
done

# Vérification des résultats
if [ -z "$DEP_DEPTHS" ]; then
    echo "Aucun module trouvé dans le projet" >&2
    exit 0
fi

# Affichage des résultats triés par profondeur
echo "Profondeur des modules :" >&2
printf '%s' "$DEP_DEPTHS" | sort -t: -k4nr -k2
