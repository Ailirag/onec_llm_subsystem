[CmdletBinding()]
param(
    [string]$V8Path = "",
    [Nullable[bool]]$StoreInGit = $null,
    [string]$OutputPath = "",
    [switch]$AllowNonMain,
    [switch]$IncludeHttp,
    [switch]$Stage,
    [switch]$Force,

    # Собрать cf, проверив только затронутое правкой, без полного регресса.
    #
    # Нужен, когда cf требуется для проверки конкретного изменения, а не для
    # выпуска: полный прогон Web UI занимает большую часть времени сборки и
    # доказывает то, чего правка не касалась. Результат ЯВНО не release-ready,
    # в Git не кладётся и называется иначе — перепутать его с выпуском нельзя.
    [switch]$AffectedOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Workflow.Common.ps1")

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
$branchName = Get-WorkflowBranchName -RepositoryRoot $repositoryRoot
if (-not $AllowNonMain -and $branchName -ne [string]$config.mainBranch) {
    throw "Release builds are allowed only from '$($config.mainBranch)'. Current branch: '$branchName'."
}

$status = @(
    (Invoke-WorkflowGit -RepositoryRoot $repositoryRoot -Arguments @("status", "--porcelain")).Output
)
if ($status.Count -gt 0) {
    throw "Release build requires a clean working tree."
}

$headCommit = [string](
    (Invoke-WorkflowGit -RepositoryRoot $repositoryRoot -Arguments @("rev-parse", "HEAD")).Output |
        Select-Object -First 1
)
$sourceDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.sourceDir)
$version = Get-ConfigurationVersion -ConfigurationFile (Join-Path $sourceDirectory "Configuration.xml")
$extensions = @(Get-WorkflowExtensions -RepositoryRoot $repositoryRoot -Config $config -AllowMissingOptional)
$storeArtifact = if ($null -ne $StoreInGit) {
    [bool]$StoreInGit
}
else {
    [bool]$config.artifacts.storeInGit
}
if ($AffectedOnly) {
    # Неполная проверка не имеет права попасть туда, где лежат выпуски: артефакт в
    # Git читается как «этот cf прошёл всё», и отличить его там будет уже нечем.
    if ($null -ne $StoreInGit -and [bool]$StoreInGit) {
        throw "-AffectedOnly and -StoreInGit contradict each other: an artifact proven only on affected tests must not be stored as a release."
    }
    $storeArtifact = $false
    if ($Stage) {
        throw "-AffectedOnly and -Stage contradict each other: there is nothing to stage, the artifact stays outside Git."
    }
}

if ($storeArtifact) {
    $manifestProbePath = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.artifacts.manifest)
    if (Test-Path -LiteralPath $manifestProbePath -PathType Leaf) {
        $manifestProbe = Get-Content -Raw -LiteralPath $manifestProbePath -Encoding UTF8 | ConvertFrom-Json
        $versionAlreadyExists = $false

        # Наличие свойства проверяется через PSObject.Properties, а не сравнением с
        # $null. При Set-StrictMode -Version 2.0 обращение к отсутствующему свойству
        # PSCustomObject само бросает исключение, поэтому проверка «есть ли releases»
        # падала на манифесте старого формата, где этого ключа нет. Фаза Release
        # из-за этого не работала никогда — обрывалась до всякой сборки.
        if ($null -ne $manifestProbe.PSObject.Properties["releases"] -and $null -ne $manifestProbe.releases) {
            $versionAlreadyExists = @(
                $manifestProbe.releases |
                    Where-Object { [string]$_.version -eq $version }
            ).Count -gt 0
        }
        elseif ($null -ne $manifestProbe.PSObject.Properties["configurationVersion"]) {
            $versionAlreadyExists = [string]$manifestProbe.configurationVersion -eq $version
        }

        if ($versionAlreadyExists -and -not $Force) {
            throw "Version $version already exists in the artifact manifest."
        }
    }
}

$stateDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.localStateDir)
$timestamp = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
$releaseWorkPath = Join-Path $stateDirectory "release\$timestamp"
$preflightReportPath = Join-Path $releaseWorkPath "preflight.json"
[System.IO.Directory]::CreateDirectory($releaseWorkPath) | Out-Null

