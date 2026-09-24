[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "manifest\llm-subsystem.json"),
    [switch]$KeepOutput
)

$ErrorActionPreference = "Stop"

$objectDirectories = @{
    Language            = "Languages"
    Subsystem           = "Subsystems"
    CommonPicture       = "CommonPictures"
    SessionParameter    = "SessionParameters"
    Role                = "Roles"
    CommonTemplate      = "CommonTemplates"
    CommonModule        = "CommonModules"
    EventSubscription   = "EventSubscriptions"
    ScheduledJob        = "ScheduledJobs"
    Constant            = "Constants"
    CommonForm          = "CommonForms"
    Catalog             = "Catalogs"
    Enum                = "Enums"
    DataProcessor       = "DataProcessors"
    InformationRegister = "InformationRegisters"
}

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

function Assert-OutputPath {
    param(
        [string]$RepositoryPath,
        [string]$OutputPath
    )

    $repositoryPrefix = [System.IO.Path]::GetFullPath($RepositoryPath).TrimEnd("\") + "\"
    $fullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)

    if (-not $fullOutputPath.StartsWith(
        $repositoryPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Output path must stay inside the repository: $fullOutputPath"
    }
    if ($fullOutputPath -eq $repositoryPrefix.TrimEnd("\")) {
        throw "Repository root cannot be used as output path."
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

function Set-ElementText {
    param(
        [System.Xml.XmlElement]$Parent,
        [string]$ElementName,
        [string]$Value
    )

    $node = $Parent.SelectSingleNode(('./*[local-name()="{0}"]' -f $ElementName))
    if ($null -eq $node) {
        throw "Required configuration property was not found: $ElementName"
    }
    $node.InnerText = $Value
}

function Set-LocalizedElementText {
    param(
        [System.Xml.XmlElement]$Parent,
        [string]$ElementName,
        [string]$Value,
        [string]$Language = "ru"
    )

    $node = $Parent.SelectSingleNode(('./*[local-name()="{0}"]' -f $ElementName))
    if ($null -eq $node) {
        throw "Required configuration property was not found: $ElementName"
    }

    $node.RemoveAll()
    $namespace = "http://v8.1c.ru/8.1/data/core"
    $itemNode = $node.OwnerDocument.CreateElement("v8", "item", $namespace)
    $languageNode = $node.OwnerDocument.CreateElement("v8", "lang", $namespace)
    $contentNode = $node.OwnerDocument.CreateElement("v8", "content", $namespace)
    $languageNode.InnerText = $Language
    $contentNode.InnerText = $Value
    $itemNode.AppendChild($languageNode) | Out-Null
    $itemNode.AppendChild($contentNode) | Out-Null
    $node.AppendChild($itemNode) | Out-Null
}

$manifestFullPath = [System.IO.Path]::GetFullPath($ManifestPath)
$repositoryPath = Split-Path (Split-Path $manifestFullPath -Parent) -Parent
$manifest = Get-Content -LiteralPath $manifestFullPath -Raw -Encoding UTF8 | ConvertFrom-Json
$sourcePath = Get-FullPath -BasePath $repositoryPath -Path $manifest.sourceDirectory
$outputPath = Get-FullPath -BasePath $repositoryPath -Path $manifest.embeddedDirectory
$ordinaryConfigurationTemplate = Join-Path $repositoryPath "cf\Configuration.xml"

Assert-OutputPath -RepositoryPath $repositoryPath -OutputPath $outputPath

& (Join-Path $PSScriptRoot "Test-SubsystemCoverage.ps1") -ManifestPath $manifestFullPath
if (-not $?) {
    throw "Subsystem coverage check failed."
}

if (-not (Test-Path -LiteralPath $ordinaryConfigurationTemplate -PathType Leaf)) {
    throw "Ordinary configuration template was not found: $ordinaryConfigurationTemplate"
}

if (Test-Path -LiteralPath $outputPath) {
    if (-not $KeepOutput) {
        Get-ChildItem -LiteralPath $outputPath -Force | Remove-Item -Recurse -Force
    }
}
else {
    New-Item -ItemType Directory -Path $outputPath | Out-Null
}

[xml]$sourceConfiguration = Get-Content -LiteralPath (Join-Path $sourcePath "Configuration.xml") -Raw -Encoding UTF8
[xml]$targetConfiguration = Get-Content -LiteralPath $ordinaryConfigurationTemplate -Raw -Encoding UTF8

$sourceRoot = $sourceConfiguration.SelectSingleNode(
    '/*[local-name()="MetaDataObject"]/*[local-name()="Configuration"]'
)
$targetRoot = $targetConfiguration.SelectSingleNode(
    '/*[local-name()="MetaDataObject"]/*[local-name()="Configuration"]'
)
$sourceProperties = $sourceRoot.SelectSingleNode('./*[local-name()="Properties"]')
$targetProperties = $targetRoot.SelectSingleNode('./*[local-name()="Properties"]')
$sourceConfigurationName = $sourceProperties.SelectSingleNode('./*[local-name()="Name"]').InnerText.Trim()

$targetRoot.SetAttribute("uuid", [string]$manifest.configuration.uuid)
$internalIds = @($manifest.configuration.internalObjectIds)
$internalIdNodes = @(
    $targetRoot.SelectNodes(
        './*[local-name()="InternalInfo"]/*[local-name()="ContainedObject"]/*[local-name()="ObjectId"]'
    )
)
if ($internalIdNodes.Count -ne $internalIds.Count) {
    throw "InternalInfo ID count does not match the manifest."
}
for ($index = 0; $index -lt $internalIdNodes.Count; $index++) {
    $internalIdNodes[$index].InnerText = [string]$internalIds[$index]
}

Set-ElementText -Parent $targetProperties -ElementName "Name" -Value $manifest.configuration.name
Set-ElementText -Parent $targetProperties -ElementName "ConfigurationExtensionCompatibilityMode" -Value $manifest.configuration.compatibilityMode
Set-ElementText -Parent $targetProperties -ElementName "Vendor" -Value $manifest.configuration.vendor
Set-ElementText -Parent $targetProperties -ElementName "Version" -Value $manifest.configuration.version
Set-LocalizedElementText -Parent $targetProperties -ElementName "Copyright" -Value $manifest.configuration.copyright
Set-LocalizedElementText -Parent $targetProperties -ElementName "VendorInformationAddress" -Value $manifest.configuration.vendorInformationAddress
Set-LocalizedElementText -Parent $targetProperties -ElementName "ConfigurationInformationAddress" -Value $manifest.configuration.configurationInformationAddress

$sourceSynonym = $sourceProperties.SelectSingleNode('./*[local-name()="Synonym"]')
$targetSynonym = $targetProperties.SelectSingleNode('./*[local-name()="Synonym"]')
$newSynonym = $targetConfiguration.ImportNode($sourceSynonym, $true)
$synonymContent = $newSynonym.SelectSingleNode('.//*[local-name()="content"]')
$synonymContent.InnerText = [string]$manifest.configuration.synonym
$targetProperties.ReplaceChild($newSynonym, $targetSynonym) | Out-Null

$sourceDefaultRoles = $sourceProperties.SelectSingleNode('./*[local-name()="DefaultRoles"]')
$targetDefaultRoles = $targetProperties.SelectSingleNode('./*[local-name()="DefaultRoles"]')
$newDefaultRoles = $targetConfiguration.ImportNode($sourceDefaultRoles, $true)
$targetProperties.ReplaceChild($newDefaultRoles, $targetDefaultRoles) | Out-Null

$targetChildObjects = $targetRoot.SelectSingleNode('./*[local-name()="ChildObjects"]')
$targetChildObjects.RemoveAll()
$excludedObjects = @($manifest.excludedFromEmbedded)
$sourceChildNodes = $sourceRoot.SelectNodes('./*[local-name()="ChildObjects"]/*')
$includedChildNodes = @()

foreach ($sourceChildNode in $sourceChildNodes) {
    $objectReference = "{0}.{1}" -f $sourceChildNode.LocalName, $sourceChildNode.InnerText.Trim()
    if ($objectReference -in $excludedObjects) {
        continue
    }

    $includedChildNodes += $sourceChildNode
    $importedNode = $targetConfiguration.ImportNode($sourceChildNode, $true)
    $targetChildObjects.AppendChild($importedNode) | Out-Null
}

foreach ($objectType in @($includedChildNodes | ForEach-Object LocalName | Sort-Object -Unique)) {
    if (-not $objectDirectories.ContainsKey($objectType)) {
        throw "No source directory mapping for metadata type: $objectType"
    }

    $directoryName = $objectDirectories[$objectType]
    $sourceDirectory = Join-Path $sourcePath $directoryName
    $targetDirectory = Join-Path $outputPath $directoryName

    if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
        throw "Source metadata directory was not found: $sourceDirectory"
    }

    New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    Get-ChildItem -LiteralPath $sourceDirectory -Force |
        Copy-Item -Destination $targetDirectory -Recurse -Force
}

$languageNode = $includedChildNodes | Where-Object { $_.LocalName -eq "Language" } | Select-Object -First 1
if ($null -eq $languageNode) {
    throw "The embedded configuration must contain a language."
}
$targetLanguagePath = Join-Path $outputPath ("Languages\{0}.xml" -f $languageNode.InnerText.Trim())
[xml]$targetLanguage = Get-Content -LiteralPath $targetLanguagePath -Raw -Encoding UTF8
$objectBelonging = $targetLanguage.SelectSingleNode(
    '/*[local-name()="MetaDataObject"]/*[local-name()="Language"]/*[local-name()="Properties"]/*[local-name()="ObjectBelonging"]'
)
if ($null -ne $objectBelonging) {
    $objectBelonging.ParentNode.RemoveChild($objectBelonging) | Out-Null
}

$targetConfiguration.DocumentElement.SetAttribute("version", "2.20")
$targetLanguage.DocumentElement.SetAttribute("version", "2.20")

Get-ChildItem -LiteralPath (Join-Path $outputPath "Roles") -Recurse -File -Filter "Rights.xml" |
    ForEach-Object {
        [xml]$rights = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        $sourceConfigurationReference = "Configuration.{0}" -f $sourceConfigurationName
        $targetConfigurationReference = "Configuration.{0}" -f $manifest.configuration.name
        $changed = $false

        $rights.SelectNodes('//*[local-name()="name"]') |
            Where-Object { $_.InnerText.Trim() -eq $sourceConfigurationReference } |
            ForEach-Object {
                $_.InnerText = $targetConfigurationReference
                $changed = $true
            }

        if ($changed) {
            Save-Xml -Document $rights -Path $_.FullName
        }
    }

Save-Xml -Document $targetConfiguration -Path (Join-Path $outputPath "Configuration.xml")
Save-Xml -Document $targetLanguage -Path $targetLanguagePath

Write-Host ("[OK] Embedded configuration generated: {0}" -f $outputPath)
Write-Host ("     Objects: {0}" -f $includedChildNodes.Count)
Write-Host ("     Compatibility: {0}" -f $manifest.configuration.compatibilityMode)
