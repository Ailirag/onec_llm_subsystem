[CmdletBinding()]
param(
    [string]$BasePath = (Join-Path $env:LOCALAPPDATA "Ailirag\onec_llm_subsystem\functional-test-base"),
    [string]$V8Path = "",
    [int]$SeedTimeoutSeconds = 120,
    [switch]$Recreate,
    # Новый workflow сохраняет и восстанавливает реестр вокруг прогона сам.
    # Ключ не даёт адаптеру вносить промежуточную запись о временном стенде.
    [switch]$SkipRegistryUpdate,
    # Цикл разработки: база уже поднята и засеяна, пересевать фикстуры не нужно.
    # Экономит COM-подключение и повторную запись тестовых данных на каждой итерации.
    [switch]$SkipSeed,
    # Workflow уже скопировал проверочную базу текущих исходников. В этом режиме
    # адаптер не встраивает LLM повторно: расширение загрузит сам workflow.
    [switch]$SkipConfigurationLoad
)

$ErrorActionPreference = "Stop"

$repositoryPath = Split-Path $PSScriptRoot -Parent
$buildPath = Join-Path $repositoryPath ".build\functional-tests"
$mergedConfigurationPath = Join-Path $buildPath "configuration"

function Resolve-V8Executable {
    param([string]$Path)

    if ($Path) {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $Path = Join-Path $Path "1cv8.exe"
        }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "1C executable was not found: $Path"
        }
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $candidate = Get-ChildItem "C:\Program Files\1cv8\*\bin\1cv8.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Directory.Parent.Name } -Descending |
        Select-Object -First 1
    if (-not $candidate) {
        throw "1cv8.exe was not found. Pass -V8Path explicitly."
    }
    return $candidate.FullName
}

function Invoke-1C {
    param(
        [string]$Arguments,
        [string]$LogName
    )

    $logPath = Join-Path $buildPath $LogName
    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    $argumentLine = "$Arguments /DisableStartupDialogs /DisableStartupMessages /Out `"$logPath`""
    Write-Host "Running: 1cv8.exe $Arguments"
    $process = Start-Process -FilePath $script:V8Executable `
        -ArgumentList $argumentLine `
        -NoNewWindow `
        -Wait `
        -PassThru
    if (Test-Path -LiteralPath $logPath) {
        $logText = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
        if ($logText) {
            Write-Host $logText.Trim()
        }
    }
    if ($process.ExitCode -ne 0) {
        throw "1C command failed with exit code $($process.ExitCode). Log: $logPath"
    }
}

function Set-TestDefaultRoles {
    param([string]$ConfigurationFile)

    [xml]$document = Get-Content -LiteralPath $ConfigurationFile -Raw -Encoding UTF8
    $defaultRoles = $document.SelectSingleNode(
        '/*[local-name()="MetaDataObject"]/*[local-name()="Configuration"]' +
        '/*[local-name()="Properties"]/*[local-name()="DefaultRoles"]'
    )
    if (-not $defaultRoles) {
        throw "DefaultRoles was not found in merged test configuration."
    }

    $rolesDirectory = Join-Path (Split-Path $ConfigurationFile -Parent) "Roles"
    $roleNames = @(
        Get-ChildItem -LiteralPath $rolesDirectory -Filter "*.xml" -File |
            Sort-Object BaseName |
            ForEach-Object { "Role.$($_.BaseName)" }
    )
    if ($roleNames.Count -eq 0) {
        throw "No roles were found in merged test configuration."
    }

    $defaultRoles.RemoveAll()
    foreach ($roleName in $roleNames) {
        $item = $document.CreateElement(
            "xr",
            "Item",
            "http://v8.1c.ru/8.3/xcf/readable"
        )
        $typeAttribute = $document.CreateAttribute(
            "xsi",
            "type",
            "http://www.w3.org/2001/XMLSchema-instance"
        )
        $typeAttribute.Value = "xr:MDObjectRef"
        [void]$item.Attributes.Append($typeAttribute)
        $item.InnerText = $roleName
        [void]$defaultRoles.AppendChild($item)
    }

    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $settings.Indent = $true
    $settings.IndentChars = "`t"
    $settings.NewLineChars = "`r`n"
    $settings.NewLineHandling = [System.Xml.NewLineHandling]::Replace
    $writer = [System.Xml.XmlWriter]::Create($ConfigurationFile, $settings)
    try {
        $document.Save($writer)
    } finally {
        $writer.Dispose()
    }
}

