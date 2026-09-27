# Раннер web-test из cc-1c-skills для сценариев tests/ui: UI-смоука и сборки
# инструкций. Подключается точкой:
#
#     . (Join-Path $PSScriptRoot "WebTestRunner.ps1")
#
# Плагин ставят и в Codex, и в Claude Code, а каталоги у них разные:
#
#     %USERPROFILE%\.codex\plugins\cache\cc-1c-skills\1c-skills\<версия>\.codex\skills\web-test\scripts\run.mjs
#     %USERPROFILE%\.claude\plugins\cache\cc-1c-skills\1c-skills\<версия>\.claude\skills\web-test\scripts\run.mjs
#
# Find-WebTestRunner берет самую свежую установку из обеих.

function Find-WebTestRunner {
    param([string]$Path = "")

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Раннер web-test не найден: $Path"
        }
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $installs = foreach ($agent in @(".codex", ".claude")) {
        $root = Join-Path $env:USERPROFILE "$agent\plugins\cache\cc-1c-skills\1c-skills"
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $runner = Join-Path $_.FullName "$agent\skills\web-test\scripts\run.mjs"
            if (Test-Path -LiteralPath $runner -PathType Leaf) {
                [pscustomobject]@{ Path = $runner; Installed = $_.LastWriteTime }
            }
        }
    }
    $newest = $installs | Sort-Object Installed -Descending | Select-Object -First 1
    if (-not $newest) {
        throw ("Раннер web-test из cc-1c-skills не найден ни в Codex, ни в Claude Code. " +
            "Установите плагин или передайте путь к run.mjs параметром -WebTestRunner.")
    }
    return $newest.Path
}

# Раннер ищет свои npm-зависимости рядом с run.mjs, поэтому ставить их больше
# некуда, кроме каталога плагина. Ставятся один раз, при первом запуске.
function Install-WebTestRunnerDependencies {
    param([Parameter(Mandatory)][string]$Runner)

    $directory = Split-Path $Runner -Parent
    if (Test-Path -LiteralPath (Join-Path $directory "node_modules")) {
        return
    }
    Write-Host "Раннеру web-test не хватает зависимостей: ставлю их в $directory (npm ci)."
    & npm.cmd ci --prefix $directory
    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось поставить зависимости раннера web-test."
    }
}
