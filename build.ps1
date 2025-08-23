# ============================ 
# Paramètres
# ============================
param(
    [Parameter(Mandatory=$true)][string]$p,  # Projet (obligatoire)
    [switch]$Debug,
    [string]$m,
    [switch]$ForceRebuild
)

# ============================ 
# Configuration
# ============================
$ExtensionsToHash = @("java", "xml", "properties", "txt", "json", "yml", "yaml", "md", "js", "ts", "css", "ftl")
$Exclusions = @("target", "build", "bin", "dist", ".idea", ".git", "node_modules", "generated")
$M2Root = if ($IsWindows) { "$env:USERPROFILE\.m2" } else { "$HOME/.m2" }

# Vérifier que le projet existe
if (-not (Test-Path $p)) {
    Write-Host "❌ Le chemin du projet '$p' n'existe pas!" -ForegroundColor Red
    exit 1
}

$rootPomPath = Join-Path $p "pom.xml"
if (-not (Test-Path $rootPomPath)) {
    Write-Host "❌ Aucun pom.xml trouvé dans '$p'!" -ForegroundColor Red
    exit 1
}

# Obtenir info du projet
try {
    [xml]$rootPom = Get-Content $rootPomPath
    $artifactId = $rootPom.project.artifactId
    $version = $rootPom.project.version
    if (-not $artifactId -or -not $version) {
        throw "ArtifactId ou version manquant"
    }
} catch {
    Write-Host "❌ Impossible de lire le pom.xml racine: $_" -ForegroundColor Red
    exit 1
}

$CacheRoot = Join-Path $M2Root "cache" "$artifactId-$version"
$HashFileName = "hash.txt"

Write-Host "🚀 Analyse du projet: $artifactId-$version" -ForegroundColor Green
Write-Host "📁 Projet: $p" -ForegroundColor Cyan

# ============================
# Fonctions simplifiées
# ============================

function Get-ProjectModules {
    $poms = Get-ChildItem -Path $p -Recurse -Filter pom.xml | Where-Object {
        $path = $_.FullName
        -not ($Exclusions | Where-Object { $path -like "*$_*" })
    }
    
    $modules = @{}
    $dependencies = @{}
    
    foreach ($pomFile in $poms) {
        try {
            [xml]$pomXml = Get-Content $pomFile.FullName
            $modId = $pomXml.project.artifactId
            if ($modId) {
                $modules[$modId] = $pomFile.Directory.FullName
                
                # Récupérer dépendances internes
                $deps = @()
                if ($pomXml.project.dependencies.dependency) {
                    $deps += $pomXml.project.dependencies.dependency.artifactId | Where-Object { $modules.ContainsKey($_) }
                }
                $dependencies[$modId] = $deps
            }
        } catch {
            Write-Warning "⚠️ Erreur lors de la lecture de $($pomFile.FullName)"
        }
    }
    
    return @{ Modules = $modules; Dependencies = $dependencies }
}

function Get-ModuleHash {
    param([string]$ModulePath)
    
    $files = Get-ChildItem -Path $ModulePath -Recurse -File | Where-Object {
        $ext = $_.Extension.TrimStart(".")
        ($ExtensionsToHash -contains $ext) -and -not ($Exclusions | Where-Object { $_.FullName -like "*$_*" })
    }
    
    if ($files.Count -eq 0) { return "NO_FILES" }
    
    $hashes = $files | ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
    $combined = [string]::Join("", $hashes)
    return (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($combined))) -Algorithm SHA256).Hash
}

function Get-HashCache {
    $cachePath = Join-Path $CacheRoot $HashFileName
    if (-not (Test-Path $cachePath)) { return @{} }
    
    try {
        $content = Get-Content $cachePath -Raw | ConvertFrom-Json
        return $content.ModuleHashes
    } catch {
        return @{}
    }
}

function Set-HashCache {
    param([hashtable]$HashCache)
    
    if (-not (Test-Path $CacheRoot)) { New-Item -Path $CacheRoot -ItemType Directory -Force | Out-Null }
    
    $cacheData = @{
        ModuleHashes = $HashCache
        LastUpdated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        ProjectInfo = @{ ArtifactId = $artifactId; Version = $version }
    }
    
    $cacheData | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $CacheRoot $HashFileName) -Encoding UTF8
}

