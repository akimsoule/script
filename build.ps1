<#
.SYNOPSIS
Script de compilation intelligent pour projets Maven avec gestion de cache.

.DESCRIPTION
Ce script PowerShell optimise la compilation des projets Maven en:
- Vérifiant les modifications des fichiers sources pour une compilation sélective
- Gérant un cache des dépendances et des artefacts compilés
- Supportant la compilation de modules spécifiques
- Permettant l'initialisation du cache et la reconstruction forcée

.PARAMETER p
Chemin vers le projet Maven à compiler (obligatoire)

.PARAMETER m
Module spécifique à compiler (optionnel)

.PARAMETER ForceRebuild
Force la reconstruction complète en ignorant le cache

.PARAMETER Init
Initialise ou réinitialise le cache

.PARAMETER UseGit
Utilise Git pour détecter les changements au lieu du hachage des fichiers

.EXAMPLE
.\build.ps1 -p "C:\MonProjet"
Compile le projet en utilisant le cache

.EXAMPLE
.\build.ps1 -p "C:\MonProjet" -m "module-core" -ForceRebuild
Force la reconstruction du module spécifié
#>

param(
    [Parameter(Mandatory=$true)][string]$p,
    [string]$m,
    [switch]$ForceRebuild,
    [switch]$Init,
    [switch]$UseGit
)

# Configuration
$ExtensionsToHash = @("java", "xml", "properties", "txt", "json", "yml", "yaml")
$Exclusions = @("target", "build", ".idea", ".git", "node_modules")
$M2Root = if ($IsWindows) { "$env:USERPROFILE\.m2" } else { "$HOME/.m2" }

# Validations principales
if (-not (Test-Path $p)) { Write-Host "❌ Projet inexistant: $p" -ForegroundColor Red; exit 1 }
$rootPom = Join-Path $p "pom.xml"
if (-not (Test-Path $rootPom)) { Write-Host "❌ pom.xml manquant dans: $p" -ForegroundColor Red; exit 1 }

# Lecture du pom racine
try {
    [xml]$pomXml = Get-Content $rootPom
    $artifactId = $pomXml.project.artifactId
    $version = $pomXml.project.version
    if (-not $artifactId -or -not $version) { throw "ArtifactId/version manquant" }
} catch {
    Write-Host "❌ Erreur pom.xml: $_" -ForegroundColor Red; exit 1
}

$CacheRoot = Join-Path $M2Root "cache" "$artifactId-$version"
Write-Host "🚀 Projet: $artifactId-$version" -ForegroundColor Green

# Fonctions simplifiées
function Get-Modules {
    $poms = Get-ChildItem $p -Recurse -Filter pom.xml | Where-Object { 
        -not ($Exclusions | Where-Object { $_.FullName -like "*$_*" })
    }
    
    $modules = @{}
    $deps = @{}
    
    foreach ($pom in $poms) {
        try {
            [xml]$xml = Get-Content $pom.FullName
            $id = $xml.project.artifactId
            if ($id) {
                $modules[$id] = $pom.Directory.FullName
                $deps[$id] = @($xml.project.dependencies.dependency.artifactId | Where-Object { $modules.ContainsKey($_) })
            }
        } catch { }
    }
    return @{ Modules = $modules; Dependencies = $deps }
}

function Get-Hash($path) {
    $files = Get-ChildItem $path -Recurse -File | Where-Object {
        ($ExtensionsToHash -contains $_.Extension.TrimStart(".")) -and 
        -not ($Exclusions | Where-Object { $_.FullName -like "*$_*" })
    }
    if (-not $files) { return "EMPTY" }
    
    $combined = ($files | ForEach-Object { (Get-FileHash $_.FullName).Hash }) -join ""
    return (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($combined)))).Hash
}

function Get-CachedHashes {
    $cachePath = Join-Path $CacheRoot "hash.txt"
    if (-not (Test-Path $cachePath)) { return @{} }
    try {
        $content = Get-Content $cachePath -Raw | ConvertFrom-Json
        $result = @{}
        $content.ModuleHashes.PSObject.Properties | ForEach-Object { $result[$_.Name] = $_.Value }
        return $result
    } catch { return @{} }
}

function Set-CachedHashes($hashes) {
    if (-not (Test-Path $CacheRoot)) { New-Item $CacheRoot -ItemType Directory -Force | Out-Null }
    @{ ModuleHashes = $hashes; LastUpdated = Get-Date } | ConvertTo-Json | 
        Set-Content (Join-Path $CacheRoot "hash.txt") -Encoding UTF8
}