function Update-LocalDatabaseRegistry {
    $registryPath = Join-Path $repositoryPath ".v8-project.json"
    if (Test-Path -LiteralPath $registryPath) {
        $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
    } else {
        $registry = [pscustomobject]@{
            v8path = (Split-Path $script:V8Executable -Parent)
            databases = @()
            default = "llm-functional-test"
        }
    }

    $registry.v8path = Split-Path $script:V8Executable -Parent
    $databases = @($registry.databases | Where-Object { $_.id -ne "llm-functional-test" })
    $databases += [pscustomobject]@{
        id = "llm-functional-test"
        name = "LLM subsystem functional tests"
        type = "file"
        path = $BasePath
        user = ""
        password = ""
        aliases = @("llm-test", "functional-test")
        branches = @("codex/*")
        configSrc = $mergedConfigurationPath
    }
    $registry.databases = $databases
    if (-not $registry.default) {
        $registry.default = "llm-functional-test"
    }

    $json = $registry | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText(
        $registryPath,
        $json + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

$V8Executable = Resolve-V8Executable $V8Path
New-Item -ItemType Directory -Path $buildPath -Force | Out-Null

$baseFullPath = [System.IO.Path]::GetFullPath($BasePath)
if ($Recreate -and (Test-Path -LiteralPath $baseFullPath)) {
    $rootPath = [System.IO.Path]::GetPathRoot($baseFullPath)
    if ($baseFullPath.TrimEnd("\") -eq $rootPath.TrimEnd("\") -or $baseFullPath.Length -lt 12) {
        throw "Refusing to remove unsafe base path: $baseFullPath"
    }
    Remove-Item -LiteralPath $baseFullPath -Recurse -Force
}

if (-not $SkipConfigurationLoad) {
    $manifestPath = Join-Path $repositoryPath "manifest\llm-subsystem.json"
    & (Join-Path $PSScriptRoot "Build-EmbeddedConfiguration.ps1") `
        -ManifestPath $manifestPath
    & (Join-Path $PSScriptRoot "Merge-EmbeddedConfiguration.ps1") `
        -TargetConfigurationPath (Join-Path $repositoryPath "cf") `
        -DonorConfigurationPath (Join-Path $repositoryPath "cf llm") `
        -OutputDirectory $mergedConfigurationPath
    Set-TestDefaultRoles (Join-Path $mergedConfigurationPath "Configuration.xml")
    Copy-Item -LiteralPath (Join-Path $repositoryPath 'tests/fixtures/result-handler.bsl') `
        -Destination (Join-Path $mergedConfigurationPath 'CommonModules/AI_ОбработчикиРезультатовПереопределяемый/Ext/Module.bsl') -Force

    if (-not (Test-Path -LiteralPath (Join-Path $baseFullPath "1Cv8.1CD"))) {
        New-Item -ItemType Directory -Path $baseFullPath -Force | Out-Null
        Invoke-1C `
            -Arguments "CREATEINFOBASE `"File=$baseFullPath;`"" `
            -LogName "create-base.log"
    }

    Invoke-1C `
        -Arguments "DESIGNER /F`"$baseFullPath`" /LoadConfigFromFiles `"$mergedConfigurationPath`" -Format Hierarchical" `
        -LogName "load-configuration.log"
    Invoke-1C `
        -Arguments "DESIGNER /F`"$baseFullPath`" /UpdateDBCfg" `
        -LogName "update-database.log"
}
elseif (-not (Test-Path -LiteralPath (Join-Path $baseFullPath "1Cv8.1CD") -PathType Leaf)) {
    throw "Workflow не передал готовую проверочную базу: $baseFullPath"
}

if ($SkipSeed) {
    Write-Host "Пересев фикстур пропущен (-SkipSeed)."
    if (-not $SkipRegistryUpdate) {
        Update-LocalDatabaseRegistry
    }
    Write-Host ""
    Write-Host "[OK] Функциональная база обновлена: $baseFullPath"
    return
}

& (Join-Path $PSScriptRoot "Invoke-FunctionalSeed.ps1") `
    -BasePath $baseFullPath `
    -TimeoutSeconds $SeedTimeoutSeconds

if (-not $SkipRegistryUpdate) {
    Update-LocalDatabaseRegistry
}

Write-Host ""
Write-Host "[OK] Persistent functional test base is ready:"
Write-Host "     Base:  $baseFullPath"
Write-Host "     Alias: llm-functional-test"
