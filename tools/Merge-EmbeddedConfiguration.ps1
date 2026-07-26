[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetConfigurationPath,

    [string]$DonorConfigurationPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "cf llm"),

    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) ".build\merged-cf")
)

$ErrorActionPreference = "Stop"

$objectDirectories = @{
    Language             = "Languages"
    Subsystem            = "Subsystems"
    CommonPicture        = "CommonPictures"
    SessionParameter     = "SessionParameters"
    Role                 = "Roles"
    CommonTemplate       = "CommonTemplates"
    CommonModule         = "CommonModules"
    EventSubscription    = "EventSubscriptions"
    ScheduledJob         = "ScheduledJobs"
    Constant             = "Constants"
    Catalog              = "Catalogs"
    Enum                 = "Enums"
    DataProcessor        = "DataProcessors"
    InformationRegister = "InformationRegisters"
}

$objectTypeOrder = @(
    "Language",
    "Subsystem",
    "CommonPicture",
    "SessionParameter",
    "Role",
    "CommonTemplate",
    "CommonModule",
    "EventSubscription",
    "ScheduledJob",
    "Constant",
    "Catalog",
    "Enum",
    "DataProcessor",
    "InformationRegister"
)

function Get-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-OutputPath {
    param(
        [string]$RepositoryPath,
        [string]$Path
    )

    $repositoryPrefix = (Get-FullPath $RepositoryPath).TrimEnd("\") + "\"
    $fullPath = Get-FullPath $Path
    if (-not $fullPath.StartsWith(
        $repositoryPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Output directory must stay inside the repository: $fullPath"
    }
}

function Get-ConfigurationNode {
    param([xml]$Document)

    return $Document.SelectSingleNode(
        '/*[local-name()="MetaDataObject"]/*[local-name()="Configuration"]'
    )
}

function Get-ChildObjectReference {
    param([System.Xml.XmlElement]$Node)
    return "{0}.{1}" -f $Node.LocalName, $Node.InnerText.Trim()
}

function Get-MetadataPath {
    param(
        [string]$ConfigurationPath,
        [System.Xml.XmlElement]$ChildNode
    )

    if (-not $objectDirectories.ContainsKey($ChildNode.LocalName)) {
        throw "No directory mapping for metadata type: $($ChildNode.LocalName)"
    }

    return Join-Path $ConfigurationPath (
        "{0}\{1}.xml" -f $objectDirectories[$ChildNode.LocalName], $ChildNode.InnerText.Trim()
    )
}

function Get-MetadataUuid {
    param([string]$MetadataPath)

    [xml]$metadata = Get-Content -LiteralPath $MetadataPath -Raw -Encoding UTF8
    $metadataObject = $metadata.SelectSingleNode(
        '/*[local-name()="MetaDataObject"]/*[1]'
    )
    return $metadataObject.GetAttribute("uuid")
}

function Copy-MetadataObject {
    param(
        [string]$SourceConfigurationPath,
        [string]$TargetConfigurationPath,
        [System.Xml.XmlElement]$ChildNode
    )

    $directoryName = $objectDirectories[$ChildNode.LocalName]
    $objectName = $ChildNode.InnerText.Trim()
    $sourceDirectory = Join-Path $SourceConfigurationPath $directoryName
    $targetDirectory = Join-Path $TargetConfigurationPath $directoryName
    $sourceMetadataFile = Join-Path $sourceDirectory ("{0}.xml" -f $objectName)
    $targetMetadataFile = Join-Path $targetDirectory ("{0}.xml" -f $objectName)
    $sourceObjectDirectory = Join-Path $sourceDirectory $objectName
    $targetObjectDirectory = Join-Path $targetDirectory $objectName

    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    Copy-Item -LiteralPath $sourceMetadataFile -Destination $targetMetadataFile -Force

    if (Test-Path -LiteralPath $targetObjectDirectory) {
        Remove-Item -LiteralPath $targetObjectDirectory -Recurse -Force
    }
    if (Test-Path -LiteralPath $sourceObjectDirectory) {
        Copy-Item -LiteralPath $sourceObjectDirectory -Destination $targetObjectDirectory -Recurse -Force
    }
}

function Save-Xml {
    param(
        [xml]$Document,
        [string]$Path
    )

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $settings.Indent = $true
    $settings.IndentChars = "`t"
    $settings.NewLineChars = "`r`n"
    $settings.NewLineHandling = [System.Xml.NewLineHandling]::Replace

    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    try {
        $Document.Save($writer)
    }
    finally {
        $writer.Dispose()
    }
}

$repositoryPath = Split-Path $PSScriptRoot -Parent
$targetPath = Get-FullPath $TargetConfigurationPath
$donorPath = Get-FullPath $DonorConfigurationPath
$outputPath = Get-FullPath $OutputDirectory
Assert-OutputPath -RepositoryPath $repositoryPath -Path $outputPath

$targetConfigurationFile = Join-Path $targetPath "Configuration.xml"
$donorConfigurationFile = Join-Path $donorPath "Configuration.xml"
if (-not (Test-Path -LiteralPath $targetConfigurationFile -PathType Leaf)) {
    throw "Target Configuration.xml was not found: $targetConfigurationFile"
}
if (-not (Test-Path -LiteralPath $donorConfigurationFile -PathType Leaf)) {
    throw "Donor Configuration.xml was not found: $donorConfigurationFile"
}

[xml]$targetConfiguration = Get-Content -LiteralPath $targetConfigurationFile -Raw -Encoding UTF8
[xml]$donorConfiguration = Get-Content -LiteralPath $donorConfigurationFile -Raw -Encoding UTF8
$targetRoot = Get-ConfigurationNode -Document $targetConfiguration
$donorRoot = Get-ConfigurationNode -Document $donorConfiguration
$targetChildren = @($targetRoot.SelectNodes('./*[local-name()="ChildObjects"]/*'))
$donorChildren = @($donorRoot.SelectNodes('./*[local-name()="ChildObjects"]/*'))
$targetByReference = @{}

foreach ($child in $targetChildren) {
    $targetByReference[(Get-ChildObjectReference $child)] = $child
}

$conflicts = @()
foreach ($donorChild in $donorChildren) {
    $reference = Get-ChildObjectReference $donorChild
    if (-not $targetByReference.ContainsKey($reference)) {
        continue
    }
    if ($donorChild.LocalName -eq "Language") {
        continue
    }

    $targetUuid = Get-MetadataUuid (Get-MetadataPath -ConfigurationPath $targetPath -ChildNode $targetByReference[$reference])
    $donorUuid = Get-MetadataUuid (Get-MetadataPath -ConfigurationPath $donorPath -ChildNode $donorChild)
    if ($targetUuid -ne $donorUuid) {
        $conflicts += "{0}: target={1}, donor={2}" -f $reference, $targetUuid, $donorUuid
    }
}

if ($conflicts.Count -gt 0) {
    throw "Metadata conflicts found:`n  $($conflicts -join "`n  ")"
}

if (Test-Path -LiteralPath $outputPath) {
    Get-ChildItem -LiteralPath $outputPath -Force | Remove-Item -Recurse -Force
}
else {
    New-Item -ItemType Directory -Path $outputPath | Out-Null
}
Get-ChildItem -LiteralPath $targetPath -Force |
    Where-Object { $_.Name -ne "ConfigDumpInfo.xml" } |
    Copy-Item -Destination $outputPath -Recurse -Force

$mergedNodes = New-Object System.Collections.Generic.List[System.Xml.XmlElement]
foreach ($targetChild in $targetChildren) {
    $mergedNodes.Add($targetChild)
}

$addedCount = 0
$updatedCount = 0
foreach ($donorChild in $donorChildren) {
    $reference = Get-ChildObjectReference $donorChild
    if ($donorChild.LocalName -eq "Language" -and $targetByReference.ContainsKey($reference)) {
        continue
    }

    Copy-MetadataObject -SourceConfigurationPath $donorPath -TargetConfigurationPath $outputPath -ChildNode $donorChild

    if ($targetByReference.ContainsKey($reference)) {
        $updatedCount++
        continue
    }

    $mergedNodes.Add($donorChild)
    $targetByReference[$reference] = $donorChild
    $addedCount++
}

$targetChildObjects = $targetRoot.SelectSingleNode('./*[local-name()="ChildObjects"]')
$targetChildObjects.RemoveAll()
foreach ($objectType in $objectTypeOrder) {
    foreach ($node in $mergedNodes | Where-Object { $_.LocalName -eq $objectType }) {
        $importedNode = $targetConfiguration.ImportNode($node, $true)
        $targetChildObjects.AppendChild($importedNode) | Out-Null
    }
}

$targetConfigurationName = $targetRoot.SelectSingleNode(
    './*[local-name()="Properties"]/*[local-name()="Name"]'
).InnerText.Trim()
$donorConfigurationName = $donorRoot.SelectSingleNode(
    './*[local-name()="Properties"]/*[local-name()="Name"]'
).InnerText.Trim()
$donorConfigurationReference = "Configuration.{0}" -f $donorConfigurationName
$targetConfigurationReference = "Configuration.{0}" -f $targetConfigurationName

Get-ChildItem -LiteralPath (Join-Path $outputPath "Roles") -Recurse -File -Filter "Rights.xml" |
    ForEach-Object {
        [xml]$rights = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        $changed = $false
        $rights.SelectNodes('//*[local-name()="name"]') |
            Where-Object { $_.InnerText.Trim() -eq $donorConfigurationReference } |
            ForEach-Object {
                $_.InnerText = $targetConfigurationReference
                $changed = $true
            }
        if ($changed) {
            Save-Xml -Document $rights -Path $_.FullName
        }
    }

Save-Xml -Document $targetConfiguration -Path (Join-Path $outputPath "Configuration.xml")

Write-Host ("[OK] Embedded subsystem merged into: {0}" -f $outputPath)
Write-Host ("     Added objects:   {0}" -f $addedCount)
Write-Host ("     Updated objects: {0}" -f $updatedCount)
Write-Host ("     Target root:     {0}" -f $targetConfigurationReference)
