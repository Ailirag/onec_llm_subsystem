[CmdletBinding()]
param(
    [ValidateSet("Generate", "Validate")]
    [string]$Action = "Generate",

    [string]$BasePath = "",
    [string]$V8Path = "",
    [switch]$SkipHttp
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Workflow.Common.ps1")

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
if (-not [bool]$config.functionalTests.enabled) {
    throw "Functional test data generation is disabled in .1c-workflow.json."
}
$extensions = @(Get-WorkflowExtensions -RepositoryRoot $repositoryRoot -Config $config -AllowMissingOptional)
# Сид — отдельный шаг, если перед ним ставятся расширения или исполнитель стенда:
# внутри initializeScript он выполнился бы раньше них.
$standExecEnabled = Test-WorkflowStandExecEnabled -Config $config
$separateSeed = $extensions.Count -gt 0 -or $standExecEnabled
$stateDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.localStateDir)

$scriptRelativePath = if ($Action -eq "Generate") {
    [string]$config.functionalTests.initializeScript
}
else {
    [string]$config.functionalTests.smokeScript
}
$scriptPath = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $scriptRelativePath
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Functional test script was not found: $scriptPath"
}

$state = Read-WorkflowState -RepositoryRoot $repositoryRoot -Config $config
if (-not $BasePath -and $null -ne $state) {
    $BasePath = [string]$state.basePath
}
if (-not $BasePath -and $Action -eq "Generate" -and $separateSeed) {
    $BasePath = Join-Path $stateDirectory "test-data\base"
}
$arguments = @()
if ($BasePath) {
    $BasePath = [System.IO.Path]::GetFullPath($BasePath)
    $arguments += @("-BasePath", $BasePath)
}
if ($V8Path -and $Action -eq "Generate") {
    $arguments += @("-V8Path", $V8Path)
}
if ($SkipHttp -and $Action -eq "Validate") {
    $arguments += "-SkipHttp"
}

$logPath = Join-Path $stateDirectory "logs\test-data-$($Action.ToLowerInvariant()).log"

if ($Action -eq "Generate" -and $separateSeed) {
    if (-not $BasePath) {
        throw "A functional test BasePath is required when extensions or standExec are enabled."
    }
    # Порядок подготовки один на все места, где стенд собирается вне фазы:
    # см. Invoke-WorkflowStandPreparation.
    Invoke-WorkflowStandPreparation `
        -RepositoryRoot $repositoryRoot `
        -Config $config `
        -BasePath $BasePath `
        -InitializeArguments $arguments `
        -V8Path $V8Path `
        -LogDirectory (Join-Path $stateDirectory "logs\test-data")
    Write-Host "Functional test action '$Action' completed. Logs: $(Join-Path $stateDirectory 'logs\test-data')"
    return
}

Invoke-WorkflowPowerShell `
    -ScriptPath $scriptPath `
    -Arguments $arguments `
    -LogPath $logPath | Out-Null
Write-Host "Functional test action '$Action' completed. Log: $logPath"
