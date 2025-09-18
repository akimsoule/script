#!/bin/bash

# Variables
DOCKERFILE_PATH="./Dockerfile"
IMAGE_NAME="metasploitable"
CONTAINER_NAME="metasploitable_container"

# Créer un répertoire pour le projet (idempotent)
echo "Création du répertoire pour le projet..."
mkdir -p metasploitable-docker
cd metasploitable-docker

# Créer le Dockerfile (idempotent)
if [ ! -f $DOCKERFILE_PATH ]; then
    echo "Création du Dockerfile..."
    cat > $DOCKERFILE_PATH <<EOL
# Utilisation d'une image de base Ubuntu 18.04
FROM ubuntu:18.04

# Mise à jour et installation de paquets vulnérables
RUN apt-get update && apt-get install -y \\
    openssh-server \\
    ftp \\
    mysql-server \\
    apache2 \\
    netcat \\
    && apt-get clean

# Créer un utilisateur pour l'environnement Metasploitable
RUN useradd -m -s /bin/bash metasploitable && echo "metasploitable:password" | chpasswd

# Ouvrir un shell bash à l'exécution
CMD ["/bin/bash"]
EOL
else
    echo "Le Dockerfile existe déjà, aucune action nécessaire."
fi

# Construire l'image Docker (idempotent)
if [[ "$(docker images -q $IMAGE_NAME 2> /dev/null)" == "" ]]; then
    echo "Construction de l'image Docker..."
    docker build -t $IMAGE_NAME .
else
    echo "L'image Docker '$IMAGE_NAME' existe déjà, aucune action nécessaire."
fi

# Lancer le conteneur avec les ports exposés
echo "Lancement du conteneur Docker..."
docker run -it --rm -p 22:22 -p 80:80 -p 3307:3306 --name $CONTAINER_NAME $IMAGE_NAME

# Confirmation de fin de script
echo "Conteneur lancé. Accédez à http://localhost pour tester Apache, ou connectez-vous via SSH avec l'utilisateur 'metasploitable' et le mot de passe 'password'."