# Объём прогона. Выпуск — единственное место, где полный регресс обязателен: на
# задачных фазах он по решению команды выключен по умолчанию, и именно этот прогон
# остаётся гарантией. Полагаться на значение по умолчанию нельзя — оно должно быть
# видно в вызове.
#
# -AffectedOnly берёт объём сборки поставки: проверяется ровно то, чего правка
# касается. Это НЕ выпуск, и ниже он таковым не считается.
$webUiScope = if ($AffectedOnly) {
    Get-WorkflowWebUiScope -Config $config -PhaseKey "package"
}
else {
    Get-WorkflowWebUiScope -Config $config -PhaseKey "release"
}
if ($AffectedOnly) {
    Write-Host "Сборка БЕЗ полного регресса: объём Web UI '$webUiScope'."
    Write-Host "  Артефакт не является выпуском: он доказывает только затронутое правкой."
}

$preflightScript = Join-Path $PSScriptRoot "Test-Configuration.ps1"
$preflightArguments = @(
    "-V8Path", (Resolve-WorkflowV8Path -Config $config -V8Path $V8Path),
    "-ReportPath", $preflightReportPath,
    "-RequireClean",
    # Объём задаётся явно и полным. Выпуск — единственное место, где полный регресс
    # обязателен: на задачных фазах он по решению команды выключен по умолчанию, и
    # именно этот прогон остаётся гарантией. Полагаться здесь на значение по
    # умолчанию нельзя — оно должно быть видно в вызове.
    "-WebUiScope", $webUiScope,
    "-KeepTemporaryFiles",
    # Выпуск не берёт базы из кэша: артефакт собирается из исходников в этом самом
    # прогоне. Кэш экономит минуты задачных фаз, а здесь цена доверия выше цены
    # времени.
    "-NoBuiltBaseCache"
)
if ($IncludeHttp) {
    $preflightArguments += "-IncludeHttp"
}
$releaseLog = Join-Path $releaseWorkPath "preflight-console.log"
Invoke-WorkflowPowerShell `
    -ScriptPath $preflightScript `
    -Arguments $preflightArguments `
    -LogPath $releaseLog | Out-Null

$preflightReport = Get-Content -Raw -LiteralPath $preflightReportPath -Encoding UTF8 | ConvertFrom-Json
if ($AffectedOnly) {
    # Полноты не требуем — её и не обещали. Но успех прогона обязателен: cf,
    # собранный из исходников, на которых упала проверка, не нужен никому.
    if (-not [bool]$preflightReport.success) {
        throw "Preflight failed, so there is nothing to build. See $preflightReportPath"
    }
}
elseif (-not [bool]$preflightReport.releaseReady) {
    throw "Release preflight is not release-ready. See $preflightReportPath"
}
$preflightCf = [string]$preflightReport.temporaryCf
if (-not (Test-Path -LiteralPath $preflightCf -PathType Leaf)) {
    throw "Preflight CF was not found: $preflightCf"
}

if ($OutputPath) {
    $artifactPath = [System.IO.Path]::GetFullPath($OutputPath)
}
elseif ($storeArtifact) {
    $relativeArtifactPath = ([string]$config.artifacts.cfTemplate).Replace("{version}", $version)
    $artifactPath = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $relativeArtifactPath
}
elseif ($AffectedOnly) {
    # Имя отличается от выпускного намеренно: два файла одной версии в одном
    # каталоге иначе неразличимы, а доказано у них разное.
    $artifactPath = Join-Path $stateDirectory "releases\$($config.project)_$version-affected.cf"
}
else {
    $artifactPath = Join-Path $stateDirectory "releases\$($config.project)_$version.cf"
}

if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
    if (-not $Force) {
        throw "Release artifact already exists: $artifactPath"
    }
}
if ($storeArtifact -and -not (Test-WorkflowPathUnderRoot -Path $artifactPath -Root $repositoryRoot)) {
    throw "A Git-stored release artifact must stay inside the repository: $artifactPath"
}
[System.IO.Directory]::CreateDirectory((Split-Path $artifactPath -Parent)) | Out-Null
Copy-Item -LiteralPath $preflightCf -Destination $artifactPath -Force:$Force
$sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash.ToLowerInvariant()
$builtAt = [DateTimeOffset]::Now.ToString("o")
$artifactPaths = @($artifactPath)
$artifactRecords = @(
    [pscustomobject]@{
        kind = "cf"
        component = "main"
        componentVersion = $version
        path = if ($storeArtifact) {
            $artifactPath.Substring($repositoryRoot.TrimEnd('\').Length + 1).Replace('\', '/')
        }
        else {
            $artifactPath
        }
        sha256 = $sha256
        size = (Get-Item -LiteralPath $artifactPath).Length
    }
)

foreach ($extension in $extensions) {
    $preflightExtension = @(
        $preflightReport.extensions |
            Where-Object { [string]$_.name -eq [string]$extension.name }
    ) | Select-Object -First 1
    if ($null -eq $preflightExtension) {
        throw "Preflight did not produce extension '$($extension.name)'."
    }
    $preflightCfe = [string]$preflightExtension.temporaryCfe
    if (-not (Test-Path -LiteralPath $preflightCfe -PathType Leaf)) {
        throw "Preflight CFE was not found for '$($extension.name)': $preflightCfe"
    }

    $extensionVersion = [string]$extension.version
    if ([string]::IsNullOrWhiteSpace($extensionVersion)) {
        throw "Extension '$($extension.name)' must define Version in Configuration.xml before release."
    }
    $relativeCfePath = ([string]$extension.artifactTemplate).
        Replace("{name}", [string]$extension.name).
        Replace("{version}", $extensionVersion)
    if ($OutputPath) {
        $cfePath = Join-Path (Split-Path $artifactPath -Parent) (Split-Path $relativeCfePath -Leaf)
    }
    elseif ($storeArtifact) {
        $cfePath = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $relativeCfePath
    }
    else {
        $cfePath = Join-Path (Split-Path $artifactPath -Parent) (Split-Path $relativeCfePath -Leaf)
    }
    if ($storeArtifact -and -not (Test-WorkflowPathUnderRoot -Path $cfePath -Root $repositoryRoot)) {
        throw "A Git-stored CFE artifact must stay inside the repository: $cfePath"
    }
    if (@($artifactPaths | Where-Object {
        [string]::Equals(
            [System.IO.Path]::GetFullPath($_),
            [System.IO.Path]::GetFullPath($cfePath),
            [System.StringComparison]::OrdinalIgnoreCase
        )
    }).Count -gt 0) {
        throw "Multiple release components resolve to the same artifact path: $cfePath"
    }
    if ((Test-Path -LiteralPath $cfePath -PathType Leaf) -and -not $Force) {
        throw "Release extension artifact already exists: $cfePath"
    }
    [System.IO.Directory]::CreateDirectory((Split-Path $cfePath -Parent)) | Out-Null
    Copy-Item -LiteralPath $preflightCfe -Destination $cfePath -Force:$Force
    $cfeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $cfePath).Hash.ToLowerInvariant()
    $artifactPaths += $cfePath
    $artifactRecords += [pscustomobject]@{
        kind = "cfe"
        component = [string]$extension.name
        componentVersion = $extensionVersion
        path = if ($storeArtifact) {
            $cfePath.Substring($repositoryRoot.TrimEnd('\').Length + 1).Replace('\', '/')
        }
        else {
            $cfePath
        }
        sha256 = $cfeHash
        size = (Get-Item -LiteralPath $cfePath).Length
    }
}

$releaseEntry = [pscustomobject]@{
    version = $version
    platformVersion = [string]$config.platformVersion
    sourceCommit = $headCommit
    builtAt = $builtAt
    # Что именно доказано этой сборкой. Без этих двух полей файл рядом с
    # выпускным неотличим от него, а доказано у них разное: полный регресс
    # против объёма задачной фазы.
    releaseReady = -not $AffectedOnly
    webUiScope = $webUiScope
    artifacts = @($artifactRecords)
}

if ($storeArtifact) {
    $manifestPath = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.artifacts.manifest)
    $releases = @()
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $existingManifest = Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8 | ConvertFrom-Json
        # Та же причина, что выше: при Set-StrictMode обращение к отсутствующему
        # свойству бросает исключение, поэтому сначала проверяется его наличие.
        if ($null -ne $existingManifest.PSObject.Properties["releases"] -and $null -ne $existingManifest.releases) {
            $releases += @($existingManifest.releases)
        }
        elseif ($null -ne $existingManifest.PSObject.Properties["configurationVersion"]) {
            # Поля legacy-манифеста читаются через Get-WorkflowSettingValue: состав
            # старого формата не гарантирован, а при Set-StrictMode отсутствие любого
            # из них обрушило бы выпуск целиком.
            $legacyArtifacts = @()
            foreach ($legacyArtifact in @(Get-WorkflowSettingValue -Object $existingManifest -Name "artifacts" -Default @())) {
                $legacyPath = [string](Get-WorkflowSettingValue -Object $legacyArtifact -Name "path" -Default "")
                if (-not $legacyPath) {
                    continue
                }
                if (-not $legacyPath.StartsWith("artifacts/")) {
                    $legacyPath = "artifacts/$legacyPath"
                }
                $legacyArtifacts += [pscustomobject]@{
                    kind = [string](Get-WorkflowSettingValue -Object $legacyArtifact -Name "kind" -Default "")
                    path = $legacyPath
                    sha256 = [string](Get-WorkflowSettingValue -Object $legacyArtifact -Name "sha256" -Default "")
                }
            }
            $releases += [pscustomobject]@{
                version = [string](Get-WorkflowSettingValue -Object $existingManifest -Name "configurationVersion" -Default "")
                platformVersion = [string](Get-WorkflowSettingValue -Object $existingManifest -Name "platformVersion" -Default "")
                sourceCommit = [string](Get-WorkflowSettingValue -Object $existingManifest -Name "sourceCommit" -Default "")
                builtAt = $null
                artifacts = $legacyArtifacts
            }
        }
    }

    $sameVersion = @($releases | Where-Object { [string]$_.version -eq $version })
    if ($sameVersion.Count -gt 0 -and -not $Force) {
        throw "Version $version already exists in the artifact manifest."
    }
    if ($sameVersion.Count -gt 0) {
        $releases = @($releases | Where-Object { [string]$_.version -ne $version })
    }
    $releases += $releaseEntry
    $manifest = [pscustomobject]@{
        schemaVersion = 2
        project = [string]$config.project
        releases = $releases
    }
    Write-WorkflowJson -Value $manifest -Path $manifestPath | Out-Null

    if ($Stage) {
        Invoke-WorkflowGit `
            -RepositoryRoot $repositoryRoot `
            -Arguments (@("add", "--") + $artifactPaths + @($manifestPath)) | Out-Null
    }
}
else {
    Write-WorkflowJson -Value $releaseEntry -Path "$artifactPath.json" | Out-Null
}

if (-not $Force) {
    $preflightRoot = Join-Path $stateDirectory "preflight"
    $preflightTemporaryRoot = [string]$preflightReport.temporaryRoot
    if ($preflightTemporaryRoot) {
        # Общая функция с повторами: выпуск падал здесь ПОСЛЕ того, как артефакт был
        # собран и манифест обновлён — 1С ещё держала файл журнала.
        Remove-WorkflowTemporaryTree `
            -Path $preflightTemporaryRoot `
            -AllowedRoot $preflightRoot | Out-Null
    }
}

Write-Host "Release artifact: $artifactPath"
Write-Host "Version: $version"
Write-Host "Source commit: $headCommit"
Write-Host "SHA256: $sha256"
foreach ($extensionArtifact in @($artifactRecords | Where-Object { $_.kind -eq "cfe" })) {
    Write-Host "Extension artifact [$($extensionArtifact.component)]: $($extensionArtifact.path)"
    Write-Host "Extension SHA256 [$($extensionArtifact.component)]: $($extensionArtifact.sha256)"
}
if ($Stage) {
    Write-Host "Artifact and manifest were staged. No commit or push was performed."
}