function Get-Dependents {
    param([string]$Module, [hashtable]$Dependencies)
    
    $dependents = @()
    foreach ($mod in $Dependencies.Keys) {
        if ($Dependencies[$mod] -contains $Module) {
            $dependents += $mod
            $dependents += Get-Dependents -Module $mod -Dependencies $Dependencies
        }
    }
    return $dependents | Sort-Object -Unique
}

# ============================
# Script principal
# ============================

$projectData = Get-ProjectModules
$modules = $projectData.Modules
$dependencies = $projectData.Dependencies

if ($modules.Count -eq 0) {
    Write-Host "❌ Aucun module Maven trouvé dans le projet!" -ForegroundColor Red
    exit 1
}

Write-Host "📦 Modules trouvés: $($modules.Keys.Count)" -ForegroundColor Cyan

# Déterminer les modules à traiter
if ($m) {
    $specifiedModules = $m -split ',' | ForEach-Object { $_.Trim() }
    $validModules = @()
    $invalidModules = @()
    
    foreach ($module in $specifiedModules) {
        if ($modules.ContainsKey($module)) {
            $validModules += $module
        } else {
            $invalidModules += $module
        }
    }
    
    if ($invalidModules.Count -gt 0) {
        Write-Host "❌ Modules non trouvés: $($invalidModules -join ', ')" -ForegroundColor Red
        Write-Host "💡 Modules disponibles: $($modules.Keys -join ', ')" -ForegroundColor Yellow
        exit 1
    }
    
    $modulesToProcess = $validModules
    Write-Host "🎯 Modules spécifiés: $($modulesToProcess -join ', ')" -ForegroundColor Green
} else {
    # Détecter les modules modifiés
    $oldCache = Get-HashCache
    $newCache = @{}
    $modifiedModules = @()
    
    Write-Host "🔍 Analyse des modifications..." -ForegroundColor Yellow
    
    foreach ($module in $modules.Keys) {
        $hash = Get-ModuleHash -ModulePath $modules[$module]
        $newCache[$module] = $hash
        
        if ($ForceRebuild -or -not $oldCache.ContainsKey($module) -or $oldCache[$module] -ne $hash) {
            $modifiedModules += $module
        }
    }
    
    Set-HashCache -HashCache $newCache
    
    if ($modifiedModules.Count -eq 0) {
        Write-Host "✅ Aucune modification détectée. Rien à construire." -ForegroundColor Green
        exit 0
    }
    
    $modulesToProcess = $modifiedModules
    Write-Host "🔄 Modules modifiés: $($modulesToProcess -join ', ')" -ForegroundColor Green
}

# Calculer tous les modules affectés (incluant les dépendants)
$allAffectedModules = @($modulesToProcess)
foreach ($module in $modulesToProcess) {
    $dependents = Get-Dependents -Module $module -Dependencies $dependencies
    $allAffectedModules += $dependents
}
$allAffectedModules = $allAffectedModules | Sort-Object -Unique

Write-Host "⚡ Modules à reconstruire: $($allAffectedModules -join ', ')" -ForegroundColor Cyan

# Générer commande Maven
$isRootAffected = $allAffectedModules -contains $artifactId

if ($isRootAffected -or $allAffectedModules.Count -eq $modules.Count) {
    $mavenCommand = "mvn clean install -T 1C"
} else {
    $projectsArg = ($allAffectedModules | ForEach-Object { ":$_" }) -join ","
    $mavenCommand = "mvn clean install --projects $projectsArg --also-make-dependents -T 1C"
}

Write-Host "`n🔨 Commande Maven:" -ForegroundColor Yellow
Write-Host "   $mavenCommand" -ForegroundColor White

# Exécution
$confirmation = Read-Host "`n❓ Exécuter maintenant? (O/N)"
if ($confirmation -match "^[OoYy]") {
    Write-Host "▶️ Exécution en cours..." -ForegroundColor Green
    Push-Location $p
    try {
        Invoke-Expression $mavenCommand
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ Build terminé avec succès!" -ForegroundColor Green
        } else {
            Write-Host "❌ Échec du build (code: $LASTEXITCODE)" -ForegroundColor Red
            exit $LASTEXITCODE
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "⏸️ Commande non exécutée." -ForegroundColor Yellow
}
