<#
.SYNOPSIS
Удаляет базы и стенды ветвей, которых больше нет в удалённом репозитории.

.DESCRIPTION
Базы и стенды создаются на ветку и не удаляются ничем. На одной машине это заметно
глазами, на сборочной — нет: ветки приходят и уходят десятками, и диск кончается
молча. Замер на этом проекте: четыре базы по 38–45 МБ за два дня работы одного
человека, причём ни одной из этих ветвей на origin уже не существовало.

Что считается устаревшим: каталог, чьё имя совпадает со слагом ветки, которой нет
среди `git ls-remote --heads`. Слаг вычисляется той же функцией, что выделяет
ресурсы, поэтому расхождения между «как назвали» и «как ищем» быть не может.

Чего скрипт НЕ делает без явного разрешения:

- не удаляет базу ветки, выгруженной в какой-либо worktree прямо сейчас, даже если
  её нет на origin: работа могла ещё не начаться пушем;
- не удаляет базу, метка владельца которой называет ДРУГУЮ существующую рабочую
  копию: её ветки в этом репозитории нет и не будет, и по веткам такая база всегда
  выглядит осиротевшей. Вместе с базой сохраняются стенды того же слага — своей
  метки у стенда нет, его собирает адаптер проекта. Метка исчезнувшей копии не
  защищает: после неё база и есть тот мусор, ради которого уборка заведена;
- не удаляет ничего вообще без ключа `-Apply`. По умолчанию печатает план.

Порядок именно такой: скрипт, удаляющий данные, обязан быть безопасным при запуске
по ошибке. Просмотр плана — поведение по умолчанию, удаление — осознанное действие.

.PARAMETER Apply
Выполнить удаление. Без ключа печатается план.

.PARAMETER OriginOnly
Считать живыми только ветки origin, игнорируя локальные. По умолчанию локальные
ветки и ветки, выгруженные в worktree, считаются живыми.

.PARAMETER ReportPath
Куда записать JSON-отчёт.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$OriginOnly,
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Workflow.Common.ps1")

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
$stateDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.localStateDir)
if (-not $ReportPath) {
    $timestamp = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
    $ReportPath = Join-Path $stateDirectory "reports\stale-bases-$timestamp.json"
}

$parallel = Get-WorkflowParallelSettings -Config $config
if (-not [bool]$parallel.enabled -or -not [bool]$parallel.perBranchStands) {
    Write-Host "Ресурсы не выделяются на ветку (parallel.perBranchStands = false) — удалять нечего."
    return
}

