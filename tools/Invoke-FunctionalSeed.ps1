<#
.SYNOPSIS
Проектный адаптер наполнения функционального стенда.

.DESCRIPTION
Комплект задаёт контракт -BasePath, а данные и способ их записи определяет
проект. Замените тело проектной реализацией; файл намеренно не входит в замок.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BasePath,
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"

$repositoryPath = Split-Path $PSScriptRoot -Parent
$buildPath = Join-Path $repositoryPath ".build\functional-tests"
$modeRunner = Join-Path $PSScriptRoot "Invoke-1CFunctionalTestMode.ps1"
$resultFile = Join-Path $buildPath "seed-result.txt"
$standardOutput = Join-Path $buildPath "seed-com.stdout.log"
$standardError = Join-Path $buildPath "seed-com.stderr.log"

if (-not (Test-Path -LiteralPath (Join-Path $BasePath "1Cv8.1CD") -PathType Leaf)) {
    throw "Функциональная база не существует: $BasePath"
}

New-Item -ItemType Directory -Path $buildPath -Force | Out-Null
Remove-Item -LiteralPath $resultFile,$standardOutput,$standardError -Force -ErrorAction SilentlyContinue

# Только для одноразового стенда: функциональные сценарии проверяют HTTP и
# файловый импорт/экспорт расширения. В рабочей базе эти флаги не меняются.
. (Join-Path $repositoryPath "scripts\workflow\Workflow.Common.ps1")
$standInfoBase = ConvertTo-WorkflowStandInfoBase -BasePath $BasePath
Disable-WorkflowExtensionSafeMode `
    -RepositoryRoot $repositoryPath `
    -InfoBase $standInfoBase `
    -ExtensionNames @("LLM") `
    -LogPath (Join-Path $buildPath "disable-extension-safe-mode.log")

$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$modeRunner`" " +
    "-BasePath `"$BasePath`" -Mode seed -ResultPath `"$resultFile`""
$process = Start-Process -FilePath "powershell.exe" `
    -ArgumentList $arguments `
    -WindowStyle Hidden `
    -RedirectStandardOutput $standardOutput `
    -RedirectStandardError $standardError `
    -PassThru
if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "Наполнение функционального стенда превысило таймаут $TimeoutSeconds с."
}
$process.WaitForExit()

if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) {
    throw "Seed не создал файл результата. Диагностика: $standardError"
}
$resultLines = @(Get-Content -LiteralPath $resultFile -Encoding UTF8)
$resultLines | ForEach-Object { Write-Host $_ }
if ($resultLines.Count -eq 0 -or $resultLines[0] -ne "OK") {
    throw "Наполнение функционального стенда завершилось ошибкой. Результат: $resultFile"
}

Write-Host "[OK] Функциональный стенд наполнен: $([System.IO.Path]::GetFullPath($BasePath))"
