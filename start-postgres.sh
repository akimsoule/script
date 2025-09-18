#!/bin/bash

# Script idempotent pour démarrer un conteneur PostgreSQL
# Usage: ./start-postgres.sh <nom_base_de_donnees> [port] [mot_de_passe]

# Configuration par défaut
DEFAULT_PORT=5432
DEFAULT_PASSWORD="postgres"
POSTGRES_USER="postgres"
POSTGRES_VERSION="15"

# Fonction d'aide
show_help() {
    echo "Usage: $0 <nom_base_de_donnees> [port] [mot_de_passe]"
    echo ""
    echo "Paramètres:"
    echo "  nom_base_de_donnees    Nom de la base de données (obligatoire)"
    echo "  port                   Port d'écoute (défaut: $DEFAULT_PORT)"
    echo "  mot_de_passe          Mot de passe postgres (défaut: $DEFAULT_PASSWORD)"
    echo ""
    echo "Exemples:"
    echo "  $0 myapp"
    echo "  $0 myapp 5433"
    echo "  $0 myapp 5433 monmotdepasse"
    echo ""
    echo "Le conteneur sera nommé: postgres-<nom_base_de_donnees>"
    echo "Les données seront persistées dans: ~/.docker/postgres-<nom_base_de_donnees>/data"
}

# Vérification des paramètres
if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    show_help
    exit 0
fi

# Récupération des paramètres
DB_NAME="$1"
PORT="${2:-$DEFAULT_PORT}"
PASSWORD="${3:-$DEFAULT_PASSWORD}"

# Validation du nom de base de données
if [[ ! "$DB_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
    echo "❌ Erreur: Le nom de base de données doit commencer par une lettre et ne contenir que des lettres, chiffres et underscores"
    exit 1
fi

# Validation du port
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
    echo "❌ Erreur: Le port doit être un nombre entre 1024 et 65535"
    exit 1
fi

# Variables dérivées
CONTAINER_NAME="postgres-$DB_NAME"
DATA_DIR="$HOME/.docker/postgres-$DB_NAME/data"
INIT_DIR="$HOME/.docker/postgres-$DB_NAME/init"

echo "🐘 Démarrage du conteneur PostgreSQL pour la base '$DB_NAME'..."
echo "📦 Conteneur: $CONTAINER_NAME"
echo "🔌 Port: $PORT"
echo "📂 Données: $DATA_DIR"

# Vérifier si Docker est installé et en cours d'exécution
if ! command -v docker &> /dev/null; then
    echo "❌ Docker n'est pas installé. Veuillez installer Docker Desktop."
    exit 1
fi

if ! docker info &> /dev/null; then
    echo "❌ Docker n'est pas en cours d'exécution. Veuillez démarrer Docker Desktop."
    exit 1
fi

# Vérifier si le port est déjà utilisé
if lsof -Pi :$PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "❌ Le port $PORT est déjà utilisé par un autre processus."
    echo "💡 Processus utilisant le port:"
    lsof -Pi :$PORT -sTCP:LISTEN
    exit 1
fi

# Créer les répertoires de données s'ils n'existent pas
mkdir -p "$DATA_DIR"
mkdir -p "$INIT_DIR"

# Vérifier si le conteneur existe déjà
if docker ps -a --format "table {{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
    echo "📦 Le conteneur '$CONTAINER_NAME' existe déjà"
    
    # Vérifier s'il est en cours d'exécution
    if docker ps --format "table {{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
        echo "✅ Le conteneur '$CONTAINER_NAME' est déjà en cours d'exécution"
        echo "🔗 Connexion: psql -h localhost -p $PORT -U $POSTGRES_USER -d $DB_NAME"
        exit 0
    else
        echo "🔄 Démarrage du conteneur existant..."
        if docker start "$CONTAINER_NAME" > /dev/null; then
            echo "✅ Conteneur '$CONTAINER_NAME' démarré avec succès"
        else
            echo "❌ Erreur lors du démarrage du conteneur existant"
            exit 1
        fi
    fi
else
    echo "🔄 Création et démarrage d'un nouveau conteneur..."
    
    # Créer le script d'initialisation de la base de données
    cat > "$INIT_DIR/init-db.sql" << EOF
-- Script d'initialisation pour la base de données $DB_NAME
CREATE DATABASE "$DB_NAME";
GRANT ALL PRIVILEGES ON DATABASE "$DB_NAME" TO $POSTGRES_USER;

-- Se connecter à la nouvelle base de données
\c "$DB_NAME";

-- Créer une table d'exemple (optionnel)
-- CREATE TABLE IF NOT EXISTS example_table (
--     id SERIAL PRIMARY KEY,
--     name VARCHAR(100) NOT NULL,
--     created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
-- );

-- Afficher un message de confirmation
SELECT 'Base de données $DB_NAME initialisée avec succès!' as message;
EOF

    # Démarrer le conteneur PostgreSQL
    if docker run -d \
        --name "$CONTAINER_NAME" \
        -e POSTGRES_USER="$POSTGRES_USER" \
        -e POSTGRES_PASSWORD="$PASSWORD" \
        -e POSTGRES_DB="postgres" \
        -p "$PORT:5432" \
        -v "$DATA_DIR:/var/lib/postgresql/data" \
        -v "$INIT_DIR:/docker-entrypoint-initdb.d" \
        --restart unless-stopped \
        postgres:$POSTGRES_VERSION > /dev/null; then
        
        echo "🎉 Conteneur '$CONTAINER_NAME' créé et démarré avec succès"
    else
        echo "❌ Erreur lors de la création du conteneur"
        exit 1
    fi
fi

# Attendre que PostgreSQL soit prêt
echo "⏳ Attente du démarrage de PostgreSQL..."
for i in {1..30}; do
    if docker exec "$CONTAINER_NAME" pg_isready -U "$POSTGRES_USER" > /dev/null 2>&1; then
        echo "✅ PostgreSQL est prêt!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "❌ Timeout: PostgreSQL n'a pas démarré dans les temps"
        exit 1
    fi
    sleep 1
done

# Afficher les informations de connexion
echo ""
echo "🎯 Informations de connexion:"
echo "  Host: localhost"
echo "  Port: $PORT"
echo "  Database: $DB_NAME"
echo "  Username: $POSTGRES_USER"
echo "  Password: $PASSWORD"
echo ""
echo "🔗 Commandes utiles:"
echo "  # Se connecter à la base de données"
echo "  psql -h localhost -p $PORT -U $POSTGRES_USER -d $DB_NAME"
echo ""
echo "  # Arrêter le conteneur"
echo "  docker stop $CONTAINER_NAME"
echo ""
echo "  # Redémarrer le conteneur"
echo "  docker start $CONTAINER_NAME"
echo ""
echo "  # Supprimer le conteneur (⚠️ les données seront perdues)"
echo "  docker rm -f $CONTAINER_NAME"
echo ""
echo "  # Voir les logs"
echo "  docker logs $CONTAINER_NAME"
echo ""
echo "📂 Données persistées dans: $DATA_DIR"

# Vérifier si psql est installé pour la connexion
if ! command -v psql &> /dev/null; then
    echo ""
    echo "💡 Pour installer le client PostgreSQL:"
    echo "  # Sur macOS avec Homebrew:"
    echo "  brew install postgresql"
    echo ""
    echo "  # Ou utilisez Docker pour vous connecter:"
    echo "  docker exec -it $CONTAINER_NAME psql -U $POSTGRES_USER -d $DB_NAME"
fi