function Get-GitChanges($modules) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    
    Push-Location $p
    try {
        if (-not (git rev-parse --is-inside-work-tree 2>$null)) { return $null }
        
        $changedFiles = @()
        $changedFiles += git ls-files --others --exclude-standard 2>$null
        $changedFiles += git diff --name-only 2>$null
        $changedFiles += git diff --name-only --staged 2>$null
        
        $changedFiles = $changedFiles | Where-Object { $_ } | Sort-Object -Unique
        if (-not $changedFiles) { return @() }
        
        $changedModules = @()
        $projectPath = Resolve-Path $p
        
        foreach ($module in $modules.Keys) {
            $relPath = $modules[$module].Replace($projectPath, "").TrimStart("/\")
            if ($changedFiles | Where-Object { $_ -like "$relPath*" }) {
                $changedModules += $module
            }
        }
        return $changedModules
    } catch { return $null }
    finally { Pop-Location }
}

function Get-Dependents($module, $deps) {
    $result = @()
    foreach ($mod in $deps.Keys) {
        if ($deps[$mod] -contains $module) {
            $result += $mod
            $result += Get-Dependents $mod $deps
        }
    }
    return $result | Sort-Object -Unique
}

# Script principal
$projectData = Get-Modules
$modules = $projectData.Modules
$dependencies = $projectData.Dependencies

if ($modules.Count -eq 0) { Write-Host "❌ Aucun module trouvé" -ForegroundColor Red; exit 1 }

# Write-Host "📦 Modules:"
# $modules.Keys | ForEach-Object { Write-Host "  - $_" -ForegroundColor Cyan }

# Initialisation du cache
if ($Init) {
    $cache = @{}
    foreach ($mod in $modules.Keys) { $cache[$mod] = Get-Hash $modules[$mod] }
    Set-CachedHashes $cache
    Write-Host "✅ Cache initialisé" -ForegroundColor Green
    exit 0
}

# Déterminer les modules à traiter
if ($m) {
    $specified = $m -split ',' | ForEach-Object { $_.Trim() }
    $invalid = $specified | Where-Object { -not $modules.ContainsKey($_) }
    if ($invalid) {
        Write-Host "❌ Modules inexistants: $($invalid -join ', ')" -ForegroundColor Red
        Write-Host "💡 Disponibles: $($modules.Keys -join ', ')" -ForegroundColor Yellow
        exit 1
    }
    $modulesToBuild = $specified
} else {
    # Détection automatique
    $modifiedModules = @()
    
    if ($UseGit) {
        $gitChanges = Get-GitChanges $modules
        if ($null -ne $gitChanges) {
            $modifiedModules = $gitChanges
            if ($ForceRebuild -and $modifiedModules.Count -eq 0) { $modifiedModules = $modules.Keys }
        } else {
            Write-Host "⚠️ Git indisponible, utilisation du cache" -ForegroundColor Yellow
            $UseGit = $false
        }
    }
    
    if (-not $UseGit) {
        $oldHashes = Get-CachedHashes
        $newHashes = @{}
        
        foreach ($mod in $modules.Keys) {
            $hash = Get-Hash $modules[$mod]
            $newHashes[$mod] = $hash
            if ($ForceRebuild -or $oldHashes[$mod] -ne $hash) { $modifiedModules += $mod }
        }
        Set-CachedHashes $newHashes
    }
    
    if ($modifiedModules.Count -eq 0) {
        Write-Host "✅ Aucune modification détectée" -ForegroundColor Green
        exit 0
    }
    
    $modulesToBuild = $modifiedModules
}

# Inclure les dépendants
$allModules = @($modulesToBuild)
foreach ($mod in $modulesToBuild) {
    $allModules += Get-Dependents $mod $dependencies
}
$allModules = $allModules | Sort-Object -Unique

Write-Host "🔄 Modules à construire: $($allModules -join ', ')" -ForegroundColor Green

# Commande Maven
$isRootAffected = $allModules -contains $artifactId
if ($isRootAffected -or $allModules.Count -eq $modules.Count) {
    $cmd = "mvn clean install -T 1C"
} else {
    $projects = ($allModules | ForEach-Object { ":$_" }) -join ","
    $cmd = "mvn clean install --projects $projects --also-make-dependents -T 1C"
}

Write-Host "`n🔨 Commande: $cmd" -ForegroundColor Yellow

# Exécution
$confirm = Read-Host "❓ Exécuter? (O/N)"
if ($confirm -match "^[OoYy]") {
    Push-Location $p
    try {
        Invoke-Expression $cmd
        if ($LASTEXITCODE -ne 0) { Write-Host "❌ Build échoué" -ForegroundColor Red; exit $LASTEXITCODE }
        Write-Host "✅ Build réussi!" -ForegroundColor Green
    } finally { Pop-Location }
} else {
    Write-Host "⏸️ Annulé" -ForegroundColor Yellow
}
