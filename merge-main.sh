#!/bin/sh

# Récupère la branche courante (par exemple develop/quiz/ca-demo)
current_branch=$(git symbolic-ref --short HEAD)

# Vérifie que la branche courante n'est pas déjà main
if [ "$current_branch" = "main" ]; then
    echo "Vous êtes déjà sur la branche main. Aucune copie à faire."
    exit 1
fi

# Assure-toi d'être sur la branche main
git checkout main

# Mets à jour la branche main avec les derniers changements
git pull origin main

# Liste tous les fichiers présents dans main
main_files=$(git ls-tree -r main --name-only)

# Change de branche pour récupérer les modifications de la branche courante (develop/quiz/ca-demo)
git checkout main

# Crée une liste temporaire des fichiers modifiés dans la branche courante
modified_files=$(git diff --name-only main $current_branch)

# Parcourt les fichiers modifiés et les remplace seulement s'ils existent dans main
for file in $modified_files; do
    if echo "$main_files" | grep -q "$file"; then
        echo "Copie du fichier $file depuis $current_branch vers main"
        # Copie et remplace directement le fichier dans main
        git checkout $current_branch -- "$file"
    fi
done

# Ajoute les fichiers remplacés à l'index de git
git add .

# Valide les changements avec un message
git commit -m "Rapatriement des modifications des fichiers existants depuis $current_branch vers main"

# Pousse les changements vers le dépôt distant
git push origin main
