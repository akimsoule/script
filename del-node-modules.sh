#!/usr/bin/env bash
# Supprime tous les dossiers node_modules récursivement depuis le répertoire courant
find . -type d -name 'node_modules' -prune -exec rm -rf '{}' +
