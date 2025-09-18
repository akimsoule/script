#!/bin/bash

# Récupérer une citation aléatoire depuis l'API ZenQuotes
quote_response=$(curl -s "https://zenquotes.io/api/random")

# Extraire la citation du JSON retourné (limiter à 50 caractères)
quote=$(echo "$quote_response" | jq -r '.[0].q')

# Vérifier si la citation est vide, et définir une valeur par défaut
if [ -z "$quote" ]; then
  quote="Mise à jour du code"
fi

# Récupérer le nom de la branche courante
current_branch=$(git symbolic-ref --short HEAD)

# Exécuter la commande git
git add . && git commit -m "$quote" && git push origin "$current_branch"
