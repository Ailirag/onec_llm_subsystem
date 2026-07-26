[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "manifest\llm-subsystem.json")
)

$ErrorActionPreference = "Stop"

function Get-FullPath {
    param(
        [string]$BasePath,
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Get-ConfigurationObjects {
    param([string]$ConfigurationPath)

    [xml]$configuration = Get-Content -LiteralPath $ConfigurationPath -Raw -Encoding UTF8
    $nodes = $configuration.SelectNodes(
        '/*[local-name()="MetaDataObject"]/*[local-name()="Configuration"]/*[local-name()="ChildObjects"]/*'
    )

    return @(
        $nodes | ForEach-Object {
            "{0}.{1}" -f $_.LocalName, $_.InnerText.Trim()
        }
    )
}

function Get-SubsystemContent {
    param([string]$SubsystemsPath)

    $subsystemFiles = Get-ChildItem -LiteralPath $SubsystemsPath -Recurse -File -Filter "*.xml" |
        Where-Object { $_.FullName -notmatch '[\\/]Ext[\\/]' }

    $result = foreach ($file in $subsystemFiles) {
        [xml]$subsystem = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        $rootObject = $subsystem.SelectSingleNode(
            '/*[local-name()="MetaDataObject"]/*[local-name()="Subsystem"]'
        )
        if ($null -eq $rootObject) {
            continue
        }

        $subsystem.SelectNodes(
            '/*[local-name()="MetaDataObject"]/*[local-name()="Subsystem"]/*[local-name()="Properties"]/*[local-name()="Content"]/*[local-name()="Item"]'
        ) | ForEach-Object {
            $_.InnerText.Trim()
        }
    }

    return @($result)
}

$manifestFullPath = [System.IO.Path]::GetFullPath($ManifestPath)
$repositoryPath = Split-Path (Split-Path $manifestFullPath -Parent) -Parent
$manifest = Get-Content -LiteralPath $manifestFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
$sourcePath = Get-FullPath -BasePath $repositoryPath -Path $manifest.sourceDirectory
$configurationPath = Join-Path $sourcePath "Configuration.xml"
$subsystemsPath = Join-Path $sourcePath "Subsystems"

if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) {
    throw "Configuration.xml was not found: $configurationPath"
}
if (-not (Test-Path -LiteralPath $subsystemsPath -PathType Container)) {
    throw "Subsystems directory was not found: $subsystemsPath"
}

$configurationObjects = @(Get-ConfigurationObjects -ConfigurationPath $configurationPath)
$subsystemContent = @(Get-SubsystemContent -SubsystemsPath $subsystemsPath)
$allowedOutside = @($manifest.allowedOutsideSubsystem)

$missing = @(
    $configurationObjects |
        Where-Object { $_ -notin $subsystemContent -and $_ -notin $allowedOutside } |
        Sort-Object -Unique
)
$dangling = @(
    $subsystemContent |
        Where-Object { $_ -notin $configurationObjects } |
        Sort-Object -Unique
)
$staleAllowList = @(
    $allowedOutside |
        Where-Object { $_ -notin $configurationObjects } |
        Sort-Object -Unique
)

Write-Host ("Configuration objects: {0}" -f $configurationObjects.Count)
Write-Host ("Subsystem content:    {0}" -f @($subsystemContent | Sort-Object -Unique).Count)
Write-Host ("Allowed outside:      {0}" -f $allowedOutside.Count)

if ($missing.Count -gt 0) {
    Write-Error ("Objects outside subsystems:`n  {0}" -f ($missing -join "`n  "))
}
if ($dangling.Count -gt 0) {
    Write-Error ("Subsystem references missing objects:`n  {0}" -f ($dangling -join "`n  "))
}
if ($staleAllowList.Count -gt 0) {
    Write-Error ("Stale allowedOutsideSubsystem entries:`n  {0}" -f ($staleAllowList -join "`n  "))
}

if ($missing.Count -gt 0 -or $dangling.Count -gt 0 -or $staleAllowList.Count -gt 0) {
    exit 1
}

Write-Host "[OK] Every metadata object belongs to a subsystem or is explicitly allowed outside."
