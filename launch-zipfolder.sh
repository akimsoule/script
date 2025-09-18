#!/bin/bash

# Script de lancement pour ZipFolderApp
# Ce script compile et installe l'application si nécessaire

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="ZipFolderApp"

echo "🚀 Lancement de ZipFolderApp..."

# Vérifier si le répertoire existe
if [ ! -d "$SCRIPT_DIR/$APP_DIR" ]; then
    echo "❌ Répertoire ZipFolderApp non trouvé"
    exit 1
fi

# Se placer dans le répertoire de l'application
cd "$SCRIPT_DIR/$APP_DIR"

# Vérifier si l'application est déjà compilée
if [ ! -f "$HOME/Applications/ZipFolderApp" ]; then
    echo "📦 Application non trouvée, compilation automatique..."
    ./build-zipfolder-app.sh
fi

# Lancer l'application
echo "🎯 Lancement de l'application..."
"$HOME/Applications/ZipFolderApp"