# ── 1. Живые ветки ────────────────────────────────────────────────────────────
$remote = Invoke-WorkflowGit `
    -RepositoryRoot $repositoryRoot `
    -Arguments @("ls-remote", "--heads", "origin") `
    -AllowFailure
if ($remote.ExitCode -ne 0) {
    throw "Не удалось получить список ветвей origin. Удаление без этого списка небезопасно: все базы выглядели бы устаревшими."
}
# Слаги базы разработки и стенда РАЗНЫЕ, и это не мелочь. База именуется полным
# слагом, стенд — усечённым до 40 символов с отпечатком (см. Get-WorkflowStandSlug).
# Для длинной ветки имена не совпадают, поэтому единый набор живых слагов удалил бы
# стенд живой ветки, оставив её базу.
$liveDevSlugs = @{}
$liveStandSlugs = @{}

function Register-LiveBranch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $devSlug = ConvertTo-WorkflowSlug -Value $BranchName
    $standSlug = Get-WorkflowStandSlug -BranchName $BranchName
    if (-not $script:liveDevSlugs.ContainsKey($devSlug)) {
        $script:liveDevSlugs[$devSlug] = $Source
    }
    if (-not $script:liveStandSlugs.ContainsKey($standSlug)) {
        $script:liveStandSlugs[$standSlug] = $Source
    }
}

foreach ($line in @($remote.Output)) {
    if ($line -match 'refs/heads/(?<branch>.+)$') {
        Register-LiveBranch -BranchName $Matches["branch"] -Source "origin/$($Matches["branch"])"
    }
}

# Ветки, выгруженные в worktree, живые всегда: работа могла ещё не начаться пушем,
# и удаление базы под ногами разработчика недопустимо.
$worktrees = Invoke-WorkflowGit -RepositoryRoot $repositoryRoot -Arguments @("worktree", "list", "--porcelain")
foreach ($line in @($worktrees.Output)) {
    if ($line -match '^branch refs/heads/(?<branch>.+)$') {
        Register-LiveBranch -BranchName $Matches["branch"] -Source "worktree $($Matches["branch"])"
    }
}

if (-not $OriginOnly) {
    $local = Invoke-WorkflowGit -RepositoryRoot $repositoryRoot -Arguments @("branch", "--format=%(refname:short)")
    foreach ($line in @($local.Output)) {
        $branch = ([string]$line).Trim()
        if (-not $branch) {
            continue
        }
        Register-LiveBranch -BranchName $branch -Source "local $branch"
    }
}

Write-Host "Живых баз: $($liveDevSlugs.Count), живых стендов: $($liveStandSlugs.Count)"

# ── 2. Каталоги, выделяемые на ветку ──────────────────────────────────────────
$project = [string]$config.project
$roots = @()
$devRoot = [string]$parallel.devBaseRoot
if ($devRoot) {
    $roots += [pscustomobject]@{ kind = "dev-base"; path = (Join-Path $devRoot $project) }
}
$testRoot = [string]$parallel.testBaseRoot
if ($testRoot) {
    $roots += [pscustomobject]@{ kind = "functional-stand"; path = (Join-Path $testRoot "$project-functional") }
    $roots += [pscustomobject]@{ kind = "web-ui-stand"; path = (Join-Path $testRoot "$project-functional-ui") }
}

$stale = @()
$kept = @()
# Слаги, чьи базы принадлежат другой рабочей копии. Заполняется на проходе по
# базам разработчика и защищает стенды тех же ветвей: корни перечислены так, что
# база идёт раньше своих стендов.
$foreignSlugs = @{}
foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root.path -PathType Container)) {
        continue
    }
    # Корень стенда может содержать саму базу, а не только подкаталоги ветвей: если
    # стенд когда-то создавали без разбивки по ветке, рядом лежат СЛУЖЕБНЫЕ каталоги
    # 1С — 1Cv8Log, 1Cv8JobScheduler, 1Cv8Temp. Первый прогон плана показал их как
    # «устаревшие ветки»: скрипт удалил бы журнал и планировщик живой базы.
    #
    # Поэтому признак кандидата ПОЛОЖИТЕЛЬНЫЙ: каталог считается базой или стендом
    # ветки только если содержит файл базы 1Cv8.1CD непосредственно в себе. Список
    # исключений по именам служебных каталогов был бы хуже — он ломается на любом
    # новом имени, которое добавит платформа.
    if (Test-Path -LiteralPath (Join-Path $root.path "1Cv8.1CD") -PathType Leaf) {
        # Такая база осталась от эпохи, когда стенд был один на проект. Сама она не
        # трогается: определить, нужна ли она, скрипт не может, а удалять по догадке
        # нельзя. Достаточно сказать о ней вслух.
        Write-Warning "В корне $($root.kind) лежит база вне разбивки по ветвям: $($root.path). Скрипт её не трогает — решите вручную, нужна ли она."
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $root.path -Directory -ErrorAction SilentlyContinue)) {
        $slug = $directory.Name
        if (-not (Test-Path -LiteralPath (Join-Path $directory.FullName "1Cv8.1CD") -PathType Leaf)) {
            continue
        }
        $entry = [pscustomobject]@{
            kind = $root.kind
            slug = $slug
            path = $directory.FullName
            sizeMb = 0
            reason = ""
        }
        $bytes = 0
        foreach ($file in @(Get-ChildItem -LiteralPath $directory.FullName -File -Recurse -ErrorAction SilentlyContinue)) {
            $bytes += $file.Length
        }
        $entry.sizeMb = [Math]::Round($bytes / 1MB, 1)

        # Чужая рабочая копия проверяется ПЕРВОЙ: её база не наша независимо от
        # того, есть ли у нас ветка с таким же именем. Ветки своего репозитория о
        # соседнем клоне не знают ничего, и по ним такая база всегда выглядит
        # осиротевшей.
        $foreignOwner = Get-WorkflowForeignBaseOwner `
            -Path $directory.FullName `
            -RepositoryRoot $repositoryRoot
        # У стенда своей метки нет: его собирает адаптер проекта, а не комплект.
        # Зато слаг у стенда и базы один — он выводится из имени ветки одной и той
        # же функцией. Поэтому чужая база защищает и стенды своей ветки; если базу
        # соседнего клона уже удалили, защиты нет, и это сказано прямо.
        if (-not $foreignOwner -and $root.kind -ne "dev-base" -and $foreignSlugs.ContainsKey($slug)) {
            $foreignOwner = [string]$foreignSlugs[$slug]
        }
        if ($foreignOwner) {
            if ($root.kind -eq "dev-base") {
                $foreignSlugs[$slug] = $foreignOwner
            }
            $entry.reason = "владелец — другая рабочая копия: $foreignOwner"
            $kept += $entry
            continue
        }

        $liveTable = if ($root.kind -eq "dev-base") { $liveDevSlugs } else { $liveStandSlugs }
        if ($liveTable.ContainsKey($slug)) {
            $entry.reason = "живая ветка: $($liveTable[$slug])"
            $kept += $entry
            continue
        }
        $entry.reason = "ветки с таким слагом нет"
        $stale += $entry
    }
}

# ── 3. План и удаление ────────────────────────────────────────────────────────
# Measure-Object на пустом наборе не возвращает Sum вовсе, и при Set-StrictMode
# обращение к свойству падает. Суммируем сами.
$totalMb = 0
foreach ($entry in $stale) {
    $totalMb += $entry.sizeMb
}
$totalMb = [Math]::Round($totalMb, 1)
Write-Host ""
Write-Host "Сохраняется: $(@($kept).Count) каталог(ов)"
foreach ($entry in $kept) {
    Write-Host "  [$($entry.kind)] $($entry.slug) — $($entry.reason)"
}
Write-Host ""
Write-Host "Устарело: $(@($stale).Count) каталог(ов), $totalMb МБ"
foreach ($entry in $stale) {
    Write-Host "  [$($entry.kind)] $($entry.slug) — $($entry.sizeMb) МБ — $($entry.path)"
}

$removed = @()
$failed = @()
if ($Apply) {
    foreach ($entry in $stale) {
        # Проверка принадлежности корню обязательна: путь пришёл из конфигурации, и
        # опечатка в devBaseRoot без неё превратила бы уборку в удаление чужого
        # каталога.
        $owningRoot = @($roots | Where-Object { $entry.path.StartsWith($_.path, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($owningRoot.Count -eq 0) {
            $failed += [pscustomobject]@{ path = $entry.path; message = "путь вне известных корней, удаление отклонено" }
            continue
        }
        try {
            Remove-Item -LiteralPath $entry.path -Recurse -Force -ErrorAction Stop
            $removed += $entry.path
            Write-Host "удалено: $($entry.path)"
        }
        catch {
            $failed += [pscustomobject]@{ path = $entry.path; message = $_.Exception.Message }
            Write-Warning "не удалось удалить $($entry.path): $($_.Exception.Message)"
        }
    }
}
else {
    Write-Host ""
    Write-Host "Это план. Для удаления запустите с ключом -Apply."
}

$report = [pscustomobject]@{
    operation = "stale-bases"
    project = $project
    applied = [bool]$Apply
    liveDevSlugs = @($liveDevSlugs.Keys | Sort-Object)
    liveStandSlugs = @($liveStandSlugs.Keys | Sort-Object)
    stale = @($stale)
    kept = @($kept)
    removed = @($removed)
    failed = @($failed)
    freedMb = if ($Apply) { $totalMb } else { 0 }
    completedAt = [DateTimeOffset]::Now.ToString("o")
}
Write-WorkflowJson -Value $report -Path $ReportPath | Out-Null
Write-Host ""
Write-Host "Отчёт: $ReportPath"
if ($failed.Count -gt 0) {
    throw "Не удалось удалить $($failed.Count) каталог(ов). Обычная причина — база открыта Конфигуратором или Apache держит стенд."
}
