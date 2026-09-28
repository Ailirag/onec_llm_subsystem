[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Objects,

    [string]$Component = "main",

    [string]$BasePath = "",
    [string]$Database = "",
    [string]$V8Path = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Workflow.Common.ps1")

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
$state = Read-WorkflowState -RepositoryRoot $repositoryRoot -Config $config
if ($null -eq $state) {
    throw "Local workflow state is missing. Run Initialize-Developer.ps1 first."
}

$branchName = Get-WorkflowBranchName -RepositoryRoot $repositoryRoot
if ([string]$state.branch -ne $branchName) {
    throw "The local database belongs to branch '$($state.branch)', but the current branch is '$branchName'."
}
$infoBase = Resolve-WorkflowInfoBase `
    -RepositoryRoot $repositoryRoot `
    -Config $config `
    -BranchName $branchName `
    -Database $Database `
    -ExplicitPath $BasePath `
    -FallbackPath ([string]$state.basePath)
$isFileBase = [string]$infoBase.Kind -ne "server"
$baseFullPath = if ($isFileBase) { [System.IO.Path]::GetFullPath([string]$infoBase.Path) } else { "" }
$infoBaseArguments = @(Get-WorkflowInfoBaseSkillArguments -InfoBase $infoBase)
# Существование проверяется только у файловой базы: у серверной ответ знает
# кластер, и подменять его проверкой пути значило бы отказывать по ложной причине.
if ($isFileBase -and -not (Test-Path -LiteralPath (Join-Path $baseFullPath "1Cv8.1CD") -PathType Leaf)) {
    throw "Branch-specific information base was not found: $baseFullPath"
}

$extensions = @(Get-WorkflowExtensions -RepositoryRoot $repositoryRoot -Config $config -AllowMissingOptional)
$selectedExtension = $null
if ($Component -eq "main") {
    $sourceDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.sourceDir)
}
else {
    $selectedExtension = @(
        $extensions | Where-Object { [string]$_.name -eq $Component }
    ) | Select-Object -First 1
    if ($null -eq $selectedExtension) {
        throw "Unknown workflow component '$Component'. Expected 'main' or one of: $($extensions.name -join ', ')."
    }
    $sourceDirectory = [string]$selectedExtension.sourcePath
}
$v8Executable = Resolve-WorkflowV8Path -Config $config -V8Path $V8Path
$ccRoot = Resolve-Cc1CSkillsRoot -Config $config
$stateDirectory = Split-Path (Get-WorkflowStatePath -RepositoryRoot $repositoryRoot -Config $config) -Parent
$timestamp = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
$exportDirectory = Join-Path $stateDirectory "designer-import\$timestamp\$Component"
$logPath = Join-Path $exportDirectory "dump.log"
[System.IO.Directory]::CreateDirectory($exportDirectory) | Out-Null

$dumpScript = Resolve-CcSkillScript `
    -Cc1CSkillsRoot $ccRoot `
    -SkillName "db-dump-xml" `
    -ScriptName "db-dump-xml.ps1"
$objectList = ($Objects | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ","
if (-not $objectList) {
    throw "At least one metadata object must be specified."
}

$dumpArguments = @("-V8Path", $v8Executable) + $infoBaseArguments + @(
    "-ConfigDir", $exportDirectory,
    "-Mode", "Partial",
    "-Objects", $objectList
)
if ($null -ne $selectedExtension) {
    $dumpArguments += @("-Extension", ([string]$selectedExtension.name))
}
Invoke-WorkflowPowerShell `
    -ScriptPath $dumpScript `
    -Arguments $dumpArguments `
    -LogPath $logPath | Out-Null

function Get-RelativeWorkflowFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $rootPrefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "File is outside the expected root: $fullPath"
    }
    return $fullPath.Substring($rootPrefix.Length).Replace('\', '/')
}

$exportedFiles = @{}
Get-ChildItem -LiteralPath $exportDirectory -File -Recurse |
    Where-Object {
        $_.FullName -ne $logPath -and
        $_.Name -ne "ConfigDumpInfo.xml"
    } |
    ForEach-Object {
        $relativePath = Get-RelativeWorkflowFile -Root $exportDirectory -Path $_.FullName
        $exportedFiles[$relativePath] = $_.FullName
    }

if ($exportedFiles.Count -eq 0) {
    throw "The partial Configurator export did not contain metadata files."
}

$objectRoots = @(
    $exportedFiles.Keys |
        Where-Object { $_ -match '^[^/]+/[^/]+\.xml$' } |
        ForEach-Object { $_.Substring(0, $_.Length - 4) }
)

$sourceFiles = @{}
Get-ChildItem -LiteralPath $sourceDirectory -File -Recurse |
    ForEach-Object {
        $relativePath = Get-RelativeWorkflowFile -Root $sourceDirectory -Path $_.FullName
        $isCovered = $exportedFiles.ContainsKey($relativePath)
        if (-not $isCovered) {
            foreach ($objectRoot in $objectRoots) {
                if ($relativePath.StartsWith("$objectRoot/", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isCovered = $true
                    break
                }
            }
        }
        if ($isCovered) {
            $sourceFiles[$relativePath] = $_.FullName
        }
    }

$relativePaths = @(
    @($exportedFiles.Keys) + @($sourceFiles.Keys) |
        Sort-Object -Unique
)
$differences = @()
foreach ($relativePath in $relativePaths) {
    $hasExport = $exportedFiles.ContainsKey($relativePath)
    $hasSource = $sourceFiles.ContainsKey($relativePath)
    $status = ""

    if ($hasExport -and -not $hasSource) {
        $status = "A"
    }
    elseif ($hasSource -and -not $hasExport) {
        $status = "D"
    }
    elseif (
        (Get-FileHash -Algorithm SHA256 -LiteralPath $exportedFiles[$relativePath]).Hash -ne
        (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceFiles[$relativePath]).Hash
    ) {
        $status = "M"
    }

    if ($status) {
        $differences += [pscustomobject]@{
            status = $status
            path = $relativePath
        }
    }
}

$report = [pscustomobject]@{
    operation = "designer-import"
    branch = $branchName
    component = $Component
    basePath = $baseFullPath
    objects = @($Objects)
    exportDirectory = $exportDirectory
    exportedFileCount = $exportedFiles.Count
    differences = @($differences)
    createdAt = [DateTimeOffset]::Now.ToString("o")
}
$reportPath = Join-Path $exportDirectory "report.json"
Write-WorkflowJson -Value $report -Path $reportPath | Out-Null

Write-Host "Configurator changes were exported to an isolated directory."
Write-Host "Export: $exportDirectory"
Write-Host "Report: $reportPath"
Write-Host "Component: $Component"
Write-Host "No files under '$($sourceDirectory.Substring($repositoryRoot.TrimEnd('\').Length + 1).Replace('\', '/'))' were overwritten."
if ($differences.Count -gt 0) {
    Write-Host "Differences:"
    $differences | ForEach-Object { Write-Host "  $($_.status) $($_.path)" }
}
