[CmdletBinding()]
param(
    [string]$BaseRef = "",

    [string]$ReportPath = "",

    # Отклонить замечание с причиной: "<ключ>=<причина>". Повторяется перечислением
    # через точку с запятой, потому что запуск через -File массивы не разбирает.
    [string]$Dismiss = "",

    # Только собрать пакет и показать путь. Нужно, когда ревьюера запускают руками.
    [switch]$PacketOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "Workflow.Common.ps1")

<#
Независимое ревью правки.

Зачем отдельный этап. Тест проверяет, что код делает заявленное, и по построению
молчит о том, нужно ли это делать вообще. Гейт проверяет правила, и правила
«здесь лишнее» не существует. Всё, что мы ловили вручную — курсор в константе
вместо запроса, чтение набора по каждой задаче, включённое задание с пустым
телом, — проходило и тесты, и гейт: код был верен и покрыт.

Почему независимое. Автор — худший ревьюер собственной правки не по
невнимательности: он только что выбрал это решение и читает код как его
подтверждение. Поэтому ревьюер получает ТОЛЬКО правку, тесты и чек-лист, и не
получает объяснений автора.

Чего этап не проверяет. Комплект не может убедиться, что ревьюер независим и что
он читал код. Он проверяет форму: отчёт есть, относится к нынешнему содержимому,
каждое замечание показано на файле. Остальное — соглашение.
#>

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
$stateDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.localStateDir)

$reviewConfig = Get-WorkflowSettingValue -Object $config -Name "review" -Default $null
$enabled = [bool](Get-WorkflowSettingValue -Object $reviewConfig -Name "enabled" -Default $false)

if (-not $enabled) {
    Write-Host "Ревью отключено манифестом (review.enabled = false)."
    Write-Host "  Это осознанный отказ проекта, а не пропуск: фаза Verify проверять отчёт не станет."
    exit 0
}

if (-not $BaseRef) {
    $BaseRef = "origin/$([string]$config.mainBranch)"
}

$fingerprint = Get-WorkflowFingerprint -RepositoryRoot $repositoryRoot
$critiqueDirectory = Get-WorkflowCritiqueDirectory -StateDirectory $stateDirectory -Fingerprint $fingerprint
[System.IO.Directory]::CreateDirectory($critiqueDirectory) | Out-Null

if (-not $ReportPath) {
    $ReportPath = Join-Path $critiqueDirectory "report.json"
}
$dismissalsPath = Join-Path (Join-Path $stateDirectory "critique") "dismissals.json"

