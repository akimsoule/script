#!/usr/bin/env node

/**
 * Script de génération de messages de commit intelligents
 * Utilise l'état Git actuel pour générer un message pertinent
 */

// Fonction pour nettoyer le statut Git et extraire les informations pertinentes
function cleanGitStatus(status) {
    // Supprimer les lignes inutiles et garder les changements
    return status
        .split('\n')
        .filter(line => line.match(/modified:|new file:|deleted:|renamed:/))
        .map(line => line.trim())
        .join('\n');
}

// Fonction pour générer un message de commit basé sur les changements
function generateCommitMessage(status) {
    const cleanStatus = cleanGitStatus(status);
    
    // Si aucun changement détecté
    if (!cleanStatus) {
        return "Mise à jour du code";
    }

    // Détecter le type principal de changement
    const hasModified = cleanStatus.includes('modified:');
    const hasNew = cleanStatus.includes('new file:');
    const hasDeleted = cleanStatus.includes('deleted:');
    const hasRenamed = cleanStatus.includes('renamed:');

    // Compter les fichiers modifiés
    const modifiedCount = (cleanStatus.match(/modified:/g) || []).length;
    const newCount = (cleanStatus.match(/new file:/g) || []).length;
    const deletedCount = (cleanStatus.match(/deleted:/g) || []).length;
    const renamedCount = (cleanStatus.match(/renamed:/g) || []).length;

    // Générer un message approprié
    if (hasNew && !hasModified && !hasDeleted && !hasRenamed) {
        if (newCount === 1) {
            const fileName = cleanStatus.match(/new file:\s+(.+)/)[1];
            return `Ajouter ${fileName}`;
        }
        return `Ajouter ${newCount} nouveaux fichiers`;
    }

    if (hasDeleted && !hasModified && !hasNew && !hasRenamed) {
        if (deletedCount === 1) {
            const fileName = cleanStatus.match(/deleted:\s+(.+)/)[1];
            return `Supprimer ${fileName}`;
        }
        return `Supprimer ${deletedCount} fichiers`;
    }

    if (hasRenamed && !hasModified && !hasNew && !hasDeleted) {
        if (renamedCount === 1) {
            const match = cleanStatus.match(/renamed:\s+(.+)\s+->\s+(.+)/);
            const newName = match[2];
            return `Renommer en ${newName}`;
        }
        return `Renommer ${renamedCount} fichiers`;
    }

    if (hasModified && !hasNew && !hasDeleted && !hasRenamed) {
        if (modifiedCount === 1) {
            const fileName = cleanStatus.match(/modified:\s+(.+)/)[1];
            // Détecter les types de fichiers courants
            if (fileName.endsWith('.css')) return "Mettre à jour les styles";
            if (fileName.endsWith('.js')) return "Mettre à jour la logique JavaScript";
            if (fileName.match(/test|spec/)) return "Mettre à jour les tests";
            if (fileName.match(/README|\.md$/)) return "Mettre à jour la documentation";
            return `Modifier ${fileName}`;
        }
        return `Mettre à jour ${modifiedCount} fichiers`;
    }

    // Si plusieurs types de changements
    const totalChanges = modifiedCount + newCount + deletedCount + renamedCount;
    return `Mettre à jour ${totalChanges} fichiers`;
}

// Récupérer le statut Git des arguments
const gitStatus = process.argv[2] || '';

// Générer et afficher le message
const message = generateCommitMessage(gitStatus);
console.log(message);
