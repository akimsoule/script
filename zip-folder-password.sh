#!/bin/bash

# Configuration des chemins - À modifier selon vos besoins
FOLDER_PATH="/Users/akimsoule/Downloads/compte_taxe"  # Modifiez ce chemin
PASSWORD='acheteur1234!'            # Mot de passe
OUTPUT_ZIP="/Users/akimsoule/Downloads/compte_taxe.zip"    # Modifiez le chemin de sortie

if [ ! -d "$FOLDER_PATH" ]; then
  echo "Erreur : Le dossier '$FOLDER_PATH' n'existe pas"
  exit 1
fi

if [ -f "$OUTPUT_ZIP" ]; then
  echo "🗑️  Suppression de l'archive existante..."
  rm "$OUTPUT_ZIP"
fi

echo "🔄 Création de l'archive chiffrée..."

7z a -tzip -p"$PASSWORD" -mem=AES256 "$OUTPUT_ZIP" "$FOLDER_PATH"

if [ $? -eq 0 ]; then
  echo "✅ Archive créée avec succès : $OUTPUT_ZIP"
  echo "🔒 Chiffrement : AES-256 avec noms de fichiers masqués"
else
  echo "❌ Erreur lors de la création de l'archive"
  exit 1
fi