# ── Отклонения ────────────────────────────────────────────────────────────────
if ($Dismiss) {
    $dismissals = Get-WorkflowCritiqueDismissals -Path $dismissalsPath
    foreach ($item in @($Dismiss.Split(";"))) {
        $value = ([string]$item).Trim()
        if (-not $value) {
            continue
        }
        $separator = $value.IndexOf("=")
        if ($separator -le 0) {
            throw "Отклонение задаётся как '<ключ>=<причина>': $value"
        }
        $key = $value.Substring(0, $separator).Trim()
        $reason = $value.Substring($separator + 1).Trim()
        if (-not $reason) {
            throw "Отклонение без причины — это пропуск, только выглядит как решение: $value"
        }

        # Отпечаток файла запоминается вместе с причиной: отклонение действует до
        # следующей правки этого файла, а не навсегда.
        $fileHash = ""
        $reportForKey = $null
        if (Test-Path -LiteralPath $ReportPath -PathType Leaf) {
            $reportForKey = Test-WorkflowCritiqueReport -Path $ReportPath -Fingerprint $fingerprint
            foreach ($finding in @($reportForKey.Findings)) {
                if ($finding.Key -eq $key) {
                    $fileHash = [string]((Invoke-WorkflowGit `
                        -RepositoryRoot $repositoryRoot `
                        -Arguments @("hash-object", "--", $finding.File) `
                        -AllowFailure).Output | Select-Object -First 1)
                }
            }
        }

        $dismissals[$key] = [pscustomobject]@{
            reason = $reason
            fileHash = $fileHash
            dismissedAt = (Get-Date).ToString("o")
        }
        Write-Host "Отклонено $key : $reason"
    }

    $ordered = [ordered]@{}
    foreach ($key in @(@($dismissals.Keys) | Sort-Object)) {
        $ordered[$key] = $dismissals[$key]
    }
    [System.IO.Directory]::CreateDirectory((Split-Path $dismissalsPath -Parent)) | Out-Null
    Set-Content `
        -LiteralPath $dismissalsPath `
        -Value (ConvertTo-Json -InputObject ([pscustomobject]$ordered) -Depth 5) `
        -Encoding UTF8
}

# ── Пакет ─────────────────────────────────────────────────────────────────────
$packetPath = Join-Path $critiqueDirectory "packet.md"
$tokenPath = Join-Path $critiqueDirectory "token.txt"

# Токен переживает повторный запуск на том же содержимом: иначе отчёт, сделанный
# минуту назад, переставал бы засчитываться от одного лишь перезапуска фазы.
if (Test-Path -LiteralPath $tokenPath -PathType Leaf) {
    $token = (Get-Content -Raw -LiteralPath $tokenPath -Encoding UTF8).Trim()
}
else {
    $token = New-WorkflowCritiqueToken
    Set-Content -LiteralPath $tokenPath -Value $token -Encoding UTF8
}
$packet = New-WorkflowCritiquePacket `
    -RepositoryRoot $repositoryRoot `
    -BaseRef $BaseRef `
    -Fingerprint $fingerprint `
    -ReportPath $ReportPath `
    -PacketPath $packetPath `
    -Token $token

if ($packet.Empty) {
    Write-Host "Ревью пропущено: правка не трогает ни код, ни тесты."
    exit 0
}

Write-Host "Пакет ревью: $packetPath"
Write-Host "  файлов в правке: $($packet.FileCount), строк диффа: $($packet.DiffLines)"

if ($PacketOnly) {
    Write-Host "Отчёт ожидается здесь: $ReportPath"
    exit 0
}

# ── Запуск ревьюера ───────────────────────────────────────────────────────────
# Команду называет проект, а если не назвал — она собирается под ТОГО ЖЕ агента,
# которым идёт разработка, и запускается отдельным сеансом. Ревьюер слабее автора
# находит меньше автора, и такое ревью создаёт видимость проверки; поэтому
# инструмент и модель берутся из текущего сеанса, а не из умолчания комплекта.
#
# Переносимость между инструментами сохраняется: агентский CLI читает пакет
# файлом и пишет отчёт сам, обёртка над подпиской принимает промпт текстом и
# печатает ответ. Комплект поддерживает обе формы и не выбирает инструмент.
$agent = Get-WorkflowDevelopmentAgent
$reviewer = Resolve-WorkflowReviewCommand -ReviewConfig $reviewConfig -Agent $agent
if ($null -eq $reviewer) {
    throw ("Ревью включено, но ревьюера нечем запустить: review.command пуст, а агент " +
        "разработки не распознан по окружению. Назовите команду списком аргументов с " +
        "подстановками {packet} и {report} либо запустите ревьюера руками: -PacketOnly, " +
        "затем положить отчёт в $ReportPath.")
}

$command = @($reviewer.Command)
$inputMode = [string]$reviewer.Input
$outputMode = [string]$reviewer.Output

$modelText = if ($reviewer.Model) { $reviewer.Model } else { "умолчание инструмента" }
Write-Host "Ревьюер: $($reviewer.Source); агент $($reviewer.Agent), модель $modelText"

# Круг считается по задаче, а не по содержимому: по содержимому счётчик
# обнулялся бы каждой правкой и не срабатывал бы никогда.
$rounds = Get-WorkflowCritiqueRounds -StateDirectory $stateDirectory -ReviewConfig $reviewConfig
if ($rounds.Exhausted) {
    Write-Host "Круги ревью исчерпаны ($($rounds.Done) из $($rounds.Limit)): это последний разбор."
}
[void](Step-WorkflowCritiqueRound -StateDirectory $stateDirectory)
$rounds = Get-WorkflowCritiqueRounds -StateDirectory $stateDirectory -ReviewConfig $reviewConfig
Write-Host "Круг ревью: $($rounds.Done) из $($rounds.Limit)."

if (@("path", "stdin", "argument") -notcontains $inputMode) {
    throw "review.input принимает 'path', 'stdin' или 'argument', а задано '$inputMode'."
}
if (@("file", "stdout") -notcontains $outputMode) {
    throw "review.output принимает 'file' или 'stdout', а задано '$outputMode'."
}

$packetText = Get-Content -Raw -LiteralPath $packetPath -Encoding UTF8

$arguments = @(
    $command | ForEach-Object {
        ([string]$_).
            Replace("{packet}", $packetPath).
            Replace("{packetText}", $packetText).
            Replace("{report}", $ReportPath).
            Replace("{root}", $repositoryRoot)
    }
)

$logPath = Join-Path $critiqueDirectory "reviewer.log"
Write-Host "Запуск ревьюера: $($arguments -join ' ')"

$executable = $arguments[0]
$rest = @()
if ($arguments.Count -gt 1) {
    $rest = $arguments[1..($arguments.Count - 1)]
}

# Отчёт от прошлого запуска удаляется до вызова: иначе упавший ревьюер оставил бы
# в силе чужой ответ, и фаза сочла бы ревью выполненным.
if (Test-Path -LiteralPath $ReportPath) {
    Remove-Item -LiteralPath $ReportPath -Force
}

# Привязка к текущему сеансу с дочернего процесса снимается. Унаследованные
# идентификатор сеанса и канал сообщений подключили бы ревьюера к сеансу автора:
# он увидел бы контекст правки и перестал быть вторым мнением — а выглядело бы
# это как независимое ревью. Значения восстанавливаются сразу после запуска:
# фаза продолжает работать в своём сеансе.
$sessionVariables = @(Get-WorkflowAgentSessionVariables)
$savedSession = @{}
foreach ($name in $sessionVariables) {
    $savedSession[$name] = [System.Environment]::GetEnvironmentVariable($name)
    if ($null -ne $savedSession[$name]) {
        [System.Environment]::SetEnvironmentVariable($name, $null)
    }
}

try {
    if ($inputMode -eq "stdin") {
        $output = $packetText | & $executable @rest 2>&1
    }
    else {
        $output = & $executable @rest 2>&1
    }
    $exitCode = $LASTEXITCODE
}
finally {
    foreach ($name in $sessionVariables) {
        if ($null -ne $savedSession[$name]) {
            [System.Environment]::SetEnvironmentVariable($name, $savedSession[$name])
        }
    }
}
$outputText = (@($output) -join [System.Environment]::NewLine)
Set-Content -LiteralPath $logPath -Value $outputText -Encoding UTF8

if ($exitCode -ne 0) {
    throw "Ревьюер завершился с кодом ${exitCode}. Журнал: $logPath"
}

if ($outputMode -eq "stdout") {
    # Отчёт печатается, а не пишется файлом. Комплект достаёт из вывода JSON и
    # кладёт его сам — дальше разница между инструментами исчезает.
    Set-Content `
        -LiteralPath $ReportPath `
        -Value (ConvertFrom-WorkflowCritiqueOutput -Text $outputText) `
        -Encoding UTF8
}

# ── Разбор ────────────────────────────────────────────────────────────────────
# Здесь проверка строгая: пакет только что отдан ревьюеру, и ответ обязан это
# подтверждать — токеном и замечанием по учебному примеру.
$report = Test-WorkflowCritiqueReport `
    -Path $ReportPath `
    -Fingerprint $fingerprint `
    -Token $token `
    -RequireProbe
$dismissals = Get-WorkflowCritiqueDismissals -Path $dismissalsPath

$fileHashes = @{}
foreach ($finding in @($report.Findings)) {
    if ($fileHashes.ContainsKey($finding.File)) {
        continue
    }
    $fileHashes[$finding.File] = [string]((Invoke-WorkflowGit `
        -RepositoryRoot $repositoryRoot `
        -Arguments @("hash-object", "--", $finding.File) `
        -AllowFailure).Output | Select-Object -First 1)
}

$resolution = Resolve-WorkflowCritiqueFindings `
    -Findings @($report.Findings) `
    -Dismissals $dismissals `
    -FileHashes $fileHashes

Write-Host ""
Write-Host "Ревьюер: $($report.Reviewer)"
Write-Host "Замечаний: $(@($report.Findings).Count), отклонено ранее: $(@($resolution.Dismissed).Count)"

foreach ($item in @($resolution.Dismissed)) {
    Write-Host "  [отклонено] $($item.Finding.Title) — $($item.Reason)"
}
foreach ($finding in @($resolution.Expired)) {
    Write-Host "  [отклонение истекло: файл изменился] $($finding.Title)"
}

if (@($resolution.Open).Count -eq 0) {
    Write-Host "Открытых замечаний нет."
    exit 0
}

# Круг назначают только замечания, из-за которых правку нельзя выпускать.
# Шлифовать можно бесконечно, и ревьюер, которому нечего сказать по существу,
# всегда найдёт, что сказать по вкусу.
$blockingSeverities = @(Get-WorkflowCritiqueBlockingSeverities -ReviewConfig $reviewConfig)
$blocking = @(Select-WorkflowBlockingFindings -Findings @($resolution.Open) -BlockingSeverities $blockingSeverities)
$advisory = @($resolution.Open | Where-Object { $blocking -notcontains $_ })

Write-Host ""
if ($blocking.Count -gt 0) {
    Write-Host "Открытые замечания, требующие ответа:"
    foreach ($finding in $blocking) {
        $place = if ($finding.Line) { "$($finding.File):$($finding.Line)" } else { $finding.File }
        $severity = if ($finding.Severity) { $finding.Severity } else { "без серьёзности — считается блокирующим" }
        Write-Host "  [$($finding.Key)] $($finding.ChecklistItem) — $place ($severity)"
        Write-Host "      $($finding.Title)"
        if ($finding.Detail) {
            Write-Host "      $($finding.Detail)"
        }
    }
}
if ($advisory.Count -gt 0) {
    Write-Host ""
    Write-Host "Замечания вкуса — записаны, круг не продлевают:"
    foreach ($finding in $advisory) {
        Write-Host "  [$($finding.Key)] $($finding.Title)"
    }
}

if ($blocking.Count -eq 0) {
    Write-Host ""
    Write-Host "Блокирующих замечаний нет: правку можно вести дальше."
    exit 0
}

Write-Host ""
Write-Host "Ответить на замечание можно двумя способами: исправить код — тогда ревью"
Write-Host "переспросит на новом содержимом, — либо отклонить с причиной:"
Write-Host "  -Dismiss `"<ключ>=<причина>`""

# Круги кончились. Дальше комплект НЕ назначает новый: он требует решения —
# отклонить оставшееся с причиной или позвать человека. Молча пропустить нельзя,
# иначе предел превратился бы в способ не чинить; бесконечно звать ревьюера тоже
# нельзя — шлифовка не сходится сама.
if ($rounds.Exhausted) {
    Write-Host ""
    Write-Host "Круги ревью исчерпаны: сделано $($rounds.Done) из $($rounds.Limit)."
    Write-Host "Новый круг не назначается. Оставшееся закройте решением: отклоните с"
    Write-Host "причиной или вынесите на человека. Поднять предел — review.maxRounds."
    throw ("Ревью не сходится: $($blocking.Count) блокирующих замечаний после " +
        "$($rounds.Done) кругов. Нужно решение, а не ещё один круг.")
}

throw "Открытых блокирующих замечаний ревью: $($blocking.Count). Круг $($rounds.Done) из $($rounds.Limit)."
