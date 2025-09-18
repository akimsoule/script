#!/bin/bash

# Nom du conteneur
CONTAINER_NAME="ubuntu-desktop"
# Nom du volume pour la persistance
VOLUME_NAME="ubuntu-desktop-data"
# Utilisateur VNC
VNC_USER="kasm-user"
# Mot de passe VNC (à modifier selon vos besoins)
VNC_PASSWORD="password"
# Port pour accéder à l'interface web
WEB_PORT="6901"

# Vérifier si le volume existe déjà, sinon le créer
if ! docker volume ls | grep -q "$VOLUME_NAME"; then
    echo "Création du volume $VOLUME_NAME..."
    docker volume create "$VOLUME_NAME"
fi

# Arrêter et supprimer le conteneur s'il existe déjà
if docker ps -a | grep -q "$CONTAINER_NAME"; then
    echo "Arrêt et suppression du conteneur existant..."
    docker stop "$CONTAINER_NAME"
    docker rm "$CONTAINER_NAME"
fi

# Lancer le nouveau conteneur
echo "Démarrage du conteneur Ubuntu Desktop..."
docker run \
    --name "$CONTAINER_NAME" \
    -d \
    --restart unless-stopped \
    --shm-size=512m \
    -p "$WEB_PORT:6901" \
    -e "VNC_PW=$VNC_PASSWORD" \
    -v "$VOLUME_NAME:/home/kasm-user" \
    #--user root \
    kasmweb/ubuntu-focal-desktop:1.16.0

echo "Conteneur démarré avec succès!"
echo "Accédez à votre bureau Ubuntu via: http://localhost:$WEB_PORT"
echo "Utilisateur VNC: $VNC_USER"
echo "Mot de passe VNC: $VNC_PASSWORD"