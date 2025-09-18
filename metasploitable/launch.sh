#!/bin/bash

# Vérifier si un conteneur avec ce nom existe déjà
if [ "$(docker ps -aq -f name=metasploitable)" ]; then
    # Arrêter le conteneur s'il est en cours d'exécution
    docker stop metasploitable >/dev/null 2>&1
    # Supprimer le conteneur
    docker rm metasploitable >/dev/null 2>&1
fi

# Supprimer le réseau s'il existe
docker network rm meta_network 2>/dev/null || true

# Créer le réseau personnalisé
docker network create \
    --driver bridge \
    --subnet=192.168.1.0/24 \
    --gateway=192.168.1.1 \
    --opt "com.docker.network.bridge.name"="meta_bridge" \
    meta_network

# Lancer le nouveau conteneur
docker run -d \
    --name metasploitable \
    --network meta_network \
    --ip 192.168.1.100 \
    -p 21:21 \
    -p 22:22 \
    -p 23:23 \
    -p 25:25 \
    -p 80:80 \
    -p 139:139 \
    -p 443:443 \
    -p 3306:3306 \
    -p 5432:5432 \
    -p 8000:8000 \
    metasploitable
