#!/bin/bash

# Vérifier que le script reçoit bien un argument
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <path_to_existing_react_project>"
    exit 1
fi

# Récupérer le chemin du projet existant
EXISTING_PROJECT_PATH=$1

# Vérifier que le chemin fourni est un dossier valide
if [ ! -d "$EXISTING_PROJECT_PATH" ]; then
    echo "Le chemin fourni n'est pas un dossier valide : $EXISTING_PROJECT_PATH"
    exit 1
fi

# Demander le nom du nouveau projet
read -p "Entrez le nom du nouveau projet : " NEW_PROJECT_NAME

# Créer le dossier du nouveau projet
NEW_PROJECT_PATH=$(pwd)/$NEW_PROJECT_NAME
mkdir -p $NEW_PROJECT_PATH

# Copier l'arborescence des fichiers (sans les fichiers node_modules et .git)
rsync -av --progress --exclude 'node_modules' --exclude '.git' "$EXISTING_PROJECT_PATH/" "$NEW_PROJECT_PATH"

# Aller dans le nouveau dossier de projet
cd $NEW_PROJECT_PATH

# Installer les dépendances du projet
if [ -f "package.json" ]; then
    echo "Installation des dépendances..."
    npm install
else
    echo "Le fichier package.json est introuvable dans le projet source."
    exit 1
fi

# Mettre à jour les dépendances du projet
echo "Mise à jour des dépendances..."
npm update

# Déployer le projet sur Netlify et configurer les variables d'environnement
echo "Déploiement sur Netlify et configuration des variables d'environnement..."
netlify init --manual --name "$NEW_PROJECT_NAME"

# Configurer les variables d'environnement
netlify env:set REACT_APP_CAPTCHA_CLIENT 6LcD4_UpAAAAAJIVKROcSXoX5uNUS8wJpYdsiWxM
netlify env:set REACT_APP_CAPTCHA_SERVER 6LcD4_UpAAAAAM0ySd9px_fdkMHRhVokvfHQB-3l

echo "Le nouveau projet React '$NEW_PROJECT_NAME' a été créé avec succès à l'emplacement : $NEW_PROJECT_PATH"
echo "Les variables d'environnement ont été configurées sur Netlify."
