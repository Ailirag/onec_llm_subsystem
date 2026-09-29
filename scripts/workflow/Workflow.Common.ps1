Set-StrictMode -Version 2.0

function Get-WorkflowRepositoryRoot {
    param(
        [string]$StartPath = $PSScriptRoot
    )

    $resolvedStart = [System.IO.Path]::GetFullPath($StartPath)
    $result = Invoke-WorkflowGit -RepositoryRoot $resolvedStart -Arguments @("rev-parse", "--show-toplevel")
    return [System.IO.Path]::GetFullPath(($result.Output | Select-Object -First 1))
}

function Invoke-WorkflowGit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    # git печатает пути в UTF-8, а PowerShell декодирует вывод чужого процесса
    # кодировкой консоли. На русской Windows это cp866, и кириллическое имя
    # файла превращается в мусор молча: путь «не существует», отпечаток теряет
    # файл, сборка объявляет тысячи мнимых отличий, а Selfcheck подтверждает
    # вчерашний текст. Дефект виден только там, где консоль не UTF-8, то есть у
    # всех, кроме того, кто её себе переключил.
    #
    # Кодировка ставится на время вызова и возвращается назад: глобально её
    # менять нельзя — тогда наши же сообщения поедут на консоли с cp866.
    # Присвоение падает, когда консоли нет вовсе (служба, перенаправленный
    # поток); это не повод ронять вызов git.
    $previousOutputEncoding = $null
    try {
        $previousOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
    catch {
        $previousOutputEncoding = $null
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $rawOutput = @(& git.exe -C $RepositoryRoot @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($null -ne $previousOutputEncoding) {
            try {
                [Console]::OutputEncoding = $previousOutputEncoding
            }
            catch {
                # Восстановить не удалось — вывод останется в UTF-8. Это хуже
                # исходного состояния только внешне и не стоит отказа фазы.
            }
        }
    }

    $output = @(
        $rawOutput |
            Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
            ForEach-Object { [string]$_ }
    )
    $errorOutput = @(
        $rawOutput |
            Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
            ForEach-Object { [string]$_ }
    )

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        $combinedOutput = @($output + $errorOutput)
        throw "git $($Arguments -join ' ') failed with exit code $exitCode.`n$($combinedOutput -join [Environment]::NewLine)"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
        ErrorOutput = $errorOutput
    }
}

function Merge-WorkflowSettings {
    <#
    .SYNOPSIS
    Накладывает настройки проекта на поставку комплекта.

    .DESCRIPTION
    Правила намеренно простые, потому что сложные пришлось бы держать в голове
    при каждом чтении настройки:

      объект  — сливается рекурсивно, ключ проекта побеждает;
      скаляр  — заменяется целиком;
      массив  — заменяется ЦЕЛИКОМ, а не дополняется.

    Массив заменой — решение, а не упрощение. «Список фикстур проекта плюс
    шаблонный» не имеет смысла ни в одном сценарии: шаблонный список — пример, и
    дополнение им означало бы, что проект не может ничего убрать.

    Ключ, заданный проектом, побеждает ВСЕГДА, даже со значением null: иначе
    «выключить то, что комплект включил» было бы невыразимо.
    #>
    param(
        $Base,

        $Override
    )

    if ($null -eq $Override) {
        return $Base
    }
    if ($null -eq $Base) {
        return $Override
    }
    if ($Base -isnot [System.Management.Automation.PSCustomObject] -or
        $Override -isnot [System.Management.Automation.PSCustomObject]) {
        return $Override
    }

    $result = [ordered]@{}
    foreach ($property in $Base.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }
    foreach ($property in $Override.PSObject.Properties) {
        if ($result.Contains($property.Name)) {
            $result[$property.Name] = Merge-WorkflowSettings `
                -Base $result[$property.Name] `
                -Override $property.Value
        }
        else {
            $result[$property.Name] = $property.Value
        }
    }

    return [pscustomobject]$result
}

function Get-WorkflowConfig {
    <#
    .SYNOPSIS
    Настройки процесса: поставка комплекта плюс переопределения проекта.

    .DESCRIPTION
    Два файла и два владельца. .1c-workflow.defaults.json принадлежит комплекту
    и переписывается при каждой установке; .1c-workflow.json принадлежит проекту
    и установщик его не трогает, кроме ключей, которые сам же и вычисляет.

    Так было не всегда: один файл с одним владельцем означал, что переустановка
    сбрасывает настройки проекта на умолчания. На живой конфигурации это стоило
    24 переопределённых ключа и целую секцию unitTests, исчезавшую бесследно;
    хуже всего, что выключенные наборы проверок не роняют фазы, а молча
    пропускаются — зелёный прогон, который ничего не проверял.

    Файла поставки нет — читается один манифест, как раньше. Проект на старом
    комплекте обязан продолжать работать: обновление комплекта и переезд на
    два файла происходят не одновременно.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $configPath = Join-Path $RepositoryRoot ".1c-workflow.json"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Workflow configuration was not found: $configPath"
    }

    $config = Get-Content -Raw -LiteralPath $configPath -Encoding UTF8 | ConvertFrom-Json

    $defaultsPath = Join-Path $RepositoryRoot ".1c-workflow.defaults.json"
    if (Test-Path -LiteralPath $defaultsPath -PathType Leaf) {
        $defaults = Get-Content -Raw -LiteralPath $defaultsPath -Encoding UTF8 | ConvertFrom-Json
        $config = Merge-WorkflowSettings -Base $defaults -Override $config
    }

    if ($config.schemaVersion -ne 1) {
        throw "Unsupported workflow schema version: $($config.schemaVersion)"
    }
    return $config
}

function Resolve-WorkflowPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $Path))
}

function ConvertTo-WorkflowVersionNumbers {
    <#
    .SYNOPSIS
    Числовая часть версии cc-1c-skills для сравнения. Пусто — версия несравнима.

    .DESCRIPTION
    Версии выглядят как `2026.9.13+56b0c0c`: датовая часть и хеш сборки. Сравнивать
    осмысленно только датовую часть, хеш к порядку отношения не имеет.

    Несравнимая версия возвращается пустым массивом, а НЕ нулями: ноль поставил бы
    её ниже всех остальных, и незнакомый формат молча оказался бы «старым».
    #>
    param([string]$Version)

    $core = ([string]$Version).Split("+")[0].Trim()
    if (-not $core) {
        return @()
    }
    $numbers = @()
    foreach ($part in $core.Split(".")) {
        $value = 0
        if (-not [int]::TryParse($part, [ref]$value)) {
            return @()
        }
        $numbers += $value
    }
    return $numbers
}

function Compare-WorkflowVersion {
    <#
    .SYNOPSIS
    -1, 0 или 1 для пары версий. Несравнимая пара — $null.
    #>
    param([string]$Left, [string]$Right)

    $a = @(ConvertTo-WorkflowVersionNumbers -Version $Left)
    $b = @(ConvertTo-WorkflowVersionNumbers -Version $Right)
    if ($a.Count -eq 0 -or $b.Count -eq 0) {
        return $null
    }
    $length = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $length; $i++) {
        # Имена НЕ $left/$right: в PowerShell переменные регистронезависимы, и
        # присваивание попало бы в параметры $Left/$Right, объявленные как [string].
        # Число превратилось бы в строку, а сравнение — в лексикографическое:
        # "7" оказывалось бы больше "13", и порядок версий вставал бы с ног на голову.
        $leftPart = if ($i -lt $a.Count) { $a[$i] } else { 0 }
        $rightPart = if ($i -lt $b.Count) { $b[$i] } else { 0 }
        if ($leftPart -lt $rightPart) { return -1 }
        if ($leftPart -gt $rightPart) { return 1 }
    }
    return 0
}

function Select-WorkflowCc1CSkillsVersion {
    <#
    .SYNOPSIS
    Какую из установленных версий cc-1c-skills брать. Пусто — подходящей нет.

    .DESCRIPTION
    Объявленная в манифесте версия — НИЖНЯЯ ГРАНИЦА, а не точное совпадение.

    Точное совпадение требовалось раньше и не работало: кэш плагина хранит ровно
    одну версию — последнюю установленную. Релиз апстрима вытеснял запиненную, и
    падала ЛЮБАЯ фаза, включая Start, с ошибкой, не связанной с правкой
    разработчика. Воспроизводимости это не давало — вытесненной версии на диске
    уже не существовало, — а «лечение» сводилось к поднятию пина, то есть к тому
    самому молчаливому апгрейду тулчейна, от которого пин и защищал.

    Порядок выбора:
      1. точное совпадение — берём его, объявленная версия установлена;
      2. иначе самая новая из тех, что не ниже объявленной;
      3. иначе ничего: всё установленное старше, и работать с ним нельзя.

    Версия, которую не удалось разобрать, в пункте 2 не участвует. Если разобрать
    не удалось САМУ объявленную, остаётся только пункт 1: сравнивать не с чем, и
    принимать наугад что попало хуже, чем честно отказать.
    #>
    param(
        [string]$RequiredVersion,
        [string[]]$Installed = @()
    )

    $available = @($Installed | Where-Object { $_ })
    if ($available -contains $RequiredVersion) {
        return $RequiredVersion
    }

    $best = ""
    foreach ($candidate in $available) {
        $comparison = Compare-WorkflowVersion -Left $candidate -Right $RequiredVersion
        if ($null -eq $comparison -or $comparison -lt 0) {
            continue
        }
        if (-not $best -or (Compare-WorkflowVersion -Left $candidate -Right $best) -gt 0) {
            $best = $candidate
        }
    }
    return $best
}

function Resolve-Cc1CSkillsRoot {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $cacheRoot = Join-Path $env:USERPROFILE ".codex\plugins\cache\cc-1c-skills\1c-skills"
    $requiredVersion = [string]$Config.cc1cSkillsVersion
    $requiredPath = Join-Path $cacheRoot $requiredVersion
    if (Test-Path -LiteralPath $requiredPath -PathType Container) {
        return [System.IO.Path]::GetFullPath($requiredPath)
    }

    $installed = @(
        Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            Select-Object -ExpandProperty Name
    )
    $selected = Select-WorkflowCc1CSkillsVersion -RequiredVersion $requiredVersion -Installed $installed
    if ($selected) {
        # Сообщаем вслух: фактически использованная версия отличается от
        # объявленной, и это должно быть видно в логе фазы, а не только в отчёте.
        Write-Host "cc-1c-skills: объявлено не ниже '$requiredVersion', используется '$selected'."
        return [System.IO.Path]::GetFullPath((Join-Path $cacheRoot $selected))
    }

    throw "Required cc-1c-skills version '$requiredVersion' or newer is not installed. Installed versions: $($installed -join ', ')"
}

function Get-WorkflowCc1CSkillsVersion {
    <#
    .SYNOPSIS
    Фактически использованная версия cc-1c-skills — имя разрешённого каталога.

    .DESCRIPTION
    Отдельная функция, потому что в отчёт и в имя каталога runtime обязана попадать
    именно ФАКТИЧЕСКАЯ версия. Объявленная стала нижней границей, и запись её как
    «версия прогона» превратила бы отчёт в неправду ровно в тот момент, когда он
    нужен: при разборе регрессии из-за смены тулчейна.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Cc1CSkillsRoot
    )

    return Split-Path $Cc1CSkillsRoot -Leaf
}

function Resolve-CcSkillScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Cc1CSkillsRoot,

        [Parameter(Mandatory = $true)]
        [string]$SkillName,

        [Parameter(Mandatory = $true)]
        [string]$ScriptName
    )

    $scriptPath = Join-Path $Cc1CSkillsRoot ".codex\skills\$SkillName\scripts\$ScriptName"
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "cc-1c-skills script was not found: $scriptPath"
    }
    return [System.IO.Path]::GetFullPath($scriptPath)
}

function Get-WorkflowDirectoryHash {
    <#
    .SYNOPSIS
    Отпечаток содержимого каталога: относительные пути файлов и их хеши.

    .DESCRIPTION
    Нужен там, где каталог копируется и копию требуется уметь признать
    устаревшей. Время изменения для этого не годится: переустановка плагина
    двигает его, не меняя содержимого, а копирование теряет.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $rootPrefix = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    $entries = @(
        Get-ChildItem -LiteralPath $Path -File -Recurse |
            Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' } |
            Sort-Object FullName |
            ForEach-Object {
                $relativePath = $_.FullName.Substring($rootPrefix.Length).Replace('\', '/')
                "$relativePath`:$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash)"
            }
    )
    $payload = [System.Text.Encoding]::UTF8.GetBytes($entries -join "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($payload))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Initialize-WorkflowWebTestRuntime {
    <#
    .SYNOPSIS
    Готовит локальную копию раннера web-test и возвращает пути к ней.

    .DESCRIPTION
    Раннер живёт в кеше плагина cc-1c-skills — общем для всех проектов и версий.
    Ставить в него node_modules и браузеры нельзя: кеш переустанавливается
    целиком, а версия раннера для прогона зафиксирована проектом. Поэтому
    скрипты копируются в локальное состояние, а зависимости ставятся там.

    Копия признаётся устаревшей по отпечатку исходного каталога, а не по времени:
    переустановка плагина двигает время, не меняя скриптов.

    PLAYWRIGHT_BROWSERS_PATH устанавливается здесь и намеренно НЕ восстанавливается:
    браузер нужен вызывающему на всём прогоне. Прежнее значение возвращается полем
    PreviousBrowsersPath — вернуть его обязан вызывающий в своём finally. Если
    подготовка упала, переменная восстанавливается здесь: прогона не будет.

    Потребителей двое — регрессия Web UI и сборка инструкций, — и подготовка у них
    обязана быть одна. Разойдись они, вторым потребителем платится отладка уже
    решённых задач: пиннинг версии, отпечаток копии, установка Chromium.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Cc1CSkillsRoot,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory
    )

    $webTestSource = Join-Path $Cc1CSkillsRoot ".codex\skills\web-test\scripts"
    $sourceRunner = Join-Path $webTestSource "run.mjs"
    if (-not (Test-Path -LiteralPath $sourceRunner -PathType Leaf)) {
        throw "Pinned cc-1c-skills web-test runner was not found: $sourceRunner"
    }

    $runtimeParent = Join-Path $StateDirectory "web-test-runtime"
    $runtimeRoot = Join-Path $runtimeParent (Get-WorkflowCc1CSkillsVersion -Cc1CSkillsRoot $Cc1CSkillsRoot)
    $runtimeMarker = Join-Path $runtimeRoot ".source-sha256"
    $sourceHash = Get-WorkflowDirectoryHash -Path $webTestSource
    $installedHash = if (Test-Path -LiteralPath $runtimeMarker -PathType Leaf) {
        (Get-Content -Raw -LiteralPath $runtimeMarker).Trim()
    }
    else {
        ""
    }

    if ($installedHash -ne $sourceHash) {
        if (Test-Path -LiteralPath $runtimeRoot) {
            if (-not (Test-WorkflowPathUnderRoot -Path $runtimeRoot -Root $runtimeParent)) {
                throw "Refusing to replace an unexpected web-test runtime path: $runtimeRoot"
            }
            Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
        }
        [System.IO.Directory]::CreateDirectory($runtimeRoot) | Out-Null
        Get-ChildItem -LiteralPath $webTestSource -Force |
            Where-Object { $_.Name -ne "node_modules" } |
            Copy-Item -Destination $runtimeRoot -Recurse -Force
    }

    $previousBrowsersPath = $env:PLAYWRIGHT_BROWSERS_PATH
    $browserPath = Join-Path $runtimeRoot "browsers"
    $env:PLAYWRIGHT_BROWSERS_PATH = $browserPath
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $runtimeRoot "node_modules\playwright") -PathType Container)) {
            # Out-Host обязателен: внутри функции поток вывода нативной команды
            # стал бы частью возвращаемого значения, и вызывающий получил бы
            # массив строк npm вместо описателя runtime.
            & npm.cmd ci --prefix $runtimeRoot --ignore-scripts | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "Local npm ci for web-test failed with exit code $LASTEXITCODE."
            }
        }

        $browserMarker = Join-Path $browserPath ".chromium-installed"
        if (-not (Test-Path -LiteralPath $browserMarker -PathType Leaf)) {
            $playwrightCli = Join-Path $runtimeRoot "node_modules\playwright\cli.js"
            & node.exe $playwrightCli install chromium | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw "Local Playwright Chromium installation failed with exit code $LASTEXITCODE."
            }
            [System.IO.Directory]::CreateDirectory($browserPath) | Out-Null
            [System.IO.File]::WriteAllText(
                $browserMarker,
                [DateTimeOffset]::Now.ToString("o"),
                [System.Text.UTF8Encoding]::new($false)
            )
        }

        # Отметка пишется последней: она означает «копия готова к работе», а не
        # «файлы скопированы». Упади установка зависимостей — следующий прогон
        # обязан повторить подготовку, а не считать копию пригодной.
        if ($installedHash -ne $sourceHash) {
            [System.IO.File]::WriteAllText(
                $runtimeMarker,
                $sourceHash + [Environment]::NewLine,
                [System.Text.UTF8Encoding]::new($false)
            )
        }
    }
    catch {
        $env:PLAYWRIGHT_BROWSERS_PATH = $previousBrowsersPath
        throw
    }

    return [pscustomobject]@{
        Root = $runtimeRoot
        Runner = Join-Path $runtimeRoot "run.mjs"
        BrowsersPath = $browserPath
        PreviousBrowsersPath = $previousBrowsersPath
    }
}

function Resolve-WorkflowV8Path {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [string]$V8Path = ""
    )

    if ($V8Path) {
        $candidate = [System.IO.Path]::GetFullPath($V8Path)
    }
    else {
        $candidate = "C:\Program Files\1cv8\$($Config.platformVersion)\bin"
    }

    $executable = if (Test-Path -LiteralPath $candidate -PathType Container) {
        Join-Path $candidate "1cv8.exe"
    }
    else {
        $candidate
    }

    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Required 1C platform $($Config.platformVersion) was not found: $candidate"
    }
    return [System.IO.Path]::GetFullPath($executable)
}

function Invoke-WorkflowPowerShell {
    <#
    .SYNOPSIS
    Запускает скрипт в отдельном процессе `powershell.exe -File` и пишет лог.

    .DESCRIPTION
    ВАЖНО про массивные параметры вызываемого скрипта. Запуск через `-File` НЕ
    разбирает массивы: `-Param a,b` приходит одной строкой «a,b», а повторение
    `-Param a -Param b` отклоняется как «specified more than once». Поэтому скрипт,
    объявивший `[string[]]`, обязан сам разбирать перечисление через запятую —
    иначе он получит один элемент со всем списком внутри и молча проверит не то.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$LogPath,

        [switch]$AllowFailure
    )

    $logDirectory = Split-Path $LogPath -Parent
    [System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1
        )
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $textOutput = @($output | ForEach-Object { [string]$_ })
    [System.IO.File]::WriteAllLines(
        [System.IO.Path]::GetFullPath($LogPath),
        $textOutput,
        [System.Text.UTF8Encoding]::new($false)
    )

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Script failed with exit code ${exitCode}: $ScriptPath. See log: $LogPath"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $textOutput
        LogPath = [System.IO.Path]::GetFullPath($LogPath)
    }
}

function Get-WorkflowStatePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $stateDirectory = Resolve-WorkflowPath -RepositoryRoot $RepositoryRoot -Path ([string]$Config.localStateDir)
    return Join-Path $stateDirectory "state.json"
}

function Get-WorkflowTaskStatePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $stateDirectory = Resolve-WorkflowPath -RepositoryRoot $RepositoryRoot -Path ([string]$Config.localStateDir)
    return Join-Path $stateDirectory "task-state.json"
}

function Read-WorkflowState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $statePath = Get-WorkflowStatePath -RepositoryRoot $RepositoryRoot -Config $Config
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }
    return Get-Content -Raw -LiteralPath $statePath -Encoding UTF8 | ConvertFrom-Json
}

function Write-WorkflowJson {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    [System.IO.Directory]::CreateDirectory((Split-Path $fullPath -Parent)) | Out-Null
    $json = $Value | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($fullPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    return $fullPath
}

function Write-WorkflowState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $statePath = Get-WorkflowStatePath -RepositoryRoot $RepositoryRoot -Config $Config
    return Write-WorkflowJson -Value $State -Path $statePath
}

function Read-WorkflowTaskState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $statePath = Get-WorkflowTaskStatePath -RepositoryRoot $RepositoryRoot -Config $Config
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }
    return Get-Content -Raw -LiteralPath $statePath -Encoding UTF8 | ConvertFrom-Json
}

function Write-WorkflowTaskState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $statePath = Get-WorkflowTaskStatePath -RepositoryRoot $RepositoryRoot -Config $Config
    return Write-WorkflowJson -Value $State -Path $statePath
}

function ConvertFrom-WorkflowGitPath {
    <#
    .SYNOPSIS
    Путь из вывода git — в путь, пригодный для файловых операций.

    .DESCRIPTION
    git печатает путь В КАВЫЧКАХ, когда тот содержит пробел или спецсимвол, и
    ключ core.quotePath=false этого не отменяет: он управляет только экранированием
    не-ASCII. Проверяется тривиально:

        git status --porcelain      ->  M "cf llm/Catalogs/Задачи.xml"
        git diff --name-only        ->    cf llm/Catalogs/Задачи.xml

    То есть одна и та же правка приходит в двух видах, и вид зависит от команды.
    Кавычка, не снятая перед Join-Path, превращается в часть имени файла:
    Test-Path отвечает «нет», и файл попадает в отчёт как исчезнувший, хотя лежит
    на месте. Так и вышло у проекта с каталогами «cf llm» и «cfe llm».

    Разбор был написан ТРИЖДЫ — в отпечатке, в платформенном влиянии и в снимке
    исходников, — и в третьем месте кавычки не снимались вовсе. Это не случайность:
    три копии одного разбора расходятся всегда, вопрос только в том, какая из них
    попадётся первой.

    Внутри кавычек git экранирует по правилам C: \" \\ \t \n \r и восьмеричные
    коды байтов UTF-8 вида \320\227. Поэтому обратные слэши разворачиваются ДО
    нормализации разделителей — иначе экранированная кавычка потеряется, а
    восьмеричные коды склеятся в мусор.
    #>
    param(
        [string]$Path = ""
    )

    $value = [string]$Path
    if (-not $value) {
        return ""
    }

    $value = $value.Trim()
    if (-not ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2)) {
        # Некавыченный путь отдаётся как есть, только с нормализацией разделителей:
        # экранирования в нём нет, и разворачивать нечего.
        return $value.Replace([char]92, [char]47)
    }

    $inner = $value.Substring(1, $value.Length - 2)
    $bytes = New-Object System.Collections.Generic.List[byte]
    $index = 0

    while ($index -lt $inner.Length) {
        $char = $inner[$index]

        if ($char -ne [char]92) {
            foreach ($byte in [System.Text.Encoding]::UTF8.GetBytes([string]$char)) {
                [void]$bytes.Add($byte)
            }
            $index++
            continue
        }

        $index++
        if ($index -ge $inner.Length) {
            break
        }
        $escape = $inner[$index]

        if ($escape -ge '0' -and $escape -le '7') {
            # Восьмеричный код БАЙТА, а не символа: кириллица приходит парами
            # вида Ð, и собирать их надо в байты, иначе получится мусор.
            $digits = ""
            while ($index -lt $inner.Length -and $digits.Length -lt 3 -and
                $inner[$index] -ge '0' -and $inner[$index] -le '7') {
                $digits += $inner[$index]
                $index++
            }
            [void]$bytes.Add([Convert]::ToByte($digits, 8))
            continue
        }

        $decoded = switch ($escape) {
            'n' { [char]10 }
            't' { [char]9 }
            'r' { [char]13 }
            'a' { [char]7 }
            'b' { [char]8 }
            'f' { [char]12 }
            'v' { [char]11 }
            default { $escape }
        }
        foreach ($byte in [System.Text.Encoding]::UTF8.GetBytes([string]$decoded)) {
            [void]$bytes.Add($byte)
        }
        $index++
    }

    return ([System.Text.Encoding]::UTF8.GetString($bytes.ToArray())).Replace([char]92, [char]47)
}

function ConvertFrom-WorkflowGitStatusLine {
    <#
    .SYNOPSIS
    Путь из строки `git status --porcelain`: снимает состояние, кавычки и стрелку переименования.

    .DESCRIPTION
    Возвращает объект с полями Path и PreviousPath. У переименования значим новый
    путь, но старый тоже нужен: ветка, переименовавшая файл, изменила обе стороны.
    #>
    param(
        [string]$Line = ""
    )

    $value = [string]$Line
    if ($value.Length -le 3) {
        return [pscustomobject]@{ State = ""; Path = ""; PreviousPath = "" }
    }

    $state = $value.Substring(0, 2)
    $rest = $value.Substring(3).Trim()
    $previous = ""

    $arrow = $rest.IndexOf(" -> ")
    if ($arrow -ge 0) {
        $previous = ConvertFrom-WorkflowGitPath -Path $rest.Substring(0, $arrow)
        $rest = $rest.Substring($arrow + 4)
    }

    return [pscustomobject]@{
        State = $state
        Path = (ConvertFrom-WorkflowGitPath -Path $rest)
        PreviousPath = $previous
    }
}

function Get-WorkflowPlatformNeutralPatterns {
    <#
    .SYNOPSIS
    Пути, изменение которых НЕ МОЖЕТ изменить поведение конфигурации, стендов или
    самих проверок.

    .DESCRIPTION
    Один список на две задачи. Первая — решить, нужна ли фазе проверка платформой
    вообще. Вторая — решить, обесценилась ли собранная база в кэше. Прежде списка
    было два: в проверке влияния — полный, а у кэша только сьют Web UI. Из-за
    этого правка файла политики тестов или документации пересобирала базу и стенд
    целиком, хотя ни то, ни другое не попадает в базу.

    Два списка одного и того же неизбежно расходятся, и разойдутся в ту сторону,
    которую реже проверяют: лишняя пересборка никого не роняет, её просто терпят.

    Пути проекта берутся из манифеста, а не зашиты: сьют Web UI и файл политики у
    каждого проекта свои.
    #>
    param(
        [object]$Config = $null,

        # Список для КЭША собранных баз. Он шире: сценарии Web UI и скрипты гейта
        # базу не меняют, но платформу для прогона требуют, поэтому пропускать
        # из-за них фазу нельзя, а пересобирать базу — незачем.
        [switch]$ForCache
    )

    $patterns = @(
        '^docs/',
        '^\.gitlab/',
        '^\.github/',
        '^\.vscode/',
        '^\.gitignore$',
        '^\.gitattributes$',
        '^\.editorconfig$',
        '^LICENSE$',
        '\.md$'
    )

    if ($null -eq $Config) {
        return $patterns
    }

    # ── Пути, объявленные ПРОЕКТОМ ──────────────────────────────────────────
    # Комплект не может знать состав чужих инструментов. Проект знает: скрипт
    # сборки релиза или запускающий файл не участвуют ни в одной фазе, и правка
    # в них не может изменить результат проверки платформой. Без этого ключа
    # такая правка стоила полного прогона, который о ней ничего не говорит.
    #
    # Объявление проверяется: путь, накрывающий исходники конфигурации или
    # расширения, отклоняется. Иначе ключом можно было бы молча отключить
    # проверку собственной конфигурации, и выглядело бы это как быстрые фазы.
    $sourceDirectory = [string](Get-WorkflowSettingValue -Object $Config -Name "sourceDir" -Default "")
    $probes = New-Object System.Collections.ArrayList
    if ($sourceDirectory) {
        [void]$probes.Add("$($sourceDirectory.Replace([char]92, [char]47).Trim([char]47))/Configuration.xml")
    }
    foreach ($extension in @(Get-WorkflowSettingValue -Object $Config -Name "extensions" -Default @())) {
        $extensionPath = [string](Get-WorkflowSettingValue -Object $extension -Name "sourcePath" -Default "")
        if ($extensionPath) {
            [void]$probes.Add("$($extensionPath.Replace([char]92, [char]47).Trim([char]47))/Configuration.xml")
        }
    }

    foreach ($declared in @(Get-WorkflowSettingValue -Object $Config -Name "platformNeutralPaths" -Default @())) {
        $pattern = ([string]$declared).Trim()
        if (-not $pattern) {
            continue
        }
        foreach ($probe in $probes) {
            if ($probe -match $pattern) {
                throw ("platformNeutralPaths объявляет нейтральным '$pattern', но под него попадают " +
                    "исходники конфигурации ($probe). Так проверка платформой отключилась бы для самой " +
                    "конфигурации, и выглядело бы это просто как быстрые фазы.")
            }
        }
        if ($patterns -notcontains $pattern) {
            $patterns += $pattern
        }
    }

    if (-not $ForCache) {
        return $patterns
    }

    # Сценарии Web UI читают конфигурацию, но не меняют её: они не попадают ни в
    # базу, ни в стенд. Правка сценария не обязана стоить пересборки — именно
    # из-за этого проверки и запускали в обход фаз.
    $suite = [string](Get-WorkflowSettingValue `
        -Object (Get-WorkflowSettingValue -Object $Config -Name "webUiTests" -Default $null) `
        -Name "suite" -Default "")
    if ($suite) {
        $patterns += ('^' + [regex]::Escape($suite.Replace([char]92, [char]47).Trim([char]47)) + '/')
    }

    # Гейт читает репозиторий и не касается ни конфигурации, ни данных стенда,
    # поэтому его правка не обязана обесценивать собранную базу. Прежде обесценивала:
    # каждое обновление комплекта означало пересборку базы и стенда ради скрипта,
    # который в базу не попадает.
    #
    # Только для КЭША. В платформенное влияние это не уходит намеренно: ветка,
    # изменившая гейт, обязана прогнать фазу целиком — иначе новые правила гейта
    # впервые применятся уже после мержа.
    $patterns += '^scripts/ci/'

    # Политика сопровождения тестов управляет ГЕЙТОМ, а не конфигурацией.
    $policy = [string](Get-WorkflowSettingValue `
        -Object (Get-WorkflowSettingValue -Object $Config -Name "testMaintenance" -Default $null) `
        -Name "policy" -Default "")
    if ($policy) {
        $patterns += ('^' + [regex]::Escape($policy.Replace([char]92, [char]47).Trim([char]47)) + '$')
    }

    return $patterns
}

function Get-WorkflowPlatformImpact {
    <#
    .SYNOPSIS
    Отвечает, может ли набор изменений ветки повлиять на результат проверки платформой.

    .DESCRIPTION
    Нужна, чтобы ветка, не трогающая ничего кроме документации, не платила полный
    preflight дважды. Конфигурация в такой ветке побайтово равна основной, которая
    уже проверена, и повторная сборка базы не может дать другого ответа.

    Список безопасных путей — БЕЛЫЙ, и это принципиально. Чёрный список был бы
    дефектом по построению: каждый новый каталог по умолчанию попадал бы в «не
    влияет», и однажды туда попало бы то, что влияет. Неизвестный путь считается
    влияющим, фаза выполняется целиком.

    Сравнение идёт СРАЗУ по двум источникам: накопленному ветке diff относительно
    базы и незакоммиченным правкам рабочего дерева. По одному diff пропуск был бы
    неверным — правка конфигурации, ещё не попавшая в коммит, осталась бы
    непроверенной.

    Diff берётся по всей ветке, а не по последнему коммиту, намеренно: ветка,
    которая изменила конфигурацию раньше, а сейчас правит только README, обязана
    проверяться полностью. Иначе пропуск зависел бы от того, как разложены коммиты.

    Возвращает объект с полями:
      Impacts   — требуется ли проверка платформой;
      Paths     — все изменённые пути;
      Unsafe    — пути, из-за которых проверка требуется;
      BaseRef   — с чем сравнивали.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$BaseRef
    )

    # Пути, изменение которых не может изменить поведение конфигурации 1С, стендов
    # или самих проверок. Всё остальное — влияет.
    # Манифест читается ЗДЕСЬ, а не приходит параметром: иначе каждый вызывающий
    # обязан был бы его передать, а забывший получил бы полный прогон вместо
    # пропуска — то есть ошибку, которую не видно.
    #
    # БЕЗ -ForCache, и это не упущение. Сценарии Web UI и скрипты гейта нейтральны
    # только для кэша собранных баз: платформа для их прогона нужна тем более.
    # А вот пути, объявленные проектом, учитываются: он знает свои инструменты,
    # не участвующие ни в одной фазе.
    $neutralConfig = $null
    try {
        $neutralConfig = Get-WorkflowConfig -RepositoryRoot $RepositoryRoot
    }
    catch {
        # Манифеста нет или он битый — решает базовый список. Отказ в пропуске
        # всегда безопаснее пропуска по неполным данным.
        $neutralConfig = $null
    }

    $safePatterns = @(Get-WorkflowPlatformNeutralPatterns -Config $neutralConfig)

    $paths = New-Object System.Collections.ArrayList
    $baseAvailable = (Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("rev-parse", "--verify", "--quiet", $BaseRef) `
        -AllowFailure).ExitCode -eq 0
    if (-not $baseAvailable) {
        # Не с чем сравнивать — считаем, что влияет. Отказ в пропуске всегда
        # безопаснее пропуска по неполным данным.
        return [pscustomobject]@{
            Impacts = $true
            Paths = @()
            Unsafe = @()
            BaseRef = $BaseRef
        }
    }

    # Различия только в концах строк платформу не касаются: загруженная
    # конфигурация от них не зависит, и ответ проверки был бы тот же самый.
    foreach ($line in @((Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("-c", "core.quotePath=false", "diff", "--ignore-cr-at-eol",
            "--name-only", "$BaseRef...HEAD")).Output)) {
        $value = ([string]$line).Trim()
        if ($value -and -not $paths.Contains($value)) {
            [void]$paths.Add($value)
        }
    }
    foreach ($line in @((Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("-c", "core.quotePath=false", "status", "--porcelain=v1", "--untracked-files=all")).Output)) {
        # Разбор общий с отпечатком и снимком исходников: три копии одного
        # разбора расходятся всегда, и одна из них уже разошлась.
        $parsed = ConvertFrom-WorkflowGitStatusLine -Line ([string]$line)
        if (-not $parsed.Path) {
            continue
        }
        if ($parsed.PreviousPath -and -not $paths.Contains($parsed.PreviousPath)) {
            [void]$paths.Add($parsed.PreviousPath)
        }
        $value = $parsed.Path
        if ($value -and -not $paths.Contains($value)) {
            [void]$paths.Add($value)
        }
    }

    $unsafe = New-Object System.Collections.ArrayList
    foreach ($path in $paths) {
        $normalized = ([string]$path).Replace('\', '/')
        $safe = $false
        foreach ($pattern in $safePatterns) {
            if ($normalized -match $pattern) {
                $safe = $true
                break
            }
        }
        if (-not $safe) {
            [void]$unsafe.Add($normalized)
        }
    }

    return [pscustomobject]@{
        # Пустой список изменений тоже считается влияющим: сравнивать нечего,
        # значит и утверждать «проверка не нужна» не на чем.
        Impacts = [bool]($paths.Count -eq 0 -or $unsafe.Count -gt 0)
        Paths = @($paths)
        Unsafe = @($unsafe)
        BaseRef = $BaseRef
    }
}

function Get-WorkflowKitOnlyChange {
    <#
    .SYNOPSIS
    Отвечает, состоит ли правка ветки ТОЛЬКО из файлов комплекта процесса.

    .DESCRIPTION
    Подъём комплекта не меняет ни одного исходника конфигурации, но проходил как
    обычная задача: ветка, Start, Compile, Selfcheck, Verify. Selfcheck при этом
    заново собирал базу и стенд и генерировал данные — над конфигурацией,
    побайтово равной основной, которая уже проверена. Замерено на 0.35.0: 111
    секунд Selfcheck, из них 69 — генерация данных стенда, промах кэша вызван
    скриптом, который в базу 1С не попадает физически.

    Список разрешённых путей БЕЛЫЙ и берётся из замка установки, а не из догадок
    по каталогам. Чёрный список был бы дефектом по построению: каждый новый файл
    по умолчанию считался бы «файлом комплекта», и однажды так прошла бы правка
    конфигурации. По той же причине неизвестный путь всегда делает ответ
    отрицательным, а не наоборот.

    В разрешённые попадает и то, что комплект правит, но в замке не сверяет:
    манифест проекта, сам замок и файлы с размеченными блоками (AGENTS.md,
    CLAUDE.md, .gitignore). Это цена одного компромисса, названного прямо:
    правка `.1c-workflow.json` в такой ветке проверку платформой не получит.
    Манифест не попадает в базу и не меняет исходники, но меняет поведение фаз,
    поэтому облегчённый зачёт за ним не признаётся полной проверкой ничем — см.
    состояние `kit-updated`, из которого не собирается выпуск.

    Пустая правка — НЕ правка комплекта. Ветка без изменений зачитывала бы
    облегчённую фазу ни за что, а состояние выглядело бы так же, как после
    настоящего подъёма.

    Возвращает объект с полями:
      KitOnly        — можно ли зачесть подъём комплекта облегчённой фазой;
      Paths          — все изменённые пути ветки;
      Foreign        — пути, из-за которых облегчённый зачёт невозможен;
      ProcessVersion — версия процесса из замка;
      Problem        — почему ответ отрицательный, если дело не в путях.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$BaseRef,

        [string]$LockPath = ""
    )

    $result = [pscustomobject]@{
        KitOnly = $false
        Paths = @()
        Foreign = @()
        ProcessVersion = ""
        Problem = ""
    }

    if (-not $LockPath) {
        $LockPath = Join-Path $RepositoryRoot ".1c-workflow.lock.json"
    }
    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
        $result.Problem = "Замка установки нет: $LockPath. Состав комплекта неизвестен, и отличить его правку от прикладной нечем."
        return $result
    }

    try {
        $lock = Get-Content -Raw -LiteralPath $LockPath -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $result.Problem = "Замок установки не читается: $LockPath. $($_.Exception.Message)"
        return $result
    }

    $result.ProcessVersion = [string](Get-WorkflowSettingValue -Object $lock -Name "processVersion" -Default "")
    $managed = @(Get-WorkflowSettingValue -Object $lock -Name "managedPaths" -Default @())
    if ($managed.Count -eq 0) {
        # Замок прежнего образца перечислял только сверяемые файлы. Достроить
        # список по нему нельзя: комплект пишет и то, что намеренно не сверяет,
        # и такой путь выглядел бы чужим. Отказ честнее догадки.
        $result.Problem = "Замок установки не перечисляет файлы комплекта (managedPaths). Переустановите комплект: состав известен установщику, а не проекту."
        return $result
    }

    $allowed = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $managed) {
        [void]$allowed.Add(([string]$path).Replace([char]92, [char]47).Trim([char]47))
    }

    $impact = Get-WorkflowPlatformImpact -RepositoryRoot $RepositoryRoot -BaseRef $BaseRef
    $result.Paths = @($impact.Paths)
    if ($result.Paths.Count -eq 0) {
        $result.Problem = "В ветке нет изменений относительно '$BaseRef': зачитывать нечего."
        return $result
    }

    $foreign = New-Object System.Collections.ArrayList
    foreach ($path in $result.Paths) {
        $normalized = ([string]$path).Replace([char]92, [char]47).Trim([char]47)
        if (-not $allowed.Contains($normalized)) {
            [void]$foreign.Add($normalized)
        }
    }
    $result.Foreign = @($foreign)
    $result.KitOnly = [bool]($foreign.Count -eq 0)
    return $result
}

function Test-WorkflowPathInScope {
    <#
    .SYNOPSIS
    Попадает ли путь в область, заданную префиксами каталогов.

    .DESCRIPTION
    Пустой список префиксов означает «вся копия», а не «ничего»: сужение — это
    осознанный выбор вызывающего, и его отсутствие не должно тихо обнулять набор.

    Сравнение идёт по границе каталога, а не по подстроке: иначе «tests/web» ловил
    бы «tests/web-old» и правка одного каталога считалась бы правкой другого.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path,

        [string[]]$Prefixes = @(),

        [string[]]$Exclusions = @(),

        [string[]]$ExcludePatterns = @()
    )

    $normalized = ([string]$Path).Replace([char]92, [char]47).Trim([char]47)
    $matches = {
        param([string[]]$Candidates)
        foreach ($prefix in @($Candidates | Where-Object { $_ })) {
            $value = ([string]$prefix).Replace([char]92, [char]47).Trim([char]47)
            if ($normalized -eq $value -or $normalized.StartsWith("$value/")) {
                return $true
            }
        }
        return $false
    }

    # Исключение сильнее включения: спорный путь остаётся ЗА областью. Ошибка в эту
    # сторону стоит лишней пересборки, ошибка в обратную — подтверждает чужой код.
    if (& $matches @($Exclusions)) {
        return $false
    }
    foreach ($pattern in @($ExcludePatterns | Where-Object { $_ })) {
        if ($normalized -match $pattern) {
            return $false
        }
    }
    $list = @($Prefixes | Where-Object { $_ })
    if ($list.Count -eq 0) {
        return $true
    }
    return (& $matches $list)
}

function ConvertFrom-WorkflowCritiqueOutput {
    <#
    .SYNOPSIS
    Достаёт JSON-отчёт из вывода ревьюера.

    .DESCRIPTION
    Нужна ради переносимости между инструментами, а не ради удобства. Агентские
    CLI (claude, codex) умеют записать отчёт файлом сами; обёртка над подпиской
    обычно только печатает ответ, и почти всегда — в заборе ```json с текстом
    вокруг: «вот что я нашёл», список, вежливое заключение.

    Берётся последний блок: модель, исправившая себя по ходу ответа, оставляет
    верный вариант последним, а первый — черновиком.

    Отсутствие JSON — ОШИБКА, а не пустой отчёт. Пустой отчёт означает «замечаний
    нет», и подменять им «ревьюер ничего не ответил» значило бы выдавать молчание
    за одобрение.
    #>
    param(
        [string]$Text = ""
    )

    if (-not $Text) {
        throw "Ревьюер ничего не напечатал: отчёт взять неоткуда."
    }

    $fences = [regex]::Matches($Text, '```(?:json)?\s*(\{.*?\})\s*```',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($fences.Count -gt 0) {
        return $fences[$fences.Count - 1].Groups[1].Value
    }

    # Забора нет — ищем последний сбалансированный объект верхнего уровня.
    $depth = 0
    $start = -1
    $last = ""
    $inString = $false
    $escaped = $false

    for ($index = 0; $index -lt $Text.Length; $index++) {
        $char = $Text[$index]

        if ($inString) {
            if ($escaped) {
                $escaped = $false
            }
            elseif ($char -eq [char]92) {
                $escaped = $true
            }
            elseif ($char -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($char -eq '"') {
            $inString = $true
            continue
        }
        if ($char -eq '{') {
            if ($depth -eq 0) {
                $start = $index
            }
            $depth++
            continue
        }
        if ($char -eq '}') {
            $depth--
            if ($depth -eq 0 -and $start -ge 0) {
                $last = $Text.Substring($start, $index - $start + 1)
            }
            if ($depth -lt 0) {
                $depth = 0
                $start = -1
            }
        }
    }

    if (-not $last) {
        throw "В выводе ревьюера нет JSON-объекта. Вывод: $($Text.Substring(0, [Math]::Min(400, $Text.Length)))"
    }

    return $last
}

function Find-WorkflowGitLfsPointers {
    <#
    .SYNOPSIS
    Файлы исходников, оставшиеся указателями Git LFS вместо содержимого.

    .DESCRIPTION
    Картинки, макеты и двоичные части конфигурации обычно хранятся в Git LFS. На
    клоне, сделанном без git-lfs, вместо них лежат текстовые указатели по 130
    байт, и платформа грузит такую конфигурацию БЕЗ ЕДИНОЙ ОШИБКИ. Фазы проходят,
    тесты зелёные, а собранный cf выходит неполным: в проекте — 5.9 МБ вместо
    8.2 МБ. Отличить его от правильного можно только по размеру.

    Это худший вид дефекта: успешный результат, который нельзя отличить от
    верного. Поэтому проверка стоит там, где он возникает, — перед загрузкой
    исходников, а не там, где он обнаружится: у пользователя, которому не
    показали картинку.

    Наличие git-lfs НЕ проверяется и не требуется: его отсутствие и есть ловимый
    случай. Указатель — маленький текстовый файл с фиксированной первой строкой,
    поэтому читаются только файлы меньше килобайта.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [int]$Limit = 3
    )

    $prefix = "version https://git-lfs.github.com/spec/v1"
    $pointers = New-Object System.Collections.ArrayList

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        return [pscustomobject]@{ Count = 0; Examples = @() }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $SourcePath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 0 -and $_.Length -lt 1024 })) {

        try {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        }
        catch {
            continue
        }

        $take = [Math]::Min($prefix.Length, $bytes.Length)
        if ([System.Text.Encoding]::ASCII.GetString($bytes, 0, $take) -ne $prefix) {
            continue
        }

        [void]$pointers.Add($file.FullName.Substring($SourcePath.Length).TrimStart([char]92))
    }

    return [pscustomobject]@{
        Count = $pointers.Count
        Examples = @(@($pointers) | Sort-Object | Select-Object -First $Limit)
    }
}

function Assert-WorkflowSourcesMaterialized {
    <#
    .SYNOPSIS
    Отказывает, если исходники конфигурации содержат указатели Git LFS.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )

    $found = Find-WorkflowGitLfsPointers -SourcePath $SourcePath
    if ($found.Count -eq 0) {
        return
    }

    throw ("Содержимое Git LFS не получено: указателями остались $($found.Count) файл(ов), " +
        "например $(@($found.Examples) -join ', '). Конфигурация из указателей грузится без " +
        "ошибок, но собранный cf выходит неполным — без картинок и двоичных частей. " +
        "Выполните: git lfs install, затем git lfs pull.")
}

function ConvertFrom-WorkflowEolLine {
    <#
    .SYNOPSIS
    Разбирает строку git ls-files --eol на вид концов строк, атрибуты и путь.

    .DESCRIPTION
    Формат строки: "i/lf    w/crlf  attr/text=auto eol=crlf     <путь>". Путь
    отделён табуляцией. Разбор вынесен отдельно, потому что решение «дефект или
    норма» принимается по ДВУМ полям сразу — виду концов строк в индексе и
    атрибутам файла: по одному лишь виду испорченный файл от намеренно не
    нормализуемого не отличить.
    #>
    param(
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }

    if ($Line -notmatch '^i/(\S+)\s+w/(\S+)\s+attr/(.*?)\s*\t(.+)$') {
        return $null
    }

    return [pscustomobject]@{
        IndexEol = $Matches[1]
        WorkingEol = $Matches[2]
        Attributes = $Matches[3].Trim()
        Path = $Matches[4].Trim()
    }
}

function Test-WorkflowEolConverted {
    <#
    .SYNOPSIS
    Преобразует ли git концы строк этого файла.

    .DESCRIPTION
    Преобразование выключено атрибутом -text. Всё остальное — text, text=auto,
    отсутствие атрибутов — означает, что git перепишет концы строк и при add, и
    при checkout.
    #>
    param(
        [string]$Attributes
    )

    return -not ([string]$Attributes -match '(^|\s)-text($|\s)')
}

function Select-WorkflowEolOffenders {
    <#
    .SYNOPSIS
    Файлы, у которых концы строк в индексе противоречат их же атрибутам.

    .DESCRIPTION
    Дефект — не CRLF в индексе сам по себе, а РАСХОЖДЕНИЕ между тем, что файл
    объявляет, и тем, как он хранится. У файла с -text содержимое хранится как
    есть, и CRLF в индексе для него норма; у файла без -text тот же CRLF значит,
    что ренормализацию не выполнили, и следующий checkout выдаст не то, что было
    закоммичено.

    Прежняя проверка смотрела на один только вид концов строк. После перевода
    выгрузки 1С на -text она ловила бы всю конфигурацию — то есть требовала бы
    вернуть ровно ту нормализацию, которая портит данные.
    #>
    param(
        [string[]]$Lines
    )

    $offenders = New-Object System.Collections.ArrayList

    foreach ($line in @($Lines)) {
        $parsed = ConvertFrom-WorkflowEolLine -Line $line
        if ($null -eq $parsed) {
            continue
        }
        if (@("crlf", "mixed") -notcontains $parsed.IndexEol) {
            continue
        }
        if (-not (Test-WorkflowEolConverted -Attributes $parsed.Attributes)) {
            continue
        }

        [void]$offenders.Add($parsed.Path)
    }

    return @($offenders)
}

function Select-WorkflowConvertedDumpFiles {
    <#
    .SYNOPSIS
    Файлы выгрузки 1С, концы строк которых git всё ещё нормализует.

    .DESCRIPTION
    В выгрузке перевод строки бывает ДАННЫМИ: двухстрочное представление
    колонки, картинка SVG, текстовый макет, текст ограничения доступа в
    Rights.xml. Нормализация портит их в обе стороны — LF→CRLF на checkout и
    CRLF→LF на add, — и порча не видна ни в diff, ни в фазах: расходится
    собранный cf, а Конфигуратор показывает изменённой всю конфигурацию.

    Проверка положительная: она требует, чтобы у файлов выгрузки стоял -text, а
    не ищет следы уже случившейся порчи. Искать их поздно — после нормализации
    исходный вид не восстановить, он не сохранён нигде.
    #>
    param(
        [string[]]$Lines,

        [string[]]$SourcePrefixes,

        [int]$Limit = 5
    )

    # Расширения, где перевод строки бывает данными. Двоичные части выгрузки
    # (.mxl, .bin и прочие) сюда не входят: у них -text стоит давно и по другой
    # причине — они не текст вовсе.
    $dumpExtensions = @(".xml", ".html", ".txt", ".svg")

    $prefixes = @(
        @($SourcePrefixes) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Replace([string][char]92, "/").Trim("/") + "/" }
    )

    $converted = New-Object System.Collections.ArrayList

    foreach ($line in @($Lines)) {
        $parsed = ConvertFrom-WorkflowEolLine -Line $line
        if ($null -eq $parsed) {
            continue
        }

        $path = $parsed.Path.Replace([string][char]92, "/")
        if ($prefixes.Count -gt 0) {
            $inside = $false
            foreach ($prefix in $prefixes) {
                if ($path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $inside = $true
                    break
                }
            }
            if (-not $inside) {
                continue
            }
        }

        if ($dumpExtensions -notcontains [System.IO.Path]::GetExtension($path).ToLowerInvariant()) {
            continue
        }
        if (-not (Test-WorkflowEolConverted -Attributes $parsed.Attributes)) {
            continue
        }

        [void]$converted.Add($parsed.Path)
    }

    return [pscustomobject]@{
        Count = $converted.Count
        Examples = @(@($converted) | Sort-Object | Select-Object -First $Limit)
    }
}

function Expand-WorkflowPolicyPattern {
    <#
    .SYNOPSIS
    Подставляет в шаблон правила политики пути текущего проекта.

    .DESCRIPTION
    __WORKFLOW_COMPONENTS__ — каталоги выгрузки, __WEBUI_SUITE__ — корень Web UI
    сьюта из настроек.

    Зашитый путь делает правило НЕДОСТИЖИМЫМ: проект, у которого сьют лежит не
    там, получает требование «обнови проверку в каталоге X», где ни один тест не
    запускается. Выполнить его нечем, и остаётся либо обходить политику, либо
    править чужой каталог ради отметки. Поймано на живом проекте: политика
    требовала правку в tests/web-ui, прогонялся tests/<проект>, и обновление
    карты разделов правилу не засчитывалось.
    #>
    param(
        [string]$Pattern,

        [string]$ComponentPattern,

        [string]$WebUiSuite
    )

    $expanded = [string]$Pattern
    if ($ComponentPattern) {
        $expanded = $expanded.Replace("__WORKFLOW_COMPONENTS__", $ComponentPattern)
    }
    if ($WebUiSuite) {
        # Разделитель приводится к прямому слэшу: в настройках путь может быть
        # записан по-виндовому, а сравнивается он с путями из git.
        $suite = ([string]$WebUiSuite).Replace([string][char]92, "/").Trim("/")
        $expanded = $expanded.Replace("__WEBUI_SUITE__", $suite)
    }

    return $expanded
}

function Import-WorkflowDotEnv {
    <#
    .SYNOPSIS
    Загружает переменные из .env в корне репозитория, не затирая уже заданные.

    .DESCRIPTION
    Секретам нужно место, которого нет в отслеживаемых файлах. Пароль серверной
    базы комплект берёт из настроек, и от попадания в репозиторий его спасает
    только то, что тот файл не коммитят, — соглашение, а не механика. Отдельного
    места для секретов у процесса не было вовсе.

    Заданное в окружении СИЛЬНЕЕ файла: разовый запуск с другим паролем не должен
    молча брать старый, иначе результат нельзя объяснить, глядя на команду.

    Формат простой: КЛЮЧ=значение, пустые строки и строки с # пропускаются,
    окружающие кавычки снимаются. Ничего сверх этого не разбирается: файл хранит
    секреты, и вычислять в нём выражения означало бы их исполнять.

    Возвращает ИМЕНА загруженных переменных — значения не возвращаются и нигде не
    печатаются: вывод фазы копируют в переписку целиком.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [string]$FileName = ".env"
    )

    $path = Join-Path $RepositoryRoot $FileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }

    $loaded = New-Object System.Collections.ArrayList

    foreach ($line in @(Get-Content -LiteralPath $path -Encoding UTF8)) {

        $value = ([string]$line).Trim()
        if (-not $value -or $value.StartsWith("#")) {
            continue
        }

        $separator = $value.IndexOf("=")
        if ($separator -le 0) {
            continue
        }

        $name = $value.Substring(0, $separator).Trim()
        if (-not $name) {
            continue
        }

        $data = $value.Substring($separator + 1).Trim()
        if (($data.StartsWith('"') -and $data.EndsWith('"') -and $data.Length -ge 2) -or
            ($data.StartsWith("'") -and $data.EndsWith("'") -and $data.Length -ge 2)) {
            $data = $data.Substring(1, $data.Length - 2)
        }

        if ([Environment]::GetEnvironmentVariable($name)) {
            continue
        }

        [System.Environment]::SetEnvironmentVariable($name, $data)
        [void]$loaded.Add($name)
    }

    return @($loaded)
}

function Import-WorkflowSecret {
    <#
    .SYNOPSIS
    Раскрывает ссылку вида ${ИМЯ} на переменную окружения в значении настройки.

    .DESCRIPTION
    Даёт положить в отслеживаемую настройку не сам секрет, а имя переменной:
    "password": "${GT_STAND_PASSWORD}". Значение приезжает из .env или из
    окружения, а в репозитории остаётся только имя.

    Нераскрытая ссылка — ОТКАЗ, а не пустая строка. Пустой пароль платформа
    принимает и отвечает отказом доступа, неотличимым от неверных учётных
    данных: искали бы права, а дело в незаданной переменной.
    #>
    param(
        [string]$Value = ""
    )

    if (-not $Value) {
        return $Value
    }

    $match = [regex]::Match($Value, '^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$')
    if (-not $match.Success) {
        return $Value
    }

    $name = $match.Groups[1].Value
    $resolved = [Environment]::GetEnvironmentVariable($name)

    if (-not $resolved) {
        throw ("Настройка ссылается на переменную $name, а та не задана. Положите её в .env " +
            "в корне репозитория или задайте в окружении: значение секрета в отслеживаемом файле " +
            "хранить нельзя.")
    }

    return $resolved
}

function Get-WorkflowCritiqueProbe {
    <#
    .SYNOPSIS
    Учебный пример для пакета: заведомый случай из чек-листа, которого нет в репозитории.

    .DESCRIPTION
    Калибровка ревьюера на известном ответе. Без неё комплект не отличает
    «замечаний нет» от «ревьюер ничего не смотрел»: оба выглядят как пустой
    отчёт, и второй случай тише первого.

    Пример подчёркнуто грубый. Задача не поймать ревьюера на тонкости, а
    отсеять того, кто не смотрит вовсе, поэтому пропустить его нельзя, не
    пропустив заодно и настоящие замечания.

    Пример выбирается ПО ОТПЕЧАТКУ: одно и то же содержимое получает один и тот
    же пример, повторный прогон не меняет вопрос, а разные правки получают
    разные примеры.

    Путь примера заведомо невозможен в выгрузке, поэтому спутать его с настоящим
    файлом нельзя, а замечание по нему не попадает в список к исправлению.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Fingerprint
    )

    $probes = @(
        [pscustomobject]@{
            Name = "курсор в константе"
            Items = @("state-derivable-from-data", "per-item-loop")
            Code = @(
                "Процедура ОбработатьЗаказыПорцией() Экспорт",
                "",
                "	Граница = Константы.ПоследнийОбработанныйЗаказ.Получить();",
                "	Выборка = Справочники.Заказы.Выбрать();",
                "",
                "	Пока Выборка.Следующий() Цикл",
                "		Если Выборка.Ссылка <= Граница Тогда",
                "			Продолжить;",
                "		КонецЕсли;",
                "		ОбработатьЗаказ(Выборка.Ссылка);",
                "		Константы.ПоследнийОбработанныйЗаказ.Установить(Выборка.Ссылка);",
                "	КонецЦикла;",
                "",
                "КонецПроцедуры"
            )
        },
        [pscustomobject]@{
            Name = "пустой обработчик включённого задания"
            Items = @("dead-handler")
            Code = @(
                "// Регламентное задание ОчисткаУстаревшихДанных включено, расписание задано.",
                "Процедура ОчиститьУстаревшиеДанные() Экспорт",
                "",
                "	// TODO: дописать очистку",
                "",
                "КонецПроцедуры"
            )
        },
        [pscustomobject]@{
            Name = "список имён рядом с метаданными"
            Items = @("duplicated-list", "test-cannot-fail")
            Code = @(
                "Функция ИменаРеквизитовДляСравнения()",
                "",
                "	Имена = Новый Массив;",
                "	Имена.Добавить(""Статус"");",
                "	Имена.Добавить(""Исполнитель"");",
                "	Имена.Добавить(""Заголовок"");",
                "",
                "	Возврат Имена;",
                "",
                "КонецФункции",
                "",
                "// Тест:",
                "Процедура ИменаЗаполнены() Экспорт",
                "	ЮТест.ОжидаетЧто(ИменаРеквизитовДляСравнения().Количество() > 0).Равно(Истина);",
                "КонецПроцедуры"
            )
        }
    )

    $index = 0
    if ($Fingerprint.Length -gt 0) {
        $index = [Convert]::ToInt32($Fingerprint.Substring(0, 1), 16) % $probes.Count
    }
    $probe = $probes[$index]

    return [pscustomobject]@{
        Path = "__probe__/УчебныйПример.bsl"
        Name = $probe.Name
        Items = @($probe.Items)
        Code = @($probe.Code)
    }
}

function New-WorkflowCritiqueToken {
    <#
    .SYNOPSIS
    Разовый токен пакета: его возврат в отчёте доказывает, что пакет дошёл.

    .DESCRIPTION
    Токен СЛУЧАЙНЫЙ, а не выведенный из отпечатка. Выводимый из отпечатка можно
    посчитать по опубликованной формуле, ни разу не открыв пакет, — то есть он
    доказывал бы знание комплекта, а не получение правки.
    #>
    param()

    return ([guid]::NewGuid().ToString("N").Substring(0, 16))
}

function Get-WorkflowAgentSessionVariables {
    <#
    .SYNOPSIS
    Переменные окружения, привязывающие процесс к ТЕКУЩЕМУ сеансу агента.

    .DESCRIPTION
    Ревьюер обязан быть независимым сеансом, а не продолжением того, чью работу
    он проверяет. Унаследованные идентификатор сеанса и канал сообщений — это и
    есть привязка: дочерний процесс подключается к родительскому сеансу, видит
    его контекст и перестаёт быть вторым мнением.

    Список именно переменных, а не «всё, что начинается с CLAUDE_»: снести лишнее
    значит сломать запуск. Ключи с настройками (путь к исполняемому файлу, модель)
    наследуются намеренно — ревью должно идти тем же инструментом.
    #>
    param()

    return @(
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ATTENDED",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_PID",
        "CODEX_SESSION_ID",
        "CODEX_THREAD_ID"
    )
}

function Get-WorkflowDevelopmentAgent {
    <#
    .SYNOPSIS
    Каким агентом и какой моделью ведётся разработка прямо сейчас.

    .DESCRIPTION
    Определяется по окружению, а не по настройкам проекта: настройка устаревает
    молча, а окружение описывает текущий сеанс по определению. Ревью должно
    идти ТЕМ ЖЕ инструментом и той же моделью — ревьюер слабее автора находит
    меньше автора, и такое ревью создаёт видимость проверки.

    Модель берётся из окружения, если инструмент её объявляет. Не объявляет —
    возвращается пустая строка, и команда собирается без указания модели: сеанс
    пойдёт на умолчании инструмента. Придумывать модель нельзя — записанная
    наугад, она молча уводит ревью на другую.
    #>
    param()

    if ($env:CLAUDECODE -or $env:CLAUDE_CODE_EXECPATH) {
        $executable = [string]$env:CLAUDE_CODE_EXECPATH
        if (-not $executable) {
            $executable = "claude"
        }
        return [pscustomobject]@{
            Kind = "claude"
            Executable = $executable
            Model = [string]$env:ANTHROPIC_MODEL
        }
    }

    if ($env:CODEX_HOME -or ([string]$env:AI_AGENT).StartsWith("codex")) {
        return [pscustomobject]@{
            Kind = "codex"
            Executable = "codex"
            Model = [string]$env:CODEX_MODEL
        }
    }

    return [pscustomobject]@{
        Kind = "none"
        Executable = ""
        Model = ""
    }
}

function Resolve-WorkflowReviewCommand {
    <#
    .SYNOPSIS
    Команда ревьюера: заданная проектом или собранная под текущего агента.

    .DESCRIPTION
    Проект называет команду сам — она и побеждает: комплект не выбирает
    инструмент за проект. Команды нет — собирается запуск ТОГО ЖЕ агента, которым
    идёт разработка, отдельным сеансом.

    Автосборка не догадка: путь к исполняемому файлу и модель берутся из
    окружения текущего сеанса. Агент не распознан — команды нет, и фаза скажет
    об этом прямо, а не запустит что попало.
    #>
    param(
        $ReviewConfig,

        $Agent,

        [string]$PacketPlaceholder = "{packet}",

        [string]$ReportPlaceholder = "{report}",

        # Задание для сеанса. Пусто — ревью: механизм один, а зовут им и
        # ревьюера, и архитектора, и разница между ними только в задании.
        [string]$Prompt = ""
    )

    $explicit = @(Get-WorkflowSettingValue -Object $ReviewConfig -Name "command" -Default @())
    if ($explicit.Count -gt 0) {
        return [pscustomobject]@{
            Command = @($explicit)
            Input = [string](Get-WorkflowSettingValue -Object $ReviewConfig -Name "input" -Default "path")
            Output = [string](Get-WorkflowSettingValue -Object $ReviewConfig -Name "output" -Default "file")
            Source = "настройка проекта"
            Agent = "по настройке"
            Model = [string](Get-WorkflowSettingValue -Object $ReviewConfig -Name "model" -Default "")
        }
    }

    $requested = [string](Get-WorkflowSettingValue -Object $ReviewConfig -Name "agent" -Default "auto")
    if ($requested -eq "none") {
        return $null
    }

    if ($null -eq $Agent) {
        $Agent = Get-WorkflowDevelopmentAgent
    }
    if ($requested -ne "auto" -and $requested -ne $Agent.Kind) {
        return $null
    }
    if ($Agent.Kind -eq "none") {
        return $null
    }

    $model = [string](Get-WorkflowSettingValue -Object $ReviewConfig -Name "model" -Default "")
    if (-not $model) {
        $model = [string]$Agent.Model
    }

    if (-not $Prompt) {
        $Prompt = "Ты независимый ревьюер. Прочитай пакет ревью $PacketPlaceholder, " +
            "проверь правку по описанному в нём и запиши отчёт в $ReportPlaceholder " +
            "строго в формате, который пакет задаёт. Код не правь."
    }
    $prompt = $Prompt

    $command = switch ($Agent.Kind) {
        "claude" {
            $arguments = @($Agent.Executable, "-p", $prompt)
            if ($model) {
                $arguments += @("--model", $model)
            }
            $arguments
        }
        "codex" {
            $arguments = @($Agent.Executable, "exec")
            if ($model) {
                $arguments += @("--model", $model)
            }
            $arguments + @($prompt)
        }
        default { @() }
    }

    if (@($command).Count -eq 0) {
        return $null
    }

    return [pscustomobject]@{
        Command = @($command)
        Input = "path"
        Output = "file"
        Source = "автоопределение по текущему сеансу"
        Agent = $Agent.Kind
        Model = $model
    }
}

function Get-WorkflowUserHelpSettings {
    <#
    .SYNOPSIS
    Настройки требования встроенной справки.

    .DESCRIPTION
    Виды узкие намеренно: справка нужна тому, что пользователь открывает и чем
    распоряжается. Требовать её от регистра, который пишет код, значит требовать
    документацию для разработчика — её место в docs, а не в F1.
    #>
    param(
        $Config
    )

    $help = Get-WorkflowSettingValue -Object $Config -Name "userHelp" -Default $null

    $kinds = @(Get-WorkflowSettingValue -Object $help -Name "kinds" -Default @())
    if ($kinds.Count -eq 0) {
        $kinds = @("Catalogs", "Documents", "Reports", "DataProcessors", "BusinessProcesses", "Tasks")
    }

    $languages = @(Get-WorkflowSettingValue -Object $help -Name "languages" -Default @())
    if ($languages.Count -eq 0) {
        $languages = @("ru")
    }

    return [pscustomobject]@{
        Enabled = [bool](Get-WorkflowSettingValue -Object $help -Name "enabled" -Default $false)
        Kinds = @($kinds)
        Languages = @($languages)
        # Картинки справки лежат отдельно от страниц: страница хранит их строкой
        # data:, а исходники нужны, чтобы переснять и вставить заново.
        ImagesDir = [string](Get-WorkflowSettingValue -Object $help -Name "imagesDir" -Default "docs/help-images")
        # Порог предупреждения о тяжёлой странице. Картинка внутри страницы растёт
        # на треть от кодирования, и такую страницу неудобно читать и править.
        PageWarnKb = [int](Get-WorkflowSettingValue -Object $help -Name "pageWarnKb" -Default 400)
    }
}

function Test-WorkflowObjectHelpRegistration {
    <#
    .SYNOPSIS
    Проверяет, что страница справки не только лежит на диске, но подключена к объекту.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Language
    )

    $parts = @(([string]$Object).Replace([string][char]92, "/").Split("/"))
    if ($parts.Count -ne 2) {
        return $false
    }

    $kindPath = Join-Path $SourcePath $parts[0]
    $ownerPath = Join-Path $kindPath "$($parts[1]).xml"
    $objectPath = Join-Path $kindPath $parts[1]
    $descriptorPath = Join-Path (Join-Path $objectPath "Ext") "Help.xml"
    $pagePath = Join-Path (Join-Path (Join-Path $objectPath "Ext") "Help") "$Language.html"

    if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $descriptorPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $pagePath -PathType Leaf)) {
        return $false
    }

    try {
        [xml]$owner = Get-Content -Raw -LiteralPath $ownerPath -Encoding UTF8
        $include = $owner.SelectSingleNode(
            "/*[local-name()='MetaDataObject']/*[1]/*[local-name()='Properties']/*[local-name()='IncludeHelpInContents']")
        if ($null -eq $include -or ([string]$include.InnerText).Trim().ToLowerInvariant() -ne "true") {
            return $false
        }

        [xml]$descriptor = Get-Content -Raw -LiteralPath $descriptorPath -Encoding UTF8
        $pages = @($descriptor.SelectNodes("/*[local-name()='Help']/*[local-name()='Page']"))
        if (-not @($pages | Where-Object { ([string]$_.InnerText).Trim() -eq $Language }).Count) {
            return $false
        }
    }
    catch {
        return $false
    }

    $text = [string](Get-Content -Raw -LiteralPath $pagePath -Encoding UTF8)
    # Разметка без текста справкой не является: <html></html> открывается
    # пустым окном, и это ровно то же, что её отсутствие.
    $plain = ($text -replace "<[^>]+>", "").Trim()
    return ($plain.Length -gt 40)
}

function Find-WorkflowObjectsWithoutHelp {
    <#
    .SYNOPSIS
    Новые объекты, которые пользователь открывает, но справки по F1 у них нет.

    .DESCRIPTION
    Проверяется минимальный исполнимый контракт справки: объект включает её в
    состав, Help.xml объявляет язык, а непустая страница существует. Отличить
    полезный текст от пересказа полей комплект не может и не притворяется.

    Пустой файл справкой не считается. Пустая справка хуже отсутствующей: она
    обещает ответ и не даёт его, а по составу конфигурации выглядит как готовая.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [string[]]$Objects = @(),

        [string[]]$Languages = @("ru")
    )

    $missing = New-Object System.Collections.ArrayList

    foreach ($object in @($Objects | Where-Object { $_ })) {
        $parts = @(([string]$object).Replace([string][char]92, "/").Split("/"))
        if ($parts.Count -ne 2) {
            continue
        }

        $found = $false
        foreach ($language in @($Languages)) {
            if (Test-WorkflowObjectHelpRegistration `
                -SourcePath $SourcePath `
                -Object $object `
                -Language $language) {
                $found = $true
                break
            }
        }

        if (-not $found) {
            [void]$missing.Add(($parts -join "."))
        }
    }

    return @($missing)
}

function Find-WorkflowObjectsWithoutHelpInComponents {
    <#
    .SYNOPSIS
    Объекты без справки во всём составе проекта, включая расширения.

    .DESCRIPTION
    Паспорт пользовательской инструкции называет объект, а не компонент, в
    котором он поставляется. Поэтому страница считается найденной, если объект
    и содержательная справка есть хотя бы в одном включённом компоненте.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [string[]]$Objects = @(),

        [string[]]$Languages = @("ru")
    )

    $missing = New-Object System.Collections.ArrayList
    $components = @(Get-WorkflowComponentDirectories -Config $Config)

    foreach ($object in @($Objects | Where-Object { $_ })) {
        $parts = @(([string]$object).Replace([string][char]92, "/").Split("/"))
        if ($parts.Count -ne 2) {
            continue
        }

        $found = $false
        foreach ($component in $components) {
            $sourcePath = Resolve-WorkflowPath `
                -RepositoryRoot $RepositoryRoot `
                -Path ([string]$component.sourceDir)
            $metadataPath = Join-Path (Join-Path $sourcePath $parts[0]) "$($parts[1]).xml"
            $objectPath = Join-Path (Join-Path $sourcePath $parts[0]) $parts[1]
            if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf) -and
                -not (Test-Path -LiteralPath $objectPath -PathType Container)) {
                continue
            }

            if (@(Find-WorkflowObjectsWithoutHelp `
                -SourcePath $sourcePath `
                -Objects @($object) `
                -Languages $Languages).Count -eq 0) {
                $found = $true
                break
            }
        }

        if (-not $found) {
            [void]$missing.Add(($parts -join "."))
        }
    }

    return @($missing)
}

function Get-WorkflowNewUserHelpCoverage {
    <#
    .SYNOPSIS
    Покрытие встроенной справкой новых пользовательских объектов всех компонентов.

    .DESCRIPTION
    Основная конфигурация и включённые расширения равноправны: пользователь
    открывает их объекты в одном интерфейсе и ожидает F1 в каждом. Возвращает
    общее число новых поднадзорных объектов и список объектов без справки.
    Имя расширения добавляется к сообщению, чтобы одинаковые имена объектов в
    разных компонентах не скрывали источник ошибки.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [string[]]$AddedPaths = @(),

        [string[]]$Kinds = @(),

        [string[]]$Languages = @("ru")
    )

    $total = 0
    $missing = New-Object System.Collections.ArrayList

    foreach ($component in @(Get-WorkflowComponentDirectories -Config $Config)) {
        $objects = @(
            Get-WorkflowAddedMetadataObjects `
                -AddedPaths $AddedPaths `
                -SourceRelativePath ([string]$component.sourceDir) `
                -Kinds $Kinds
        )
        if ($objects.Count -eq 0) {
            continue
        }

        $total += $objects.Count
        $sourcePath = Resolve-WorkflowPath `
            -RepositoryRoot $RepositoryRoot `
            -Path ([string]$component.sourceDir)
        foreach ($object in @(Find-WorkflowObjectsWithoutHelp `
            -SourcePath $sourcePath `
            -Objects $objects `
            -Languages $Languages)) {
            $display = if ([bool]$component.isExtension) {
                "Extension.$($component.name):$object"
            }
            else {
                [string]$object
            }
            [void]$missing.Add($display)
        }
    }

    return [pscustomobject]@{
        Total = $total
        Missing = @($missing)
    }
}

function Get-WorkflowRouteSettings {
    <#
    .SYNOPSIS
    Пороги и виды, по которым правка относится к простому или сложному маршруту.
    #>
    param(
        $Config
    )

    $route = Get-WorkflowSettingValue -Object $Config -Name "route" -Default $null

    $structureKinds = @(Get-WorkflowSettingValue -Object $route -Name "structureKinds" -Default @())
    if ($structureKinds.Count -eq 0) {
        $structureKinds = @(
            "Catalogs", "Documents", "DocumentJournals", "InformationRegisters",
            "AccumulationRegisters", "AccountingRegisters", "CalculationRegisters",
            "ChartsOfCharacteristicTypes", "ChartsOfAccounts", "ChartsOfCalculationTypes",
            "ExchangePlans", "BusinessProcesses", "Tasks"
        )
    }

    $contractKinds = @(Get-WorkflowSettingValue -Object $route -Name "contractKinds" -Default @())
    if ($contractKinds.Count -eq 0) {
        $contractKinds = @("HTTPServices", "WebServices", "XDTOPackages", "WSReferences")
    }

    return [pscustomobject]@{
        Enabled = [bool](Get-WorkflowSettingValue -Object $route -Name "enabled" -Default $true)
        DecisionDir = [string](Get-WorkflowSettingValue -Object $route -Name "decisionDir" -Default "docs/decisions")
        ObjectThreshold = [int](Get-WorkflowSettingValue -Object $route -Name "objectThreshold" -Default 12)
        StructureKinds = @($structureKinds)
        ContractKinds = @($contractKinds)
    }
}

function Get-WorkflowChangeRoute {
    <#
    .SYNOPSIS
    Простой маршрут или сложный: нужен ли правке замысел до кода.

    .DESCRIPTION
    Ревью отвечает на вопрос «правильно ли это написано» и приходит, когда код уже
    есть. Вопрос «нужно ли это делать и где этому место» к тому времени решён, и
    замечание по нему означает переделку. Поэтому у правок, меняющих структуру
    данных или публичный контракт, точка решения стоит ДО кода.

    Признаки считаются по правке, а не по ощущению сложности: ощущение не
    воспроизводится и спорить с ним нечем.

      структура  — появился объект, хранящий данные, или изменился состав такого
                   объекта: реквизиты, измерения, ресурсы. Форма и модуль сюда не
                   относятся: они не меняют то, как данные лежат;
      контракт   — HTTP- и веб-сервисы, пакеты XDTO: у них есть внешний
                   потребитель, и совместимость ломается молча;
      права      — Rights.xml: кто и что увидит, решается не по ходу написания;
      фон        — новое регламентное задание: у него есть расписание, нагрузка и
                   параллельность, и это решения, а не детали реализации;
      объём      — затронуто больше объектов, чем порог. Большая правка сложна уже
                   тем, что её нельзя проверить целиком за один проход.

    Понижение маршрута возможно и делается явно, с причиной: правило, из которого
    нет выхода, обходят молча. Повышение свободно — осторожность не требует
    объяснений.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [string]$SourceRelativePath = "",

        [string[]]$ChangedPaths = @(),

        [string[]]$AddedPaths = @()
    )

    $settings = Get-WorkflowRouteSettings -Config $Config
    if (-not $SourceRelativePath) {
        $SourceRelativePath = [string]$Config.sourceDir
    }
    $source = ([string]$SourceRelativePath).Replace([string][char]92, "/").Trim("/")

    $reasons = New-Object System.Collections.ArrayList
    $touchedObjects = New-Object System.Collections.Generic.HashSet[string]

    foreach ($path in @($ChangedPaths | Where-Object { $_ })) {
        $normalized = ([string]$path).Replace([string][char]92, "/").Trim("/")
        if ($source -and -not $normalized.StartsWith("$source/")) {
            continue
        }
        $tail = if ($source) { $normalized.Substring($source.Length + 1) } else { $normalized }
        $parts = @($tail.Split("/"))
        if ($parts.Count -lt 2) {
            continue
        }
        $kind = $parts[0]
        $name = $parts[1] -replace "\.xml$", ""
        [void]$touchedObjects.Add("$kind/$name")

        # Состав объекта данных лежит в <Вид>/<Имя>.xml. Правка формы или модуля
        # идёт глубже по пути и структуру не меняет.
        if ($parts.Count -eq 2 -and $parts[1].EndsWith(".xml") -and
            @($settings.StructureKinds) -contains $kind) {
            [void]$reasons.Add("структура: изменён состав $kind.$name")
        }
        if (@($settings.ContractKinds) -contains $kind) {
            [void]$reasons.Add("контракт: $kind.$name")
        }
        if ($kind -eq "Roles" -and $normalized.EndsWith("Rights.xml")) {
            [void]$reasons.Add("права: $kind.$name")
        }
    }

    foreach ($path in @($AddedPaths | Where-Object { $_ })) {
        $normalized = ([string]$path).Replace([string][char]92, "/").Trim("/")
        if ($source -and -not $normalized.StartsWith("$source/")) {
            continue
        }
        $tail = if ($source) { $normalized.Substring($source.Length + 1) } else { $normalized }
        $parts = @($tail.Split("/"))
        if ($parts.Count -ne 2 -or -not $parts[1].EndsWith(".xml")) {
            continue
        }
        $kind = $parts[0]
        $name = $parts[1] -replace "\.xml$", ""
        if (@($settings.StructureKinds) -contains $kind) {
            [void]$reasons.Add("структура: новый объект данных $kind.$name")
        }
        if ($kind -eq "ScheduledJobs") {
            [void]$reasons.Add("фон: новое регламентное задание $name")
        }
    }

    if ($touchedObjects.Count -gt $settings.ObjectThreshold) {
        [void]$reasons.Add("объём: затронуто объектов $($touchedObjects.Count) при пороге $($settings.ObjectThreshold)")
    }

    $unique = @(@($reasons) | Sort-Object -Unique)

    return [pscustomobject]@{
        Route = if ($unique.Count -gt 0) { "сложный" } else { "простой" }
        Reasons = $unique
        TouchedObjects = $touchedObjects.Count
        Settings = $settings
    }
}

function Get-WorkflowRouteDecisionPath {
    <#
    .SYNOPSIS
    Где лежит записанный замысел этой задачи.

    .DESCRIPTION
    Файл именуется по ветке и живёт в репозитории, а не в локальном состоянии:
    замысел переживает ветку, читается людьми и попадает в MR вместе с правкой.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    $settings = Get-WorkflowRouteSettings -Config $Config
    $slug = ($BranchName -replace "[^A-Za-z0-9А-Яа-яЁё_-]+", "-").Trim("-")
    return (Join-Path (Join-Path $RepositoryRoot ($settings.DecisionDir -replace "/", [string][char]92)) "$slug.md")
}

function Get-WorkflowRouteDowngrade {
    <#
    .SYNOPSIS
    Явное понижение маршрута с причиной, если оно было.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    $path = Join-Path (Join-Path $StateDirectory "route") "downgrade.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $record = Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
    if ([string](Get-WorkflowSettingValue -Object $record -Name "branch" -Default "") -ne $BranchName) {
        return $null
    }
    if (-not [string](Get-WorkflowSettingValue -Object $record -Name "reason" -Default "")) {
        return $null
    }

    return $record
}

function Get-WorkflowDecisionOpenQuestions {
    <#
    .SYNOPSIS
    Вопросы автору, оставшиеся без ответа в замысле.

    .DESCRIPTION
    Черновик архитектора замыслом не является: решение принимает автор. Отличить
    одно от другого можно ровно по одному признаку — отвечены ли вопросы, которых
    из задачи и кода не видно.

    Без этого требование выродилось бы в штамп: сеанс сам сгенерировал текст, сам
    же его и засчитал. Формат вопроса — "- [ ] текст", ответ — что угодно вместо
    пустых скобок.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    $open = New-Object System.Collections.ArrayList
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ($line -match "^\s*[-*]\s*\[\s*\]\s*(.+)$") {
            [void]$open.Add($Matches[1].Trim())
        }
    }

    return @($open)
}

function Assert-WorkflowRouteDecision {
    <#
    .SYNOPSIS
    Проверяет, что у сложной правки записан замысел.

    .DESCRIPTION
    Проверяется наличие решения, а не его качество: комплект не может отличить
    продуманный замысел от переписанной задачи. Но отсутствие он отличает точно, а
    именно оно и означает, что архитектурный вопрос не задавали.

    Понижение маршрута снимает требование и печатается вслух вместе с причиной:
    решение «здесь это лишнее» законно, молчаливый пропуск — нет.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [Parameter(Mandatory = $true)]
        $RouteResult
    )

    if (-not $RouteResult.Settings.Enabled) {
        Write-Host "Классификация маршрута отключена манифестом (route.enabled = false)."
        return
    }

    if ($RouteResult.Route -eq "простой") {
        Write-Host "Маршрут простой: правка идёт внутри существующей структуры."
        return
    }

    Write-Host "Маршрут сложный:"
    foreach ($reason in @($RouteResult.Reasons)) {
        Write-Host "  $reason"
    }

    $downgrade = Get-WorkflowRouteDowngrade -StateDirectory $StateDirectory -BranchName $BranchName
    if ($null -ne $downgrade) {
        Write-Host ("Маршрут понижен решением автора: $([string]$downgrade.reason)")
        return
    }

    $decisionPath = Get-WorkflowRouteDecisionPath `
        -RepositoryRoot $RepositoryRoot `
        -Config $Config `
        -BranchName $BranchName
    if ((Test-Path -LiteralPath $decisionPath -PathType Leaf) -and
        ([string](Get-Content -Raw -LiteralPath $decisionPath -Encoding UTF8)).Trim().Length -gt 200) {

        # Черновик архитектора решением не является: вопросы, на которые не
        # ответил автор, означают, что решение ещё не принято. Иначе
        # сгенерированный текст засчитывал бы сам себя.
        $open = @(Get-WorkflowDecisionOpenQuestions -Path $decisionPath)
        if ($open.Count -gt 0) {
            throw ("Замысел черновой: без ответа $($open.Count) вопрос(ов) автору в " +
                "$decisionPath — например «$($open[0])». Решение принимает автор, а не сеанс, " +
                "который его предложил: ответь в файле, отметив ответ вместо [ ].")
        }

        Write-Host "Замысел записан: $decisionPath"
        return
    }

    throw ("Сложный маршрут требует записанного замысла, а его нет: $decisionPath. " +
        "Опиши, что решено и почему отвергнуты соседние варианты, — это вопрос " +
        "«нужно ли это делать и где этому место», и после написания кода он стоит " +
        "переделки. Если здесь он избыточен, понизь маршрут с причиной: " +
        "Invoke-TaskWorkflow.ps1 -Phase Verify -RouteDowngrade ""<причина>"".")
}

function Get-WorkflowAdoptionStatus {
    <#
    .SYNOPSIS
    Картина внедрения процесса: что уже работает, а что только установлено.

    .DESCRIPTION
    Это ОТЧЁТ, а не проверка, и разница принципиальная. Внедрение по построению
    постепенное: проверки включают по одной, каждую с задачей, на которой она
    что-то поймала. Отказ на неполном внедрении ронял бы gate у всех, кто идёт
    этим путём честно, — такую проверку отключают в первый же день, и она
    перестаёт значить что-либо.

    Отчёт отвечает на вопрос, который иначе принимают на веру. Сколько файлов
    лежит в репозитории, видно и так; проходила ли хоть одна задача полный цикл —
    нет. Именно это отличает внедрённый процесс от установленного.

    Чего отчёт не доказывает: включённый набор проверок может быть пустым, а
    пройденная фаза подтверждать меньше, чем кажется. Он показывает состояние,
    а не качество.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        $Config,

        $TaskState = $null
    )

    $items = New-Object System.Collections.ArrayList

    function Add-AdoptionItem {
        param([string]$Name, [bool]$Done, [string]$Detail, [string]$State = "")

        $value = if ($State) { $State } elseif ($Done) { "да" } else { "нет" }
        [void]$items.Add([pscustomobject]@{ Name = $Name; State = $value; Detail = $Detail })
    }

    # Поставка и настройки разделены — переустановка не сбросит настройки проекта.
    $defaultsPath = Join-Path $RepositoryRoot ".1c-workflow.defaults.json"
    if (Test-Path -LiteralPath $defaultsPath -PathType Leaf) {
        Add-AdoptionItem -Name "настройки отделены от поставки" -Done $true -Detail "два файла, как положено"
    }
    else {
        Add-AdoptionItem -Name "настройки отделены от поставки" -Done $false `
            -Detail "один манифест: переустановка сбросит настройки проекта"
    }

    # Три значения, которые нейтральный комплект задать не может.
    $overlayRoot = Join-Path $RepositoryRoot "docs\rules\project"
    $filled = 0
    foreach ($name in @("change-markers.md", "locks.md", "logging.md")) {
        $path = Join-Path $overlayRoot $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        $text = [string](Get-Content -Raw -LiteralPath $path -Encoding UTF8)
        # Заготовка отличается от уточнения длиной: пустой файл с заголовком —
        # это «место есть», а не «значение задано».
        if ($text.Trim().Length -gt 400) {
            $filled = $filled + 1
        }
    }
    $overlayState = switch ($filled) {
        3 { "да" }
        0 { "нет" }
        default { "частично" }
    }
    Add-AdoptionItem -Name "уточнения правил проекта" -Done ($filled -eq 3) -State $overlayState `
        -Detail "заполнено $filled из 3: префикс объектов, порядок блокировок, состав ПДн"

    # Выключенный набор — не ошибка, но и не проверка.
    foreach ($suite in @(
        @{ Name = "функциональный контур"; Key = "functionalTests" },
        @{ Name = "Web UI регрессия"; Key = "webUiTests" },
        @{ Name = "политика актуализации тестов"; Key = "testMaintenance" },
        @{ Name = "независимое ревью"; Key = "review" }
    )) {
        $section = Get-WorkflowSettingValue -Object $Config -Name $suite.Key -Default $null
        $enabled = [bool](Get-WorkflowSettingValue -Object $section -Name "enabled" -Default $false)
        $detail = if ($enabled) { "включено" } else { "выключено: фазы этот набор не проверяют" }
        Add-AdoptionItem -Name $suite.Name -Done $enabled -Detail $detail
    }

    # Главный признак. Всё остальное — файлы, которые можно положить и не
    # пользоваться ими ни разу.
    $phase = [string](Get-WorkflowSettingValue -Object $TaskState -Name "phase" -Default "")
    $passed = @("verified", "released") -contains $phase
    $detail = if ($passed) {
        "состояние задачи: $phase"
    }
    elseif ($phase) {
        "состояние задачи: $phase — цикл не доведён до Verify"
    }
    else {
        "задача не начиналась"
    }
    Add-AdoptionItem -Name "задача прошла цикл целиком" -Done $passed -Detail $detail

    return [pscustomobject]@{
        Items = @($items)
        Done = @($items | Where-Object { $_.State -eq "да" }).Count
        Total = @($items).Count
        CyclePassed = $passed
    }
}

function Get-WorkflowCritiqueBlockingSeverities {
    <#
    .SYNOPSIS
    Серьёзности замечаний, которые требуют нового круга ревью.

    .DESCRIPTION
    Шлифовать можно бесконечно, и ревьюер, которому нечего сказать по существу,
    всегда найдёт, что сказать по вкусу. Круг назначают только замечания, из-за
    которых правку нельзя выпускать: blocker и major. Замечание вкуса (minor)
    записывается и печатается, но цикл не продлевает.

    Порог настраивается: проекту, который хочет доводить до блеска, достаточно
    добавить minor в review.blockingSeverities.
    #>
    param(
        $ReviewConfig
    )

    $configured = @(Get-WorkflowSettingValue -Object $ReviewConfig -Name "blockingSeverities" -Default @())
    if ($configured.Count -gt 0) {
        return @($configured | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }

    return @("blocker", "major")
}

function Select-WorkflowBlockingFindings {
    <#
    .SYNOPSIS
    Замечания, которые не дают выпускать правку.

    .DESCRIPTION
    Замечание без серьёзности считается блокирующим. Умолчание в пользу строгости
    намеренно: ревьюер, забывший поле, иначе понижал бы собственное замечание до
    вкусового — и цикл заканчивался бы тем, что проверку просто не заметили.
    #>
    param(
        [object[]]$Findings = @(),

        [string[]]$BlockingSeverities = @("blocker", "major")
    )

    $blocking = New-Object System.Collections.ArrayList
    foreach ($finding in @($Findings)) {
        $severity = ([string](Get-WorkflowSettingValue -Object $finding -Name "severity" -Default "")).ToLowerInvariant()
        if (-not $severity) {
            [void]$blocking.Add($finding)
            continue
        }
        if (@($BlockingSeverities) -contains $severity) {
            [void]$blocking.Add($finding)
        }
    }

    return @($blocking)
}

function Get-WorkflowCritiqueRounds {
    <#
    .SYNOPSIS
    Сколько кругов ревью уже сделано в этой задаче и сколько их разрешено.

    .DESCRIPTION
    Счёт ведётся по ЗАДАЧЕ, а не по содержимому. По содержимому он сбрасывался бы
    каждой правкой — то есть никогда не срабатывал бы: исправил замечание,
    отпечаток другой, счётчик обнулён, шлифовка продолжается вечно.

    Файл счётчика лежит рядом с пакетом и обнуляется фазой Start: новая задача —
    новые круги.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        $ReviewConfig
    )

    $limit = [int](Get-WorkflowSettingValue -Object $ReviewConfig -Name "maxRounds" -Default 3)
    if ($limit -lt 1) {
        $limit = 1
    }

    # Счётчик лежит НАД каталогом отпечатка: у каждого содержимого свой каталог,
    # и счёт внутри него обнулялся бы каждой правкой — предел не срабатывал бы
    # никогда, а заводится он ровно от бесконечной шлифовки.
    $statePath = Join-Path (Join-Path $StateDirectory "critique") "rounds.json"
    $done = 0
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $state = Get-Content -Raw -LiteralPath $statePath -Encoding UTF8 | ConvertFrom-Json
            $done = [int](Get-WorkflowSettingValue -Object $state -Name "rounds" -Default 0)
        }
        catch {
            $done = 0
        }
    }

    return [pscustomobject]@{
        Done = $done
        Limit = $limit
        StatePath = $statePath
        Exhausted = $done -ge $limit
    }
}

function Step-WorkflowCritiqueRound {
    <#
    .SYNOPSIS
    Отмечает очередной круг ревью.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory
    )

    $rounds = Get-WorkflowCritiqueRounds -StateDirectory $StateDirectory -ReviewConfig $null
    $next = $rounds.Done + 1
    [System.IO.Directory]::CreateDirectory((Split-Path $rounds.StatePath -Parent)) | Out-Null
    Set-Content `
        -LiteralPath $rounds.StatePath `
        -Value (ConvertTo-Json -InputObject ([pscustomobject]@{
            rounds = $next
            updatedAt = (Get-Date).ToString("o")
        }) -Depth 3) `
        -Encoding UTF8

    return $next
}

function Reset-WorkflowCritiqueRounds {
    <#
    .SYNOPSIS
    Обнуляет счёт кругов: началась новая задача.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory
    )

    $statePath = (Get-WorkflowCritiqueRounds -StateDirectory $StateDirectory -ReviewConfig $null).StatePath
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        Remove-Item -LiteralPath $statePath -Force
    }
}

function Get-WorkflowCritiqueDirectory {
    <#
    .SYNOPSIS
    Каталог артефактов ревью для конкретного содержимого рабочей копии.

    .DESCRIPTION
    Отчёт привязан к ОТПЕЧАТКУ, а не к ветке и не к коммиту. Правка кода делает
    прежний отчёт недействительным сама: ревью, прочитавшее другой текст, ничего
    не говорит о нынешнем. Тот же отпечаток — тот же ответ, и повторно платить за
    него не нужно.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Fingerprint
    )

    return (Join-Path (Join-Path $StateDirectory "critique") $Fingerprint)
}

function Get-WorkflowCritiqueFindingKey {
    <#
    .SYNOPSIS
    Устойчивый ключ замечания: пункт чек-листа, файл и суть.

    .DESCRIPTION
    Ключ нужен отклонениям. Если бы он зависел от отпечатка всей копии, любая
    правка в соседнем файле обнуляла бы разобранные отклонения, и автор
    переписывал бы одни и те же причины — церемония, которую перестают читать
    на третий раз.

    В ключ не входит номер строки: сдвиг кода не делает замечание другим.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Finding
    )

    $parts = @(
        ([string]$Finding.checklistItem).Trim().ToLowerInvariant(),
        ([string]$Finding.file).Replace([char]92, [char]47).Trim().ToLowerInvariant(),
        ([string]$Finding.title).Trim().ToLowerInvariant()
    )
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($parts -join "|"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant().Substring(0, 16)
}

function Test-WorkflowCritiqueReport {
    <#
    .SYNOPSIS
    Разбирает отчёт ревью и отказывает, если он не о том содержимом.

    .DESCRIPTION
    Проверяется форма, а не добросовестность: комплект не может убедиться, что
    ревьюер был независим и что он вообще читал код. Он убеждается, что отчёт
    существует, относится к нынешнему содержимому и что каждое замечание показано
    на файле — замечание без файла нельзя ни проверить, ни исправить.

    Пустой список замечаний — законный ответ, и отличать его от «ревью не было»
    обязан отпечаток, а не догадка.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Fingerprint,

        # Разовый токен пакета. Пусто — проверка не выполняется: так читают отчёт
        # там, где пакета уже нет, например на Verify.
        [string]$Token = "",

        # Требовать замечание по учебному примеру.
        [switch]$RequireProbe
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Отчёт ревью не найден: $Path"
    }

    try {
        $report = Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Отчёт ревью не разбирается как JSON: $Path. $($_.Exception.Message)"
    }

    $reported = [string](Get-WorkflowSettingValue -Object $report -Name "fingerprint" -Default "")
    if ($reported -ne $Fingerprint) {
        throw ("Отчёт ревью относится к другому содержимому: в отчёте '$reported', " +
            "сейчас '$Fingerprint'. Ревью читало другой текст, и о нынешнем оно не говорит.")
    }

    if ($Token) {
        $reportedToken = [string](Get-WorkflowSettingValue -Object $report -Name "packetToken" -Default "")
        if ($reportedToken -ne $Token) {
            throw ("Отчёт не возвращает токен пакета: ожидался '$Token', в отчёте '$reportedToken'. " +
                "Токен разовый и лежит только в пакете — значит, пакет до ревьюера не дошёл.")
        }
    }

    $probe = Get-WorkflowCritiqueProbe -Fingerprint $Fingerprint
    $probeSeen = $false

    $findings = New-Object System.Collections.ArrayList
    foreach ($finding in @(Get-WorkflowSettingValue -Object $report -Name "findings" -Default @())) {
        $file = [string](Get-WorkflowSettingValue -Object $finding -Name "file" -Default "")
        $title = [string](Get-WorkflowSettingValue -Object $finding -Name "title" -Default "")
        if (-not $file -or -not $title) {
            throw ("Замечание без файла или без сути: $(ConvertTo-Json -InputObject $finding -Depth 3 -Compress). " +
                "Такое замечание нельзя ни проверить, ни исправить.")
        }
        if ($file.Replace([char]92, [char]47).Trim([char]47) -eq $probe.Path) {
            # Замечание по учебному примеру — это ответ комплекту, а не работа
            # автору: примера в репозитории нет, исправлять в нём нечего.
            $probeSeen = $true
            continue
        }

        [void]$findings.Add([pscustomobject]@{
            Key = (Get-WorkflowCritiqueFindingKey -Finding $finding)
            ChecklistItem = [string](Get-WorkflowSettingValue -Object $finding -Name "checklistItem" -Default "")
            File = $file.Replace([char]92, [char]47)
            Line = [string](Get-WorkflowSettingValue -Object $finding -Name "line" -Default "")
            Title = $title
            Detail = [string](Get-WorkflowSettingValue -Object $finding -Name "detail" -Default "")
        })
    }

    if ($RequireProbe -and -not $probeSeen) {
        throw ("Ревьюер не назвал учебный пример ($($probe.Path): $($probe.Name)). " +
            "Пример грубый и лежит прямо в пакете: пропустивший его пропустит и настоящее " +
            "замечание, поэтому ревью не засчитано. Пустой отчёт так отличается от ответа, " +
            "данного не глядя.")
    }

    return [pscustomobject]@{
        Fingerprint = $Fingerprint
        Reviewer = [string](Get-WorkflowSettingValue -Object $report -Name "reviewer" -Default "")
        Findings = @($findings)
        ProbeSeen = $probeSeen
        Path = [System.IO.Path]::GetFullPath($Path)
    }
}

function Resolve-WorkflowCritiqueFindings {
    <#
    .SYNOPSIS
    Делит замечания на снятые отклонением и оставшиеся без ответа.

    .DESCRIPTION
    Отклонение живёт, пока не изменился файл, к которому оно относится. Вечное
    отклонение превратило бы журнал в список «когда-то посмотрели», а отклонение
    на один прогон заставляло бы переписывать причины после каждой правки.

    Причина обязательна и хранится текстом: «отклонено» без причины — это
    «пропущено», только выглядит как решение.
    #>
    param(
        [object[]]$Findings = @(),

        [object]$Dismissals = $null,

        [object]$FileHashes = $null
    )

    $open = New-Object System.Collections.ArrayList
    $dismissed = New-Object System.Collections.ArrayList
    $expired = New-Object System.Collections.ArrayList

    foreach ($finding in @($Findings)) {

        $record = $null
        if ($null -ne $Dismissals -and $Dismissals.ContainsKey($finding.Key)) {
            $record = $Dismissals[$finding.Key]
        }

        if ($null -eq $record) {
            [void]$open.Add($finding)
            continue
        }

        $reason = [string](Get-WorkflowSettingValue -Object $record -Name "reason" -Default "")
        if (-not $reason) {
            [void]$open.Add($finding)
            continue
        }

        $recordedHash = [string](Get-WorkflowSettingValue -Object $record -Name "fileHash" -Default "")
        $currentHash = ""
        if ($null -ne $FileHashes -and $FileHashes.ContainsKey($finding.File)) {
            $currentHash = [string]$FileHashes[$finding.File]
        }

        if ($recordedHash -and $currentHash -and $recordedHash -ne $currentHash) {
            [void]$expired.Add($finding)
            [void]$open.Add($finding)
            continue
        }

        [void]$dismissed.Add([pscustomobject]@{
            Finding = $finding
            Reason = $reason
        })
    }

    return [pscustomobject]@{
        Open = @($open)
        Dismissed = @($dismissed)
        Expired = @($expired)
    }
}

function Get-WorkflowCritiqueDismissals {
    <#
    .SYNOPSIS
    Журнал отклонений ветки: ключ замечания → причина и отпечаток файла.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $result = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $result
    }

    try {
        $parsed = Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Журнал отклонений не разбирается как JSON: $Path. $($_.Exception.Message)"
    }

    foreach ($property in @($parsed.PSObject.Properties)) {
        $result[[string]$property.Name] = $property.Value
    }

    return $result
}

function Get-WorkflowCritiqueDiffLimit {
    <#
    .SYNOPSIS
    Сколько строк диффа попадает в пакет ревью.

    .DESCRIPTION
    Предел нужен не ради денег, а ради внимания: правка на десять тысяч строк,
    отданная целиком, читается ревьюером по диагонали, и ответ получается
    вежливым и бесполезным. Обрезка называется в пакете прямо, чтобы ревьюер знал,
    что видел не всё, и сказал об этом.
    #>
    param()

    return 6000
}

function New-WorkflowCritiquePacket {
    <#
    .SYNOPSIS
    Собирает пакет для независимого ревьюера: правка, чек-лист, форма ответа.

    .DESCRIPTION
    В пакет НЕ входят объяснения автора — ни описание ветки, ни сообщения
    коммитов. Ревьюер, прочитавший «зачем так сделано», начинает проверять
    согласованность объяснения с кодом вместо вопроса «нужно ли это вообще»,
    а именно этот вопрос и пропускают тесты с гейтом.

    Комментарии в самом коде убрать нельзя, и пакет прямо предупреждает: они
    объясняют замысел, но не доказывают необходимость.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$BaseRef,

        [Parameter(Mandatory = $true)]
        [string]$Fingerprint,

        [Parameter(Mandatory = $true)]
        [string]$ReportPath,

        [Parameter(Mandatory = $true)]
        [string]$PacketPath,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [string]$ChecklistPath = ""
    )

    $changed = @(Get-WorkflowChangedPaths -RepositoryRoot $RepositoryRoot -BaseRef $BaseRef)
    $neutral = @(Get-WorkflowPlatformNeutralPatterns)
    $meaningful = @(
        $changed | Where-Object {
            $path = ([string]$_).Replace([char]92, [char]47)
            @($neutral | Where-Object { $path -match $_ }).Count -eq 0
        }
    )

    if ($meaningful.Count -eq 0) {
        return [pscustomobject]@{
            Empty = $true
            Path = $PacketPath
            FileCount = 0
            DiffLines = 0
            Truncated = $false
        }
    }

    # Дифф берётся ДВУХТОЧЕЧНЫЙ: он включает и коммиты ветки, и незакоммиченное
    # рабочее дерево. Ревью на фазе идёт по тому же тексту, который проверяют
    # остальные фазы, иначе ревьюер отвечал бы про вчерашнюю правку.
    $diff = @((Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("-c", "core.quotePath=false", "diff", $BaseRef)).Output)

    $truncated = $false
    $limit = Get-WorkflowCritiqueDiffLimit
    if ($diff.Count -gt $limit) {
        $diff = @($diff[0..($limit - 1)])
        $truncated = $true
    }

    if (-not $ChecklistPath) {
        $ChecklistPath = Join-Path $RepositoryRoot "docs\review-checklist.md"
    }
    $checklist = ""
    if (Test-Path -LiteralPath $ChecklistPath -PathType Leaf) {
        $checklist = Get-Content -Raw -LiteralPath $ChecklistPath -Encoding UTF8
    }
    $projectChecklistPath = Join-Path $RepositoryRoot "docs\review-checklist.project.md"
    if (Test-Path -LiteralPath $projectChecklistPath -PathType Leaf) {
        $checklist = $checklist + [System.Environment]::NewLine +
            (Get-Content -Raw -LiteralPath $projectChecklistPath -Encoding UTF8)
    }

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# Пакет независимого ревью")
    [void]$lines.Add("")
    [void]$lines.Add("Ты НЕ автор этой правки, и твоя задача — найти лишнее, а не одобрить сделанное.")
    [void]$lines.Add("")
    [void]$lines.Add("Комментарии в коде объясняют замысел автора и НЕ доказывают необходимость.")
    [void]$lines.Add("Ровно так прошли мимо проверок курсор в константе вместо запроса и чтение")
    [void]$lines.Add("набора записей по каждой задаче: оба были подробно откомментированы.")
    [void]$lines.Add("")
    [void]$lines.Add("В пакете есть УЧЕБНЫЙ ПРИМЕР — отдельный файл $((Get-WorkflowCritiqueProbe -Fingerprint $Fingerprint).Path).")
    [void]$lines.Add("Он не из репозитория и содержит случай из чек-листа. Назови его наравне с")
    [void]$lines.Add("остальными: по нему комплект отличает ответ «замечаний нет» от ответа,")
    [void]$lines.Add("данного не глядя.")
    [void]$lines.Add("")
    [void]$lines.Add("Замечание принимается, только если его видно на файле и строке. Стиль,")
    [void]$lines.Add("переименования и «можно вынести в функцию» — не предмет этого ревью.")
    [void]$lines.Add("Пустой список замечаний — законный ответ.")
    [void]$lines.Add("")
    [void]$lines.Add("## Чек-лист")
    [void]$lines.Add("")
    [void]$lines.Add($checklist)
    [void]$lines.Add("")
    $probe = Get-WorkflowCritiqueProbe -Fingerprint $Fingerprint
    [void]$lines.Add("## Учебный пример: $($probe.Path)")
    [void]$lines.Add("")
    [void]$lines.Add('```bsl')
    foreach ($line in @($probe.Code)) {
        [void]$lines.Add([string]$line)
    }
    [void]$lines.Add('```')
    [void]$lines.Add("")
    [void]$lines.Add("## Правка")
    [void]$lines.Add("")
    [void]$lines.Add("База сравнения: $BaseRef. Файлов: $($meaningful.Count).")
    if ($truncated) {
        [void]$lines.Add("")
        [void]$lines.Add("ВНИМАНИЕ: дифф обрезан до $limit строк. Скажи об этом в отчёте, если")
        [void]$lines.Add("судить по обрезанному тексту нельзя.")
    }
    [void]$lines.Add("")
    [void]$lines.Add('```diff')
    foreach ($line in $diff) {
        [void]$lines.Add([string]$line)
    }
    [void]$lines.Add('```')
    [void]$lines.Add("")
    [void]$lines.Add("## Ответ")
    [void]$lines.Add("")
    [void]$lines.Add("Запиши JSON в файл (UTF-8, без BOM):")
    [void]$lines.Add("")
    [void]$lines.Add("    $ReportPath")
    [void]$lines.Add("")
    [void]$lines.Add('```json')
    [void]$lines.Add('{')
    [void]$lines.Add('  "fingerprint": "' + $Fingerprint + '",')
    [void]$lines.Add('  "packetToken": "' + $Token + '",')
    [void]$lines.Add('  "reviewer": "<чем выполнено ревью>",')
    [void]$lines.Add('  "findings": [')
    [void]$lines.Add('    {')
    [void]$lines.Add('      "checklistItem": "<идентификатор пункта чек-листа>",')
    [void]$lines.Add('      "file": "<путь от корня репозитория>",')
    [void]$lines.Add('      "line": 0,')
    [void]$lines.Add('      "severity": "blocker | major | minor",')
    [void]$lines.Add('      "title": "<суть одной строкой>",')
    [void]$lines.Add('      "detail": "<что именно лишнее и чем заменить>"')
    [void]$lines.Add('    }')
    [void]$lines.Add('  ]')
    [void]$lines.Add('}')
    [void]$lines.Add('```')
    [void]$lines.Add("")
    [void]$lines.Add("Серьёзность ставь по вреду, а не по усилию на исправление:")
    [void]$lines.Add("blocker — правку нельзя выпускать (дефект, потеря данных, сломанный")
    [void]$lines.Add("контракт); major — выпускать можно, но это придётся переделывать;")
    [void]$lines.Add("minor — вкус и шлифовка. Круг ревью назначают только blocker и major:")
    [void]$lines.Add("шлифовать можно бесконечно, и цикл на этом не заканчивался бы никогда.")
    [void]$lines.Add("Замечание без severity считается блокирующим.")
    [void]$lines.Add("")
    [void]$lines.Add("Поля fingerprint и packetToken скопируй как есть. По первому комплект")
    [void]$lines.Add("понимает, что отчёт относится к этому тексту, а не к прошлому; по второму —")
    [void]$lines.Add("что пакет дошёл до тебя, а не был угадан по формуле.")

    [System.IO.Directory]::CreateDirectory((Split-Path $PacketPath -Parent)) | Out-Null
    Set-Content -LiteralPath $PacketPath -Value ($lines -join [System.Environment]::NewLine) -Encoding UTF8

    return [pscustomobject]@{
        Empty = $false
        Path = [System.IO.Path]::GetFullPath($PacketPath)
        FileCount = $meaningful.Count
        DiffLines = $diff.Count
        Truncated = $truncated
    }
}

function Assert-WorkflowCritiqueResolved {
    <#
    .SYNOPSIS
    Проверяет, что ревью выполнено для НЫНЕШНЕГО содержимого и замечания закрыты.

    .DESCRIPTION
    Отдельная фаза, которую никто не проверяет, — это предложение, а не этап:
    пропустить её стоит ровно ничего. Поэтому работа делается фазой Critique, а
    наличие её результата проверяется здесь, на последнем рубеже перед MR.

    Отпечаток делает проверку честной: исправил замечание — содержимое другое,
    прежний отчёт к нему не относится, ревью переспросит.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Fingerprint
    )

    $reviewConfig = Get-WorkflowSettingValue -Object $Config -Name "review" -Default $null
    if (-not [bool](Get-WorkflowSettingValue -Object $reviewConfig -Name "enabled" -Default $false)) {
        Write-Host "Ревью отключено манифестом (review.enabled = false) — отчёт не требуется."
        return
    }

    $critiqueDirectory = Get-WorkflowCritiqueDirectory -StateDirectory $StateDirectory -Fingerprint $Fingerprint
    $reportPath = Join-Path $critiqueDirectory "report.json"

    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        throw ("Ревью для этого содержимого не выполнено: отчёта нет ($reportPath). " +
            "Запусти Invoke-TaskWorkflow.ps1 -Phase Critique.")
    }

    $report = Test-WorkflowCritiqueReport -Path $reportPath -Fingerprint $Fingerprint
    $dismissals = Get-WorkflowCritiqueDismissals `
        -Path (Join-Path (Join-Path $StateDirectory "critique") "dismissals.json")

    $fileHashes = @{}
    foreach ($finding in @($report.Findings)) {
        if ($fileHashes.ContainsKey($finding.File)) {
            continue
        }
        $fileHashes[$finding.File] = [string]((Invoke-WorkflowGit `
            -RepositoryRoot $RepositoryRoot `
            -Arguments @("hash-object", "--", $finding.File) `
            -AllowFailure).Output | Select-Object -First 1)
    }

    $resolution = Resolve-WorkflowCritiqueFindings `
        -Findings @($report.Findings) `
        -Dismissals $dismissals `
        -FileHashes $fileHashes

    # Выпуск держат только те замечания, из-за которых правку нельзя выпускать.
    # Замечание вкуса записано, названо и не мешает: иначе шлифовка стала бы
    # условием выпуска, а закончить её нельзя по определению.
    $blockingSeverities = @(Get-WorkflowCritiqueBlockingSeverities -ReviewConfig $reviewConfig)
    $blocking = @(Select-WorkflowBlockingFindings `
        -Findings @($resolution.Open) `
        -BlockingSeverities $blockingSeverities)

    if ($blocking.Count -gt 0) {
        $titles = @($blocking | ForEach-Object { "$($_.Key) $($_.Title)" })
        throw ("Открытые блокирующие замечания ревью: $($titles -join ' | '). Исправь код либо " +
            "отклони с причиной: Invoke-CodeCritique.ps1 -Dismiss ""<ключ>=<причина>"".")
    }

    Write-Host ("Ревью: замечаний $(@($report.Findings).Count), отклонено с причиной " +
        "$(@($resolution.Dismissed).Count), вкусовых без ответа $(@($resolution.Open).Count). " +
        "Блокирующих нет.")
    foreach ($item in @($resolution.Dismissed)) {
        Write-Host "  [отклонено] $($item.Finding.Title) — $($item.Reason)"
    }
}

function Get-WorkflowFingerprintEntries {
    <#
    .SYNOPSIS
    Отпечаток СОДЕРЖИМОГО рабочей копии: пары «путь — хеш файла».

    .DESCRIPTION
    Прежняя версия хешировала номер коммита и строки `git status`, то есть ИМЕНА,
    а не содержимое. Коммит без единой правки менял отпечаток: HEAD стал другим, а
    список изменённых файлов опустел. Selfcheck идёт по рабочему дереву, коммит
    делается сразу после него — и зачёт срывался в самом обычном ходе работы,
    заставляя повторить полный прогон над теми же файлами.

    Берутся хеши из индекса, поверх них — хеши изменённых и неотслеживаемых файлов
    рабочего дерева, удалённые выбрасываются. После коммита ровно тех же правок
    набор пар тот же, и отпечаток совпадает.

    -Paths сужает область до перечисленных префиксов, -ExcludePaths выбрасывает
    из неё. Это нужно кэшам собранных баз: стенд зависит от конфигурации,
    расширений и подготовки данных, но не от сценариев Web UI, и правка сценария
    не обязана стоить пересборки стенда.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [string[]]$Paths = @(),

        [string[]]$ExcludePaths = @(),

        # Исключения регулярными выражениями: список «что не влияет на платформу»
        # задан именно так, и переписывать его в префиксы значило бы завести его
        # вторую копию — ровно ту ошибку, из-за которой кэш и обесценивался зря.
        [string[]]$ExcludePatterns = @()
    )

    $prefixes = @(
        $Paths |
            Where-Object { $_ } |
            ForEach-Object { ([string]$_).Replace([char]92, [char]47).Trim([char]47) }
    )
    $exclusions = @(
        $ExcludePaths |
            Where-Object { $_ } |
            ForEach-Object { ([string]$_).Replace([char]92, [char]47).Trim([char]47) }
    )
    $entries = New-Object "System.Collections.Generic.Dictionary[string,string]"

    # Индекс отдаёт хеши, не читая файлы: на конфигурации в тысячи XML это
    # единственный способ уложиться в доли секунды.
    foreach ($line in @((Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("-c", "core.quotePath=false", "ls-files", "-s")).Output)) {
        $value = [string]$line
        # Формат: "<права> <хеш> <стадия><TAB><путь>"
        $tab = $value.IndexOf([char]9)
        if ($tab -lt 0) {
            continue
        }
        $path = $value.Substring($tab + 1).Trim().Replace([char]92, [char]47)
        $parts = $value.Substring(0, $tab).Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
        if ($parts.Count -lt 2 -or -not (Test-WorkflowPathInScope `
            -Path $path -Prefixes $prefixes -Exclusions $exclusions -ExcludePatterns $ExcludePatterns)) {
            continue
        }
        $entries[$path] = $parts[1]
    }

    # Рабочее дерево сильнее индекса: правка, которую ещё не проиндексировали,
    # обязана менять отпечаток, иначе Selfcheck подтверждал бы вчерашний текст.
    foreach ($line in @((Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @(
            "-c", "core.quotePath=false",
            "status", "--porcelain=v1", "--untracked-files=all")).Output)) {
        $parsed = ConvertFrom-WorkflowGitStatusLine -Line ([string]$line)
        $state = $parsed.State
        $path = $parsed.Path
        if (-not $path) {
            continue
        }
        if (-not (Test-WorkflowPathInScope `
            -Path $path -Prefixes $prefixes -Exclusions $exclusions -ExcludePatterns $ExcludePatterns)) {
            continue
        }
        if ($state.Contains("D") -or -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $path) -PathType Leaf)) {
            [void]$entries.Remove($path)
            continue
        }
        $hash = [string](
            (Invoke-WorkflowGit `
                -RepositoryRoot $RepositoryRoot `
                -Arguments @("hash-object", "--", $path)).Output |
                Select-Object -First 1
        )
        if ($hash) {
            $entries[$path] = $hash
        }
    }

    return $entries
}

function Get-WorkflowFingerprint {
    <#
    .SYNOPSIS
    Отпечаток содержимого рабочей копии одной строкой.

    .DESCRIPTION
    Считается ровно по тем парам «путь — хеш», которые отдаёт
    Get-WorkflowFingerprintEntries: разойтись им негде, источник один.

    Пары нужны отдельно, чтобы на промахе кэша было чем ответить на вопрос
    «почему опять пересборка». Без ответа он задаётся человеку — и задавался
    трижды подряд, пока не выяснилось, что базу обесценивал скрипт гейта,
    который в базу не попадает вовсе.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [string[]]$Paths = @(),

        [string[]]$ExcludePaths = @(),

        [string[]]$ExcludePatterns = @()
    )

    $entries = Get-WorkflowFingerprintEntries `
        -RepositoryRoot $RepositoryRoot `
        -Paths $Paths `
        -ExcludePaths $ExcludePaths `
        -ExcludePatterns $ExcludePatterns

    return (Get-WorkflowFingerprintFromEntries -Entries $entries)
}

function Get-WorkflowFingerprintFromEntries {
    <#
    .SYNOPSIS
    Свёртка пар «путь — хеш» в одну строку отпечатка.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entries
    )

    $payload = @(
        @($Entries.Keys) |
            Sort-Object -CaseSensitive |
            ForEach-Object { "$_ $($Entries[$_])" }
    )
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($payload -join "`n"))
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
}

function Test-WorkflowBranchGoneOnServer {
    <#
    .SYNOPSIS
    Ветку отправляли, а на сервере её больше нет: MR смержен и ветка удалена.

    .DESCRIPTION
    Пуш в такую ветку СОЗДАЁТ её заново и не открывает ничего: MR закрыт, и
    коммит остаётся лежать в стороне от main. Со стороны это выглядит как
    успешная отправка — git печатает «new branch», а не отказ.

    Именно так потерялся запускающий файл сборки: MR смержили, ветку сервер
    удалил, а следующий коммит уехал в неё. Обнаружилось это тем, что файла не
    оказалось после git pull.

    Признак точный и виден ДО пуша: ветка отслеживает origin/<имя>, которой на
    сервере нет. Ни API, ни хуков для этого не нужно — а хук и не поставить, у
    репозитория с Git LFS pre-push занят.

    Отсутствие связи с сервером ответом не считается: неизвестность возвращает
    $false, потому что мешать работе в самолёте хуже, чем пропустить проверку.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [Parameter(Mandatory = $true)]
        [string]$MainBranch,

        [string]$Remote = "origin"
    )

    if (-not $BranchName -or $BranchName -eq $MainBranch) {
        return $false
    }

    $tracked = (Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("config", "--get", "branch.$BranchName.merge") `
        -AllowFailure).ExitCode -eq 0
    if (-not $tracked) {
        return $false
    }

    $probe = Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("ls-remote", "--heads", $Remote, "refs/heads/$BranchName") `
        -AllowFailure

    if ($probe.ExitCode -ne 0) {
        return $false
    }

    return (@($probe.Output | Where-Object { $_ }).Count -eq 0)
}

function Test-WorkflowBranchAlreadyMerged {
    <#
    .SYNOPSIS
    Ветка уже целиком в основной: новые коммиты на ней никуда не поедут.

    .DESCRIPTION
    Случай выглядит безобидно и потому дорог. MR смержен, GitLab удалил ветку на
    сервере, локальная осталась — и следующий коммит ложится на неё. Фазы при
    этом проходят: дерево корректное, проверять его можно сколько угодно. Не едет
    только результат, и обнаруживается это вопросом «где изменения?».

    Проверяется вхождение вершины ветки в origin/<основная>. Именно вхождение, а
    не удалённость upstream: удаление ветки на сервере видно локально только после
    fetch --prune, которого фаза не делает, а вершина в main — факт, доступный
    сразу.

    Ответ не запрещает работу: дерево верное, и бывает, что человек намеренно
    продолжает на смерженной ветке. Он лишь называет то, что иначе выяснится
    позже всех.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [Parameter(Mandatory = $true)]
        [string]$MainBranch
    )

    if (-not $BranchName -or $BranchName -eq $MainBranch) {
        return $false
    }

    # Ветка, которую ещё ни разу не отправляли, содержится в main целиком просто
    # потому, что своих коммитов у неё нет. Предупреждать о ней — значит врать в
    # безобидном случае, а проверка, которая врёт, перестаёт читаться и в
    # настоящем. Так и вышло: предупреждение печаталось каждый прогон, я принимал
    # его за шум, и коммит уехал в ветку смерженного MR.
    $tracked = (Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("config", "--get", "branch.$BranchName.merge") `
        -AllowFailure).ExitCode -eq 0
    if (-not $tracked) {
        return $false
    }

    $reference = "origin/$MainBranch"
    $exists = (Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("rev-parse", "--verify", "--quiet", $reference) `
        -AllowFailure).ExitCode -eq 0
    if (-not $exists) {
        return $false
    }

    return (Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("merge-base", "--is-ancestor", $BranchName, $reference) `
        -AllowFailure).ExitCode -eq 0
}

function Get-WorkflowBranchName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $result = Invoke-WorkflowGit -RepositoryRoot $RepositoryRoot -Arguments @("branch", "--show-current")
    return [string]($result.Output | Select-Object -First 1)
}

function ConvertTo-WorkflowSlug {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $slug = $Value.ToLowerInvariant() -replace '[^a-z0-9_-]+', '-'
    $slug = $slug -replace '[-_]{2,}', '-'
    $slug = $slug.Trim('-', '_')
    if (-not $slug) {
        return "workspace"
    }
    return $slug
}

function Get-WorkflowSettingValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$Default
    )

    if ($null -eq $Object) {
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    if ($null -eq $property.Value) {
        return $Default
    }
    if ($property.Value -is [string] -and [string]::IsNullOrWhiteSpace($property.Value)) {
        return $Default
    }
    return $property.Value
}

function Find-WorkflowMissingAdapterPaths {
    <#
    .SYNOPSIS
    Возвращает объявленные проектные адаптеры, файлов которых нет на диске.

    .DESCRIPTION
    Путь в defaults — такой же исполнимый контракт, как включённый флаг. Раньше
    комплект годами объявлял tools/Invoke-FunctionalSeed.ps1, которого никогда
    не поставлял: дефект обнаруживался только при первом включении тестов.
    Проверка не зависит от enabled намеренно — выключение прогона не превращает
    битую ссылку в корректную установку.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $contracts = @(
        [pscustomobject]@{ Section = "functionalTests"; Property = "initializeScript" },
        [pscustomobject]@{ Section = "functionalTests"; Property = "seedScript" },
        [pscustomobject]@{ Section = "functionalTests"; Property = "publishScript" },
        [pscustomobject]@{ Section = "functionalTests"; Property = "smokeScript" },
        [pscustomobject]@{ Section = "webUiTests"; Property = "script" },
        [pscustomobject]@{ Section = "webUiTests"; Property = "publishScript" },
        [pscustomobject]@{ Section = "unitTests"; Property = "script" },
        [pscustomobject]@{ Section = "userGuides"; Property = "script" },
        [pscustomobject]@{ Section = "userGuides"; Property = "renderScript" },
        [pscustomobject]@{ Section = "releaseGuides"; Property = "script" },
        [pscustomobject]@{ Section = "releaseGuides"; Property = "sourceScript" },
        [pscustomobject]@{ Section = "releaseGuides"; Property = "seedScript" }
    )
    $missing = New-Object System.Collections.ArrayList
    foreach ($contract in $contracts) {
        $sectionName = [string]$contract.Section
        $propertyName = [string]$contract.Property
        $section = Get-WorkflowSettingValue -Object $Config -Name $sectionName -Default $null
        if ($null -eq $section) {
            continue
        }
        $declared = [string](Get-WorkflowSettingValue -Object $section -Name $propertyName -Default "")
        if ([string]::IsNullOrWhiteSpace($declared)) {
            continue
        }
        $path = Resolve-WorkflowPath -RepositoryRoot $RepositoryRoot -Path $declared
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [void]$missing.Add([pscustomobject]@{
                Setting = "$sectionName.$propertyName"
                Declared = $declared
                Path = $path
            })
        }
    }
    return @($missing)
}

function Get-WorkflowMachineSettingsPath {
    <#
    .SYNOPSIS
    Файл машинных настроек: где на ЭТОЙ машине разворачивать базы и стенды.

    .DESCRIPTION
    Лежит в профиле пользователя, а не в репозитории, и это главное в нём.
    Корень баз — свойство машины, а не проекта: диск, свободное место и
    раскладка у каждого свои. Путь, записанный в общий `.1c-workflow.json`,
    уезжает всей команде и на чужой машине либо не существует, либо занят
    чем-то другим.

    Один файл на пользователя, а не на репозиторий: разработчик с тремя
    конфигурациями отвечает на вопрос один раз, и повторный клон репозитория
    вопрос не возвращает. Отдельный проект может получить свой корень — для
    этого в файле есть раздел `projects`.

    ONEC_WORKFLOW_HOME существует ради тестов: прогон не должен писать в
    настоящий профиль того, кто его запустил.
    #>
    $homeDirectory = [string]$env:ONEC_WORKFLOW_HOME
    if (-not $homeDirectory) {
        $homeDirectory = Join-Path ([string]$env:USERPROFILE) ".onec-workflow"
    }
    return Join-Path $homeDirectory "machine.json"
}

function Read-WorkflowMachineSettings {
    <#
    .SYNOPSIS
    Машинные настройки или $null, если их ещё нет.

    .DESCRIPTION
    Битый файл не роняет фазу: он равносилен отсутствующему, и следующий шаг —
    обычный вопрос пользователю. Отказ здесь означал бы, что испорченный JSON
    в профиле блокирует работу во всех проектах сразу.
    #>
    $path = Get-WorkflowMachineSettingsPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        return (Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-WorkflowMachineBaseRoot {
    <#
    .SYNOPSIS
    Корень баз, записанный на этой машине: сначала для проекта, потом общий.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $settings = Read-WorkflowMachineSettings
    if ($null -eq $settings) {
        return ""
    }

    $projectName = [string](Get-WorkflowSettingValue -Object $Config -Name "project" -Default "")
    if ($projectName) {
        $projects = Get-WorkflowSettingValue -Object $settings -Name "projects" -Default $null
        $entry = Get-WorkflowSettingValue -Object $projects -Name $projectName -Default $null
        $perProject = [string](Get-WorkflowSettingValue -Object $entry -Name "baseRoot" -Default "")
        if ($perProject) {
            return $perProject
        }
    }

    return [string](Get-WorkflowSettingValue -Object $settings -Name "baseRoot" -Default "")
}

function Save-WorkflowMachineBaseRoot {
    <#
    .SYNOPSIS
    Записывает корень баз в профиль пользователя.

    .DESCRIPTION
    Существующие разделы сохраняются: файл общий для всех проектов, и запись
    ответа по одному из них не должна стирать ответы по соседним.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BaseRoot,

        [switch]$ForThisProjectOnly
    )

    $path = Get-WorkflowMachineSettingsPath
    [System.IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null

    $settings = Read-WorkflowMachineSettings
    $result = [ordered]@{}
    if ($null -ne $settings) {
        foreach ($property in @($settings.PSObject.Properties)) {
            $result[$property.Name] = $property.Value
        }
    }
    $result["schemaVersion"] = 1
    if (-not $result.Contains("baseRoot")) {
        $result["baseRoot"] = ""
    }
    $projects = [ordered]@{}
    $existingProjects = Get-WorkflowSettingValue -Object $settings -Name "projects" -Default $null
    if ($null -ne $existingProjects) {
        foreach ($property in @($existingProjects.PSObject.Properties)) {
            $projects[$property.Name] = $property.Value
        }
    }
    $result["projects"] = $projects

    $fullRoot = [System.IO.Path]::GetFullPath($BaseRoot)
    if ($ForThisProjectOnly) {
        $projectName = [string](Get-WorkflowSettingValue -Object $Config -Name "project" -Default "")
        $entry = [ordered]@{}
        $existingEntry = if ($projects.Contains($projectName)) { $projects[$projectName] } else { $null }
        if ($null -ne $existingEntry) {
            foreach ($property in @($existingEntry.PSObject.Properties)) {
                $entry[$property.Name] = $property.Value
            }
        }
        $entry["baseRoot"] = $fullRoot
        $projects[$projectName] = [pscustomobject]$entry
    }
    else {
        $result["baseRoot"] = $fullRoot
    }

    Write-WorkflowJson -Value ([pscustomobject]$result) -Path $path | Out-Null
    return $path
}

function Get-WorkflowMachineBspSourcePath {
    <#
    .SYNOPSIS
    Локальный каталог исходников объявленной версии БСП.

    .DESCRIPTION
    Версия принадлежит проекту, путь — машине. Поэтому общий манифест хранит
    только version, а соответствие version -> path лежит рядом с корнем баз в
    `%USERPROFILE%\.onec-workflow\machine.json` и переиспользуется всеми клонами.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $settings = Read-WorkflowMachineSettings
    $onecLite = Get-WorkflowSettingValue -Object $settings -Name "onecLite" -Default $null
    $sources = Get-WorkflowSettingValue -Object $onecLite -Name "bspSources" -Default $null
    return [string](Get-WorkflowSettingValue -Object $sources -Name $Version -Default "")
}

function Save-WorkflowMachineBspSourcePath {
    <#
    .SYNOPSIS
    Запоминает на этой машине каталог исходников конкретной версии БСП.

    .DESCRIPTION
    Сохраняет все неизвестные разделы machine.json: файл общий для процесса,
    и настройка корпуса не должна стирать корни баз или будущие параметры.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )

    $fullPath = [System.IO.Path]::GetFullPath($SourcePath)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "Каталог исходников БСП $Version не существует: $fullPath"
    }

    $path = Get-WorkflowMachineSettingsPath
    [System.IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
    $settings = Read-WorkflowMachineSettings
    $result = [ordered]@{}
    if ($null -ne $settings) {
        foreach ($property in @($settings.PSObject.Properties)) {
            $result[$property.Name] = $property.Value
        }
    }
    $result["schemaVersion"] = 1
    if (-not $result.Contains("baseRoot")) {
        $result["baseRoot"] = ""
    }
    if (-not $result.Contains("projects")) {
        $result["projects"] = [ordered]@{}
    }

    $onecLite = [ordered]@{}
    $existingOnecLite = Get-WorkflowSettingValue -Object $settings -Name "onecLite" -Default $null
    if ($null -ne $existingOnecLite) {
        foreach ($property in @($existingOnecLite.PSObject.Properties)) {
            $onecLite[$property.Name] = $property.Value
        }
    }
    $sources = [ordered]@{}
    $existingSources = Get-WorkflowSettingValue -Object $existingOnecLite -Name "bspSources" -Default $null
    if ($null -ne $existingSources) {
        foreach ($property in @($existingSources.PSObject.Properties)) {
            $sources[$property.Name] = $property.Value
        }
    }
    $sources[$Version] = $fullPath
    $onecLite["bspSources"] = [pscustomobject]$sources
    $result["onecLite"] = [pscustomobject]$onecLite

    Write-WorkflowJson -Value ([pscustomobject]$result) -Path $path | Out-Null
    return $path
}

function Test-WorkflowBspSourcePathProblem {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath
    )

    $value = ([string]$SourcePath).Trim()
    if (-not $value) {
        return "путь пустой"
    }
    if (-not [System.IO.Path]::IsPathRooted($value)) {
        return "путь должен быть полным: локальная привязка не зависит от каталога запуска"
    }
    try {
        $full = [System.IO.Path]::GetFullPath($value)
    }
    catch {
        return "путь не разбирается: $($_.Exception.Message)"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        return "каталог не существует: $full"
    }
    return ""
}

function Request-WorkflowBspSourcePath {
    <#
    .SYNOPSIS
    Один раз спрашивает локальный путь к требуемой проектом версии БСП.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [int]$Attempts = 3
    )

    Write-Host ""
    Write-Host "Проект использует корпус БСП $Version для onec-lite."
    Write-Host "Укажите локальный корень XML-выгрузки Конфигуратора или EDT workspace."
    Write-Host "Ответ сохранится в $(Get-WorkflowMachineSettingsPath) и в Git не попадёт."
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $answer = Read-Host "Путь к БСП $Version"
        $problem = Test-WorkflowBspSourcePathProblem -SourcePath $answer
        if (-not $problem) {
            return [System.IO.Path]::GetFullPath($answer)
        }
        Write-Warning "Путь не принят: $problem"
    }
    throw "Не удалось получить локальный путь к БСП $Version за $Attempts попытки."
}

function Test-WorkflowBaseRootProblem {
    <#
    .SYNOPSIS
    Причина, по которой корень баз не годится. Пустая строка — годится.

    .DESCRIPTION
    Проверки выбраны по цене ошибки, а не по вкусу.

    Относительный путь разошёлся бы у разных вызовов: фазы запускаются из
    разных каталогов, и «bases» означал бы каждый раз своё место.

    Корень ВНУТРИ репозитория — самая дорогая из ошибок: база 1С попадает под
    git, выгрузка перестаёт быть источником правды, а `status` показывает
    тысячи файлов. Проверяется именно вложенность, а не совпадение.

    Несуществующий диск отличается от несуществующего каталога: каталог фаза
    создаст сама, диск создать нельзя, и «сделаю потом» превращается в отказ
    посреди развёртывания.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$BaseRoot
    )

    $value = ([string]$BaseRoot).Trim()
    if (-not $value) {
        return "путь пустой"
    }
    if (-not [System.IO.Path]::IsPathRooted($value)) {
        return "путь должен быть полным, с буквой диска: фазы запускаются из разных каталогов"
    }

    try {
        $full = [System.IO.Path]::GetFullPath($value)
    }
    catch {
        return "путь не разбирается: $($_.Exception.Message)"
    }

    $repositoryFull = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\') + '\'
    if (($full.TrimEnd('\') + '\').StartsWith($repositoryFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "путь лежит внутри репозитория: база 1С попала бы под git вместе с выгрузкой"
    }

    $drive = [System.IO.Path]::GetPathRoot($full)
    if ($drive -and -not (Test-Path -LiteralPath $drive -PathType Container)) {
        return "диск $drive недоступен"
    }

    return ""
}

function Get-WorkflowFixedDrives {
    <#
    .SYNOPSIS
    Диски машины со свободным местом — подсказка к вопросу о корне баз.

    .DESCRIPTION
    Нужна ровно затем, чтобы человек не выбирал вслепую: базы и стенды растут
    десятками гигабайт, а системный диск обычно самый тесный.
    #>
    $drives = New-Object System.Collections.ArrayList
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if ($drive.DriveType -ne [System.IO.DriveType]::Fixed -or -not $drive.IsReady) {
                continue
            }
            [void]$drives.Add([pscustomobject]@{
                Name = $drive.Name
                FreeGb = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
                TotalGb = [math]::Round($drive.TotalSize / 1GB, 1)
            })
        }
        catch {
            continue
        }
    }
    return @($drives)
}

function Test-WorkflowInteractiveHost {
    <#
    .SYNOPSIS
    Можно ли задать вопрос человеку прямо сейчас.

    .DESCRIPTION
    Спрашивать вслепую опаснее, чем не спрашивать: при перенаправленном вводе
    Read-Host получает конец потока и возвращает пустую строку — фаза либо
    зависнет, либо примет пустой ответ за выбор. Агент, CI и задание планировщика
    запускают фазы именно так, поэтому вопрос задаётся только живой консоли, а
    в остальных случаях отказ называет ключ и переменную.
    #>
    try {
        if ([Console]::IsInputRedirected) {
            return $false
        }
    }
    catch {
        return $false
    }
    return [Environment]::UserInteractive
}

function Request-WorkflowBaseRoot {
    <#
    .SYNOPSIS
    Спрашивает у человека, где разворачивать базы и стенды этой машины.

    .DESCRIPTION
    Вопрос задаётся один раз на машину — при первой подготовке рабочего места.
    Умолчания нет намеренно: подставленный путь принимают не глядя, а ошибка
    здесь стоит десятков гигабайт не там, где нужно, и переразвёртывания всех
    баз. Вместо умолчания показываются диски со свободным местом.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [int]$Attempts = 3
    )

    Write-Host ""
    Write-Host "Где на этой машине разворачивать базы разработки и тестовые стенды?"
    Write-Host "Каталог будет создан; внутри появятся DevBases и TestBases."
    Write-Host "Ответ запишется в $(Get-WorkflowMachineSettingsPath) и в репозиторий не попадёт."
    Write-Host ""
    foreach ($drive in @(Get-WorkflowFixedDrives)) {
        Write-Host ("  {0}  свободно {1} ГБ из {2} ГБ" -f $drive.Name, $drive.FreeGb, $drive.TotalGb)
    }
    Write-Host ""

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $answer = Read-Host "Полный путь к каталогу для баз"
        $problem = Test-WorkflowBaseRootProblem -RepositoryRoot $RepositoryRoot -BaseRoot $answer
        if (-not $problem) {
            return [System.IO.Path]::GetFullPath(([string]$answer).Trim())
        }
        Write-Host "  не подходит: $problem"
    }

    throw "Корень баз не задан: $Attempts попытки подряд не дали годного пути."
}

function Resolve-WorkflowBaseRoots {
    <#
    .SYNOPSIS
    Корни баз разработки и стендов для этой машины.

    .DESCRIPTION
    Порядок разрешения задаёт, кто кого перекрывает, и выбран так, чтобы
    ближний к машине ответ всегда побеждал дальний:

      1. ключ -BaseRoot            — явное решение вызывающего, годится для CI;
      2. ONEC_WORKFLOW_BASE_ROOT   — машина, настроенная скриптом развёртывания;
      3. файл в профиле            — ответ, данный человеком один раз;
      4. parallel.devBaseRoot      — общий путь команды из манифеста проекта.

    Манифест стоит ПОСЛЕДНИМ и учитывается, только если путь на этой машине
    существует. Иначе комплект молча развернул бы чужую раскладку: путь вида
    H:\1C на машине без такого диска — это не настройка, это чужая машина.

    Пустые корни — не отказ. Эту функцию зовёт и gate, которому базы не нужны;
    отказ принадлежит тому, кто собрался базу создавать.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [string]$Explicit = ""
    )

    $section = Get-WorkflowSettingValue -Object $Config -Name "parallel" -Default $null
    $manifestDev = [string](Get-WorkflowSettingValue -Object $section -Name "devBaseRoot" -Default "")
    $manifestTest = [string](Get-WorkflowSettingValue -Object $section -Name "testBaseRoot" -Default "")

    $root = ""
    $source = ""
    if ($Explicit) {
        $root = $Explicit
        $source = "ключ -BaseRoot"
    }
    elseif ([string]$env:ONEC_WORKFLOW_BASE_ROOT) {
        $root = [string]$env:ONEC_WORKFLOW_BASE_ROOT
        $source = "переменная ONEC_WORKFLOW_BASE_ROOT"
    }
    else {
        $machineRoot = Get-WorkflowMachineBaseRoot -Config $Config
        if ($machineRoot) {
            $root = $machineRoot
            $source = "машинные настройки $(Get-WorkflowMachineSettingsPath)"
        }
    }

    if ($root) {
        $full = [System.IO.Path]::GetFullPath($root)
        return [pscustomobject]@{
            DevRoot = Join-Path $full "DevBases"
            TestRoot = Join-Path $full "TestBases"
            Root = $full
            Source = $source
        }
    }

    if ($manifestDev -and (Test-Path -LiteralPath $manifestDev -PathType Container)) {
        $testRoot = if ($manifestTest) { $manifestTest } else { $manifestDev }
        return [pscustomobject]@{
            DevRoot = [System.IO.Path]::GetFullPath($manifestDev)
            TestRoot = [System.IO.Path]::GetFullPath($testRoot)
            Root = ""
            Source = "манифест проекта"
        }
    }

    return [pscustomobject]@{ DevRoot = ""; TestRoot = ""; Root = ""; Source = "" }
}

function Assert-WorkflowBaseRoot {
    <#
    .SYNOPSIS
    Отказ с названным выходом, когда корень баз на машине не задан.

    .DESCRIPTION
    Правило без достижимого пути обходят молча, поэтому сообщение называет все
    три способа ответить, а не жалуется на отсутствие настройки.
    #>
    param(
        # Пустая строка — это и есть проверяемый случай: обязательный параметр
        # без AllowEmptyString отказал бы на привязке, и вместо объяснения с
        # выходом человек получил бы жалобу на аргумент.
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Root
    )

    if ($Root) {
        return
    }

    throw @"
Не задан корень, в котором разворачивать базы и стенды этой машины.

Подготовьте рабочее место вопросом в живой консоли:
  Invoke-TaskWorkflow.ps1 -Phase Start

или задайте путь без вопроса:
  Invoke-TaskWorkflow.ps1 -Phase Start -BaseRoot <полный путь к каталогу для баз>
  либо переменная окружения ONEC_WORKFLOW_BASE_ROOT

Ответ хранится в $(Get-WorkflowMachineSettingsPath) и в репозиторий не попадает:
корень баз — свойство машины, а не проекта.
"@
}

function Get-WorkflowParallelSettings {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $section = Get-WorkflowSettingValue -Object $Config -Name "parallel" -Default $null
    # Корень баз — свойство МАШИНЫ. Прежняя версия проверяла наличие каталога
    # H:\1C и брала его умолчанием: раскладка диска того, кто писал комплект,
    # доставалась каждому проекту. На чужой машине такой диск либо отсутствует,
    # либо занят другим, и обе развилки плохи — вторая молча.
    $roots = Resolve-WorkflowBaseRoots -Config $Config

    $enabled = if ($null -eq $section) { $true } else {
        [bool](Get-WorkflowSettingValue -Object $section -Name "enabled" -Default $true)
    }
    $perBranchStands = if ($null -eq $section) { $false } else {
        [bool](Get-WorkflowSettingValue -Object $section -Name "perBranchStands" -Default $true)
    }

    $portRangeStart = [int](Get-WorkflowSettingValue -Object $section -Name "portRangeStart" -Default 8100)
    $portRangeEnd = [int](Get-WorkflowSettingValue -Object $section -Name "portRangeEnd" -Default 8399)
    $portsPerBranch = [int](Get-WorkflowSettingValue -Object $section -Name "portsPerBranch" -Default 4)
    # Слот делится между видами стендов (web-ui и http). При portsPerBranch=1
    # подпредел http начинался бы за границей слота, то есть в слоте соседней
    # ветки — молча и гарантированно. Требование действует только когда слоты
    # реально используются: при общих стендах portsPerBranch не участвует в
    # расчётах, и падать из-за него было бы формализмом.
    $standKindCount = 2
    if ($enabled -and $perBranchStands -and $portsPerBranch -lt $standKindCount) {
        throw "parallel.portsPerBranch must be at least ${standKindCount} when parallel.perBranchStands is true: the branch slot is split between the web-ui and http stands."
    }
    if ($portRangeEnd -lt ($portRangeStart + $portsPerBranch - 1)) {
        throw "parallel.portRangeEnd must leave room for at least one branch slot of $portsPerBranch ports."
    }

    return [pscustomobject]@{
        enabled = $enabled
        perBranchStands = ($enabled -and $perBranchStands)
        # Пустая строка здесь законна: корень ещё не задан на этой машине.
        # Отказ принадлежит не конструктору настроек, а тому, кто собрался
        # создавать базу, — gate зовёт эту функцию ради проверки портов, и
        # падение на ненужном ему корне остановило бы проверку на ровном месте.
        devBaseRoot = $roots.DevRoot
        testBaseRoot = $roots.TestRoot
        baseRootSource = $roots.Source
        portRangeStart = $portRangeStart
        portRangeEnd = $portRangeEnd
        portsPerBranch = $portsPerBranch
        slotCount = [int][Math]::Floor((($portRangeEnd - $portRangeStart) + 1) / $portsPerBranch)
        lockTimeoutSeconds = [int](
            Get-WorkflowSettingValue -Object $section -Name "lockTimeoutSeconds" -Default 3600
        )
        agentConfigTemplates = @(
            Get-WorkflowSettingValue -Object $section -Name "agentConfigTemplates" -Default @()
        )
    }
}

function Get-WorkflowOnecLiteCorpusSettings {
    <#
    .SYNOPSIS
    Проверяет и разрешает проектные корпуса onec-lite на этой машине.

    .DESCRIPTION
    Проект хранит только намерение: нужна ли справка и какая версия БСП нужна.
    Каталог справки выводится из реально выбранного 1cv8.exe, а путь к БСП берётся
    из машинной привязки version -> path. Машинозависимые пути в Git не попадают.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [AllowEmptyString()]
        [string]$V8Executable = "",

        [AllowEmptyString()]
        [string]$BspSourcePath = ""
    )

    $onecLite = Get-WorkflowSettingValue -Object $Config -Name "onecLite" -Default $null
    $onecLiteEnabled = (
        $null -ne $onecLite -and
        [bool](Get-WorkflowSettingValue -Object $onecLite -Name "enabled" -Default $true)
    )
    $result = [ordered]@{
        enabled = $onecLiteEnabled
        platformDocsEnabled = $false
        platformDocsPaths = @()
        bspSourcesEnabled = $false
        bspVersion = ""
        bspSourcePaths = @()
    }
    if (-not $onecLiteEnabled) {
        foreach ($name in @("platformDocs", "bspSources")) {
            $child = Get-WorkflowSettingValue -Object $onecLite -Name $name -Default $null
            if ($null -ne $child -and
                [bool](Get-WorkflowSettingValue -Object $child -Name "enabled" -Default $false)) {
                throw "onecLite.$name cannot be enabled while onecLite.enabled is false."
            }
        }
        return [pscustomobject]$result
    }

    $platformDocs = Get-WorkflowSettingValue -Object $onecLite -Name "platformDocs" -Default $null
    $result.platformDocsEnabled = (
        $null -ne $platformDocs -and
        [bool](Get-WorkflowSettingValue -Object $platformDocs -Name "enabled" -Default $false)
    )
    if ($result.platformDocsEnabled) {
        if (-not $V8Executable) {
            throw "onecLite.platformDocs is enabled, but the local 1cv8 executable was not resolved."
        }
        $fullExecutable = [System.IO.Path]::GetFullPath($V8Executable)
        if (-not (Test-Path -LiteralPath $fullExecutable -PathType Leaf)) {
            throw "onecLite.platformDocs cannot use a missing local 1cv8 executable: $fullExecutable"
        }
        $result.platformDocsPaths = @((Split-Path $fullExecutable -Parent))
    }

    $bspSources = Get-WorkflowSettingValue -Object $onecLite -Name "bspSources" -Default $null
    $result.bspSourcesEnabled = (
        $null -ne $bspSources -and
        [bool](Get-WorkflowSettingValue -Object $bspSources -Name "enabled" -Default $false)
    )
    if ($result.bspSourcesEnabled) {
        $version = [string](Get-WorkflowSettingValue -Object $bspSources -Name "version" -Default "")
        if (-not $version) {
            throw "onecLite.bspSources.enabled is true, but version is empty in .1c-workflow.json."
        }
        $result.bspVersion = $version
        $resolvedBspPath = ([string]$BspSourcePath).Trim()
        if (-not $resolvedBspPath) {
            $resolvedBspPath = Get-WorkflowMachineBspSourcePath -Version $version
        }
        $problem = Test-WorkflowBspSourcePathProblem -SourcePath $resolvedBspPath
        if ($problem) {
            throw (
                "Для БСП $version не настроен пригодный локальный каталог ($problem). " +
                "Запустите Phase Start в интерактивном терминале, передайте -BspSourcePath <путь> " +
                "или задайте ONEC_WORKFLOW_BSP_SOURCE_ROOT."
            )
        }
        $result.bspSourcePaths = @([System.IO.Path]::GetFullPath($resolvedBspPath))
    }
    return [pscustomobject]$result
}

function Get-WorkflowHeadCommit {
    <#
    .SYNOPSIS
    Возвращает HEAD или пустую строку, если в репозитории ещё нет коммитов.

    .DESCRIPTION
    В свежем репозитории (этап инициализации нового проекта до стартового
    коммита) `git rev-parse HEAD` завершается ошибкой. Проверки, которые лишь
    записывают commit в отчёт, не должны из-за этого падать.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $result = Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("rev-parse", "HEAD") `
        -AllowFailure
    if ($result.ExitCode -ne 0) {
        return ""
    }
    return [string]($result.Output | Select-Object -First 1)
}

function Get-WorkflowStandBranchName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $branch = Get-WorkflowBranchName -RepositoryRoot $RepositoryRoot
    if ($branch) {
        return $branch
    }
    # Detached HEAD: стенд всё равно должен быть уникальным для этой рабочей копии.
    $head = Get-WorkflowHeadCommit -RepositoryRoot $RepositoryRoot
    if (-not $head) {
        return "detached"
    }
    return "detached-$($head.Substring(0, [Math]::Min(7, $head.Length)))"
}

function Get-WorkflowStandSlug {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [int]$MaxLength = 40
    )

    $slug = ConvertTo-WorkflowSlug -Value $BranchName
    if ($slug.Length -le $MaxLength) {
        return $slug
    }
    # Длинные имена ветвей усекаем, но добавляем короткий отпечаток, чтобы два
    # разных длинных имени не свернулись в один и тот же стенд.
    $suffix = (Get-WorkflowStableHash -Value $slug).Substring(0, 6)
    return ($slug.Substring(0, $MaxLength - 7).TrimEnd('-', '_') + "-" + $suffix)
}

function Get-WorkflowStableHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha256.ComputeHash([System.Text.UTF8Encoding]::new($false).GetBytes($Value))
    }
    finally {
        $sha256.Dispose()
    }
    return ([System.BitConverter]::ToString($bytes)).Replace("-", "").ToLowerInvariant()
}

function Get-WorkflowBranchSlot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [Parameter(Mandatory = $true)]
        [int]$SlotCount
    )

    if ($SlotCount -le 1) {
        return 0
    }
    $hash = Get-WorkflowStableHash -Value (ConvertTo-WorkflowSlug -Value $BranchName)
    $number = [System.Convert]::ToUInt32($hash.Substring(0, 8), 16)
    return [int]($number % [uint32]$SlotCount)
}

function Get-DefaultWorkflowBasePath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    $settings = Get-WorkflowParallelSettings -Config $Config
    Assert-WorkflowBaseRoot -Root $settings.devBaseRoot
    return Join-Path `
        (Join-Path $settings.devBaseRoot ([string]$Config.project)) `
        (ConvertTo-WorkflowSlug -Value $BranchName)
}

function Get-WorkflowInfoBaseRegistry {
    <#
    .SYNOPSIS
    Читает реестр баз `.v8-project.json`, если он есть.

    .DESCRIPTION
    Реестр ведёт человек: он описывает реальную инфраструктуру разработчика —
    несколько баз с разным назначением, файловых и серверных. Процесс его ЧИТАЕТ,
    а не переписывает: перезапись стёрла бы то, чего процесс не знает.

    Отсутствие файла не ошибка. Проект без реестра работает по-прежнему, на
    файловой базе, выведенной из слага ветки.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $registryPath = Join-Path $RepositoryRoot ".v8-project.json"
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
        return $null
    }
    return Get-Content -Raw -Encoding UTF8 -LiteralPath $registryPath | ConvertFrom-Json
}

function Resolve-WorkflowInfoBase {
    <#
    .SYNOPSIS
    Возвращает описатель информационной базы: файловой или серверной.

    .DESCRIPTION
    Раньше путь к базе вычислялся из слага ветки, и это делало комплект пригодным
    только для файловых баз. Там, где базы серверные, такого пути не существует в
    принципе, а вместе с ним отваливается изоляция: метка владельца писалась ВНУТРЬ
    каталога базы, которого у серверной нет.

    Порядок разрешения повторяет привычный по cc-1c-skills:

      1. явно названная база (-Database) по id или alias;
      2. явно переданный путь (-ExplicitPath);
      3. запись реестра, чей шаблон branches совпал с именем ветки;
      4. запись, названная в default;
      5. файловая база из слага ветки или -FallbackPath, прежнее поведение.

    Пункт 5 оставлен намеренно: проекты без реестра не должны заметить изменения.

    Пункты 1 и 2 стоят ВЫШЕ реестра, и это не мелочь. Названное человеком обязано
    побеждать выведенное: иначе вызов с явным путём к стенду молча уезжал бы в базу
    разработчика — реестр-то заполняется на Start и шаблоном branches совпадает с
    текущей веткой всегда. Такая ошибка не падает: загрузка проходит, прогон идёт,
    только по другой базе.

    .OUTPUTS
    PSCustomObject с полями Kind, Path, Server, Ref, UserName, Password, Id,
    Display, Source. Поле Id устойчиво и годится ключом состояния: у файловой базы
    это путь, у серверной сервер и имя.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [string]$Database = "",

        # Путь, названный вызывающим явно (ключ -BasePath). Побеждает реестр.
        [string]$ExplicitPath = "",

        # Последнее средство: путь из прошлого состояния или пусто. Реестру
        # проигрывает.
        [string]$FallbackPath = ""
    )

    if ($ExplicitPath -and -not $Database) {
        return (ConvertTo-WorkflowInfoBase -BasePath $ExplicitPath -Caller "Resolve-WorkflowInfoBase")
    }

    $registry = Get-WorkflowInfoBaseRegistry -RepositoryRoot $RepositoryRoot
    $entries = @()
    if ($null -ne $registry -and $null -ne $registry.PSObject.Properties["databases"]) {
        $entries = @($registry.databases)
    }

    $selected = $null
    $source = ""

    if ($Database) {
        foreach ($entry in $entries) {
            $aliases = @()
            if ($null -ne $entry.PSObject.Properties["aliases"] -and $null -ne $entry.aliases) {
                $aliases = @($entry.aliases | ForEach-Object { [string]$_ })
            }
            if ([string]$entry.id -eq $Database -or $aliases -contains $Database) {
                $selected = $entry
                $source = "database-key"
                break
            }
        }
        if ($null -eq $selected) {
            $known = @($entries | ForEach-Object { [string]$_.id }) -join ", "
            throw "Infobase '$Database' is not described in .v8-project.json. Known: $known"
        }
    }

    if ($null -eq $selected) {
        foreach ($entry in $entries) {
            if ($null -eq $entry.PSObject.Properties["branches"] -or $null -eq $entry.branches) {
                continue
            }
            foreach ($pattern in @($entry.branches)) {
                if ($BranchName -like [string]$pattern) {
                    $selected = $entry
                    $source = "branch-pattern"
                    break
                }
            }
            if ($null -ne $selected) {
                break
            }
        }
    }

    if ($null -eq $selected -and
        $null -ne $registry -and
        $null -ne $registry.PSObject.Properties["default"] -and
        [string]$registry.default) {

        foreach ($entry in $entries) {
            if ([string]$entry.id -eq [string]$registry.default) {
                $selected = $entry
                $source = "default"
                break
            }
        }
    }

    if ($null -eq $selected) {
        $path = $FallbackPath
        if (-not $path) {
            $path = Get-DefaultWorkflowBasePath -Config $Config -BranchName $BranchName
        }
        $full = [System.IO.Path]::GetFullPath($path)
        return [pscustomobject]@{
            Kind = "file"
            Path = $full
            Server = ""
            Ref = ""
            UserName = ""
            Password = ""
            Id = "file:$full"
            Display = $full
            Source = "fallback"
        }
    }

    $userName = ""
    if ($null -ne $selected.PSObject.Properties["user"]) {
        $userName = [string]$selected.user
    }
    $password = ""
    if ($null -ne $selected.PSObject.Properties["password"]) {
        # Значение может быть ссылкой ${ИМЯ} на переменную окружения: тогда в
        # настройках лежит имя, а сам секрет — в .env, который git не отслеживает.
        $password = Import-WorkflowSecret -Value ([string]$selected.password)
    }

    if ([string]$selected.type -eq "server") {
        $server = [string]$selected.server
        $ref = [string]$selected.ref
        if (-not $server -or -not $ref) {
            throw "Infobase '$([string]$selected.id)' is declared as server but has no server/ref."
        }
        return [pscustomobject]@{
            Kind = "server"
            Path = ""
            Server = $server
            Ref = $ref
            UserName = $userName
            Password = $password
            Id = "server:$server/$ref"
            Display = "$server\$ref"
            Source = $source
        }
    }

    $full = [System.IO.Path]::GetFullPath([string]$selected.path)
    return [pscustomobject]@{
        Kind = "file"
        Path = $full
        Server = ""
        Ref = ""
        UserName = $userName
        Password = $password
        Id = "file:$full"
        Display = $full
        Source = $source
    }
}

function Get-WorkflowInfoBaseArguments {
    <#
    .SYNOPSIS
    Аргументы подключения 1cv8 для описателя базы.

    .DESCRIPTION
    Пустой пароль НЕ передаётся ключом /P. Пустое значение схлопывается при
    передаче, платформа получает ключ без значения и отвечает отказом. Выглядит это
    как неверные учётные данные, хотя они верны.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$InfoBase
    )

    if ([string]$InfoBase.Kind -eq "server") {
        $arguments = @("/S", "$([string]$InfoBase.Server)\$([string]$InfoBase.Ref)")
    }
    else {
        $arguments = @("/F", [string]$InfoBase.Path)
    }

    if ([string]$InfoBase.UserName) {
        $arguments += @("/N", [string]$InfoBase.UserName)
        if ([string]$InfoBase.Password) {
            $arguments += @("/P", [string]$InfoBase.Password)
        }
    }

    return $arguments
}

function ConvertTo-WorkflowInfoBase {
    <#
    .SYNOPSIS
    Приводит «путь ИЛИ описатель» к описателю.

    .DESCRIPTION
    Точки вызова платформы и навыков переводятся на описатели постепенно, поэтому
    каждая из них принимает и старый -BasePath, и новый -InfoBase. Решение «что
    именно передали» обязано приниматься в одном месте: разложенное по функциям, оно
    в первой же забытой точке молча свернётся к файловой базе — и работа уедет по
    пути, которого у серверного описателя нет.
    #>
    param(
        [object]$InfoBase = $null,

        [string]$BasePath = "",

        [string]$Caller = "This command"
    )

    if ($null -ne $InfoBase) {
        return $InfoBase
    }
    if (-not $BasePath) {
        throw "$Caller requires either -InfoBase or -BasePath."
    }
    return [pscustomobject]@{
        Kind = "file"
        Path = $BasePath
        Server = ""
        Ref = ""
        UserName = ""
        Password = ""
        Id = "file:$([System.IO.Path]::GetFullPath($BasePath).ToLowerInvariant())"
        Display = $BasePath
        Source = "base-path"
    }
}

function Get-WorkflowInfoBaseSkillArguments {
    <#
    .SYNOPSIS
    Аргументы описателя базы для скриптов cc-1c-skills.

    .DESCRIPTION
    Навыки db-* принимают базу двумя разными наборами ключей: файловую —
    -InfoBasePath, серверную — -InfoBaseServer и -InfoBaseRef. Комплект обязан
    выбирать набор в ОДНОМ месте: иначе каждая новая точка вызова будет решать это
    заново, и первая же забытая точка молча уведёт работу в файловую базу по пути,
    которого у серверного описателя нет.

    Пустой пароль не передаётся по той же причине, что и в командной строке
    платформы: пустое значение схлопывается, а отказ выглядит как неверные
    учётные данные.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$InfoBase
    )

    if ([string]$InfoBase.Kind -eq "server") {
        $arguments = @(
            "-InfoBaseServer", [string]$InfoBase.Server,
            "-InfoBaseRef", [string]$InfoBase.Ref
        )
    }
    else {
        $arguments = @("-InfoBasePath", [string]$InfoBase.Path)
    }

    if ([string]$InfoBase.UserName) {
        $arguments += @("-UserName", [string]$InfoBase.UserName)
        if ([string]$InfoBase.Password) {
            $arguments += @("-Password", [string]$InfoBase.Password)
        }
    }

    return $arguments
}

function Get-WorkflowStandAdministrator {
    <#
    .SYNOPSIS
    Администратор стенда: одни учётные данные на все стенды всех проектов.

    .DESCRIPTION
    На каждом стенде — функциональном, Web UI, стенде инструкций — есть
    пользователь ИБ «Администратор» без пароля и с административными ролями.
    Остальных пользователей проект заводит и меняет как угодно.

    Зачем одно правило на всех. Как только проекту нужны ролевые сценарии, в базе
    появляются пользователи, и с этого момента представляться обязано КАЖДОЕ
    подключение: конфигуратор, предприятие, COM, публикация. Без общего правила
    каждый проект решал это заново и по-своему (known-issues, п. 4), а комплект не
    мог подключиться к стенду, не зная, кого спросить.

    Пустой пароль комплект не передаёт вовсе — ни ключом /P, ни -Password: пустое
    значение схлопывается при передаче, и отказ выглядит как неверный пароль. Это
    делают Get-WorkflowInfoBaseArguments и Get-WorkflowInfoBaseSkillArguments.

    Стенд локальный и выбрасываемый, данные в нём демонстрационные. Рабочим базам
    правило не применяется и применяться не должно.
    #>
    return [pscustomobject]@{
        UserName = "Администратор"
        Password = ""
    }
}

function ConvertTo-WorkflowStandInfoBase {
    <#
    .SYNOPSIS
    Описатель файлового стенда с учётными данными администратора стенда.

    .DESCRIPTION
    Отличие от ConvertTo-WorkflowInfoBase только в учётных данных. Подключаться
    так можно лишь к стенду, где администратор уже заведён: платформа отказывает
    входу по имени в базу, где пользователей нет вовсе («Пользователь ИБ не
    идентифицирован»). Поэтому перед первым подключением к свежему стенду
    вызывается Initialize-WorkflowStandAdministrator.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $administrator = Get-WorkflowStandAdministrator
    $infoBase = ConvertTo-WorkflowInfoBase -BasePath $BasePath -Caller "ConvertTo-WorkflowStandInfoBase"
    $infoBase.UserName = $administrator.UserName
    $infoBase.Password = $administrator.Password
    $infoBase.Source = "stand-administrator"
    return $infoBase
}

function Get-WorkflowStandAdministratorScript {
    <#
    .SYNOPSIS
    Текст дочернего процесса, который заводит администратора стенда через COM.

    .DESCRIPTION
    Вынесен отдельно, чтобы тесты комплекта проверяли состав без платформы.
    Исходы: created — пользователей не было, администратор заведён; exists —
    администратор стенда уже есть. Любой другой исход — исключение с причиной.

    К объектам 1С скрипт обращается ТОЛЬКО через InvokeMember. Объект соединения
    1С не отдаёт типовую информацию, и COM-адаптер PowerShell возвращает на
    `$соединение.Метаданные` молча $null — без ошибки. А перечислимую коллекцию
    (`Роли`, результат `ПолучитьПользователей`) PowerShell при возврате из функции
    разворачивает в Object[], и следующий вызов её метода «не находится». Поэтому
    помощники возвращают результат через запятую: так он не разворачивается.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $administrator = Get-WorkflowStandAdministrator
    $path = [System.IO.Path]::GetFullPath($BasePath).Replace("'", "''")
    $user = $administrator.UserName.Replace("'", "''")
    $password = $administrator.Password.Replace("'", "''")
    return @"
`$ErrorActionPreference = 'Stop'
function Get-ComProperty(`$Object, [string]`$Name) {
    ,([System.__ComObject].InvokeMember(`$Name, [Reflection.BindingFlags]::GetProperty, `$null, `$Object, `$null))
}
function Set-ComProperty(`$Object, [string]`$Name, `$Value) {
    [void][System.__ComObject].InvokeMember(`$Name, [Reflection.BindingFlags]::SetProperty, `$null, `$Object, @(`$Value))
}
function Invoke-ComMethod(`$Object, [string]`$Name, [object[]]`$Arguments = @()) {
    ,([System.__ComObject].InvokeMember(`$Name, [Reflection.BindingFlags]::InvokeMethod, `$null, `$Object, `$Arguments))
}
`$connector = New-Object -ComObject 'V83.COMConnector'
`$base = 'File="$path";'
function Connect([string]`$Name, [string]`$Secret) {
    `$suffix = if (`$Name) { 'Usr="' + `$Name + '";Pwd="' + `$Secret + '";' } else { '' }
    try { return ,(`$connector.Connect(`$base + `$suffix)) } catch { return `$null }
}
`$open = Connect '$user' '$password'
`$created = `$false
if (`$null -eq `$open) {
    `$open = Connect '' ''
}
if (`$null -eq `$open) {
    throw 'На стенде есть пользователи ИБ, но под администратором стенда $user (Get-WorkflowStandAdministrator) войти нельзя: его нет или у него задан пароль. Адаптер, заводящий пользователей, обязан первым завести именно его.'
}
`$metadata = Get-ComProperty `$open 'Метаданные'
`$allRoles = Get-ComProperty `$metadata 'Роли'
`$roles = @()
`$hasAdministratorRole = `$false
`$count = Invoke-ComMethod `$allRoles 'Количество'
for (`$index = 0; `$index -lt `$count; `$index++) {
    `$role = Invoke-ComMethod `$allRoles 'Получить' @(`$index)
    `$roles += ,`$role
    if (Invoke-ComMethod `$open 'ПравоДоступа' @('Администрирование', `$metadata, `$role)) {
        `$hasAdministratorRole = `$true
    }
}
if (-not `$hasAdministratorRole) { throw 'В конфигурации нет роли с правом Администрирование: администратора стенда завести нечем.' }
`$users = Get-ComProperty `$open 'ПользователиИнформационнойБазы'
`$standUser = Invoke-ComMethod `$users 'НайтиПоИмени' @('$user')
if (`$null -eq `$standUser) {
    `$standUser = Invoke-ComMethod `$users 'СоздатьПользователя'
    Set-ComProperty `$standUser 'Имя' '$user'
    Set-ComProperty `$standUser 'ПолноеИмя' '$user'
    Set-ComProperty `$standUser 'АутентификацияСтандартная' `$true
    Set-ComProperty `$standUser 'ПоказыватьВСпискеВыбора' `$true
    `$created = `$true
}
`$userRoles = Get-ComProperty `$standUser 'Роли'
[void](Invoke-ComMethod `$userRoles 'Очистить')
foreach (`$role in `$roles) { [void](Invoke-ComMethod `$userRoles 'Добавить' @(`$role)) }
[void](Invoke-ComMethod `$standUser 'Записать')
if (`$created) { Write-Output 'stand-administrator:created' } else { Write-Output 'stand-administrator:exists' }
"@
}

function Initialize-WorkflowStandAdministrator {
    <#
    .SYNOPSIS
    Гарантирует администратора стенда. Вызывается до первого подключения по имени.

    .DESCRIPTION
    Идемпотентна: на стенде, где администратор уже есть, это одно COM-подключение.

    Заводить его нужно РАНЬШЕ первого запуска предприятия. Конфигурация может при
    старте сама завести пользователей: так, доработка регламентных заданий создаёт
    администраторов со случайными паролями, и база, где к этому моменту нет своего
    администратора, запирается навсегда — войти в неё больше нечем.

    COM выполняется в ДОЧЕРНЕМ процессе: соединение держит файл базы, пока жив
    процесс, а следом идёт конфигуратор с монопольным доступом. Освобождение COM
    в том же процессе зависит от сборщика мусора и не гарантировано.

    .OUTPUTS
    Строка исхода: created или exists.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $script = Get-WorkflowStandAdministratorScript -BasePath $BasePath
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(& powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1 |
            ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $outcome = $output | Where-Object { $_ -like "stand-administrator:*" } | Select-Object -Last 1
    if ($exitCode -ne 0 -or -not $outcome) {
        throw "Администратор стенда не заведён ($BasePath): $($output -join ' | ')"
    }
    return $outcome.Substring("stand-administrator:".Length)
}

function Get-WorkflowSourceStamp {
    <#
    .SYNOPSIS
    Точный слепок исходников компонентов: что именно поедет в базу.

    .DESCRIPTION
    Отметка содержимого базы отвечает на вопрос «в базе уже лежит то, что сейчас в
    рабочей копии?». Ответ решает, ПРОПУСТИТЬ ли перезаливку, поэтому ошибка здесь
    не падает — она молча оставляет старую конфигурацию, а фаза сообщает «зелено».

    Отсюда два требования, и оба неочевидны.

    Первое: коммита НЕДОСТАТОЧНО. С грязным деревом HEAD совпадает, а исходники уже
    другие. Списка изменённых путей тоже недостаточно: правку файла туда-обратно
    (и любую вторую правку того же файла) он не отличает. Поэтому слепок строится
    из СОДЕРЖИМОГО: дерево коммита на каталог компонента плюс хеш каждого файла,
    который в рабочей копии отличается от коммита. Двоичные файлы (Ext/*.bin) так
    учитываются наравне с текстом — в git diff они прошли бы как «Binary files
    differ», то есть одинаково при любом содержимом.

    Второе: границы берутся из Get-WorkflowComponentDirectories — того же места,
    откуда их берёт загрузчик. Правка вне этих каталогов (документация, скрипты)
    в базу попасть не может, и заставлять из-за неё перезаливать серверную базу
    незачем. Но если этот список разойдётся с загрузчиком, изменение компонента
    останется незамеченным — молча. Поэтому источник ровно один.

    Переименования отключены (--no-renames): запись вида «R old -> new» пришлось бы
    разбирать, а с отключением каждая строка — обычный путь.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $directories = @(
        Get-WorkflowComponentDirectories -Config $Config |
            ForEach-Object { $_.sourceDir } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    if ($directories.Count -eq 0) {
        throw "Configuration defines no component source directories, so the infobase content stamp cannot be computed."
    }

    $parts = @()
    foreach ($directory in $directories) {
        $tree = Invoke-WorkflowGit -RepositoryRoot $RepositoryRoot -Arguments @("rev-parse", "HEAD:$directory") -AllowFailure
        # Каталога нет в коммите (новое расширение, свежий репозиторий) — это
        # состояние тоже часть слепка, а не повод упасть.
        $treeHash = if ($tree.ExitCode -eq 0) {
            [string]($tree.Output | Select-Object -First 1)
        }
        else {
            "absent"
        }
        $parts += "tree $directory $treeHash"
    }

    $status = Invoke-WorkflowGit -RepositoryRoot $RepositoryRoot -Arguments (
        @(
            "-c", "core.quotePath=false",
            "status", "--porcelain=v1", "--untracked-files=all", "--no-renames", "--"
        ) + $directories
    )
    $deviations = @()
    foreach ($line in @($status.Output)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        # Первые два символа — состояние индекса и рабочего дерева, дальше пробел.
        # Кавычки снимаются тем же разбором, что в отпечатке и платформенном
        # влиянии. Здесь их не снимали вовсе: путь с пробелом уходил в Join-Path
        # вместе с кавычкой, Test-Path отвечал «нет», и лежащий на месте файл
        # попадал в отклонения как исчезнувший.
        $path = ConvertFrom-WorkflowGitPath -Path ([string]$line).Substring(3)
        if (-not $path) {
            continue
        }
        $fullPath = Join-Path $RepositoryRoot $path
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $hash = Invoke-WorkflowGit -RepositoryRoot $RepositoryRoot -Arguments @("hash-object", "--", $path)
            $deviations += "file $path $([string]($hash.Output | Select-Object -First 1))"
        }
        else {
            $deviations += "gone $path"
        }
    }
    # Порядок вывода git зависит от регистра и локали, слепок зависеть не должен.
    $parts += @($deviations | Sort-Object)

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($parts -join "`n"))
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
}

function Get-WorkflowForeignBaseOwner {
    <#
    .SYNOPSIS
    Чьей рабочей копии принадлежит каталог базы, если копия эта — НЕ наша.

    .DESCRIPTION
    Уборка судит о нужности базы по веткам СВОЕГО репозитория. Пока рабочая копия
    одна, этого хватает. Две копии одного проекта на машине — и база чужой ветки
    выглядит осиротевшей: такой ветки в этом клоне нет и не будет. 20.09.2026 план
    уборки предложил удалить базы работающего пилота из соседнего клона, и от
    потери их отделяло только то, что план посмотрели глазами.

    Метка владельца лежит в каталоге базы ровно для этого: файловую базу видят обе
    копии, и она называет ту, что базу завела. Здесь метка читается и отвечает на
    один вопрос — «наша ли она».

    Чужой считается копия, которая СУЩЕСТВУЕТ. Метка удалённого клона никого не
    защищает: база после него осталась мусором, ради которого уборку и заводили.

    Возвращает путь чужой рабочей копии или пустую строку. Пустая строка означает
    «метки нет, метка битая, метка о нас самих или её копии больше нет» — то есть
    решать судьбу каталога по веткам, как раньше.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $markerPath = Join-Path ([System.IO.Path]::GetFullPath($Path)) ".onec-workflow-owner.json"
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return ""
    }
    try {
        $marker = Get-Content -Raw -LiteralPath $markerPath -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        # Битая метка читается как отсутствующая: она ведёт к решению по веткам, а
        # не к удалению того, о чём ничего не известно.
        return ""
    }

    $owner = [string](Get-WorkflowSettingValue -Object $marker -Name "worktree" -Default "")
    if (-not $owner) {
        return ""
    }
    if (-not (Test-Path -LiteralPath $owner -PathType Container)) {
        return ""
    }

    $ownerFull = [System.IO.Path]::GetFullPath($owner).TrimEnd([char]92)
    $ourFull = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char]92)
    if ([string]::Equals($ownerFull, $ourFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ""
    }
    return $ownerFull
}

function Get-WorkflowInfoBaseStatePath {
    <#
    .SYNOPSIS
    Где лежит отметка базы: владелец и содержимое.

    .DESCRIPTION
    У файловой базы отметка лежит В КАТАЛОГЕ базы — тем же файлом
    .onec-workflow-owner.json, что и раньше. Это принципиально: две рабочие копии,
    разрешившиеся в один путь, обязаны увидеть отметку друг друга, а состояние,
    спрятанное в каталоге репозитория, второй копии не видно.

    У серверной базы каталога нет, поэтому отметка кладётся рядом с профилем
    пользователя и адресуется устойчивым идентификатором базы. Область та же —
    машина: серверную базу с одного компьютера ведёт один комплект. Захват той же
    базы с ДРУГОЙ машины так не ловится; это принято сознательно — иначе пришлось бы
    писать признак внутрь самой базы, то есть запускать платформу ради проверки.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$InfoBase
    )

    if ([string]$InfoBase.Kind -ne "server") {
        return (Join-Path ([System.IO.Path]::GetFullPath([string]$InfoBase.Path)) ".onec-workflow-owner.json")
    }

    $root = [string]$env:LOCALAPPDATA
    if (-not $root) {
        $root = [System.IO.Path]::GetTempPath()
    }
    $slug = ConvertTo-WorkflowSlug -Value "$([string]$InfoBase.Server)-$([string]$InfoBase.Ref)"
    $hash = Get-WorkflowStableHash -Value ([string]$InfoBase.Id)
    return (Join-Path (Join-Path $root "onec-workflow\infobases") "$slug-$hash.json")
}

function Get-WorkflowInfoBaseState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InfoBase
    )

    $path = Get-WorkflowInfoBaseStatePath -InfoBase $InfoBase
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        return (Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        # Битую отметку читаем как отсутствующую: это ведёт к перезаливке, то есть
        # к лишней работе, а не к работе над неизвестным содержимым.
        return $null
    }
}

function Set-WorkflowInfoBaseState {
    <#
    .SYNOPSIS
    Записывает, ЧТО сейчас лежит в базе. Вызывается только после успешной загрузки.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$InfoBase,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [Parameter(Mandatory = $true)]
        [string]$WorktreePath,

        [string]$Commit = "",

        [string]$SourceStamp = "",

        # Загрузка выполнялась без обновления конфигурации базы данных.
        [switch]$CompileOnly
    )

    $path = Get-WorkflowInfoBaseStatePath -InfoBase $InfoBase
    $directory = Split-Path $path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $state = [pscustomobject]@{
        project = [string]$Config.project
        branch = $BranchName
        worktree = [System.IO.Path]::GetFullPath($WorktreePath)
        infoBase = [string]$InfoBase.Display
        commit = $Commit
        sourceStamp = $SourceStamp
        compileOnly = [bool]$CompileOnly
        updatedAt = [DateTimeOffset]::Now.ToString("o")
    }
    Write-WorkflowJson -Value $state -Path $path | Out-Null
    return $state
}

function Get-WorkflowInfoBaseReloadReason {
    <#
    .SYNOPSIS
    Почему базу нужно перезалить. Пустая причина — содержимое базы актуально.

    .DESCRIPTION
    Это и есть правило пропуска, ради которого заводилась отметка, поэтому оно
    устроено «отказ по умолчанию»: перезаливка НЕ нужна лишь тогда, когда отметка
    прочитана, принадлежит этой же рабочей копии и ветке, и слепок исходников
    совпадает. Любая неопределённость — отметки нет, она старого образца без
    слепка, её не удалось разобрать — трактуется как «нужно перезалить».

    Обратный порядок («перезаливать, только если видно расхождение») выглядит так
    же, но ошибается в опасную сторону: неизвестное состояние базы он принимает за
    актуальное.

    Чужая РАБОЧАЯ КОПИЯ — не причина для перезаливки, а конфликт: молча затирать
    базу соседа нельзя. Такой случай возвращается с признаком Conflict, и решение
    принимает вызывающий. Другая ВЕТКА той же копии конфликтом не считается:
    человеку выделяют несколько баз, но не по базе на задачу, и переключение
    ветки — обычный ход работы, а не столкновение двух агентов.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$InfoBase,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [Parameter(Mandatory = $true)]
        [string]$WorktreePath,

        [string]$SourceStamp = "",

        # Вызывающему нужна база с обновлённой структурой БД. Совпадения исходников
        # для этого мало: предыдущая загрузка могла идти в режиме -CompileOnly, и
        # тогда конфигурация в базе есть, а базы данных под неё нет.
        [switch]$RequireDatabaseUpdate
    )

    $result = [pscustomobject]@{
        Reload = $true
        Conflict = $false
        Reason = ""
        State = $null
    }

    $state = Get-WorkflowInfoBaseState -InfoBase $InfoBase
    $result.State = $state
    if ($null -eq $state) {
        $result.Reason = "the infobase carries no workflow stamp, so its content is unknown"
        return $result
    }

    $worktree = [System.IO.Path]::GetFullPath($WorktreePath)
    if ([string]$state.worktree -and [string]$state.worktree -ne $worktree) {
        $result.Conflict = $true
        $result.Reason = (
            "the infobase belongs to worktree '$([string]$state.worktree)' " +
            "(branch '$([string]$state.branch)'), current worktree is '$worktree'"
        )
        return $result
    }
    if ([string]$state.branch -and [string]$state.branch -ne $BranchName) {
        # Та же рабочая копия, другая ветка — это смена задачи, а не захват базы.
        # Баз на человека несколько, но не по одной на задачу: считать такое
        # конфликтом значило бы требовать -AdoptResources на каждом переключении
        # ветки. Содержимое базы при этом чужое, поэтому она перезаливается.
        $result.Reason = "the infobase holds branch '$([string]$state.branch)', current branch is '$BranchName'"
        return $result
    }

    $stamp = $SourceStamp
    if (-not $stamp) {
        $stamp = Get-WorkflowSourceStamp -RepositoryRoot $RepositoryRoot -Config $Config
    }
    $recorded = if ($null -ne $state.PSObject.Properties["sourceStamp"]) {
        [string]$state.sourceStamp
    }
    else {
        ""
    }
    if (-not $recorded) {
        $result.Reason = "the stamp predates content tracking, so the loaded sources are unknown"
        return $result
    }
    if ($recorded -ne $stamp) {
        $result.Reason = "component sources changed since the last load"
        return $result
    }
    if ($RequireDatabaseUpdate) {
        $loadedCompileOnly = (
            $null -eq $state.PSObject.Properties["compileOnly"] -or
            [bool]$state.compileOnly
        )
        if ($loadedCompileOnly) {
            $result.Reason = "the last load skipped the database update"
            return $result
        }
    }

    $result.Reload = $false
    $result.Reason = ""
    return $result
}

function Get-WorkflowBuiltBaseKey {
    <#
    .SYNOPSIS
    Ключ кэша собранной базы: от чего её содержимое зависит.

    .DESCRIPTION
    В ключ входит ВСЁ, что может изменить собранную базу: отпечаток исходников в
    своей области, версия платформы, версия навыков и вид базы. Забытая
    составляющая опаснее лишней: лишняя стоит пересборки, забытая отдаёт прогону
    базу от других исходников, и проверка подтвердит не тот код.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [string]$Fingerprint,

        [string[]]$Parts = @()
    )

    $payload = @($Kind, $Fingerprint) + @($Parts | ForEach-Object { [string]$_ })
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($payload -join "|"))
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant().Substring(0, 32)
}

function Compare-WorkflowFingerprintEntries {
    <#
    .SYNOPSIS
    Чем нынешние пары «путь — хеш» отличаются от сохранённых рядом с базой в кэше.

    .DESCRIPTION
    Промах кэша печатался как «базы для этих исходников в кэше нет — собираем», и
    объяснение на этом заканчивалось. Вопрос «почему опять пересборка» пришлось
    задавать человеку трижды, а ответом оказался скрипт гейта: он входил в
    отпечаток, хотя в базу не попадает.

    Сравнение лишних пересборок не чинит. Оно делает их ВИДИМЫМИ — список причин
    печатается там же, где возникает вопрос.
    #>
    param(
        [object]$Current = $null,

        [object]$Reference = $null,

        [int]$Limit = 5
    )

    if ($null -eq $Current -or $null -eq $Reference) {
        return [pscustomobject]@{
            Compared = $false
            Added = @()
            Removed = @()
            Changed = @()
            Total = 0
        }
    }

    $added = New-Object System.Collections.ArrayList
    $removed = New-Object System.Collections.ArrayList
    $changed = New-Object System.Collections.ArrayList

    foreach ($path in @($Current.Keys)) {
        if (-not $Reference.ContainsKey($path)) {
            [void]$added.Add([string]$path)
            continue
        }
        if ([string]$Reference[$path] -ne [string]$Current[$path]) {
            [void]$changed.Add([string]$path)
        }
    }
    foreach ($path in @($Reference.Keys)) {
        if (-not $Current.ContainsKey($path)) {
            [void]$removed.Add([string]$path)
        }
    }

    $take = {
        param([object]$Values)
        @(@($Values) | Sort-Object -CaseSensitive | Select-Object -First $Limit)
    }

    return [pscustomobject]@{
        Compared = $true
        Added = (& $take $added)
        Removed = (& $take $removed)
        Changed = (& $take $changed)
        Total = ($added.Count + $removed.Count + $changed.Count)
    }
}

function Get-WorkflowBuiltBaseCacheRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Kind
    )

    return (Join-Path (Join-Path $StateDirectory "built-bases") $Kind)
}

function Get-WorkflowBuiltBaseEntries {
    <#
    .SYNOPSIS
    Пары «путь — хеш» последней базы, сохранённой в кэше этого вида.

    .DESCRIPTION
    Берётся самая свежая запись, а не запись под нынешним ключом: его в кэше как
    раз и нет — потому и промах. Сравнивать имеет смысл с тем, что собирали в
    прошлый раз.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Kind
    )

    $root = Get-WorkflowBuiltBaseCacheRoot -StateDirectory $StateDirectory -Kind $Kind
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return $null
    }

    foreach ($directory in @(
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTimeUtc -Descending)) {
        $manifest = Join-Path $directory.FullName "fingerprint-entries.json"
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
            continue
        }
        try {
            $parsed = Get-Content -Raw -LiteralPath $manifest -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            continue
        }
        $entries = @{}
        foreach ($property in @($parsed.PSObject.Properties)) {
            $entries[[string]$property.Name] = [string]$property.Value
        }
        return $entries
    }

    return $null
}

function Restore-WorkflowBuiltBase {
    <#
    .SYNOPSIS
    Кладёт собранную базу из кэша на место прогона. Ложь — в кэше её нет.

    .DESCRIPTION
    Возвращается КОПИЯ, а не сама запись кэша: тесты пишут в базу, и прогон,
    работающий прямо в кэше, испортил бы его для следующих. Копия файла данных
    стоит долей секунды против минут пересборки.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $entry = Join-Path (Get-WorkflowBuiltBaseCacheRoot -StateDirectory $StateDirectory -Kind $Kind) $Key
    if (-not (Test-Path -LiteralPath (Join-Path $entry "1Cv8.1CD") -PathType Leaf)) {
        return $false
    }
    # Описание записи остаётся в кэше и в стенд не переносится: это документ о
    # записи, а не часть базы.
    Copy-WorkflowStandSnapshot `
        -SourcePath $entry `
        -TargetPath $TargetPath `
        -ExcludeNames @("cache-entry.json") | Out-Null
    # Отметка времени обновляется, чтобы уборка судила по последнему
    # ИСПОЛЬЗОВАНИЮ, а не по созданию: запись, которую берут каждый прогон, не
    # должна вытесняться той, что собрана позже и никому не понадобилась.
    try {
        [System.IO.Directory]::SetLastWriteTimeUtc($entry, [datetime]::UtcNow)
    }
    catch {
        # Отметка — удобство уборки, а не условие работы.
    }
    return $true
}

function Save-WorkflowBuiltBase {
    <#
    .SYNOPSIS
    Кладёт собранную базу в кэш под ключом и подметает старые записи.

    .DESCRIPTION
    Запись собирается во временном каталоге и переносится готовой. Прерванное
    копирование иначе оставило бы обрезанный файл данных, неотличимый от целого:
    следующий прогон взял бы его как готовую базу и упал бы далеко от причины.

    Хранится ограниченное число записей: база весит десятки мегабайт, и кэш без
    предела — это тот же мусор, только незаметный.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [int]$KeepCount = 2,

        [hashtable]$Stamp = $null,

        # Пары «путь — хеш», по которым посчитан ключ. Лежат рядом с базой, чтобы
        # следующий промах кэша мог назвать причину, а не только факт.
        [object]$Entries = $null
    )

    $root = Get-WorkflowBuiltBaseCacheRoot -StateDirectory $StateDirectory -Kind $Kind
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    $entry = Join-Path $root $Key
    $staging = "$entry.partial"

    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    Copy-WorkflowStandSnapshot -SourcePath $SourcePath -TargetPath $staging | Out-Null
    $description = if ($null -ne $Stamp) { $Stamp } else { @{} }
    $description["kind"] = $Kind
    $description["key"] = $Key
    $description["savedAt"] = (Get-Date).ToString("o")
    Set-Content `
        -LiteralPath (Join-Path $staging "cache-entry.json") `
        -Value (ConvertTo-Json -InputObject ([pscustomobject]$description) -Depth 5) `
        -Encoding UTF8
    if ($null -ne $Entries) {
        $flat = [ordered]@{}
        foreach ($path in @(@($Entries.Keys) | Sort-Object -CaseSensitive)) {
            $flat[[string]$path] = [string]$Entries[$path]
        }
        Set-Content `
            -LiteralPath (Join-Path $staging "fingerprint-entries.json") `
            -Value (ConvertTo-Json -InputObject ([pscustomobject]$flat) -Depth 3) `
            -Encoding UTF8
    }

    if (Test-Path -LiteralPath $entry) {
        Remove-Item -LiteralPath $entry -Recurse -Force -ErrorAction SilentlyContinue
    }
    Move-Item -LiteralPath $staging -Destination $entry -Force

    $stale = @(
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTimeUtc -Descending |
            Select-Object -Skip ([math]::Max($KeepCount, 1))
    )
    foreach ($directory in $stale) {
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $entry
}

function Copy-WorkflowStandSnapshot {
    <#
    .SYNOPSIS
    Снимок стенда для кэша: файл данных И метки, которые положил рядом проект.

    .DESCRIPTION
    Стенд — это не только `1Cv8.1CD`. Рядом с базой проект оставляет метки о её
    состоянии: сид, создавший пользователей ИБ, кладёт признак «подключение обязано
    аутентифицироваться». Снимок без такой метки выглядит целым, база открывается,
    но запуск идёт БЕЗ имени пользователя — и платформа либо просит его в диалоге
    (прогон висит до таймаута), либо молча завершается. Обе картины уводят от
    причины: падает не стенд, а первый тест, которому не хватило входа.

    Не переносится всё, что platform создаёт сама: файлы `1Cv8*` — это журнал,
    блокировки и временные данные конкретного процесса. Блокировка завершившегося
    процесса помешала бы открыть копию, а журнал унёс бы в стенд записи чужого
    прогона.

    Каталоги не переносятся вовсе: журнал регистрации и временные данные — всё,
    что там лежит.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath,

        [string[]]$ExcludeNames = @()
    )

    $source = [System.IO.Path]::GetFullPath($SourcePath)
    $target = [System.IO.Path]::GetFullPath($TargetPath)
    if (-not (Test-Path -LiteralPath (Join-Path $source "1Cv8.1CD") -PathType Leaf)) {
        throw "Not a file information base, nothing to copy: $source"
    }
    if ($target -eq $source) {
        throw "Refusing to copy an information base onto itself: $source"
    }

    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    [System.IO.Directory]::CreateDirectory($target) | Out-Null

    foreach ($file in @(Get-ChildItem -LiteralPath $source -File)) {
        if ($file.Name -eq "1Cv8.1CD") {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $target $file.Name) -Force
            continue
        }
        if ($file.Name -like "1Cv8*") {
            continue
        }
        if (@($ExcludeNames) -contains $file.Name) {
            continue
        }
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $target $file.Name) -Force
    }
    return $target
}

function Get-WorkflowStandBuildPlan {
    <#
    .SYNOPSIS
    Что делать со стендом: копировать проверочную базу, запускать сборку, или ни
    того, ни другого.

    .DESCRIPTION
    Решение вынесено из скрипта фазы, потому что ошибиться в нём НЕЗАМЕТНО. Копия
    проверочной базы кладётся поверх каталога стенда: если её сделать после того,
    как стенд взят из кэша, стенд молча заменится базой без оверлея, расширений и
    данных. База при этом открывается, и падает не «сборка стенда», а первый тест,
    которому чего-то не хватило, — искать причину приходится с другого конца.

    Правила ровно три:
      стенд восстановлен       — не копировать и не собирать, он готов;
      адаптер умеет догружать  — копировать базу и догрузить оверлей;
      не умеет                 — пересоздать и собрать полной загрузкой.
    #>
    param(
        [bool]$StandRestored,

        [bool]$CanReuseVerificationBase
    )

    if ($StandRestored) {
        return [pscustomobject]@{
            CopyVerificationBase = $false
            RunInitializer = $false
            SkipConfigurationLoad = $true
            Recreate = $false
        }
    }
    if ($CanReuseVerificationBase) {
        return [pscustomobject]@{
            CopyVerificationBase = $true
            RunInitializer = $true
            SkipConfigurationLoad = $true
            Recreate = $false
        }
    }
    return [pscustomobject]@{
        CopyVerificationBase = $false
        RunInitializer = $true
        SkipConfigurationLoad = $false
        Recreate = $true
    }
}

function Copy-WorkflowFileInfoBase {
    <#
    .SYNOPSIS
    Делает копию файловой базы: та же конфигурация, та же структура БД.

    .DESCRIPTION
    Стенд для тестов несёт ту же конфигурацию, что и проверочная база, плюс
    тестовый оверлей. Собирать его отдельной полной загрузкой XML — значит платить
    за разбор всей конфигурации второй раз за прогон. На большой конфигурации это
    самая дорогая строка фазы, причём удвоенная.

    Копия снимает обе части: и разбор XML, и обновление структуры БД. Оверлей после
    неё догружается частичной загрузкой — это единицы файлов.

    Копируется ТОЛЬКО файл данных. Журнал регистрации и файлы блокировок к
    содержимому базы не относятся: журнал унёс бы в стенд записи чужого прогона, а
    блокировка от процесса, который уже завершился, помешала бы открыть копию.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $source = [System.IO.Path]::GetFullPath($SourcePath)
    $target = [System.IO.Path]::GetFullPath($TargetPath)
    $sourceData = Join-Path $source "1Cv8.1CD"
    if (-not (Test-Path -LiteralPath $sourceData -PathType Leaf)) {
        throw "Not a file information base, nothing to copy: $source"
    }
    if ($target -eq $source) {
        throw "Refusing to copy an information base onto itself: $source"
    }

    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    [System.IO.Directory]::CreateDirectory($target) | Out-Null
    Copy-Item -LiteralPath $sourceData -Destination (Join-Path $target "1Cv8.1CD") -Force
    return $target
}

function Test-WorkflowScriptSupportsParameter {
    <#
    .SYNOPSIS
    Принимает ли скрипт такой параметр.

    .DESCRIPTION
    Расширения договора адаптеров вводятся необязательными: проекты обновляют свои
    скрипты не одновременно с комплектом. Передать неизвестный ключ — значит уронить
    фазу на проекте, который ничего плохого не сделал, поэтому наличие ключа
    проверяется, а при его отсутствии остаётся прежний путь.

    Разбор идёт по AST, без выполнения: запускать чужой скрипт ради того, чтобы
    узнать его параметры, недопустимо.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$ParameterName
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        return $false
    }
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errors)
    if ($null -eq $ast -or $null -eq $ast.ParamBlock) {
        return $false
    }
    foreach ($parameter in @($ast.ParamBlock.Parameters)) {
        if ([string]$parameter.Name.VariablePath.UserPath -eq $ParameterName) {
            return $true
        }
    }
    return $false
}

function Get-WorkflowStandBasePath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [Parameter(Mandatory = $true)]
        [ValidateSet("functional", "functional-ui")]
        [string]$Kind
    )

    $settings = Get-WorkflowParallelSettings -Config $Config
    Assert-WorkflowBaseRoot -Root $settings.testBaseRoot
    $leaf = "$([string]$Config.project)-$Kind"
    if (-not $settings.perBranchStands) {
        return [System.IO.Path]::GetFullPath((Join-Path $settings.testBaseRoot $leaf))
    }
    $branchLeaf = Get-WorkflowStandSlug -BranchName $BranchName
    return [System.IO.Path]::GetFullPath(
        (Join-Path (Join-Path $settings.testBaseRoot $leaf) $branchLeaf)
    )
}

function Get-WorkflowStandAppName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [Parameter(Mandatory = $true)]
        [string]$DefaultAppName
    )

    $settings = Get-WorkflowParallelSettings -Config $Config
    if (-not $settings.perBranchStands) {
        return $DefaultAppName
    }
    return "$DefaultAppName-$(Get-WorkflowStandSlug -BranchName $BranchName -MaxLength 24)"
}

function Get-WorkflowStandPortRange {
    <#
    .SYNOPSIS
    Возвращает диапазон портов, выделенный ветке под конкретный вид стенда.

    .DESCRIPTION
    Слот ветки делится между видами стендов, чтобы поиск свободного порта для
    Web UI не мог отобрать порт у HTTP-стенда той же ветки. При portsPerBranch=4
    получается по два порта на вид: один рабочий и один запасной.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [Parameter(Mandatory = $true)]
        [ValidateSet("web-ui", "http")]
        [string]$Kind
    )

    $settings = Get-WorkflowParallelSettings -Config $Config
    if (-not $settings.perBranchStands) {
        return [pscustomobject]@{
            Start = $settings.portRangeStart
            End = $settings.portRangeEnd
        }
    }

    # Деление гарантированно даёт >= 1: Get-WorkflowParallelSettings отвергает
    # portsPerBranch меньше числа видов стендов.
    $kindCount = 2
    $portsPerKind = [int][Math]::Floor($settings.portsPerBranch / $kindCount)
    $kindIndex = switch ($Kind) {
        "web-ui" { 0 }
        "http" { 1 }
    }
    $slot = Get-WorkflowBranchSlot -BranchName $BranchName -SlotCount $settings.slotCount
    $slotStart = $settings.portRangeStart + ($slot * $settings.portsPerBranch)
    $start = $slotStart + ($kindIndex * $portsPerKind)
    return [pscustomobject]@{
        Start = $start
        End = $start + $portsPerKind - 1
    }
}

function Get-WorkflowStandPort {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [Parameter(Mandatory = $true)]
        [ValidateSet("web-ui", "http")]
        [string]$Kind,

        [int]$FallbackPort = 0
    )

    $settings = Get-WorkflowParallelSettings -Config $Config
    if (-not $settings.perBranchStands -and $FallbackPort -gt 0) {
        return $FallbackPort
    }
    return (Get-WorkflowStandPortRange -Config $Config -BranchName $BranchName -Kind $Kind).Start
}

function Assert-WorkflowResourceOwner {
    <#
    .SYNOPSIS
    Закрепляет базу или стенд за конкретной рабочей копией и веткой.

    .DESCRIPTION
    Пути ресурсов выводятся из СЛАГА ветки, а слаг не взаимно однозначен: имена
    `feature/AB-1` и `feature-AB-1` дают один и тот же путь. Отдельные клоны
    репозитория с одинаковой веткой тоже приводят к одному пути (worktree такое
    запрещает, клоны — нет). В обоих случаях два агента начали бы работать в одной
    базе, молча уничтожая работу друг друга.

    Функция сохранена ради адаптеров стендов: их пишут проекты, они вызывают её по
    имени, и убрать её значило бы сломать каждый такой скрипт при обновлении
    комплекта.

    Реализация ведёт ту же отметку, что и Get-WorkflowInfoBaseState. Это
    существенно: отметка несёт не только владельца, но и слепок загруженного
    содержимого. Отдельный писатель того же файла затирал бы слепок при каждом
    закреплении, и правило «в базе уже это содержимое» никогда бы не срабатывало —
    молча, лишней работой, а не отказом.

    .PARAMETER Adopt
    Передать ресурс текущей рабочей копии, перезаписав метку владельца.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [Parameter(Mandatory = $true)]
        [string]$WorktreePath,

        [string]$Description = "resource",

        [switch]$Adopt,

        # Ничего не записывать (для -WhatIf у вызывающего): проверка выполняется,
        # метка не обновляется.
        [switch]$WhatIfMode
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        # Ресурса ещё нет — метку поставит тот, кто его создаст.
        return
    }

    $infoBase = ConvertTo-WorkflowInfoBase -BasePath $fullPath -Caller "Assert-WorkflowResourceOwner"
    $current = Get-WorkflowInfoBaseState -InfoBase $infoBase
    $worktree = [System.IO.Path]::GetFullPath($WorktreePath)

    if ($null -ne $current -and -not $Adopt) {
        $sameBranch = [string]$current.branch -eq $BranchName
        $sameWorktree = [string]$current.worktree -eq $worktree
        if (-not ($sameBranch -and $sameWorktree)) {
            throw (
                "The $Description at '$fullPath' already belongs to branch " +
                "'$($current.branch)' from worktree '$($current.worktree)'. " +
                "Current branch is '$BranchName' from '$worktree'. " +
                "Two working copies resolved to the same path, so continuing would " +
                "destroy the other one's state. Fix it in one of these ways: use a " +
                "branch name whose slug differs, pass an explicit -BasePath, or re-run " +
                "the script that reported this error with -AdoptResources to take the " +
                "$Description over."
            )
        }
    }

    if ($WhatIfMode) {
        return
    }

    # Слепок содержимого сохраняется: закрепление владельца отвечает на вопрос
    # «чей ресурс», а не «что в нём лежит», и стирать ответ на второй вопрос оно
    # не вправе. Если отметка принадлежала другой ветке и её забирают через
    # -Adopt, слепок сбрасывается: содержимое базы после этого неизвестно.
    $keepContent = $null -ne $current -and [string]$current.branch -eq $BranchName
    Set-WorkflowInfoBaseState `
        -InfoBase $infoBase `
        -Config $Config `
        -BranchName $BranchName `
        -WorktreePath $worktree `
        -Commit $(if ($keepContent) { [string]$current.commit } else { "" }) `
        -SourceStamp $(if ($keepContent) { [string]$current.sourceStamp } else { "" }) `
        -CompileOnly:$(if ($keepContent) { [bool]$current.compileOnly } else { $false }) | Out-Null
}

function Get-WorkflowStandPortStatePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $stateDirectory = Resolve-WorkflowPath -RepositoryRoot $RepositoryRoot -Path ([string]$Config.localStateDir)
    return Join-Path $stateDirectory "stand-ports.json"
}

function Save-WorkflowStandPort {
    <#
    .SYNOPSIS
    Запоминает ФАКТИЧЕСКИ занятый стендом порт.

    .DESCRIPTION
    Детерминированный порт — только начало подпредела. Если он был занят и подбор
    сдвинулся, автономный запуск smoke или повторная публикация без этого знания
    ушли бы на неверный порт. Значение локальное (localStateDir), в Git не попадает.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [ValidateSet("web-ui", "http")]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [string]$BranchName,

        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $path = Get-WorkflowStandPortStatePath -RepositoryRoot $RepositoryRoot -Config $Config
    $state = if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            $null
        }
    }
    else {
        $null
    }

    $entries = @{}
    if ($null -ne $state) {
        foreach ($property in $state.PSObject.Properties) {
            $entries[$property.Name] = $property.Value
        }
    }
    $entries["$Kind|$BranchName"] = $Port
    Write-WorkflowJson -Value ([pscustomobject]$entries) -Path $path | Out-Null
}

function Get-WorkflowSavedStandPort {
    <#
    .SYNOPSIS
    Возвращает ранее сохранённый порт стенда или 0, если его нет.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [ValidateSet("web-ui", "http")]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    $path = Get-WorkflowStandPortStatePath -RepositoryRoot $RepositoryRoot -Config $Config
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return 0
    }
    try {
        $state = Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return 0
    }
    $property = $state.PSObject.Properties["$Kind|$BranchName"]
    if ($null -eq $property) {
        return 0
    }
    return [int]$property.Value
}

function Get-WorkflowSavedStandPortsForBranch {
    <#
    .SYNOPSIS
    Возвращает все зарегистрированные локальные порты стендов ветки.

    .DESCRIPTION
    Проектный адаптер публикации Web UI может использовать либо слот web-ui,
    либо общий HTTP-стенд. Проверка явного адреса инструкции поэтому не должна
    угадывать вид стенда: она сверяет порт со всеми записями текущей ветки.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    $path = Get-WorkflowStandPortStatePath -RepositoryRoot $RepositoryRoot -Config $Config
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }
    try {
        $state = Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return @()
    }

    $suffix = "|$BranchName"
    return @(
        $state.PSObject.Properties |
            Where-Object { $_.Name.EndsWith($suffix, [System.StringComparison]::Ordinal) } |
            ForEach-Object { [int]$_.Value } |
            Where-Object { $_ -gt 0 } |
            Sort-Object -Unique
    )
}

function Assert-WorkflowGuideLocalUrlMatchesBranch {
    <#
    .SYNOPSIS
    Не даёт снять инструкцию с забытой локальной публикации другой ветки.

    .DESCRIPTION
    Проверяются только loopback-адреса и только когда у текущей ветки уже есть
    зарегистрированная публикация. Внешний стенд, переданный явно, остаётся
    законным; пустой локальный реестр тоже не превращает -Url в тупик.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BranchName
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
        throw "Некорректный адрес публикации: $Url"
    }
    if (-not $uri.IsLoopback) {
        return
    }

    $savedPorts = @(Get-WorkflowSavedStandPortsForBranch `
        -RepositoryRoot $RepositoryRoot `
        -Config $Config `
        -BranchName $BranchName)
    if ($savedPorts.Count -eq 0 -or $savedPorts -contains $uri.Port) {
        return
    }

    $message = "Локальный -Url указывает на порт {0}, но для текущей ветки '{1}' " +
        "зарегистрирована публикация на порту {2}. Перепубликуйте стенд или " +
        "передайте его актуальный адрес; старый порт может обслуживать другую базу."
    throw ($message -f $uri.Port, $BranchName, ($savedPorts -join ", "))
}

function Get-WorkflowStaleBrowserProcesses {
    <#
    .SYNOPSIS
    Находит оставшиеся Chromium именно из локального web-test runtime.

    .DESCRIPTION
    Чужие Chrome/Chromium не затрагиваются. Функция диагностическая: вызывающий
    предупреждает о найденных процессах, а не завершает пользовательский браузер.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$BrowsersPath
    )

    if ($env:OS -ne "Windows_NT") {
        return @()
    }
    try {
        $root = [System.IO.Path]::GetFullPath($BrowsersPath).TrimEnd('\', '/')
        return @(
            Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
                Where-Object {
                    $_.Name -in @("chrome.exe", "chromium.exe") -and
                    $_.ExecutablePath -and
                    [System.IO.Path]::GetFullPath([string]$_.ExecutablePath).StartsWith(
                        $root + [System.IO.Path]::DirectorySeparatorChar,
                        [System.StringComparison]::OrdinalIgnoreCase)
                } |
                ForEach-Object {
                    [pscustomobject]@{
                        Id = [int]$_.ProcessId
                        Name = [string]$_.Name
                        ExecutablePath = [string]$_.ExecutablePath
                    }
                }
        )
    }
    catch {
        return @()
    }
}

function Test-WorkflowPortBusy {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    # Только слушающие сокеты. Без фильтра по состоянию исходящее соединение,
    # которому Windows выдал этот же локальный порт из эфемерного диапазона,
    # выглядел бы как занятый стенд.
    return @(
        Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    ).Count -gt 0
}

function Get-WorkflowForeignPortListener {
    <#
    .SYNOPSIS
    Чужой живой слушатель на порту, если он там есть.

    .DESCRIPTION
    Ждать освобождения порта осмысленно, только пока догорают сокеты НАШЕГО
    остановленного процесса: они исчезнут сами. Живой слушатель чужого процесса не
    исчезнет никогда, и ожидание превращается в чистую потерю времени — по
    полминуты на каждый прогон Web UI.

    Отличаем по исполняемому файлу, а не по идентификатору процесса: наш Apache
    перезапускается и меняет PID, а путь остаётся тот же.

    Слушатель без известного пути считается ЧУЖИМ. Ошибка в эту сторону стоит
    отказа от бессмысленного ожидания, ошибка в обратную — тех самых потерянных
    тридцати секунд.
    #>
    param(
        [object[]]$Listeners = @(),

        [string]$OwnExecutablePath = ""
    )

    $own = ([string]$OwnExecutablePath).Trim()
    foreach ($listener in @($Listeners | Where-Object { $null -ne $_ })) {
        $path = [string](Get-WorkflowSettingValue -Object $listener -Name "Path" -Default "")
        if ($own -and $path -and $path -eq $own) {
            continue
        }
        return $listener
    }
    return $null
}

function Get-WorkflowPortListeners {
    <#
    .SYNOPSIS
    Живые слушающие процессы на порту: идентификатор, имя и путь.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $result = New-Object System.Collections.ArrayList
    $connections = @(
        Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    )
    foreach ($connection in $connections) {
        $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            # Слушатель без живого процесса — это уже не слушатель: сокет догорает
            # и освободится сам.
            continue
        }
        [void]$result.Add([pscustomobject]@{
            ProcessId = $connection.OwningProcess
            Name = [string]$process.Name
            Path = [string]$process.Path
        })
    }
    return @($result)
}

function Wait-WorkflowPortFullyFree {
    <#
    .SYNOPSIS
    Ждёт, пока на порту не останется НИ ОДНОГО соединения в любом состоянии.

    .DESCRIPTION
    Определений «порт занят» здесь два, и они намеренно разные.

    `Test-WorkflowPortBusy` считает занятым только слушающий сокет: иначе исходящее
    соединение, которому Windows выдал этот же локальный порт из эфемерного
    диапазона, выглядело бы как поднятый стенд, и подбор порта отбрасывал бы
    исправные порты.

    Навык публикации из cc-1c-skills строже: он отказывается публиковать, если на
    порту есть любое соединение, включая TIME_WAIT — тот показывается как занятый
    процессом Idle с PID 0. Из-за расхождения публикация падала сразу после
    предыдущей фазы: сокет остановленного Apache ещё догорал в TIME_WAIT, наш
    подбор считал порт свободным, а навык — занятым.

    Раньше это не всплывало, потому что между фазами проходили минуты. С выборочным
    объёмом прогона фазы идут одна за другой, и зазор исчез.

    Возвращает $true, если порт освободился, и $false по истечении времени —
    вызывающий решает, ждать дальше, брать другой порт или падать.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [int]$TimeoutSeconds = 60,

        # Путь к нашему исполняемому файлу, который порт и держал. Пока слушает он,
        # ожидание осмысленно: процесс останавливается. Чужой слушатель порт не
        # отдаст, и ждать его — терять по полминуты на каждом прогоне.
        [string]$OwnExecutablePath = ""
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $connections = @(Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue)
        if ($connections.Count -eq 0) {
            return $true
        }

        $foreign = Get-WorkflowForeignPortListener `
            -Listeners (Get-WorkflowPortListeners -Port $Port) `
            -OwnExecutablePath $OwnExecutablePath
        if ($null -ne $foreign) {
            Write-Host ("Порт {0} держит чужой процесс {1} (PID {2}) — ожидание бессмысленно." -f `
                $Port, $foreign.Name, $foreign.ProcessId)
            if ($foreign.Path) {
                Write-Host "    $($foreign.Path)"
            }
            return $false
        }

        Start-Sleep -Milliseconds 500
    }
    return @(Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue).Count -eq 0
}

function Get-WorkflowFreePort {
    <#
    .SYNOPSIS
    Ищет свободный порт, не выходя за пределы выделенного слота.

    .DESCRIPTION
    Ограничение слотом принципиально: поиск «до конца диапазона» позволял ветке A
    занять порт, зарезервированный за веткой B, после чего сбой всплывал у B и
    выглядел необъяснимым. Лучше упасть в своём слоте с внятным сообщением.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [int]$StartPort,

        # Обязателен намеренно. Раньше при отсутствии значения поиск шёл до конца
        # общего диапазона, то есть безопасное поведение было опциональным, а
        # небезопасное — поведением по умолчанию.
        [Parameter(Mandatory = $true)]
        [int]$MaxPort
    )

    if ($MaxPort -lt $StartPort) {
        throw "Invalid port search bounds: $StartPort-$MaxPort."
    }

    $candidate = $StartPort
    while ($candidate -le $MaxPort) {
        if (-not (Test-WorkflowPortBusy -Port $candidate)) {
            return $candidate
        }
        $candidate++
    }
    throw (
        "No free port was found in the range $StartPort-$MaxPort reserved for this stand. " +
        "Either a stand of this branch is still running, or another branch hashed to the " +
        "same slot. Stop the running stand, or raise parallel.portsPerBranch / widen " +
        "parallel.portRangeStart..portRangeEnd. Do not reuse another branch's slot."
    )
}

function Invoke-WithWorkflowLock {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [int]$TimeoutSeconds = 0
    )

    $settings = Get-WorkflowParallelSettings -Config $Config
    if ($TimeoutSeconds -le 0) {
        $TimeoutSeconds = [int]$settings.lockTimeoutSeconds
    }
    # Межпроцессная блокировка на всю машину: разные worktree одного проекта
    # используют один и тот же mutex, поэтому подбор порта и публикация стенда
    # никогда не выполняются одновременно.
    $slug = ConvertTo-WorkflowSlug -Value "$([string]$Config.project)-$Name"
    $mutex = New-Object System.Threading.Mutex($false, "Global\onec-workflow-$slug")
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        catch [System.Threading.AbandonedMutexException] {
            # Предыдущий владелец завершился аварийно, блокировка перешла к нам.
            Write-Warning "Workflow lock '$Name' was abandoned by a crashed process and has been reclaimed."
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Could not acquire workflow lock '$Name' within $TimeoutSeconds seconds. Another worktree is publishing a stand for '$($Config.project)'."
        }
        return & $Action
    }
    finally {
        if ($acquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Get-ConfigurationVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigurationFile,

        [switch]$AllowEmpty
    )

    [xml]$xml = Get-Content -Raw -LiteralPath $ConfigurationFile -Encoding UTF8
    $node = $xml.SelectSingleNode("//*[local-name()='Configuration']/*[local-name()='Properties']/*[local-name()='Version']")
    if ($null -eq $node -or [string]::IsNullOrWhiteSpace($node.InnerText)) {
        if ($AllowEmpty) {
            return ""
        }
        throw "Configuration version was not found in $ConfigurationFile"
    }
    return $node.InnerText.Trim()
}

function Get-ConfigurationName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigurationFile
    )

    [xml]$xml = Get-Content -Raw -LiteralPath $ConfigurationFile -Encoding UTF8
    $node = $xml.SelectSingleNode("//*[local-name()='Configuration']/*[local-name()='Properties']/*[local-name()='Name']")
    if ($null -eq $node -or [string]::IsNullOrWhiteSpace($node.InnerText)) {
        throw "Configuration name was not found in $ConfigurationFile"
    }
    return $node.InnerText.Trim()
}

function Get-WorkflowExtensions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [switch]$AllowMissingOptional
    )

    if ($null -eq $Config.PSObject.Properties["extensions"] -or $null -eq $Config.extensions) {
        return @()
    }

    $extensions = @()
    $names = @{}
    $paths = @{}
    foreach ($definition in @($Config.extensions)) {
        $enabled = if ($null -ne $definition.PSObject.Properties["enabled"]) {
            [bool]$definition.enabled
        }
        else {
            $true
        }
        if (-not $enabled) {
            continue
        }

        $name = [string]$definition.name
        if ([string]::IsNullOrWhiteSpace($name) -or $name -notmatch '^[\p{L}][\p{L}\p{Nd}_]*$') {
            throw "Invalid extension name in .1c-workflow.json: '$name'."
        }
        $nameKey = $name.ToLowerInvariant()
        if ($names.ContainsKey($nameKey)) {
            throw "Duplicate extension name in .1c-workflow.json: '$name'."
        }
        $names[$nameKey] = $true
        if ($nameKey -eq (Get-WorkflowStandExecName).ToLowerInvariant()) {
            throw "Extension name '$name' is reserved by the workflow kit: it is the stand code executor, installed on test stands only and never shipped."
        }

        $sourceDir = ([string]$definition.sourceDir).Replace('\', '/').Trim('/')
        if ([string]::IsNullOrWhiteSpace($sourceDir)) {
            throw "Extension '$name' does not define sourceDir."
        }
        $sourcePath = Resolve-WorkflowPath -RepositoryRoot $RepositoryRoot -Path $sourceDir
        if (-not (Test-WorkflowPathUnderRoot -Path $sourcePath -Root $RepositoryRoot)) {
            throw "Extension '$name' sourceDir must stay inside the repository: $sourceDir"
        }
        $pathKey = $sourcePath.ToLowerInvariant()
        if ($paths.ContainsKey($pathKey)) {
            throw "Multiple extensions use the same sourceDir: $sourceDir"
        }
        $paths[$pathKey] = $true

        $required = if ($null -ne $definition.PSObject.Properties["required"]) {
            [bool]$definition.required
        }
        else {
            $true
        }
        $configurationFile = Join-Path $sourcePath "Configuration.xml"
        $present = Test-Path -LiteralPath $configurationFile -PathType Leaf
        if (-not $present -and ($required -or -not $AllowMissingOptional)) {
            throw "Required extension '$name' was not found: $configurationFile"
        }
        if (-not $present) {
            Write-Warning "Optional extension '$name' is absent and will be skipped: $configurationFile"
            continue
        }

        $xmlName = Get-ConfigurationName -ConfigurationFile $configurationFile
        if ($xmlName -ne $name) {
            throw "Extension manifest name '$name' does not match Configuration.xml name '$xmlName'."
        }
        $loadOrder = if ($null -ne $definition.PSObject.Properties["loadOrder"]) {
            [int]$definition.loadOrder
        }
        else {
            100
        }
        $artifactTemplate = if ($null -ne $definition.PSObject.Properties["artifactTemplate"] -and [string]$definition.artifactTemplate) {
            [string]$definition.artifactTemplate
        }
        elseif ($null -ne $Config.PSObject.Properties["artifacts"] -and [string]$Config.artifacts.cfeTemplate) {
            ([string]$Config.artifacts.cfeTemplate).Replace("{name}", $name)
        }
        else {
            "artifacts/cfe/${name}_{version}.cfe"
        }

        $extensions += [pscustomobject]@{
            name = $name
            sourceDir = $sourceDir
            sourcePath = $sourcePath
            configurationFile = $configurationFile
            required = $required
            loadOrder = $loadOrder
            artifactTemplate = $artifactTemplate
            version = Get-ConfigurationVersion -ConfigurationFile $configurationFile -AllowEmpty
        }
    }

    return @($extensions | Sort-Object loadOrder, name)
}

function Get-WorkflowComponentDirectories {
    <#
    .SYNOPSIS
    Каталоги всех компонентов 1С: основная конфигурация и включённые расширения.

    .DESCRIPTION
    Единственный ответ на вопрос «где лежат исходники компонентов». Раньше на него
    отвечали в двух местах по-разному, и это уже дало дефект: отбор целей прогона
    смотрел только `sourceDir`, поэтому в монорепозитории с расширениями правка формы
    расширения не попадала в проверку — прогон молча сообщал «изменённых объектов
    нет».

    Сведения берутся ИЗ КОНФИГУРАЦИИ и наличия файлов не требуют. Валидацию
    расширений выполняет Get-WorkflowExtensions, и она падает на отсутствующем
    обязательном расширении — для отбора целей это неверное поведение: выбор того,
    что прогонять, не должен зависеть от полноты рабочей копии.

    Раскладка каталогов значения не имеет: расширения могут лежать и в
    `extensions/<имя>/`, и прямо в корне рядом с основной конфигурацией. Процесс
    опирается на манифест, а не на соглашение о раскладке.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $components = @()
    $components += [pscustomobject]@{
        name = ""
        sourceDir = ([string]$Config.sourceDir).Replace('\', '/').Trim('/')
        isExtension = $false
    }

    if ($null -ne $Config.PSObject.Properties["extensions"] -and $null -ne $Config.extensions) {
        foreach ($definition in @($Config.extensions)) {
            $enabled = if ($null -ne $definition.PSObject.Properties["enabled"]) {
                [bool]$definition.enabled
            }
            else {
                $true
            }
            if (-not $enabled) {
                continue
            }
            $sourceDir = ([string]$definition.sourceDir).Replace('\', '/').Trim('/')
            if (-not $sourceDir) {
                continue
            }
            $components += [pscustomobject]@{
                name = [string]$definition.name
                sourceDir = $sourceDir
                isExtension = $true
            }
        }
    }

    # Более длинные пути первыми: если каталог расширения вложен в каталог основной
    # конфигурации, сопоставление по префиксу обязано выбрать расширение, а не
    # конфигурацию, иначе объект будет отнесён к чужому компоненту.
    return @($components | Sort-Object -Property @{ Expression = { $_.sourceDir.Length }; Descending = $true })
}

function Get-WorkflowComponentSourcePattern {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    # Валидация расширений сохранена: этот шаблон используется политикой, и там
    # молчаливое игнорирование битого манифеста недопустимо.
    $null = @(Get-WorkflowExtensions -RepositoryRoot $RepositoryRoot -Config $Config -AllowMissingOptional)
    $sourceDirs = @(Get-WorkflowComponentDirectories -Config $Config | ForEach-Object { $_.sourceDir })
    $escaped = @($sourceDirs | Sort-Object -Unique | ForEach-Object { [Regex]::Escape($_) })
    return "(?:$($escaped -join '|'))"
}

function Invoke-WorkflowApplyExtension {
    <#
    .SYNOPSIS
    Применяет расширение к базе данных: /UpdateDBCfg С ОБЛАСТЬЮ расширения.

    .DESCRIPTION
    Обновление без области действия трогает только основную конфигурацию.
    Расширение при этом остаётся ЗАГРУЖЕННЫМ, но НЕ ПРИМЕНЁННЫМ: платформа
    показывает его в списке расширений базы, а объекты из него в сеансе
    недоступны — ни обработки, ни общие модули, ни перехваты обработчиков
    аннотациями.

    Молчат при этом все: загрузка возвращает ноль, обновление возвращает ноль,
    проверка применимости не находит проблем. Со стороны это выглядит как
    несовместимость расширения с конфигурацией, а не как пропущенный шаг.

    Ключ `-UpdateDB` навыка db-load-xml здесь НЕ подходит: он добавляет
    `/UpdateDBCfg` без области, то есть ровно тот случай, что описан выше. Для
    расширений применение выполняет отдельный навык db-update с ключом
    -Extension.

    Область — ИМЯ расширения. Ключ -AllExtensions здесь НЕ работает: команда
    завершается успехом, а содержимое расширения в базу не попадает. Проверяется
    это по версии расширения в `ibcmd infobase config extension list`: у
    непринятого она пустая, у применённого — объявленная в самом расширении.

    Имя берётся ИЗ РАСШИРЕНИЯ, а не придумывается вызывающим. Ключ -Extension при
    загрузке задаёт лишь слот; после применения платформа подставляет настоящее
    имя, и расширение, загруженное под другим, по этому имени больше не
    находится — последующая настройка свойств падает с «расширение не найдено».
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Cc1CSkillsRoot,

        [Parameter(Mandatory = $true)]
        [string]$V8Executable,

        [string]$BasePath = "",

        [object]$InfoBase = $null,

        [Parameter(Mandatory = $true)]
        [string]$ExtensionName,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    $InfoBase = ConvertTo-WorkflowInfoBase `
        -InfoBase $InfoBase `
        -BasePath $BasePath `
        -Caller "Invoke-WorkflowApplyExtension"
    $updateScript = Resolve-CcSkillScript `
        -Cc1CSkillsRoot $Cc1CSkillsRoot `
        -SkillName "db-update" `
        -ScriptName "db-update.ps1"
    $arguments = @("-V8Path", $V8Executable) +
        (Get-WorkflowInfoBaseSkillArguments -InfoBase $InfoBase) +
        @("-Extension", $ExtensionName)
    return Invoke-WorkflowPowerShell -ScriptPath $updateScript -Arguments $arguments -LogPath $LogPath
}

function Invoke-WorkflowLoadExtension {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Cc1CSkillsRoot,

        [Parameter(Mandatory = $true)]
        [string]$V8Executable,

        [string]$BasePath = "",

        [object]$InfoBase = $null,

        [Parameter(Mandatory = $true)]
        [object]$Extension,

        [Parameter(Mandatory = $true)]
        [string]$LogPath,

        [switch]$UpdateDB
    )

    $InfoBase = ConvertTo-WorkflowInfoBase `
        -InfoBase $InfoBase `
        -BasePath $BasePath `
        -Caller "Invoke-WorkflowLoadExtension"
    $loadScript = Resolve-CcSkillScript `
        -Cc1CSkillsRoot $Cc1CSkillsRoot `
        -SkillName "db-load-xml" `
        -ScriptName "db-load-xml.ps1"
    $arguments = @("-V8Path", $V8Executable) + (Get-WorkflowInfoBaseSkillArguments -InfoBase $InfoBase) + @(
        "-ConfigDir", ([string]$Extension.sourcePath),
        "-Mode", "Full",
        "-Extension", ([string]$Extension.name)
    )
    # Ключ -UpdateDB навыка загрузки здесь НЕ используется: он добавляет
    # `/UpdateDBCfg` без области действия, и расширение остаётся неприменённым.
    # Применение выполняется отдельным шагом, см. Invoke-WorkflowApplyExtension.
    $result = Invoke-WorkflowPowerShell -ScriptPath $loadScript -Arguments $arguments -LogPath $LogPath
    if ($UpdateDB) {
        $applyLog = [System.IO.Path]::ChangeExtension($LogPath, $null).TrimEnd('.') + "-apply.log"
        Invoke-WorkflowApplyExtension `
            -Cc1CSkillsRoot $Cc1CSkillsRoot `
            -V8Executable $V8Executable `
            -InfoBase $InfoBase `
            -ExtensionName ([string]$Extension.name) `
            -LogPath $applyLog | Out-Null
    }
    return $result
}

function Invoke-WorkflowDumpExtension {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Cc1CSkillsRoot,

        [Parameter(Mandatory = $true)]
        [string]$V8Executable,

        [string]$BasePath = "",

        [object]$InfoBase = $null,

        [Parameter(Mandatory = $true)]
        [object]$Extension,

        [Parameter(Mandatory = $true)]
        [string]$OutputFile,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    $InfoBase = ConvertTo-WorkflowInfoBase `
        -InfoBase $InfoBase `
        -BasePath $BasePath `
        -Caller "Invoke-WorkflowDumpExtension"
    $dumpScript = Resolve-CcSkillScript `
        -Cc1CSkillsRoot $Cc1CSkillsRoot `
        -SkillName "db-dump-cf" `
        -ScriptName "db-dump-cf.ps1"
    return Invoke-WorkflowPowerShell `
        -ScriptPath $dumpScript `
        -Arguments (
            @("-V8Path", $V8Executable) +
            (Get-WorkflowInfoBaseSkillArguments -InfoBase $InfoBase) +
            @("-OutputFile", $OutputFile, "-Extension", ([string]$Extension.name))
        ) `
        -LogPath $LogPath
}

function Invoke-WorkflowDesignerCommand {
    <#
    .SYNOPSIS
    Запускает конфигуратор над файловой или серверной базой.

    .DESCRIPTION
    Подключение задаётся описателем -InfoBase. Ключ -BasePath оставлен для
    совместимости и означает файловую базу: вызывающие, которые ещё не знают про
    описатели, продолжают работать без изменений.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$V8Executable,

        [string]$BasePath = "",

        [object]$InfoBase = $null,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$LogPath,

        [switch]$AllowFailure
    )

    $InfoBase = ConvertTo-WorkflowInfoBase `
        -InfoBase $InfoBase `
        -BasePath $BasePath `
        -Caller "Invoke-WorkflowDesignerCommand"

    $fullLogPath = [System.IO.Path]::GetFullPath($LogPath)
    [System.IO.Directory]::CreateDirectory((Split-Path $fullLogPath -Parent)) | Out-Null
    $platformLog = "$fullLogPath.platform.log"
    $commandArguments = @("DESIGNER") + (Get-WorkflowInfoBaseArguments -InfoBase $InfoBase) + $Arguments + @(
        "/Out", $platformLog,
        "/DisableStartupDialogs"
    )
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $rawOutput = @(& $V8Executable @commandArguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    # Пароль в командной строке маскируется: лог фазы — артефакт, а секретам в
    # артефактах места нет. Маскируется ЗНАЧЕНИЕ, а не ключ: по наличию /P видно,
    # что аутентификация выполнялась, и это помогает разбирать отказы входа.
    $loggedArguments = @()
    $maskNext = $false
    foreach ($argument in $commandArguments) {
        if ($maskNext) {
            $loggedArguments += "***"
            $maskNext = $false
            continue
        }
        $loggedArguments += $argument
        if ([string]$argument -eq "/P") {
            $maskNext = $true
        }
    }
    $lines = @("1cv8.exe $($loggedArguments -join ' ')")
    $lines += @($rawOutput | ForEach-Object { [string]$_ })
    if (Test-Path -LiteralPath $platformLog -PathType Leaf) {
        $lines += Get-Content -LiteralPath $platformLog -Encoding UTF8
    }
    [System.IO.File]::WriteAllLines($fullLogPath, $lines, [System.Text.UTF8Encoding]::new($false))
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "1C Designer command failed with exit code $exitCode. See log: $fullLogPath"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $lines
        LogPath = $fullLogPath
    }
}

function Invoke-WorkflowCheckExtensions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$V8Executable,

        [string]$BasePath = "",

        [object]$InfoBase = $null,

        [Parameter(Mandatory = $true)]
        [object[]]$Extensions,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    if ($Extensions.Count -eq 0) {
        return $null
    }
    $InfoBase = ConvertTo-WorkflowInfoBase `
        -InfoBase $InfoBase `
        -BasePath $BasePath `
        -Caller "Invoke-WorkflowCheckExtensions"
    return Invoke-WorkflowDesignerCommand `
        -V8Executable $V8Executable `
        -InfoBase $InfoBase `
        -Arguments @("/CheckCanApplyConfigurationExtensions") `
        -LogPath $LogPath
}

function Invoke-WorkflowDeleteExtension {
    param(
        [Parameter(Mandatory = $true)]
        [string]$V8Executable,

        [string]$BasePath = "",

        [object]$InfoBase = $null,

        [Parameter(Mandatory = $true)]
        [string]$ExtensionName,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    $InfoBase = ConvertTo-WorkflowInfoBase `
        -InfoBase $InfoBase `
        -BasePath $BasePath `
        -Caller "Invoke-WorkflowDeleteExtension"
    return Invoke-WorkflowDesignerCommand `
        -V8Executable $V8Executable `
        -InfoBase $InfoBase `
        -Arguments @("/DeleteCfg", "-Extension", $ExtensionName) `
        -LogPath $LogPath
}

# ── Исполнитель кода стенда ───────────────────────────────────────────────────
# Расширение комплекта, которое выполняет присланный текст BSL на стенде и
# возвращает значение переменной Результат в JSON. Сиды и пробы живут в проекте;
# комплект ставит расширение, включает его и публикует. Договор — раздел
# «Исполнитель кода стенда» в docs/1c-development-workflow.md.
#
# Расширение ставится ТОЛЬКО на стенды и в поставку не входит: в extensions[]
# манифеста его нет, и объявить расширение с этим именем проект не может (см.
# Get-WorkflowExtensions).

function Get-WorkflowStandExecName {
    return "ИсполнительСтенда"
}

function Test-WorkflowStandExecEnabled {
    <#
    .SYNOPSIS
    Включён ли исполнитель кода стенда в манифесте.

    .DESCRIPTION
    Раздела может не быть: проект поставлен версией комплекта, где исполнителя
    ещё не было. Это «выключено», а не ошибка — включение обсуждается с владельцем
    проекта и делается явно.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $section = Get-WorkflowSettingValue -Object $Config -Name "standExec" -Default $null
    return [bool](Get-WorkflowSettingValue -Object $section -Name "enabled" -Default $false)
}

function Test-WorkflowStandODataEnabled {
    <#
    .SYNOPSIS
    Публиковать ли на стенде состав OData «все объекты».

    .DESCRIPTION
    Состав выставляет исполнитель стенда при установке, поэтому без него OData не
    включается. При включённом исполнителе — включён, пока standExec.odata не
    выставлен в false явно: публикация OData на стендах уже включена в VRD, и
    пустой состав означал бы сервис без единой сущности.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    if (-not (Test-WorkflowStandExecEnabled -Config $Config)) {
        return $false
    }
    $section = Get-WorkflowSettingValue -Object $Config -Name "standExec" -Default $null
    return [bool](Get-WorkflowSettingValue -Object $section -Name "odata" -Default $true)
}

function Get-WorkflowStandBaselineSettings {
    <#
    .SYNOPSIS
    Настройки базовой подготовки стенда (раздел standBaseline манифеста).

    .DESCRIPTION
    Раздела может не быть — проект поставлен версией комплекта без подготовки.
    Это «включено по умолчанию»: без подготовки тесты и сценарии в веб-клиенте
    нестабильны на любой конфигурации (регламентные задания в сеансе клиента,
    ленивые предопределённые данные), а выключается она явно.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $section = Get-WorkflowSettingValue -Object $Config -Name "standBaseline" -Default $null
    $keep = @(
        @(Get-WorkflowSettingValue -Object $section -Name "keepScheduledJobs" -Default @()) |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ }
    )
    return [pscustomobject]@{
        Enabled = [bool](Get-WorkflowSettingValue -Object $section -Name "enabled" -Default $true)
        DisableScheduledJobs = [bool](Get-WorkflowSettingValue -Object $section -Name "disableScheduledJobs" -Default $true)
        KeepScheduledJobs = @($keep)
    }
}

function Invoke-WorkflowStandBaseline {
    <#
    .SYNOPSIS
    Базовая подготовка опубликованного стенда исполнителем кода. Возвращает
    строки протокола.

    .DESCRIPTION
    Код — tools/stand-exec/stand-baseline.bsl: предопределённые данные, первые
    диалоги БСП и подсистем, скачанные новости, регламентные задания. Каждый
    блок проверяет, есть ли в конфигурации то, с чем он работает.

    Только после публикации и только через HTTP-исполнитель: во внешнем
    соединении запись констант и данных падает на подписках конфигурации (см.
    ИС_МеткаСтенда), а подготовка пишет и то и другое.

    Нет исполнителя — пропуск с причиной в протоколе. Отказ исполнителя —
    исключение: стенд не в том состоянии, на которое рассчитаны тесты. Ошибка
    отдельного блока — строка протокола, а не отказ: остальные блоки полезны и без
    него.

    .PARAMETER ScheduledJobsOnly
    Только выключить регламентные задания — после сида, который мог включить
    функциональные опции, а с ними и зависящие от них задания.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [string]$Url = "",

        [Parameter(Mandatory = $true)]
        [string]$LogPath,

        [switch]$ScheduledJobsOnly
    )

    $settings = Get-WorkflowStandBaselineSettings -Config $Config
    if (-not $settings.Enabled) {
        return @("базовая подготовка стенда выключена: standBaseline.enabled")
    }
    if (-not (Test-WorkflowStandExecEnabled -Config $Config)) {
        return @("базовая подготовка стенда пропущена: нет исполнителя кода стенда (standExec.enabled)")
    }
    if ($ScheduledJobsOnly -and -not $settings.DisableScheduledJobs) {
        return @()
    }

    $section = Get-WorkflowSettingValue -Object $Config -Name "standExec" -Default $null
    $client = Resolve-WorkflowPath -RepositoryRoot $RepositoryRoot `
        -Path ([string](Get-WorkflowSettingValue -Object $section -Name "script" -Default "tools/Invoke-StandExec.ps1"))
    $code = Join-Path $RepositoryRoot "tools\stand-exec\stand-baseline.bsl"
    if (-not (Test-Path -LiteralPath $code -PathType Leaf)) {
        throw "Код базовой подготовки стенда не найден: $code. Поднимите комплект фазой KitUpdate."
    }

    # Параметры — файлом: JSON с кавычками в аргументе powershell -File
    # разбирается ненадёжно.
    $logFullPath = [System.IO.Path]::GetFullPath($LogPath)
    [System.IO.Directory]::CreateDirectory((Split-Path $logFullPath -Parent)) | Out-Null
    $parametersPath = [System.IO.Path]::ChangeExtension($logFullPath, ".params.json")
    $parameters = [ordered]@{
        "ТолькоЗадания" = [bool]$ScheduledJobsOnly
        "ВыключатьЗадания" = [bool]$settings.DisableScheduledJobs
        "ОставитьЗадания" = @($settings.KeepScheduledJobs)
    }
    [System.IO.File]::WriteAllText($parametersPath,
        (ConvertTo-Json -InputObject $parameters -Depth 3), [System.Text.UTF8Encoding]::new($false))

    $arguments = @("-File", $code, "-Mode", "none", "-ParametersFile", $parametersPath)
    if ($Url) {
        $arguments += @("-Url", $Url)
    }
    $run = Invoke-WorkflowPowerShell -ScriptPath $client -Arguments $arguments -LogPath $logFullPath -AllowFailure

    $text = ($run.Output -join "`n")
    $response = $null
    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -ge 0 -and $end -gt $start) {
        try { $response = $text.Substring($start, $end - $start + 1) | ConvertFrom-Json } catch { $response = $null }
    }
    if ($run.ExitCode -ne 0 -or $null -eq $response -or -not [bool]$response.ok) {
        $reason = if ($null -ne $response -and $response.error) { [string]$response.error } else {
            @($run.Output | Where-Object { $_ -match '\S' } | Select-Object -Last 1) -join ""
        }
        throw "Базовая подготовка стенда не выполнена (код $($run.ExitCode)): $reason. Лог: $logFullPath"
    }
    return @(@($response.result) | ForEach-Object { [string]$_ })
}

function New-WorkflowStandExecSource {
    <#
    .SYNOPSIS
    Готовит исходники расширения-исполнителя к загрузке в стенд проекта.

    .DESCRIPTION
    Шаблон расширения нейтрален, а два его свойства обязаны совпадать с основной
    конфигурацией проекта:

    - режим совместимости: расширение с режимом выше, чем у конфигурации, к ней
      не применяется;
    - язык: язык расширения заимствован из конфигурации и ссылается на неё по
      UUID. С чужим UUID загрузка отказывает.

    Поэтому исходники не грузятся из шаблона напрямую, а копируются в каталог
    состояния с подстановкой этих свойств. Файлы копии пишутся в UTF-8 С BOM:
    так их выгружает платформа, а установщик комплекта BOM ставит только
    скриптам PowerShell.

    .OUTPUTS
    Описатель расширения в форме, которую принимает Invoke-WorkflowLoadExtension.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplateDirectory,

        [Parameter(Mandatory = $true)]
        [string]$ConfigurationDirectory,

        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory
    )

    $TemplateDirectory = [System.IO.Path]::GetFullPath($TemplateDirectory)
    $OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
    if (-not (Test-Path -LiteralPath (Join-Path $TemplateDirectory "Configuration.xml") -PathType Leaf)) {
        throw "Шаблон исполнителя стенда не найден: $TemplateDirectory. Поднимите комплект фазой KitUpdate."
    }
    $projectConfiguration = Join-Path $ConfigurationDirectory "Configuration.xml"
    if (-not (Test-Path -LiteralPath $projectConfiguration -PathType Leaf)) {
        throw "Configuration.xml основной конфигурации не найден: $projectConfiguration"
    }

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $projectText = [System.IO.File]::ReadAllText($projectConfiguration, $utf8)
    $mode = [regex]::Match($projectText, '<CompatibilityMode>([^<]+)</CompatibilityMode>').Groups[1].Value
    $languageName = [regex]::Match($projectText, '<DefaultLanguage>Language\.([^<]+)</DefaultLanguage>').Groups[1].Value
    if (-not $languageName) {
        throw "В $projectConfiguration не найден основной язык (DefaultLanguage)."
    }
    $languageFile = Join-Path $ConfigurationDirectory "Languages\$languageName.xml"
    if (-not (Test-Path -LiteralPath $languageFile -PathType Leaf)) {
        throw "Файл основного языка конфигурации не найден: $languageFile"
    }
    $languageText = [System.IO.File]::ReadAllText($languageFile, $utf8)
    $languageUuid = [regex]::Match($languageText, '<Language\s+uuid="([^"]+)"').Groups[1].Value
    $languageCode = [regex]::Match($languageText, '<LanguageCode>([^<]*)</LanguageCode>').Groups[1].Value
    if (-not $languageUuid) {
        throw "В $languageFile не найден UUID языка."
    }

    if (Test-Path -LiteralPath $OutputDirectory) {
        Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
    }
    $templateLanguage = "Languages\Русский.xml"
    foreach ($file in @(Get-ChildItem -LiteralPath $TemplateDirectory -Recurse -File)) {
        $relative = $file.FullName.Substring($TemplateDirectory.TrimEnd('\').Length + 1)
        $text = [System.IO.File]::ReadAllText($file.FullName, $utf8).TrimStart([char]0xFEFF)
        if ($relative -eq "Configuration.xml") {
            # «Без режима совместимости» означает режим текущей платформы: шаблонный
            # режим ниже него, и расширение применится.
            if ($mode -and $mode -ne "DontUse") {
                $text = [regex]::Replace(
                    $text,
                    '<ConfigurationExtensionCompatibilityMode>[^<]+</ConfigurationExtensionCompatibilityMode>',
                    "<ConfigurationExtensionCompatibilityMode>$mode</ConfigurationExtensionCompatibilityMode>")
            }
            $text = $text.Replace("<DefaultLanguage>Language.Русский</DefaultLanguage>", "<DefaultLanguage>Language.$languageName</DefaultLanguage>")
            $text = $text.Replace("<Language>Русский</Language>", "<Language>$languageName</Language>")
        }
        elseif ($relative -eq $templateLanguage) {
            $text = $text.Replace("<Name>Русский</Name>", "<Name>$languageName</Name>")
            $text = [regex]::Replace(
                $text,
                '<ExtendedConfigurationObject>[^<]+</ExtendedConfigurationObject>',
                "<ExtendedConfigurationObject>$languageUuid</ExtendedConfigurationObject>")
            if ($languageCode) {
                $text = [regex]::Replace($text, '<LanguageCode>[^<]*</LanguageCode>', "<LanguageCode>$languageCode</LanguageCode>")
            }
            $relative = "Languages\$languageName.xml"
        }
        $target = Join-Path $OutputDirectory $relative
        [System.IO.Directory]::CreateDirectory((Split-Path $target -Parent)) | Out-Null
        [System.IO.File]::WriteAllText($target, $text, [System.Text.UTF8Encoding]::new($true))
    }

    return [pscustomobject]@{
        name = Get-WorkflowStandExecName
        sourcePath = $OutputDirectory
        compatibilityMode = $mode
        language = $languageName
    }
}

function Get-WorkflowComConnectionString {
    <#
    .SYNOPSIS
    Строка подключения COMConnector для описателя базы.

    .DESCRIPTION
    Значения берутся в кавычки, кавычки внутри удваиваются: путь к файловой базе
    и пароль могут содержать и пробелы, и точку с запятой. Пустой пароль не
    передаётся — по той же причине, что и в командной строке платформы.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$InfoBase
    )

    $quote = { param($value) '"' + ([string]$value).Replace('"', '""') + '"' }
    $parts = @()
    if ([string]$InfoBase.Kind -eq "server") {
        $parts += "Srvr=$(& $quote $InfoBase.Server)"
        $parts += "Ref=$(& $quote $InfoBase.Ref)"
    }
    else {
        $parts += "File=$(& $quote ([System.IO.Path]::GetFullPath([string]$InfoBase.Path)))"
    }
    if ([string]$InfoBase.UserName) {
        $parts += "Usr=$(& $quote $InfoBase.UserName)"
        if ([string]$InfoBase.Password) {
            $parts += "Pwd=$(& $quote $InfoBase.Password)"
        }
    }
    return ($parts -join ";") + ";"
}

# ── COM-соединение с базой 1С ─────────────────────────────────────────────────
# Правильная работа с объектами 1С через COM из PowerShell не очевидна, и каждая
# ловушка стоила отдельного расследования (docs/known-issues.md комплекта, п. 13).
# Поэтому она живёт здесь одна, а не переписывается в каждом скрипте:
#
#  - члены объектов 1С вызываются только через InvokeMember: COM-адаптер
#    PowerShell на свойства соединения молча возвращает $null;
#  - результат возвращается унарной запятой: массив 1С через COM перечислим, и
#    PowerShell разворачивает его на выходе из функции — массив из одного элемента
#    становится самим элементом, и следующий вызов отвечает «Unknown name»;
#  - значение свойства передаётся в @(,$Value): иначе перечислимый объект был бы
#    развёрнут в список аргументов.

function Get-WorkflowComProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return , [System.__ComObject].InvokeMember(
        $Name, [System.Reflection.BindingFlags]::GetProperty, $null, $Object, $null)
}

function Set-WorkflowComProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$Value
    )

    [void][System.__ComObject].InvokeMember(
        $Name, [System.Reflection.BindingFlags]::SetProperty, $null, $Object, @(, $Value))
}

function Invoke-WorkflowComMethod {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [object[]]$Arguments = $null
    )

    return , [System.__ComObject].InvokeMember(
        $Name, [System.Reflection.BindingFlags]::InvokeMethod, $null, $Object, $Arguments)
}

function Invoke-WorkflowComConnection {
    <#
    .SYNOPSIS
    Открывает COM-соединение с базой, выполняет действие и отпускает соединение.

    .DESCRIPTION
    Соединение отпускается явно: пока оно живо, файловая база занята, и следующий
    шаг — конфигуратор, публикация — получил бы отказ. Даже так процесс может
    удерживать библиотеку платформы, поэтому комплект работает с COM в дочернем
    процессе (Invoke-WorkflowStandExtensionsScript), а эти функции — его начинка.

    Требует зарегистрированного V83.COMConnector той же разрядности, что
    PowerShell.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConnectionString,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    $connector = New-Object -ComObject "V83.COMConnector"
    $connection = $connector.Connect($ConnectionString)
    try {
        & $Action $connection
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($connection) | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($connector) | Out-Null
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

function Disable-WorkflowComExtensionSafeMode {
    <#
    .SYNOPSIS
    Снимает с расширения безопасный режим и защиту от опасных действий — в уже
    открытом COM-соединении.

    .DESCRIPTION
    Обе настройки снимаются ОДНОЙ записью. У свежезагруженного расширения защита
    от опасных действий включена, и запись с ней упирается в диалог
    «Предупреждение безопасности ... Разрешить открывать данный файл?», ответить
    на который внешнее соединение не может: вызов падает текстом диалога.
    Меняется флаг существующего описания защиты — создать новое через соединение
    нельзя.

    Альтернатив нет: пакетный конфигуратор (/ManageCfgExtensions) пытается
    открыть окно и отказывает, ibcmd умеет это только для файловой базы.

    Свойства расширения применяются к НОВЫМ сеансам.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Connection,

        [Parameter(Mandatory = $true)]
        [string]$ExtensionName
    )

    $manager = Get-WorkflowComProperty -Object $Connection -Name "РасширенияКонфигурации"
    $all = Invoke-WorkflowComMethod -Object $manager -Name "Получить"
    $count = [int](Invoke-WorkflowComMethod -Object $all -Name "Количество")
    for ($index = 0; $index -lt $count; $index++) {
        $extension = Invoke-WorkflowComMethod -Object $all -Name "Получить" -Arguments @($index)
        if ([string](Get-WorkflowComProperty -Object $extension -Name "Имя") -ne $ExtensionName) {
            continue
        }
        Set-WorkflowComProperty -Object $extension -Name "БезопасныйРежим" -Value $false
        $protection = Get-WorkflowComProperty -Object $extension -Name "ЗащитаОтОпасныхДействий"
        Set-WorkflowComProperty -Object $protection -Name "ПредупреждатьОбОпасныхДействиях" -Value $false
        Set-WorkflowComProperty -Object $extension -Name "ЗащитаОтОпасныхДействий" -Value $protection
        Invoke-WorkflowComMethod -Object $extension -Name "Записать" | Out-Null
        return
    }
    throw "Расширение $ExtensionName в базе не найдено. Оно загружено и применено по имени?"
}

function Invoke-WorkflowStandExtensionsScript {
    <#
    .SYNOPSIS
    Запускает tools/stand-exec/Enable-StandExtensions.ps1 в дочернем процессе.

    .DESCRIPTION
    Строка подключения передаётся переменной окружения, а не аргументом: в ней
    может быть пароль, а аргументы попадают в лог и в список процессов.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$InfoBase,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    $script = Join-Path $RepositoryRoot "tools\stand-exec\Enable-StandExtensions.ps1"
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        throw "Скрипт настройки расширений стенда не найден: $script. Поднимите комплект фазой KitUpdate."
    }
    $previous = $env:ONEC_WORKFLOW_STAND_CONNECTION
    $env:ONEC_WORKFLOW_STAND_CONNECTION = Get-WorkflowComConnectionString -InfoBase $InfoBase
    try {
        Invoke-WorkflowPowerShell -ScriptPath $script -Arguments $Arguments -LogPath $LogPath | Out-Null
    }
    finally {
        $env:ONEC_WORKFLOW_STAND_CONNECTION = $previous
    }
}

function Disable-WorkflowExtensionSafeMode {
    <#
    .SYNOPSIS
    Снимает безопасный режим и защиту от опасных действий с расширений стенда.

    .DESCRIPTION
    Для адаптеров проекта: движку модульных тестов и его расширению с тестами это
    нужно так же, как исполнителю кода стенда. Вызывать после применения
    расширений по имени и до первого сеанса, которому это важно.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$InfoBase,

        [Parameter(Mandatory = $true)]
        [string[]]$ExtensionNames,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    # Список — одной строкой через запятую: запуск через -File массивы не
    # разбирает (см. Invoke-WorkflowPowerShell).
    Invoke-WorkflowStandExtensionsScript `
        -RepositoryRoot $RepositoryRoot `
        -InfoBase $InfoBase `
        -Arguments @("-ExtensionName", ($ExtensionNames -join ",")) `
        -LogPath $LogPath
}

function Enable-WorkflowStandExec {
    <#
    .SYNOPSIS
    Снимает безопасный режим исполнителя, выставляет метку стенда и, по ключу,
    публикует всё в OData.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$InfoBase,

        [Parameter(Mandatory = $true)]
        [string]$LogPath,

        [switch]$ODataContent
    )

    $arguments = @("-ExtensionName", (Get-WorkflowStandExecName), "-ArmExecutor")
    if ($ODataContent) {
        $arguments += "-ODataContent"
    }
    Invoke-WorkflowStandExtensionsScript `
        -RepositoryRoot $RepositoryRoot `
        -InfoBase $InfoBase `
        -Arguments $arguments `
        -LogPath $LogPath
}

function Install-WorkflowStandExec {
    <#
    .SYNOPSIS
    Ставит исполнитель кода на стенд: готовит исходники, загружает и применяет
    расширение по имени, снимает безопасный режим и выставляет метку.

    .DESCRIPTION
    Вызывается после расширений проекта и ДО сида: сид проекта вправе
    пользоваться исполнителем. Стенд из кэша ставить повторно не нужно — снимок
    сделан после этого шага и уносит расширение вместе с меткой.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Cc1CSkillsRoot,

        [Parameter(Mandatory = $true)]
        [string]$V8Executable,

        [Parameter(Mandatory = $true)]
        [object]$InfoBase,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [Parameter(Mandatory = $true)]
        [string]$LogPath
    )

    $extension = New-WorkflowStandExecSource `
        -TemplateDirectory (Join-Path $RepositoryRoot "tools\stand-exec\extension") `
        -ConfigurationDirectory (Resolve-WorkflowPath -RepositoryRoot $RepositoryRoot -Path ([string]$Config.sourceDir)) `
        -OutputDirectory (Join-Path $StateDirectory "stand-exec\extension")
    Write-Host "Исполнитель стенда: режим совместимости $($extension.compatibilityMode), язык $($extension.language)."
    Invoke-WorkflowLoadExtension `
        -Cc1CSkillsRoot $Cc1CSkillsRoot `
        -V8Executable $V8Executable `
        -InfoBase $InfoBase `
        -Extension $extension `
        -UpdateDB `
        -LogPath $LogPath | Out-Null
    $enableLog = [System.IO.Path]::ChangeExtension($LogPath, $null).TrimEnd('.') + "-enable.log"
    Enable-WorkflowStandExec `
        -RepositoryRoot $RepositoryRoot `
        -InfoBase $InfoBase `
        -LogPath $enableLog `
        -ODataContent:(Test-WorkflowStandODataEnabled -Config $Config)
}

function Invoke-WorkflowStandPreparation {
    <#
    .SYNOPSIS
    Готовит файловый стенд с отдельным сидом: инициализатор проекта без сида,
    администратор стенда, расширения проекта, исполнитель кода стенда, сид.

    .DESCRIPTION
    Порядок один для всех, кто собирает стенд вне фазы: генератор данных
    (Invoke-TestDataGenerator) и стенд Web UI цикла разработки
    (Invoke-WebUiTests). Разложенный по скриптам, он разошёлся бы: стенд Web UI
    собирался своим путём, и исполнитель кода на нём не появлялся — тест,
    готовящий себе данные исполнителем, падал у разработчика и проходил в фазе.

    Сид — последним и отдельным шагом: сид проекта вправе пользоваться и
    расширениями проекта, и исполнителем кода стенда.

    .PARAMETER InitializeArguments
    Аргументы инициализатора проекта без -SkipSeed: его добавляет функция.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string[]]$InitializeArguments,

        [string]$V8Path = "",

        [Parameter(Mandatory = $true)]
        [string]$LogDirectory
    )

    $seedProperty = $Config.functionalTests.PSObject.Properties["seedScript"]
    if ($null -eq $seedProperty -or [string]::IsNullOrWhiteSpace([string]$seedProperty.Value)) {
        throw "functionalTests.seedScript is required when extensions or standExec are enabled."
    }
    $seedScript = Resolve-WorkflowPath -RepositoryRoot $RepositoryRoot -Path ([string]$seedProperty.Value)
    if (-not (Test-Path -LiteralPath $seedScript -PathType Leaf)) {
        throw "Functional test seed script was not found: $seedScript"
    }
    $initializeScript = Resolve-WorkflowPath `
        -RepositoryRoot $RepositoryRoot `
        -Path ([string]$Config.functionalTests.initializeScript)
    if (-not (Test-Path -LiteralPath $initializeScript -PathType Leaf)) {
        throw "Functional test initializer was not found: $initializeScript"
    }

    $BasePath = [System.IO.Path]::GetFullPath($BasePath)
    $stateDirectory = Resolve-WorkflowPath -RepositoryRoot $RepositoryRoot -Path ([string]$Config.localStateDir)
    $extensions = @(Get-WorkflowExtensions -RepositoryRoot $RepositoryRoot -Config $Config -AllowMissingOptional)

    Invoke-WorkflowPowerShell `
        -ScriptPath $initializeScript `
        -Arguments (@($InitializeArguments) + "-SkipSeed") `
        -LogPath (Join-Path $LogDirectory "stand-initialize.log") | Out-Null

    $v8Executable = Resolve-WorkflowV8Path -Config $Config -V8Path $V8Path
    $ccRoot = Resolve-Cc1CSkillsRoot -Config $Config
    # Администратор стенда — до первого подключения по имени.
    $administratorOutcome = Initialize-WorkflowStandAdministrator -BasePath $BasePath
    Write-Host "Stand administrator: $administratorOutcome"
    $standInfoBase = ConvertTo-WorkflowStandInfoBase -BasePath $BasePath
    foreach ($extension in $extensions) {
        Invoke-WorkflowLoadExtension `
            -Cc1CSkillsRoot $ccRoot `
            -V8Executable $v8Executable `
            -InfoBase $standInfoBase `
            -Extension $extension `
            -UpdateDB `
            -LogPath (Join-Path $LogDirectory "stand-load-extension-$($extension.name).log") | Out-Null
    }
    # Без расширений проверять нечего, а пустой список параметр не принимает:
    # при ErrorActionPreference = Stop это отказ всей подготовки.
    if ($extensions.Count -gt 0) {
        Invoke-WorkflowCheckExtensions `
            -V8Executable $v8Executable `
            -InfoBase $standInfoBase `
            -Extensions $extensions `
            -LogPath (Join-Path $LogDirectory "stand-extensions-applicability.log") | Out-Null
    }
    $standExecEnabled = Test-WorkflowStandExecEnabled -Config $Config
    if ($standExecEnabled) {
        Install-WorkflowStandExec `
            -RepositoryRoot $RepositoryRoot `
            -Config $Config `
            -Cc1CSkillsRoot $ccRoot `
            -V8Executable $v8Executable `
            -InfoBase $standInfoBase `
            -StateDirectory $stateDirectory `
            -LogPath (Join-Path $LogDirectory "stand-exec.log")
    }
    # Расширения добавляют собственные роли уже ПОСЛЕ первого создания
    # администратора. Перед сидом синхронизируем его повторно: иначе вход есть,
    # но проектные объекты отвечают «Недостаточно прав».
    $administratorOutcome = Initialize-WorkflowStandAdministrator -BasePath $BasePath
    Write-Host "Stand administrator after extensions: $administratorOutcome"
    Invoke-WorkflowPowerShell `
        -ScriptPath $seedScript `
        -Arguments @("-BasePath", $BasePath) `
        -LogPath (Join-Path $LogDirectory "stand-seed.log") | Out-Null
    Write-Host "Stand prepared: $($extensions.Count) extension(s), stand executor: $standExecEnabled."
}

function Set-WorkflowVrdExtensionServices {
    <#
    .SYNOPSIS
    Включает в публикации HTTP-сервисы расширений. Возвращает $true, если файл
    изменён.

    .DESCRIPTION
    Навык web-publish пишет <httpServices publishByDefault="true"/>, и сервисы
    РАСШИРЕНИЙ при этом не публикуются: обращение к ним отвечает 404. Нужен
    атрибут publishExtensionsByDefault. Проверено на 8.3.27: без атрибута 404, с
    ним 200.

    Модуль 1С читает default.vrd при запуске Apache, поэтому после изменения
    Apache перезапускается (Restart-WorkflowApache).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$VrdPath
    )

    if (-not (Test-Path -LiteralPath $VrdPath -PathType Leaf)) {
        throw "Файл публикации не найден: $VrdPath"
    }
    $original = [System.IO.File]::ReadAllText($VrdPath, [System.Text.UTF8Encoding]::new($false))
    $element = [regex]::Match($original, '<httpServices\b[^>]*?/?>')
    if ($element.Success) {
        $tag = $element.Value
        if ($tag -match 'publishExtensionsByDefault\s*=\s*"true"') {
            return $false
        }
        if ($tag -match 'publishExtensionsByDefault\s*=') {
            $newTag = [regex]::Replace($tag, 'publishExtensionsByDefault\s*=\s*"[^"]*"', 'publishExtensionsByDefault="true"')
        }
        else {
            $newTag = [regex]::Replace($tag, '\s*(/?)>$', ' publishExtensionsByDefault="true"$1>')
        }
        $updated = $original.Substring(0, $element.Index) + $newTag + $original.Substring($element.Index + $element.Length)
    }
    else {
        $closing = $original.LastIndexOf("</point>")
        if ($closing -lt 0) {
            throw "В $VrdPath нет элемента point: формат публикации не распознан."
        }
        $updated = $original.Substring(0, $closing) +
            '    <httpServices publishByDefault="true" publishExtensionsByDefault="true"/>' +
            [Environment]::NewLine + $original.Substring($closing)
    }
    [System.IO.File]::WriteAllText($VrdPath, $updated, [System.Text.UTF8Encoding]::new($false))
    return $true
}

function Restart-WorkflowApache {
    <#
    .SYNOPSIS
    Перезапускает Apache комплекта — только тот, что запущен из -ApachePath.

    .DESCRIPTION
    Процесс узнаётся по пути исполняемого файла, как это делает web-publish:
    сторонний Apache на машине (другого проекта или другой копии) не трогается.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApachePath
    )

    $httpd = [System.IO.Path]::GetFullPath((Join-Path $ApachePath "bin\httpd.exe"))
    if (-not (Test-Path -LiteralPath $httpd -PathType Leaf)) {
        throw "Apache не найден: $httpd"
    }
    $own = @(Get-Process -Name "httpd" -ErrorAction SilentlyContinue | Where-Object {
        try { [string]::Equals($_.Path, $httpd, [System.StringComparison]::OrdinalIgnoreCase) } catch { $false }
    })
    $own | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($own.Count -gt 0) {
        Start-Sleep -Seconds 1
    }
    Start-Process -FilePath $httpd -WorkingDirectory (Split-Path (Split-Path $httpd -Parent) -Parent) -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $running = @(Get-Process -Name "httpd" -ErrorAction SilentlyContinue | Where-Object {
        try { [string]::Equals($_.Path, $httpd, [System.StringComparison]::OrdinalIgnoreCase) } catch { $false }
    })
    if ($running.Count -eq 0) {
        throw "Apache не запустился после изменения публикации: $httpd. Проверьте конфигурацию: `"$httpd`" -t"
    }
}

function Test-WorkflowPathUnderRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-WorkflowGitChanges {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$SourceDir,

        [string]$CommitRange = "",

        [switch]$IncludeWorkingTree
    )

    $lines = @()
    if ($CommitRange) {
        $result = Invoke-WorkflowGit -RepositoryRoot $RepositoryRoot -Arguments @(
            "-c", "core.quotePath=false", "diff", "--name-status", $CommitRange, "--", $SourceDir
        )
        $lines += $result.Output
    }
    if ($IncludeWorkingTree) {
        $unstaged = Invoke-WorkflowGit -RepositoryRoot $RepositoryRoot -Arguments @(
            "-c", "core.quotePath=false", "diff", "--name-status", "HEAD", "--", $SourceDir
        )
        $lines += $unstaged.Output
        $untracked = Invoke-WorkflowGit -RepositoryRoot $RepositoryRoot -Arguments @(
            "-c", "core.quotePath=false", "ls-files", "--others", "--exclude-standard", "--", $SourceDir
        )
        foreach ($path in $untracked.Output) {
            $lines += "A`t$path"
        }
    }

    $entries = @()
    foreach ($line in ($lines | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $parts = [string]$line -split "`t"
        $entries += [pscustomobject]@{
            Status = $parts[0]
            Paths = @($parts | Select-Object -Skip 1)
            Raw = [string]$line
        }
    }
    return $entries
}

function New-WorkflowStepResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [bool]$Success,

        [int]$ExitCode = 0,

        [string]$LogPath = "",

        [string]$Message = "",

        # Длительность шага. Без неё отчёт не отвечает на вопрос «куда ушло
        # время»: перерасход виден только если его измеряют, а измерять по
        # времени записи лог-файлов приходилось вручную и задним числом.
        [double]$DurationSeconds = -1
    )

    $result = [pscustomobject]@{
        name = $Name
        success = $Success
        exitCode = $ExitCode
        log = $LogPath
        message = $Message
    }
    if ($DurationSeconds -ge 0) {
        Add-Member `
            -InputObject $result `
            -NotePropertyName "durationSeconds" `
            -NotePropertyValue ([math]::Round($DurationSeconds, 1)) `
            -Force
    }
    return $result
}

function Get-WorkflowManagedFileHash {
    <#
    .SYNOPSIS
    Хеш файла, которым управляет комплект процесса.

    .DESCRIPTION
    Считается от НОРМАЛИЗОВАННОГО текста, а не от байтов. Побайтовый хеш давал бы
    расхождение на файле, который никто не менял: `.gitattributes` держит в рабочем
    каталоге CRLF, установщик пишет `.ps1` с BOM, а рабочие копии отличаются
    завершающим переводом строки. Проверка срабатывала бы всегда и потому перестала
    бы что-либо значить.

    Нормализация обязана совпадать с той, что применяет установщик при записи
    замка: BOM снимается, CRLF приводится к LF, хвостовые переводы строк
    отбрасываются. Расхождение этих двух мест сделает проверку ложной в обе
    стороны — ровно тот класс дефекта, против которого она и вводится.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $text = [System.IO.File]::ReadAllText(
        [System.IO.Path]::GetFullPath($Path),
        [System.Text.UTF8Encoding]::new($false)
    )
    $normalized = $text.TrimStart([char]0xFEFF).Replace("`r`n", "`n").TrimEnd("`r", "`n")
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($normalized)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-WorkflowRulesOverlayProblems {
    <#
    .SYNOPSIS
    Проверяет оформление уточнений правил разработки в `docs/rules/project`.

    .DESCRIPTION
    Общие правила лежат в `docs/rules` и входят в замок установки. Особенности
    конфигурации живут рядом, в `docs/rules/project`, в замок не входят и правятся
    свободно. Связь уточнения с базовым правилом — по имени файла, и держится она
    ТОЛЬКО на заголовке внутри файла.

    Поэтому проверяются три вещи: заголовок существует, `Уточняет:` указывает на
    существующий базовый файл либо на `-`, `Причина:` не пуста. Без этого overlay
    через год превращается в набор файлов, про которые никто не помнит, что именно
    они переопределяют: отсутствие причины неотличимо от причины забытой.

    Отсутствие каталога `project` проблемой НЕ считается: проект вправе не иметь ни
    одного уточнения, и требовать их означало бы требовать особенностей там, где их
    нет.

    Возвращает объект с полями Checked (сколько файлов проверено) и Problems
    (массив описаний; пустой массив означает, что нарушений нет).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $baseDirectory = Join-Path $RepositoryRoot "docs\rules"
    $overlayDirectory = Join-Path $baseDirectory "project"
    $problems = New-Object System.Collections.ArrayList
    $checked = 0

    if (-not (Test-Path -LiteralPath $overlayDirectory -PathType Container)) {
        return [pscustomobject]@{ Checked = 0; Problems = @() }
    }

    $baseNames = @{}
    if (Test-Path -LiteralPath $baseDirectory -PathType Container) {
        foreach ($baseFile in @(Get-ChildItem -LiteralPath $baseDirectory -Filter "*.md" -File)) {
            $baseNames[$baseFile.Name.ToLowerInvariant()] = $true
        }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $overlayDirectory -Filter "*.md" -File | Sort-Object Name)) {
        $checked++
        $relative = "docs/rules/project/$($file.Name)"
        $lines = @([System.IO.File]::ReadAllLines($file.FullName, [System.Text.UTF8Encoding]::new($false)))

        # Заголовок: строка-разделитель, поля, закрывающий разделитель.
        #
        # Факт находки держится отдельным флагом, а не проверкой $header на $null.
        # Пустой заголовок даёт пустой массив, а он в PowerShell не отличается от
        # отсутствия значения: результат выражения `if (...) { @() }` в конвейер не
        # попадает вовсе, и переменная получает $null. Такой заголовок сообщал бы об
        # отсутствии разделителей вместо отсутствия полей.
        $headerFound = $false
        $header = @()
        if ($lines.Count -gt 0 -and ([string]$lines[0]).TrimStart([char]0xFEFF).Trim() -eq "---") {
            for ($index = 1; $index -lt $lines.Count; $index++) {
                if (([string]$lines[$index]).Trim() -ne "---") {
                    continue
                }
                # Диапазон 1..0 разворачивается в обратном порядке, поэтому пустой
                # заголовок не выражается диапазоном и обрабатывается условием.
                if ($index -gt 1) {
                    $header = @($lines[1..($index - 1)])
                }
                $headerFound = $true
                break
            }
        }
        if (-not $headerFound) {
            [void]$problems.Add("${relative}: в начале файла нет заголовка между строками '---'")
            continue
        }

        $refines = ""
        $reason = ""
        foreach ($line in $header) {
            $text = [string]$line
            if ($text -match '^\s*Уточняет\s*:\s*(.*)$') {
                $refines = $Matches[1].Trim()
            }
            elseif ($text -match '^\s*Причина\s*:\s*(.*)$') {
                $reason = $Matches[1].Trim()
            }
        }

        if (-not $refines) {
            [void]$problems.Add("${relative}: в заголовке нет непустого поля 'Уточняет:'")
        }
        elseif ($refines -eq "README.md") {
            [void]$problems.Add("${relative}: 'Уточняет: README.md' — индекс правилом не является")
        }
        elseif ($refines -ne "-" -and -not $baseNames.ContainsKey($refines.ToLowerInvariant())) {
            [void]$problems.Add(
                "${relative}: 'Уточняет: $refines' указывает на отсутствующий файл базовых правил docs/rules/$refines")
        }
        if (-not $reason) {
            [void]$problems.Add("${relative}: в заголовке нет непустого поля 'Причина:'")
        }
    }

    return [pscustomobject]@{ Checked = $checked; Problems = @($problems) }
}

function Get-WorkflowFailedRunMarkerName {
    <#
    .SYNOPSIS
    Имя файла-метки «этот прогон упал». Одно на запись и на уборку.
    #>
    return ".preflight-failed.json"
}

function Clear-WorkflowTemporaryRoots {
    <#
    .SYNOPSIS
    Подметает временные каталоги прошлых прогонов. Без ожиданий.

    .DESCRIPTION
    1С отпускает `1Cv8.lgf` не сразу после выхода, поэтому удаление СВОЕГО дерева
    в конце прогона регулярно не проходит. Раньше это лечили повторами с паузами:
    пять попыток по две секунды — восемь секунд ожидания в критическом пути, и всё
    равно часто безуспешно. Остатки копились: на живом проекте набралось 46
    каталогов на 2,2 ГБ, а на крупной конфигурации каждое такое дерево — гигабайты.

    Ждать не нужно. К началу СЛЕДУЮЩЕГО прогона платформа файл давно отпустила,
    поэтому уборка перенесена сюда: чужие (прошлые) деревья удаляются без единой
    паузы, а то, что всё ещё занято, останется до следующего раза — оно лежит в
    localStateDir и в Git не попадает.

    Каталог текущего прогона исключается по имени: он только что создан и нужен.

    Дерево УПАВШЕГО прогона исключается по метке. Оно и раньше переживало сам
    отказ — удаление стоит под проверкой успеха, — но следующий же прогон подметал
    его первым делом. А нужен он именно тогда: разбирать отказ по логам без стенда,
    на котором он случился, нечем, и пересобирать стенд ради этого дороже всего
    прогона. Хранится последнее такое дерево: держать историю незачем, а одно
    гарантированно переживает перезапуск фазы.

    Отказ удаления НЕ является ошибкой. Уборка не должна ронять проверку — это
    ровно тот случай, когда падение вреднее остатка.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$AllowedRoot,

        [string]$KeepPath = "",

        # Сколько последних деревьев с меткой отказа сохранить.
        [int]$KeepFailed = 1
    )

    $result = [pscustomobject]@{
        Removed = 0
        Kept = 0
        KeptFailed = @()
    }

    $fullRoot = [System.IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) {
        return $result
    }
    # Тот же предохранитель, что и у поштучного удаления: подметать разрешено
    # только внутри объявленного корня локального состояния.
    if (-not (Test-WorkflowPathUnderRoot -Path $fullRoot -Root $AllowedRoot)) {
        throw "Refusing to sweep temporary trees outside '$AllowedRoot': $fullRoot"
    }

    $keep = if ($KeepPath) { [System.IO.Path]::GetFullPath($KeepPath) } else { "" }

    # Метка отказа ищется до удаления, чтобы решение «что сохранить» принималось
    # один раз и по всему набору, а не по ходу обхода.
    $failed = @(
        Get-ChildItem -LiteralPath $fullRoot -Force -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                Test-Path -LiteralPath (Join-Path $_.FullName (Get-WorkflowFailedRunMarkerName)) -PathType Leaf
            } |
            Sort-Object Name -Descending |
            Select-Object -First ([Math]::Max(0, $KeepFailed)) |
            ForEach-Object { [System.IO.Path]::GetFullPath($_.FullName) }
    )
    $result.KeptFailed = $failed

    foreach ($entry in @(Get-ChildItem -LiteralPath $fullRoot -Force -ErrorAction SilentlyContinue)) {
        $path = [System.IO.Path]::GetFullPath($entry.FullName)
        if ($keep -and $path -eq $keep) {
            continue
        }
        if ($failed -contains $path) {
            continue
        }
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            $result.Removed++
        }
        catch {
            $result.Kept++
        }
    }
    return $result
}

function Remove-WorkflowTemporaryTree {
    <#
    .SYNOPSIS
    Удаляет временный каталог с повторами; неудача не считается ошибкой.

    .DESCRIPTION
    1С освобождает 1Cv8.lgf не мгновенно после выхода, поэтому удаление сразу после
    прогона падает с «file is being used by another process». Чем короче прогон, тем
    выше шанс: с выборочным объёмом уборка начала обгонять освобождение файла.

    Успешная проверка НЕ должна проваливаться из-за уборки. Каталог лежит в
    localStateDir и в Git не попадает, поэтому остаток безвреден: предупредить
    честнее, чем потерять результат.

    Функция общая намеренно. Сначала это было исправлено только в
    Test-Configuration.ps1, а вторая копия в Build-Release.ps1 осталась прежней — и
    выпуск упал на уборке после того, как артефакт уже был собран. Две копии одной
    защиты неизбежно расходятся.

    Возвращает $true, если каталог удалён.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$AllowedRoot,

        # Одна попытка и без пауз: остаток подметает Clear-WorkflowTemporaryRoots в
        # начале следующего прогона, когда платформа файл давно отпустила. Ждать
        # освобождения здесь — значит платить секундами в каждом прогоне за то, что
        # бесплатно решается позже.
        [int]$Attempts = 1,

        [int]$DelaySeconds = 0
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }
    # Проверка принадлежности корню обязательна: путь приходит из отчёта или
    # конфигурации, и без неё опечатка превратила бы уборку в удаление чужого дерева.
    if (-not (Test-WorkflowPathUnderRoot -Path $Path -Root $AllowedRoot)) {
        throw "Refusing to remove a path outside '$AllowedRoot': $Path"
    }

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            if ($attempt -gt 1) {
                Write-Host "Временный каталог удалён с $attempt-й попытки: платформа освобождала файл журнала."
            }
            return $true
        }
        catch {
            if ($attempt -eq $Attempts) {
                Write-Warning "Временный каталог не удалён: $Path. Причина: $($_.Exception.Message)"
                Write-Warning "Результат проверки это не отменяет: каталог в Git не попадает."
                return $false
            }
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    return $false
}

function Get-WorkflowChangedPaths {
    <#
    .SYNOPSIS
    Пути, изменённые относительно базовой ветки, включая незакоммиченное.

    .DESCRIPTION
    Три источника, и все три обязательны: коммиты ветки, правки рабочего каталога и
    неотслеживаемые файлы. Без последнего только что созданный объект метаданных не
    считался бы изменением, и проверка его пропускала бы.

    Определение вынесено в общую функцию намеренно: им пользуются и политика
    актуализации тестов, и отбор целей прогона. Две независимые реализации «что
    изменилось» неизбежно разошлись бы, и тогда политика требовала бы тест для
    одного набора объектов, а прогонялись бы проверки для другого.

    Различия ТОЛЬКО в концах строк изменением не считаются: --ignore-cr-at-eol.
    Смена правил хранения (переход выгрузки на -text и разовая ренормализация)
    переукладывает тысячи файлов, не трогая содержимое ни одного. Без этого
    отбора политика требовала бы тесты на всю конфигурацию за правку, которой не
    было, а прогон уходил бы в полный объём — то есть комплект блокировал бы
    операцию, которую сам же и предписывает.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$BaseRef
    )

    # core.quotePath=false и разбор кавычек — оба обязательны. Без ключа git
    # печатает кириллицу восьмеричными кодами, без разбора остаётся в кавычках
    # путь с пробелом. В обоих случаях путь не совпадает ни с одним правилом
    # политики, и проверка молча считает, что ничего не менялось: на живом
    # репозитории это не всплывает, пока у кого-то ключ выставлен вручную.
    $paths = @()
    $paths += (Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("-c", "core.quotePath=false", "diff", "--ignore-cr-at-eol",
            "--name-only", "$BaseRef...HEAD")).Output
    $paths += (Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("-c", "core.quotePath=false", "diff", "--ignore-cr-at-eol",
            "--name-only", "HEAD")).Output
    $paths += (Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("-c", "core.quotePath=false", "ls-files", "--others",
            "--exclude-standard")).Output

    return @(
        $paths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { (ConvertFrom-WorkflowGitPath -Path ([string]$_)).Replace('\', '/') } |
            Sort-Object -Unique
    )
}

function Get-WorkflowChangedUiTargets {
    <#
    .SYNOPSIS
    Выводит из изменённых путей объекты метаданных, которые можно открыть в интерфейсе.

    .DESCRIPTION
    Заменяет карту «изменённый объект → каталог тестов» выводом из самой выгрузки.
    Карта в политике задавала цель ПУТЁМ, поэтому её точность упиралась в каталог:
    правка одного отчёта требовала прогона всех отчётов. Здесь цель выводится из
    объекта, поэтому доходит до конкретной проверки.

    Из пути `conf/Reports/АнализВыполнения/Forms/Форма/Ext/Form/Module.bsl` берутся
    вид (`Reports`), имя объекта (`АнализВыполнения`) и, если файл описания на месте,
    синоним из самой выгрузки — то же значение, которое видит пользователь в
    интерфейсе. Синоним нужен для отбора параметризованных проверок по имени.

    Синоним берётся ПЕРВЫМ вхождением: дальше в файле идут синонимы реквизитов,
    измерений и табличных частей, и любое другое вхождение дало бы имя не объекта.

    Соответствие каталога виду задано здесь, а не взято из движка web-test: в его
    карте нет множественного числа для регистров, и ссылка для
    `InformationRegisters` собралась бы битой.

    Виды, которые нельзя открыть навигационной ссылкой, попадают в результат с
    `openable = $false`: молча выбрасывать их нельзя, иначе изменение объекта
    выглядело бы как отсутствие изменений.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$ChangedPaths
    )

    # Списочные виды открываются через e1cib/list, прикладные — через e1cib/app.
    $kindMap = @{
        "Catalogs" = "Справочник"
        "Documents" = "Документ"
        "DataProcessors" = "Обработка"
        "Reports" = "Отчет"
        "InformationRegisters" = "РегистрСведений"
        "AccumulationRegisters" = "РегистрНакопления"
        "AccountingRegisters" = "РегистрБухгалтерии"
        "CalculationRegisters" = "РегистрРасчета"
        "Enums" = "Перечисление"
        "ChartsOfCharacteristicTypes" = "ПланВидовХарактеристик"
        "ChartsOfAccounts" = "ПланСчетов"
        "ChartsOfCalculationTypes" = "ПланВидовРасчета"
        "BusinessProcesses" = "БизнесПроцесс"
        "Tasks" = "Задача"
        "ExchangePlans" = "ПланОбмена"
        "DocumentJournals" = "ЖурналДокументов"
    }
    $appKinds = @("Отчет", "Обработка")

    # Перебираются ВСЕ компоненты, а не только основная конфигурация. В монорепозитории
    # расширения лежат рядом с ней, и просмотр одного sourceDir означал, что правка
    # формы расширения не попадает в проверку вовсе: артефакт получался пустым, а
    # прогон сообщал «изменённых объектов нет» — зелёный результат без покрытия.
    $components = @(Get-WorkflowComponentDirectories -Config $Config)
    $found = New-Object System.Collections.Specialized.OrderedDictionary

    foreach ($path in @($ChangedPaths)) {
        $normalized = ([string]$path).Replace('\', '/')
        $component = $null
        foreach ($candidateComponent in $components) {
            if ($normalized.StartsWith("$($candidateComponent.sourceDir)/", [System.StringComparison]::OrdinalIgnoreCase)) {
                $component = $candidateComponent
                break
            }
        }
        if ($null -eq $component) {
            continue
        }
        $sourceDir = $component.sourceDir
        $parts = @($normalized.Substring($sourceDir.Length + 1) -split '/')
        if ($parts.Count -lt 2) {
            continue
        }
        $kindDirectory = $parts[0]
        if (-not $kindMap.Contains($kindDirectory)) {
            continue
        }
        # Второй сегмент — либо `Имя.xml`, либо каталог `Имя`.
        $objectName = $parts[1]
        if ($objectName.EndsWith(".xml", [System.StringComparison]::OrdinalIgnoreCase)) {
            $objectName = $objectName.Substring(0, $objectName.Length - 4)
        }
        if (-not $objectName) {
            continue
        }

        $kind = [string]$kindMap[$kindDirectory]
        # Ключ — вид и имя объекта БЕЗ компонента. Расширение, изменяющее заимствованный
        # объект основной конфигурации, описывает тот же объект: навигационная ссылка у
        # них одна, и проверять его дважды незачем. Пути обоих компонентов при этом
        # сохраняются, чтобы по артефакту было видно, откуда пришло изменение.
        $key = "$kind.$objectName"
        if ($found.Contains($key)) {
            [void]$found[$key].changedPaths.Add($normalized)
            if ($component.isExtension -and -not $found[$key].components.Contains($component.name)) {
                [void]$found[$key].components.Add($component.name)
            }
            continue
        }

        $synonym = ""
        $descriptionFile = Join-Path $RepositoryRoot (
            "$sourceDir/$kindDirectory/$objectName.xml".Replace('/', '\')
        )
        if (Test-Path -LiteralPath $descriptionFile -PathType Leaf) {
            $text = [System.IO.File]::ReadAllText($descriptionFile)
            $match = [regex]::Match($text, '<Synonym>.*?<v8:content>(?<value>[^<]*)</v8:content>', 'Singleline')
            if ($match.Success) {
                $synonym = $match.Groups["value"].Value.Trim()
            }
        }

        $changed = New-Object System.Collections.ArrayList
        [void]$changed.Add($normalized)
        $componentNames = New-Object System.Collections.ArrayList
        if ($component.isExtension) {
            [void]$componentNames.Add($component.name)
        }
        [void]$found.Add($key, [pscustomobject]@{
            kind = $kind
            name = $objectName
            synonym = $synonym
            link = "$kind.$objectName"
            openable = $true
            listForm = (@($appKinds) -notcontains $kind)
            components = $componentNames
            changedPaths = $changed
        })
    }

    $result = @()
    foreach ($key in @($found.Keys)) {
        $entry = $found[$key]
        $result += [pscustomobject]@{
            kind = $entry.kind
            name = $entry.name
            synonym = $entry.synonym
            link = $entry.link
            openable = $entry.openable
            listForm = $entry.listForm
            # Пусто — объект основной конфигурации. Непусто — изменение пришло из
            # перечисленных расширений: для них правка может требовать ещё и проверки
            # применимости, а не только открытия формы.
            extensions = @($entry.components)
            changedPaths = @($entry.changedPaths)
        }
    }
    return @($result)
}

function ConvertFrom-WorkflowTestPathPattern {
    <#
    .SYNOPSIS
    Превращает regex политики вида `^tests/web-ui/03-reports/` в буквальный префикс пути.

    .DESCRIPTION
    Возвращает пустую строку, если буквальной части нет.

    Разбор посимвольный, и это принципиально: снимать экранирование ДО обрезки по
    первому метасимволу нельзя. Тогда regex-точка становится неотличимой от
    буквальной, и шаблон `^tests/web-ui/.+\.test\.mjs$` даёт путь «tests/web-ui/.»
    вместо корня сьюта — из-за чего не срабатывает признак «правило требует сьют
    целиком», и отбор молча считает, что запускать нечего.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $value = $Pattern
    if ($value.StartsWith("^")) {
        $value = $value.Substring(1)
    }

    $metacharacters = [char[]]('.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '^', '$')
    $literal = New-Object System.Text.StringBuilder
    for ($index = 0; $index -lt $value.Length; $index++) {
        $character = $value[$index]
        if ($character -eq '\') {
            if ($index + 1 -ge $value.Length) {
                break
            }
            # Экранированный символ буквальный: `\.` — это точка в имени файла.
            [void]$literal.Append($value[$index + 1])
            $index++
            continue
        }
        if ($metacharacters -contains $character) {
            break
        }
        [void]$literal.Append($character)
    }
    return $literal.ToString().TrimEnd('/')
}

function Get-WorkflowWebUiScope {
    <#
    .SYNOPSIS
    Объём Web UI прогона для фазы: из webUiTests.scope манифеста, с проверками.

    .DESCRIPTION
    Полный регресс по решению команды не обязателен на задачных фазах, но обязателен
    на выпуске. Поэтому `release` здесь жёстко full: попытку задать иначе отклоняем,
    а не «уважаем настройку». Ослабить единственную оставшуюся полную проверку —
    значит остаться без гарантии вовсе, и настройкой это делаться не должно.

    Отсутствие секции scope означает full: проект, ничего не настроивший, получает
    прежнее поведение, а не молча уменьшенную проверку.

    Значение `affected` — объём БЕЗ обязательного минимума: прогоняется ровно то,
    что политика test-maintenance связала с правкой, и ничего сверх. Пустой отбор
    здесь законен и означает, что покрытие этой правки лежит не в сьюте Web UI:
    политика требует тесты для каждой области конфигурации, но для прикладной
    логики и HTTP-контракта это функциональный контур, а он в фазе прогоняется
    целиком и объёмом не ограничивается. Добавлять в такой прогон обязательный
    минимум значило бы выполнять сценарии, к правке отношения не имеющие.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [ValidateSet("selfcheck", "verify", "release", "package")]
        [string]$PhaseKey,

        [switch]$Full
    )

    if ($PhaseKey -eq "release") {
        return "full"
    }
    # У сборки поставки объём «только затронутое» — это не настройка, а смысл
    # сценария: разработчику нужен cf со своей функциональностью, а не
    # доказательство того, чего правка не касалась. Полный прогон стоит большую
    # часть времени и потому запускается ОСОЗНАННО, отдельным сценарием выпуска.
    #
    # Умолчание здесь безопасно, хотя и отличается от общего правила «не задано —
    # значит full»: результат такой сборки явно помечен как не release-ready, в
    # Git не кладётся и называется иначе. Перепутать его с выпуском нельзя.
    if ($PhaseKey -eq "package") {
        $packageConfig = Get-WorkflowSettingValue -Object $Config -Name "webUiTests" -Default $null
        $packageScopes = Get-WorkflowSettingValue -Object $packageConfig -Name "scope" -Default $null
        $packageValue = [string](Get-WorkflowSettingValue -Object $packageScopes -Name "package" -Default "")
        if ($packageValue) {
            return $packageValue
        }
        return "affected"
    }
    if ($Full) {
        return "full"
    }

    $webUiConfig = Get-WorkflowSettingValue -Object $Config -Name "webUiTests" -Default $null
    $scopeConfig = Get-WorkflowSettingValue -Object $webUiConfig -Name "scope" -Default $null
    $value = [string](Get-WorkflowSettingValue -Object $scopeConfig -Name $PhaseKey -Default "")
    if (-not $value) {
        return "full"
    }
    $allowed = @("full", "smoke", "affected", "affected+smoke")
    if (@($allowed) -notcontains $value) {
        throw "webUiTests.scope.$PhaseKey has an unknown value '$value'. Allowed: $($allowed -join ', ')."
    }
    return $value
}

function Test-WorkflowPendingSuitePath {
    <#
    .SYNOPSIS
    Лежит ли путь сьюта в каталоге отложенных сценариев.

    .DESCRIPTION
    Отложенный сценарий — написанный, но ещё не включённый в обязательный объём:
    задача идёт четвёртую неделю, форма ещё не готова, а проверка на неё уже
    написана. Держать такую проверку красной нельзя — красное, которое «так и
    должно быть», обесценивает весь прогон, и через месяц никто не смотрит на
    список упавших.

    Признак — КАТАЛОГ `pending`, а не отметка внутри файла. Разница в том, куда
    ошибается механизм при сбое. Ошибка в разборе отметки МОЛЧА выключила бы живой
    сценарий: он перестал бы выполняться, а прогон остался бы зелёным. Ошибка в
    сопоставлении пути включает отложенный сценарий в прогон — он падает, и это
    видно сразу. Из двух неверных исходов выбран громкий.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path
    )

    $normalized = ([string]$Path).Replace('\', '/').Trim('/')
    if (-not $normalized) {
        return $false
    }
    return ($normalized -eq "pending" -or $normalized -match '(^|/)pending(/|$)')
}

function Select-WorkflowRunnableSuiteTargets {
    <#
    .SYNOPSIS
    Убирает из списка целей отложенные сценарии.

    .PARAMETER AllowPending
    Оставить отложенные. Передаётся только там, где сценарий назван ЧЕЛОВЕКОМ явно
    (ключ -TestPath петли Probe): ради этого отложенные и заводятся — их пишут и
    отлаживают до того, как включить.
    #>
    param(
        [AllowEmptyCollection()]
        [string[]]$Targets = @(),

        [switch]$AllowPending
    )

    $result = @()
    foreach ($target in @($Targets)) {
        $value = [string]$target
        if (-not $value) {
            continue
        }
        if (-not $AllowPending -and (Test-WorkflowPendingSuitePath -Path $value)) {
            Write-Host "Отложенный сценарий пропущен: $value"
            continue
        }
        $result += $value
    }
    return @($result)
}

function Get-WorkflowProbePlan {
    <#
    .SYNOPSIS
    Решает, какие контуры и с каким отбором прогоняет петля Probe.

    .DESCRIPTION
    Вынесено из фазы отдельной функцией ровно потому, что это правило ОТБОРА:
    ошибка в нём не падает, а меняет объём прогона. Прогнать меньше названного —
    зелёный результат, ничего не доказывающий; прогнать больше — потерянная
    скорость, ради которой петля и заводилась. Оба исхода по выводу фазы
    неотличимы от правильного, поэтому правило проверяется тестами, а не глазами.

    Разбор ключей:

      -FunctionalTest — имена тестов функционального контура. Задан: гоняем
        функциональный контур и ТОЛЬКО его. Разработчик, назвавший тест
        проведения документа, не просил вдобавок интерфейс, и подмешивать
        выведенное из diff здесь нельзя: петля перестала бы быть точечной.

      -TestPath — сценарии Web UI поимённо. Отложенные сценарии пропускаются:
        названное человеком сильнее умолчания «pending не гоняем».

      Ни одного ключа — цели Web UI берутся из diff, отложенные отбрасываются.

    Оба ключа вместе допустимы: контуры независимы, и правка, задевающая и
    логику, и форму, проверяется одним вызовом. Функциональный контур идёт
    первым — он дешевле, и его отказ делает проверку интерфейса бессмысленной.
    #>
    param(
        [AllowEmptyCollection()]
        [string[]]$TestPath = @(),

        [AllowEmptyCollection()]
        [string[]]$FunctionalTest = @(),

        [AllowEmptyCollection()]
        [string[]]$AffectedTargets = @()
    )

    $functionalTests = @($FunctionalTest | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    $explicitTargets = @($TestPath | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })

    $plan = [pscustomobject]@{
        RunFunctional = $functionalTests.Count -gt 0
        FunctionalTests = $functionalTests
        RunWebUi = $false
        WebUiTargets = @()
        WebUiSelection = ""
    }

    if ($explicitTargets.Count -gt 0) {
        $plan.RunWebUi = $true
        $plan.WebUiSelection = "test-path"
        $plan.WebUiTargets = @(Select-WorkflowRunnableSuiteTargets -Targets $explicitTargets -AllowPending)
        return $plan
    }

    if ($plan.RunFunctional) {
        # Названы только функциональные тесты — интерфейс не трогаем.
        return $plan
    }

    $plan.RunWebUi = $true
    $plan.WebUiSelection = "affected"
    $plan.WebUiTargets = @(Select-WorkflowRunnableSuiteTargets -Targets $AffectedTargets)
    return $plan
}

function Get-WorkflowUnrequestedFunctionalTests {
    <#
    .SYNOPSIS
    Тесты, которые выполнились, хотя их не называли.

    .DESCRIPTION
    Отказом это НЕ является. Адаптер вправе выполнять неделимые группы: одна
    процедура может выполнить датасет однажды и проверить три его свойства —
    разделить такое нельзя, и требовать этого значило бы запретить нормальную
    реализацию.

    Но и молчать нельзя. Лишние тесты не портят результат, они съедают время —
    то самое, ради которого петля заводится, — и по выводу это незаметно.
    Поэтому список печатается, а решать разработчику.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResultPath,

        [AllowEmptyCollection()]
        [string[]]$ExpectedTests = @()
    )

    $expected = @($ExpectedTests | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($expected.Count -eq 0 -or -not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        return @()
    }

    $extra = @()
    foreach ($line in @(Get-Content -LiteralPath $ResultPath -Encoding UTF8)) {
        $match = [regex]::Match([string]$line, '^(?:PASS|FAIL)\|(?<name>[^|]*)\|')
        if (-not $match.Success) {
            continue
        }
        $name = $match.Groups["name"].Value.Trim()
        if ($name -and $expected -notcontains $name -and $extra -notcontains $name) {
            $extra += $name
        }
    }
    return @($extra)
}

function Test-WorkflowFunctionalSmokeResult {
    <#
    .SYNOPSIS
    Проверяет, что отбор функциональных тестов действительно применён.

    .DESCRIPTION
    Самое опасное место всего отбора. Формат результата — первая строка OK/ERROR,
    дальше `PASS|имя|детали`. Пустой список результатов даёт «OK» без единой
    строки: адаптер, не понявший отбор или не нашедший теста по имени, сообщает
    успех, ничего не выполнив. Такой прогон выглядит как доказательство и им не
    является.

    Поэтому названные тесты сверяются со списком фактически выполненных. Проверку
    делает комплект, а не адаптер: адаптер пишет проект, и полагаться на то, что
    в каждом проекте её напишут одинаково, нельзя.

    Возвращает список претензий. Пустой список — отбор применён.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResultPath,

        [AllowEmptyCollection()]
        [string[]]$ExpectedTests = @()
    )

    $expected = @($ExpectedTests | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($expected.Count -eq 0) {
        return @()
    }
    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        return @("файл результата не найден: $ResultPath")
    }

    $executed = @()
    foreach ($line in @(Get-Content -LiteralPath $ResultPath -Encoding UTF8)) {
        $match = [regex]::Match([string]$line, '^(?:PASS|FAIL)\|(?<name>[^|]*)\|')
        if ($match.Success) {
            $executed += $match.Groups["name"].Value.Trim()
        }
    }

    if ($executed.Count -eq 0) {
        return @("не выполнено ни одного теста")
    }

    $problems = @()
    foreach ($name in $expected) {
        if ($executed -notcontains $name) {
            $problems += "тест '$name' не выполнялся"
        }
    }
    return @($problems)
}

function Get-WorkflowPendingScenarios {
    <#
    .SYNOPSIS
    Отложенные сценарии сьюта с разобранной шапкой и возрастом.

    .DESCRIPTION
    Шапка обязательна и машиночитаема:

        export const pending = {
          task: 'AB-123',
          since: '2026-09-09',
          reason: 'форма ещё не реализована',
        };

    Проверяется ФОРМА, а не содержание: без ключа задачи и даты отложенный сценарий
    через полгода неотличим от забытого мусора, и удалить его будет страшно —
    неизвестно, чей он и зачем. Возраст выводится и печатается, потому что механизм
    «пока не проверяем» опасен ровно тем, что удобен: без счётчика возраста
    отложенное копится молча.

    Причина отказа возвращается строкой, а не бросается: вызывающий (gate) сам
    решает, где падать, а где печатать.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        # Дата отсчёта возраста. Задаётся явно в тестах, чтобы проверка не зависела
        # от текущего дня.
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $webUiConfig = Get-WorkflowSettingValue -Object $Config -Name "webUiTests" -Default $null
    if ($null -eq $webUiConfig -or -not [string]$webUiConfig.suite) {
        return @()
    }
    $suiteRelative = ([string]$webUiConfig.suite).Replace('\', '/').Trim('/')
    $suiteRoot = Join-Path $RepositoryRoot ($suiteRelative.Replace('/', '\'))
    $pendingRoot = Join-Path $suiteRoot "pending"
    if (-not (Test-Path -LiteralPath $pendingRoot -PathType Container)) {
        return @()
    }

    $rootPrefix = [System.IO.Path]::GetFullPath($suiteRoot).TrimEnd('\') + '\'
    $results = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $pendingRoot -Recurse -File -Filter "*.test.mjs" | Sort-Object FullName)) {
        $relative = "$suiteRelative/$($file.FullName.Substring($rootPrefix.Length).Replace('\', '/'))"
        $text = [System.IO.File]::ReadAllText($file.FullName)
        $entry = [pscustomobject]@{
            Path = $relative
            Task = ""
            Since = ""
            Reason = ""
            AgeDays = $null
            Problem = ""
        }

        $header = [regex]::Match($text, 'export\s+const\s+pending\s*=\s*\{(?<body>[^}]*)\}')
        if (-not $header.Success) {
            $entry.Problem = "нет шапки: export const pending = { task, since, reason }"
            $results += $entry
            continue
        }
        $body = $header.Groups["body"].Value
        foreach ($field in @("task", "since", "reason")) {
            $match = [regex]::Match($body, "$field\s*:\s*['""](?<value>[^'""]*)['""]")
            if ($match.Success) {
                $entry.$([cultureinfo]::InvariantCulture.TextInfo.ToTitleCase($field)) = $match.Groups["value"].Value.Trim()
            }
        }

        $missing = @()
        foreach ($field in @("Task", "Since", "Reason")) {
            if (-not [string]$entry.$field) {
                $missing += $field.ToLowerInvariant()
            }
        }
        if ($missing.Count -gt 0) {
            $entry.Problem = "в шапке не заполнено: $($missing -join ', ')"
            $results += $entry
            continue
        }

        $since = [DateTimeOffset]::MinValue
        $parsed = [DateTimeOffset]::TryParseExact(
            [string]$entry.Since,
            "yyyy-MM-dd",
            [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeLocal,
            [ref]$since
        )
        if (-not $parsed) {
            $entry.Problem = "поле since не в формате YYYY-MM-DD: '$([string]$entry.Since)'"
            $results += $entry
            continue
        }
        $entry.AgeDays = [int][Math]::Floor(($Now - $since).TotalDays)
        $results += $entry
    }
    return @($results)
}

function Get-WorkflowSuiteRootTargets {
    <#
    .SYNOPSIS
    Корень сьюта, развёрнутый в цели без отложенных сценариев.

    .DESCRIPTION
    Движок прогона получает каталог и обходит его рекурсивно — то есть цель
    «весь сьют» затянула бы и `pending`. Фильтровать это внутри движка нельзя:
    движок принадлежит проекту, а правило — процессу.

    Поэтому корень разворачивается в непосредственные ветви: подкаталоги, кроме
    `pending`, и файлы сценариев, лежащие прямо в корне. Список короткий (по числу
    разделов сьюта), а отложенное в него не попадает по построению.

    Пустой результат означает, что кроме `pending` в сьюте ничего нет, — тогда
    возвращается сам корень: молча прогонять НИЧЕГО опаснее, чем прогнать всё.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$SuiteRelativePath
    )

    $suiteRelative = ([string]$SuiteRelativePath).Replace('\', '/').Trim('/')
    $suiteRoot = Join-Path $RepositoryRoot ($suiteRelative.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $suiteRoot -PathType Container)) {
        return @($suiteRelative)
    }

    $targets = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $suiteRoot -Directory | Sort-Object Name)) {
        if (Test-WorkflowPendingSuitePath -Path $directory.Name) {
            continue
        }
        $targets += "$suiteRelative/$($directory.Name)"
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $suiteRoot -File -Filter "*.test.mjs" | Sort-Object Name)) {
        $targets += "$suiteRelative/$($file.Name)"
    }
    if ($targets.Count -eq 0) {
        return @($suiteRelative)
    }
    return @($targets)
}

function Find-WorkflowChildObjectProblems {
    <#
    .SYNOPSIS
    Расхождения между объявленными вложенными объектами (формы, макеты, команды) и файлами на диске.

    .DESCRIPTION
    Проверка целостности сверяла Configuration.xml с файлами ОБЪЕКТОВ и на этом
    останавливалась. Вложенные объекты — то, что объявлено в ChildObjects самого
    объекта, — не проверял никто, и рукописная форма прошла мимо: объект ссылался
    на ФормаСписка, файла Forms/ФормаСписка.xml не было, и узнали об этом от
    загрузки конфигурации.

    Проверка идёт в обе стороны, и вторая сторона не менее важна первой: файл формы
    без объявления 1С просто не загрузит, а в выгрузке он выглядит существующим.

    Форме нужны ДВА файла: дескриптор Forms/<Имя>.xml и разметка
    Forms/<Имя>/Ext/Form.xml. Ровно на отсутствии первого и ломается ручная
    сборка формы: модуль с разметкой написать догадываются, дескриптор — нет.

    Ожидаемые файлы намеренно перечислены, а не выведены из каталога: непустой
    каталог Forms/<Имя> сам по себе ничего не доказывает.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectXmlPath
    )

    $problems = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $ObjectXmlPath -PathType Leaf)) {
        return @($problems)
    }

    $document = New-Object System.Xml.XmlDocument
    $document.PreserveWhitespace = $false
    try {
        $document.Load([System.IO.Path]::GetFullPath($ObjectXmlPath))
    }
    catch {
        # Некорректный XML — забота отдельной проверки, которая сообщит о нём
        # внятно. Здесь второе сообщение об одном файле только путало бы.
        return @($problems)
    }

    $objectName = [System.IO.Path]::GetFileNameWithoutExtension($ObjectXmlPath)
    $objectDirectory = Join-Path ([System.IO.Path]::GetDirectoryName($ObjectXmlPath)) $objectName

    # Вложенные объекты, у которых есть собственные файлы. Реквизиты, измерения и
    # ресурсы объявляются элементами со структурой внутри и файлов не имеют.
    $kinds = [ordered]@{
        Form = "Forms"
        Template = "Templates"
        Command = "Commands"
    }

    $declared = @{}
    foreach ($kind in $kinds.Keys) {
        $declared[$kind] = New-Object System.Collections.ArrayList
    }

    foreach ($childObjects in @($document.SelectNodes('//*[local-name()="ChildObjects"]'))) {
        foreach ($node in @($childObjects.ChildNodes)) {
            if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element) {
                continue
            }
            if (-not $kinds.Contains($node.LocalName)) {
                continue
            }
            # Простой элемент с именем внутри. Сложный элемент того же имени (если
            # платформа однажды такой введёт) пропускаем: имени в нём нет.
            if ($node.SelectSingleNode('*')) {
                continue
            }
            $name = ([string]$node.InnerText).Trim()
            if ($name) {
                [void]$declared[$node.LocalName].Add($name)
            }
        }
    }

    foreach ($kind in $kinds.Keys) {
        $directoryName = $kinds[$kind]
        $kindDirectory = Join-Path $objectDirectory $directoryName

        foreach ($name in @($declared[$kind])) {
            $expected = New-Object System.Collections.ArrayList
            [void]$expected.Add("$directoryName/$name.xml")
            if ($kind -eq "Form") {
                [void]$expected.Add("$directoryName/$name/Ext/Form.xml")
            }
            foreach ($relative in $expected) {
                $full = Join-Path $objectDirectory ($relative -replace "/", [string][char]92)
                if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                    [void]$problems.Add(
                        "$objectName объявляет $kind.$name, но файла нет: $objectName/$relative")
                }
            }
        }

        if (-not (Test-Path -LiteralPath $kindDirectory -PathType Container)) {
            continue
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $kindDirectory -Filter "*.xml" -File)) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            if (@($declared[$kind]) -contains $name) {
                continue
            }
            [void]$problems.Add(
                "$objectName/$directoryName/$name.xml лежит на диске, но в ChildObjects не объявлен: " +
                "конфигурация его не увидит")
        }
    }

    return @($problems)
}

function Get-WorkflowAddedPaths {
    <#
    .SYNOPSIS
    Пути файлов, ПОЯВИВШИХСЯ в правке: и закоммиченные, и ещё нет.

    .DESCRIPTION
    Считать только закоммиченное здесь нельзя, и это выяснилось дорого. Шаг,
    искавший новые объекты метаданных, смотрел лишь `diff BaseRef...HEAD` — а фазы
    Compile и Selfcheck идут по РАБОЧЕМУ ДЕРЕВУ, где правка ещё не закоммичена.
    Новый регистр прошёл обе фазы с бодрым «новых объектов метаданных нет», и шаг
    заговорил бы только на Verify, когда правка уже написана целиком.

    Остальная политика считает изменения именно так — коммиты плюс рабочее дерево,
    — и расхождение двух определений «что изменилось» ошибается в ту сторону,
    которую замечают последней: проверка молчит.

    Неотслеживаемые файлы входят обязательно: новый объект метаданных до `git add`
    — это именно они.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [string]$BaseRef = ""
    )

    $paths = New-Object System.Collections.ArrayList

    $add = {
        param([string[]]$Values)
        foreach ($value in @($Values)) {
            $normalized = ([string]$value).Trim().Replace([char]92, [char]47)
            if ($normalized -and -not $paths.Contains($normalized)) {
                [void]$paths.Add($normalized)
            }
        }
    }

    if ($BaseRef) {
        & $add @((Invoke-WorkflowGit `
            -RepositoryRoot $RepositoryRoot `
            -Arguments @("-c", "core.quotePath=false", "diff", "--name-only",
                "--diff-filter=A", "$BaseRef...HEAD")).Output)
    }

    & $add @((Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("-c", "core.quotePath=false", "diff", "--name-only",
            "--diff-filter=A", "HEAD")).Output)

    & $add @((Invoke-WorkflowGit `
        -RepositoryRoot $RepositoryRoot `
        -Arguments @("-c", "core.quotePath=false", "ls-files", "--others",
            "--exclude-standard")).Output)

    return @($paths)
}

function Find-WorkflowObjectsWithoutTests {
    <#
    .SYNOPSIS
    Новые объекты метаданных, чьи имена не встречаются ни в одном изменённом тесте.

    .DESCRIPTION
    Путевое правило «изменился какой-нибудь файл в tests/» отличить покрытие нового
    объекта от правки постороннего теста не может. На живой правке это и вышло:
    тест постраничности зачёлся как покрытие новой очереди обогащения, и очередь
    осталась без единой проверки при зелёном гейте.

    Проверяется УПОМИНАНИЕ имени объекта в тексте изменённых тестов. Это
    эвристика, и она честно слабее «тест действительно проверяет объект»: написать
    имя в комментарии никто не мешает. Но она ловит то, ради чего заводится —
    объект, о котором тесты не знают вовсе, — и не требует от проекта размечать
    соответствие «объект → тест» руками.
    #>
    param(
        [string[]]$Objects = @(),

        [string[]]$TestContents = @()
    )

    $missing = New-Object System.Collections.ArrayList
    $haystack = (@($TestContents) -join [System.Environment]::NewLine)

    foreach ($object in @($Objects | Where-Object { $_ })) {
        $name = @(([string]$object).Split([char]47))[-1]
        if (-not $name) {
            continue
        }
        if ($haystack.Contains($name)) {
            continue
        }
        [void]$missing.Add([string]$object)
    }

    return @($missing)
}

function Get-WorkflowAddedMetadataObjects {
    <#
    .SYNOPSIS
    Объекты метаданных, ПОЯВИВШИЕСЯ в правке. Не изменённые — именно новые.

    .DESCRIPTION
    Различие принципиально. Правку существующего объекта покрывают уже
    написанные проверки: они его знают и на нём падают. Новый объект не покрыт
    ничем по определению, и данных на стенде для него тоже нет — показать его
    не на чем.

    Именно так новый отчёт уехал пустым: проверка «сформировался без ошибки»
    прошла, потому что пустой результат от правильного она не отличает, а
    отличить их можно только по данным, которых на стенде не было.

    Возвращает относительные пути ДОБАВЛЕННЫХ корневых файлов объектов вида
    `<sourceDir>/<Вид>/<Имя>.xml`. Файлы внутри объекта (модули, формы, макеты)
    в счёт не идут: объект один, и требовать за него фикстуры нужно один раз.
    #>
    param(
        [string[]]$AddedPaths = @(),

        [Parameter(Mandatory = $true)]
        [string]$SourceRelativePath,

        # Белый список видов. Пустой означает «все виды, кроме исключённых»:
        # так работает правило о тестах, где по умолчанию поднадзорно ВСЁ.
        [string[]]$Kinds = @(),

        # Виды, которые не поднадзорны. Смысл имеет только при пустом $Kinds.
        [string[]]$ExcludeKinds = @()
    )

    $source = ([string]$SourceRelativePath).Replace('\', '/').Trim('/')
    $result = New-Object System.Collections.ArrayList

    foreach ($path in @($AddedPaths | Where-Object { $_ })) {
        $normalized = ([string]$path).Replace('\', '/').Trim('/')
        if ($source -and -not $normalized.StartsWith("$source/")) {
            continue
        }
        $tail = if ($source) { $normalized.Substring($source.Length + 1) } else { $normalized }
        $parts = @($tail.Split('/'))
        if ($parts.Count -ne 2) {
            continue
        }
        # Белый список сужает, чёрный — исключает. Пустой белый список вместе с
        # пустым чёрным означает «любой вид», и это осознанное умолчание правила
        # о тестах: неизвестный вид обязан ТРЕБОВАТЬ проверку, а не освобождать
        # от неё. Раньше умолчанием был короткий белый список, и новая константа
        # с регламентным заданием прошли мимо правила молча.
        if (@($Kinds).Count -gt 0 -and @($Kinds) -notcontains $parts[0]) {
            continue
        }
        if (@($ExcludeKinds) -contains $parts[0]) {
            continue
        }
        if (-not $parts[1].EndsWith(".xml")) {
            continue
        }
        $name = $parts[1].Substring(0, $parts[1].Length - 4)
        $value = "$($parts[0])/$name"
        if (-not $result.Contains($value)) {
            [void]$result.Add($value)
        }
    }
    return @($result)
}

function Get-WorkflowKindsExemptFromTests {
    <#
    .SYNOPSIS
    Виды метаданных, новому объекту которых тест не требуется.

    .DESCRIPTION
    Список ИСКЛЮЧЕНИЙ, а не разрешений, и направление выбрано намеренно. Пока
    правило смотрело короткий белый список — отчёты, обработки, справочники,
    документы, регистры, — новая константа и новое регламентное задание проходили
    гейт с бодрым «новых объектов метаданных нет». Дыра, ради которой правило
    заводилось, оставалась открытой для всего, что в список не попало.

    При белом списке забытый вид МОЛЧА освобождается от проверки. При чёрном
    забытый вид её требует: ошибка достаётся автору сразу и стоит одной строки
    в исключениях, а не непокрытого объекта в рабочей базе.

    Освобождены виды, у которых нет собственного поведения: их содержимое
    проверяется через объекты, которые ими пользуются. Подсистема — состав
    интерфейса (его смотрит правило command-interface), картинки и стили —
    оформление, макет — данные для печати того объекта, который печатает.

    Проект добавляет свои исключения ключом testMaintenance.newObjectTestExemptKinds:
    это уточнение, а не обход — обход выглядел бы как ключ «не проверять ветку».
    #>
    param(
        [object]$Config = $null
    )

    $kinds = New-Object System.Collections.ArrayList
    foreach ($kind in @("Subsystems", "CommonPictures", "CommonTemplates",
            "Styles", "StyleItems", "Languages", "Interfaces")) {
        [void]$kinds.Add($kind)
    }

    if ($null -ne $Config) {
        $maintenance = Get-WorkflowSettingValue -Object $Config -Name "testMaintenance" -Default $null
        foreach ($kind in @(Get-WorkflowSettingValue `
            -Object $maintenance -Name "newObjectTestExemptKinds" -Default @())) {
            $value = ([string]$kind).Trim()
            if ($value -and -not $kinds.Contains($value)) {
                [void]$kinds.Add($value)
            }
        }
    }

    return @($kinds)
}

function Get-WorkflowKindsRequiringFixtures {
    <#
    .SYNOPSIS
    Виды метаданных, которым нужны данные на стенде.

    .DESCRIPTION
    Уже, чем список видов вообще, и это выяснилось на живой правке. Правило
    требовало фикстуры для ЛЮБОГО нового объекта, включая служебный регистр-очередь
    — а у очереди правильное состояние на стенде это ПУСТО. Засевать её значило бы
    выдумывать данные ради правила.

    Фикстуры нужны тому, что показывают: отчёт, обработка, справочник, документ без
    данных выглядят рабочими и пустыми одновременно, и проверка «открылось без
    ошибки» их не различает. Регистры пишет код, и проверяют их тесты, которые
    сами создают себе данные.

    Тесты при этом обязательны ВСЕМ новым объектам — это отдельное правило
    new-objects-have-tests, и оно списком видов не сужается.
    #>
    param()

    return @("Reports", "DataProcessors", "Catalogs", "Documents")
}

function Find-WorkflowPowerShellLintIssues {
    <#
    .SYNOPSIS
    Признаки правки, которую испортила генерация: съеденный обратный слэш.

    .DESCRIPTION
    Скрипты комплекта нередко правятся не руками, а генератором, и в Windows-путях
    обратный слэш там становится управляющим символом: '\t' превращается в
    табуляцию, '\\' — в пустую строку. Получившийся код РАЗБИРАЕТСЯ парсером, и
    шаг powershell-parses его пропускает; падает он в рантайме, иногда через
    несколько фаз.

    За один день это случилось дважды: .Replace('', '/') с пустым образцом и путь
    "tests<TAB>est-maintenance.json". Оба раза диагностика начиналась с середины
    чужого стектрейса.

    Ищутся ровно два признака, а не стиль вообще: пустой образец у Replace и
    управляющий символ внутри строкового литерала, похожего на путь. Узость —
    условие полезности: линтер, который ругается на всё, отключают целиком.
    #>
    param(
        [string[]]$Paths = @()
    )

    $issues = New-Object System.Collections.ArrayList
    $tab = [string][char]9
    $cr = [string][char]13

    foreach ($path in @($Paths | Where-Object { $_ })) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }

        # Второй класс: локальная переменная, случайно совпавшая с параметром.
        # PowerShell регистр не различает, поэтому $adoption и $Adoption — одна
        # переменная, и присваивание объекта параметру [switch] роняет скрипт
        # при ПРИВЯЗКЕ, до первой строки вывода. Падает только у того, кто
        # передал ключ, поэтому ключ -Adoption не работал ни разу и ни один
        # тест этого не заметил.
        #
        # Совпадение регистра в счёт не идёт: $ReportPath = "..." при
        # [string]$ReportPath — это осознанная подстановка умолчания, она
        # встречается в комплекте полтора десятка раз и законна.
        $rawText = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
        $parameterBlock = [regex]::Match($rawText, "(?ms)^param\s*\((.*?)^\)")
        $declaredParameters = @{}
        $parameterBlockLine = 0
        if ($parameterBlock.Success) {
            foreach ($declaration in [regex]::Matches(
                $parameterBlock.Groups[1].Value, '\[([A-Za-z.\[\]]+)\]\s*\$(\w+)')) {
                $declaredParameters[$declaration.Groups[2].Value.ToLowerInvariant()] =
                    $declaration.Groups[2].Value
            }
            $parameterBlockLine = ([regex]::Matches(
                $rawText.Substring(0, $parameterBlock.Index + $parameterBlock.Length), "`n")).Count + 1
        }

        $lineNumber = 0
        $inBlockComment = $false
        foreach ($line in @(Get-Content -LiteralPath $path -Encoding UTF8)) {
            $lineNumber = $lineNumber + 1

            # Описание дефекта — не дефект. Комментарий, объясняющий ловушку, и
            # фикстура теста, которая её воспроизводит, обязаны проходить: иначе
            # проверку нельзя ни задокументировать, ни проверить тестом.
            # Помеченная строка пропускается явно — молчаливых исключений нет.
            #
            # Блочный комментарий считается отдельно: справка функции начинается
            # с <# и её строки не имеют решётки в начале, а именно там ловушка и
            # описана подробнее всего.
            $trimmed = $line.TrimStart()
            if ($inBlockComment) {
                if ($line -match "#>") {
                    $inBlockComment = $false
                }
                continue
            }
            if ($trimmed.StartsWith("<#")) {
                if ($line -notmatch "#>") {
                    $inBlockComment = $true
                }
                continue
            }
            if ($trimmed.StartsWith("#") -or $line -match "lint-ok") {
                continue
            }

            if ($declaredParameters.Count -gt 0 -and $lineNumber -gt $parameterBlockLine -and
                $line -match '^\s*\$(\w+)\s*=[^=]') {
                $assigned = $matches[1]
                $declared = $declaredParameters[$assigned.ToLowerInvariant()]
                if ($declared -and $declared -cne $assigned) {
                    [void]$issues.Add([pscustomobject]@{
                        Path = $path
                        Line = $lineNumber
                        Message = ("переменная `$$assigned — это параметр `$$declared" +
                            ": регистр в PowerShell не различается, и присваивание летит в его тип")
                    })
                    continue
                }
            }

            # Третий класс: приведение типа, применённое ко всему выражению.
            # В записи [string](...).ToLowerInvariant() приведение относится к
            # результату ВМЕСТЕ с вызовом метода, поэтому метод зовётся у
            # исходного типа — у Boolean его нет, и этап падает на первом живом
            # запуске. Парсер такой код принимает, проверки по тексту скрипта
            # тоже: так дефект дожил до первой сборки инструкции.
            #
            # Обращение к СВОЙСТВУ после приведения законно и встречается в
            # комплекте больше десятка раз ([string](...).name), поэтому ловится
            # только вызов метода — со скобками.
            if ($line -match "\[(string|int|bool|double|datetime)\]\([^)]*\)\.[A-Za-z]+\(") {
                [void]$issues.Add([pscustomobject]@{
                    Path = $path
                    Line = $lineNumber
                    Message = ("приведение типа относится ко всему выражению: метод вызовется " +
                        "у исходного типа. Приводите до вызова: (...).ToString().ToLower()")
                })
                continue
            }

            if ($line -match "\.Replace\(\s*(''|"""")\s*,") {
                [void]$issues.Add([pscustomobject]@{
                    Path = $path
                    Line = $lineNumber
                    Message = "пустой образец в Replace — похоже, генерация съела обратный слэш"
                })
                continue
            }

            # Признак сужен дважды, и оба сужения выяснились на живом отказе.
            #
            # Первое: литерал должен выглядеть ПУТЁМ — слэш или расширение файла.
            # Одной точки мало: в комплекте лежат примеры кода 1С, где точка это
            # вызов метода, а табуляция — отступ, и проверка ругалась на здоровый
            # код двенадцать раз подряд.
            #
            # Второе: управляющий символ должен РАЗРЫВАТЬ слово, то есть идти
            # сразу после буквы или цифры. Табуляция в начале литерала или после
            # другой табуляции — форматирование, а съеденный '\t' всегда
            # оказывается в середине имени: "tests<TAB>est-maintenance.json".
            foreach ($match in [regex]::Matches($line, "'[^']*'|""[^""]*""")) {
                $value = $match.Value
                if ($value -notmatch "[/\\]" -and
                    $value -notmatch "\.(ps1|psm1|psd1|json|xml|mjs|js|md|bsl|cmd|bat|txt|yml|yaml)\b") {
                    continue
                }
                if ($value -match "[\p{L}\p{Nd}][$tab$cr]") {
                    [void]$issues.Add([pscustomobject]@{
                        Path = $path
                        Line = $lineNumber
                        Message = "управляющий символ внутри строки с путём — похоже, генерация съела обратный слэш"
                    })
                    break
                }
            }
        }
    }

    return @($issues)
}

function Get-WorkflowMetadataRef {
    <#
    .SYNOPSIS
    Путь вида "Catalogs/Товары" — в ссылку "Catalog.Товары", как её пишет состав
    подсистемы.

    .DESCRIPTION
    Каталог выгрузки назван во множественном числе, ссылка внутри Subsystems — в
    единственном. Без перевода сравнение «объект в подсистеме» не совпадает
    НИКОГДА, и проверка молча считает, что всё в порядке.
    #>
    param(
        [string]$Object
    )

    $singular = @{
        "Catalogs" = "Catalog"
        "Documents" = "Document"
        "DocumentJournals" = "DocumentJournal"
        "Enums" = "Enum"
        "Reports" = "Report"
        "DataProcessors" = "DataProcessor"
        "InformationRegisters" = "InformationRegister"
        "AccumulationRegisters" = "AccumulationRegister"
        "AccountingRegisters" = "AccountingRegister"
        "CalculationRegisters" = "CalculationRegister"
        "ChartsOfCharacteristicTypes" = "ChartOfCharacteristicTypes"
        "ChartsOfAccounts" = "ChartOfAccounts"
        "ChartsOfCalculationTypes" = "ChartOfCalculationTypes"
        "BusinessProcesses" = "BusinessProcess"
        "Tasks" = "Task"
        "ExchangePlans" = "ExchangePlan"
        "Constants" = "Constant"
        "ScheduledJobs" = "ScheduledJob"
        "CommonModules" = "CommonModule"
        "CommonForms" = "CommonForm"
        "CommonCommands" = "CommonCommand"
        "Roles" = "Role"
        "SettingsStorages" = "SettingsStorage"
        "FilterCriteria" = "FilterCriterion"
    }

    $parts = @(([string]$Object).Replace([string][char]92, "/").Split("/"))
    if ($parts.Count -ne 2) {
        return ""
    }
    if (-not $singular.ContainsKey($parts[0])) {
        return ""
    }

    return "$($singular[$parts[0]]).$($parts[1])"
}

function Get-WorkflowMetadataDirectory {
    <#
    .SYNOPSIS
    Ссылка «Catalog.Товары» — в каталог выгрузки «Catalogs».

    .DESCRIPTION
    Обратная сторона Get-WorkflowMetadataRef. Нужна там, где имя объекта пришло
    от человека — в паспорте сценария его пишут так, как показывает 1С, в
    единственном числе, а на диске каталог во множественном.
    #>
    param(
        [string]$Kind
    )

    $plural = @{
        "Catalog" = "Catalogs"
        "Document" = "Documents"
        "DocumentJournal" = "DocumentJournals"
        "Enum" = "Enums"
        "Report" = "Reports"
        "DataProcessor" = "DataProcessors"
        "InformationRegister" = "InformationRegisters"
        "AccumulationRegister" = "AccumulationRegisters"
        "AccountingRegister" = "AccountingRegisters"
        "CalculationRegister" = "CalculationRegisters"
        "ChartOfCharacteristicTypes" = "ChartsOfCharacteristicTypes"
        "ChartOfAccounts" = "ChartsOfAccounts"
        "ChartOfCalculationTypes" = "ChartsOfCalculationTypes"
        "BusinessProcess" = "BusinessProcesses"
        "Task" = "Tasks"
        "ExchangePlan" = "ExchangePlans"
        "CommonForm" = "CommonForms"
        "Subsystem" = "Subsystems"
    }

    $value = [string]$Kind
    if ($plural.ContainsKey($value)) {
        return $plural[$value]
    }

    return ""
}

function Get-WorkflowKindsRequiringSubsystem {
    <#
    .SYNOPSIS
    Виды метаданных, которым обязательна принадлежность подсистеме.

    .DESCRIPTION
    Список узкий намеренно: подсистема — это навигация и права, и требовать её от
    служебной подписки на события или определяемого типа значило бы требовать
    отметку ради отметки.

    Поднадзорно то, к чему человек ходит сам или что определяет работу базы:
    данные, отчёты, обработки, константы и регламентные задания. На живой
    конфигурации таких объектов вне подсистем накопилось 17 — включая шесть
    регламентных заданий, которых в интерфейсе не было видно вовсе.

    Проект может задать свой список в subsystemMembership.kinds.
    #>
    param(
        $Config
    )

    $membership = Get-WorkflowSettingValue -Object $Config -Name "subsystemMembership" -Default $null
    $kinds = @(Get-WorkflowSettingValue -Object $membership -Name "kinds" -Default @())
    if ($kinds.Count -gt 0) {
        return @($kinds)
    }

    return @(
        "Catalogs", "Documents", "DocumentJournals", "Enums", "Reports", "DataProcessors",
        "InformationRegisters", "AccumulationRegisters", "AccountingRegisters",
        "CalculationRegisters", "ChartsOfCharacteristicTypes", "ChartsOfAccounts",
        "ChartsOfCalculationTypes", "BusinessProcesses", "Tasks", "ExchangePlans",
        "Constants", "ScheduledJobs"
    )
}

function Get-WorkflowSubsystemMembership {
    <#
    .SYNOPSIS
    Ссылки на объекты, входящие хотя бы в одну подсистему выгрузки.

    .DESCRIPTION
    Читается весь каталог Subsystems целиком, вместе с вложенными: объект,
    лежащий в дочерней подсистеме, в родительскую не попадает, и проверка по
    одному верхнему уровню объявляла бы его бесхозным.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )

    $refs = New-Object System.Collections.Generic.HashSet[string]
    $root = Join-Path $SourcePath "Subsystems"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return $refs
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*.xml" -ErrorAction SilentlyContinue)) {
        # Служебные файлы подсистемы (командный интерфейс, справка) состава не
        # несут, а ссылки на команды в них выглядят похоже — читать их нельзя.
        if ($file.FullName.Replace([string][char]92, "/") -match "/Ext/") {
            continue
        }
        $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
        foreach ($match in [regex]::Matches($text, 'MDObjectRef">([^<]+)<')) {
            [void]$refs.Add($match.Groups[1].Value)
        }
    }

    return $refs
}

function Find-WorkflowObjectsOutsideSubsystems {
    <#
    .SYNOPSIS
    Новые объекты, не попавшие ни в одну подсистему.

    .DESCRIPTION
    Объект вне подсистем не виден в интерфейсе, его не открывает проверка команд
    и не находит человек: он существует только в конфигураторе. Отказ ставится на
    добавлении, потому что позже это не всплывает ничем — накопившиеся 17 таких
    объектов нашлись только при разборе дерева разделов.
    #>
    param(
        [string[]]$Objects = @(),

        $Membership,

        [string[]]$Exempt = @()
    )

    $missing = New-Object System.Collections.ArrayList

    foreach ($object in @($Objects | Where-Object { $_ })) {
        $ref = Get-WorkflowMetadataRef -Object $object
        if (-not $ref) {
            continue
        }
        if (@($Exempt) -contains $ref) {
            continue
        }
        if ($null -ne $Membership -and $Membership.Contains($ref)) {
            continue
        }

        [void]$missing.Add($ref)
    }

    return @($missing)
}

function Test-WorkflowFixturesTouched {
    <#
    .SYNOPSIS
    Затронута ли правкой подготовка данных стенда.

    .DESCRIPTION
    Пути объявляет проект: `functionalTests.fixturePaths` в `.1c-workflow.json`.
    Выводить их нельзя — сид у каждого проекта свой, и молчаливое «похоже, это
    фикстуры» ошибается в обе стороны.

    Пустой список означает, что проект фикстуры не объявил. Это НЕ повод
    пропустить проверку: без объявленных фикстур новый объект показать не на
    чем, и правило обязано сказать об этом вслух.
    #>
    param(
        [string[]]$ChangedPaths = @(),
        [string[]]$FixturePaths = @()
    )

    $fixtures = @($FixturePaths | Where-Object { $_ } | ForEach-Object { ([string]$_).Replace('\', '/').Trim('/') })
    if ($fixtures.Count -eq 0) {
        return $false
    }
    foreach ($path in @($ChangedPaths | Where-Object { $_ })) {
        $normalized = ([string]$path).Replace('\', '/').Trim('/')
        foreach ($fixture in $fixtures) {
            if ($normalized -eq $fixture -or $normalized.StartsWith("$fixture/")) {
                return $true
            }
        }
    }
    return $false
}

function Get-WorkflowSuiteFiles {
    <#
    .SYNOPSIS
    Все прогоняемые файлы сьюта Web UI относительными путями. Без отложенных.

    .DESCRIPTION
    Нужна там, где объём считается ВЫЧИТАНИЕМ: чтобы вычесть уже доказанное, надо
    сначала знать полный список поимённо. Каталоги для этого не годятся — из них
    не видно, что именно внутри доказано.

    Отложенные сценарии исключаются той же проверкой, что и везде: они красные по
    определению, и включать их в обязательный объём значит сделать его никогда не
    проходимым.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$SuiteRelativePath
    )

    $suiteRoot = Join-Path $RepositoryRoot ($SuiteRelativePath.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $suiteRoot -PathType Container)) {
        throw "Web UI suite directory was not found: $suiteRoot"
    }
    $rootPrefix = [System.IO.Path]::GetFullPath($suiteRoot).TrimEnd('\') + '\'
    $files = New-Object System.Collections.ArrayList

    foreach ($file in @(Get-ChildItem -LiteralPath $suiteRoot -Recurse -File -Filter "*.test.mjs" | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($rootPrefix.Length).Replace('\', '/')
        if (Test-WorkflowPendingSuitePath -Path $relative) {
            continue
        }
        [void]$files.Add($relative)
    }
    return @($files)
}

function Select-WorkflowWebUiReuse {
    <#
    .SYNOPSIS
    Что осталось прогнать, если часть сьюта уже доказана на этом же дереве.

    .DESCRIPTION
    Правило РАЗРЕШАЕТ не выполнять работу, поэтому устроено «отказ по умолчанию»:
    переиспользование включается, только когда доказанное целиком лежит внутри
    текущего сьюта. Любая неожиданность — файла больше нет, список пуст — это
    отказ и полный прогон, а не молчаливое уменьшение объёма.

    Проверка «доказанное ⊆ полного» не формальность. Если сьют переименовали или
    файл удалили, старый отчёт доказывает то, чего в сьюте уже нет, а остаток
    окажется меньше, чем нужно. Снаружи это неотличимо от честного полного
    прогона — ровно тот класс дефекта, против которого в комплекте заведён
    releaseReady.

    Возвращает Reuse, Remainder (что прогнать сейчас), Reused (что зачтено) и
    Reason — причину отказа для печати. Молчаливый отказ читался бы как
    «оптимизация не работает».
    #>
    param(
        [string[]]$AllFiles = @(),
        [string[]]$ProvenFiles = @()
    )

    $all = @($AllFiles | Where-Object { $_ })
    $proven = @($ProvenFiles | Where-Object { $_ } | Sort-Object -Unique)

    $result = [pscustomobject]@{
        Reuse = $false
        Remainder = @($all)
        Reused = @()
        Reason = ""
    }

    if ($all.Count -eq 0) {
        $result.Reason = "сьют пуст"
        return $result
    }
    if ($proven.Count -eq 0) {
        $result.Reason = "доказанного на этом дереве нет"
        return $result
    }

    $missing = @($proven | Where-Object { $all -notcontains $_ })
    if ($missing.Count -gt 0) {
        $result.Reason = "сьют изменился: доказанного файла больше нет ($($missing[0]))"
        return $result
    }

    $result.Reuse = $true
    $result.Reused = $proven
    $result.Remainder = @($all | Where-Object { $proven -notcontains $_ })
    return $result
}

function Get-WorkflowProvenWebUiFiles {
    <#
    .SYNOPSIS
    Файлы сьюта, полностью пройденные на ЭТОМ ЖЕ дереве прошлыми фазами.

    .DESCRIPTION
    Привязка идёт к коммиту И отпечатку файлов, а не к тому, что «прогон был».
    Отпечаток отвечает на вопрос «прошло РОВНО ЭТО»; без него зачёт однажды
    достался бы дереву, которого прогон не видел.

    Файл засчитывается, только когда ВСЕ его сценарии прошли. Параметризованный
    тест даёт несколько записей на один файл, и достаточно одной упавшей, чтобы
    файл не считался доказанным.

    Отчёт прогона Probe и прогон без UpdateDBCfg не засчитываются: первый идёт по
    отбору и полноты не обещает, второй собирает базу иначе.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        # Не обязательные: пустые значения — законный ответ «зачитывать нечему»,
        # а обязательный строковый параметр пустую строку просто не принял бы.
        [string]$Commit = "",

        [string]$Fingerprint = ""
    )

    $result = [pscustomobject]@{
        Files = @()
        Reports = @()
    }
    if (-not $Commit -or -not $Fingerprint) {
        return $result
    }

    $stateDirectory = Resolve-WorkflowPath -RepositoryRoot $RepositoryRoot -Path ([string]$Config.localStateDir)
    $reportsRoot = Join-Path $stateDirectory "reports"
    if (-not (Test-Path -LiteralPath $reportsRoot -PathType Container)) {
        return $result
    }

    $files = New-Object System.Collections.ArrayList
    $sources = New-Object System.Collections.ArrayList

    foreach ($entry in @(Get-ChildItem -LiteralPath $reportsRoot -File -Filter "*.json" -ErrorAction SilentlyContinue)) {
        $report = $null
        try {
            $report = Get-Content -Raw -LiteralPath $entry.FullName -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            continue
        }
        if ($null -eq $report -or $null -eq $report.PSObject.Properties["commit"]) {
            continue
        }
        if ([string]$report.commit -ne $Commit) {
            continue
        }
        if ($null -eq $report.PSObject.Properties["fingerprint"] -or [string]$report.fingerprint -ne $Fingerprint) {
            continue
        }
        if (-not [bool]$report.success) {
            continue
        }
        if ($null -ne $report.PSObject.Properties["probe"] -and [bool]$report.probe) {
            continue
        }
        if ($null -ne $report.PSObject.Properties["compileOnly"] -and [bool]$report.compileOnly) {
            continue
        }
        if ($null -eq $report.PSObject.Properties["webUiIncluded"] -or -not [bool]$report.webUiIncluded) {
            continue
        }

        $webUiReports = @()
        foreach ($name in @("webUiReport", "webUiAffectedReport")) {
            if ($null -eq $report.PSObject.Properties[$name]) {
                continue
            }
            $path = [string]$report.$name
            if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                $webUiReports += $path
            }
        }
        foreach ($path in $webUiReports) {
            $passed = @(Get-WorkflowPassedWebUiFiles -ReportPath $path)
            if ($passed.Count -eq 0) {
                continue
            }
            [void]$sources.Add($path)
            foreach ($file in $passed) {
                [void]$files.Add($file)
            }
        }
    }

    $result.Files = @($files | Sort-Object -Unique)
    $result.Reports = @($sources | Sort-Object -Unique)
    return $result
}

function Get-WorkflowPassedWebUiFiles {
    <#
    .SYNOPSIS
    Файлы из отчёта прогона Web UI, все сценарии которых прошли.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReportPath
    )

    try {
        $report = Get-Content -Raw -LiteralPath $ReportPath -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return @()
    }
    if ($null -eq $report -or $null -eq $report.PSObject.Properties["tests"]) {
        return @()
    }

    $byFile = @{}
    foreach ($test in @($report.tests)) {
        if ($null -eq $test.PSObject.Properties["file"]) {
            continue
        }
        $file = ([string]$test.file).Replace('\', '/').Trim('/')
        if (-not $file) {
            continue
        }
        $passed = ($null -ne $test.PSObject.Properties["status"]) -and ([string]$test.status -eq "passed")
        if ($byFile.ContainsKey($file)) {
            $byFile[$file] = $byFile[$file] -and $passed
        }
        else {
            $byFile[$file] = $passed
        }
    }
    return @($byFile.Keys | Where-Object { $byFile[$_] } | Sort-Object)
}

function Get-WorkflowSuiteFilesByTag {
    <#
    .SYNOPSIS
    Возвращает относительные пути файлов сьюта, объявивших указанный тег.

    .DESCRIPTION
    Нужна именно СПИСКОМ ПУТЕЙ, а не фильтром `--tags`: обязательный объём — это
    объединение smoke и затронутого отбором, а фильтр по тегам с путями
    ПЕРЕСЕКАЕТСЯ. Передав каталоги затронутого вместе с `--tags=smoke`, получишь
    только smoke внутри затронутого, то есть меньше требуемого, а не больше.

    Тег читается из объявления `export const tags = [...]` в начале файла.
    Файл без тега в выборку не попадает: smoke — свойство заявляемое, а не
    выводимое, иначе в обязательный минимум однажды заедет медленный обход.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$SuiteRelativePath,

        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    $suiteRoot = Join-Path $RepositoryRoot ($SuiteRelativePath.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $suiteRoot -PathType Container)) {
        throw "Web UI suite directory was not found: $suiteRoot"
    }
    $rootPrefix = [System.IO.Path]::GetFullPath($suiteRoot).TrimEnd('\') + '\'
    $matched = New-Object System.Collections.ArrayList

    foreach ($file in @(Get-ChildItem -LiteralPath $suiteRoot -Recurse -File -Filter "*.test.mjs" | Sort-Object FullName)) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        $declaration = [regex]::Match($text, 'export\s+const\s+tags\s*=\s*\[(?<body>[^\]]*)\]')
        if (-not $declaration.Success) {
            continue
        }
        $tags = @(
            [regex]::Matches($declaration.Groups["body"].Value, "['""](?<tag>[^'""]+)['""]") |
                ForEach-Object { $_.Groups["tag"].Value }
        )
        if (@($tags) -notcontains $Tag) {
            continue
        }
        $relative = $file.FullName.Substring($rootPrefix.Length).Replace('\', '/')
        if (Test-WorkflowPendingSuitePath -Path $relative) {
            continue
        }
        [void]$matched.Add("$SuiteRelativePath/$relative")
    }

    return @($matched)
}

function Get-WorkflowAffectedSuiteTargets {
    <#
    .SYNOPSIS
    Определяет, какие каталоги сьюта Web UI затронуты изменениями ветки.

    .DESCRIPTION
    Источник истины — та же политика `Test-TestMaintenance.ps1`, что проверяет
    обязательность актуализации тестов. Отдельной карты соответствий не вводится
    намеренно: две карты неизбежно разойдутся, и тогда отбор начнёт пропускать то,
    чего требует политика.

    Политика падает при нарушениях, но отчёт записывает ДО падения, поэтому её
    код возврата здесь не важен — нужен только список затронутых правил.

    Возвращает объект с полями:
      Targets         — относительные пути внутри сьюта, которые надо прогнать;
      WholeSuite      — правило потребовало сьют целиком (отбор выродился);
      WholeSuiteRules — идентификаторы таких правил;
      OutsideSuite    — затронутое вне сьюта Web UI (функциональный контур);
      ImpactedRules   — затронутые правила политики;
      PolicyReport    — путь к отчёту политики.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [string]$BaseRef = "",

        [string]$ReportPath = "",

        [string]$LogPath = "",

        # Preflight уже выполняет политику отдельным шагом. Повторный запуск дал бы
        # тот же результат вторым git diff, поэтому фаза передаёт готовый отчёт.
        [switch]$ReuseExistingReport
    )

    $maintenanceConfig = Get-WorkflowSettingValue -Object $Config -Name "testMaintenance" -Default $null
    if ($null -eq $maintenanceConfig -or -not [bool]$maintenanceConfig.enabled) {
        throw "Test maintenance policy is disabled, so affected tests cannot be derived. Run the full suite instead."
    }
    $webUiConfig = Get-WorkflowSettingValue -Object $Config -Name "webUiTests" -Default $null
    if ($null -eq $webUiConfig -or -not [bool]$webUiConfig.enabled) {
        throw "webUiTests.enabled is false: there is no suite to select from."
    }
    $suiteRelative = ([string]$webUiConfig.suite).Replace('\', '/').Trim('/')

    $stateDirectory = Resolve-WorkflowPath -RepositoryRoot $RepositoryRoot -Path ([string]$Config.localStateDir)
    $timestamp = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
    if (-not $ReportPath) {
        $ReportPath = Join-Path $stateDirectory "reports\affected-tests-policy-$timestamp.json"
    }
    if (-not $LogPath) {
        $LogPath = Join-Path $stateDirectory "logs\affected-tests\$timestamp.log"
    }

    $reportIsReady = $ReuseExistingReport -and (Test-Path -LiteralPath $ReportPath -PathType Leaf)
    if (-not $reportIsReady) {
        $maintenanceScript = Resolve-WorkflowPath `
            -RepositoryRoot $RepositoryRoot `
            -Path ([string]$maintenanceConfig.script)
        $maintenanceArguments = @("-ReportPath", $ReportPath)
        if ($BaseRef) {
            $maintenanceArguments += @("-BaseRef", $BaseRef)
        }
        Invoke-WorkflowPowerShell `
            -ScriptPath $maintenanceScript `
            -Arguments $maintenanceArguments `
            -LogPath $LogPath `
            -AllowFailure | Out-Null
    }

    if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
        throw "Test maintenance did not produce a report: $ReportPath. See log: $LogPath"
    }
    $policy = Get-Content -Raw -LiteralPath $ReportPath -Encoding UTF8 | ConvertFrom-Json

    $impactedRules = @($policy.rules | Where-Object { @($_.impactedPaths).Count -gt 0 })
    $targets = New-Object System.Collections.ArrayList
    $outsideSuite = New-Object System.Collections.ArrayList
    $wholeSuiteRules = New-Object System.Collections.ArrayList

    foreach ($rule in $impactedRules) {
        # Объём прогона правила, а не требование к автору: см. runTestPatterns в
        # отчёте политики. Старые отчёты поля не содержат — тогда берётся
        # требование, как было.
        $rulePatterns = @(
            Get-WorkflowSettingValue -Object $rule -Name "runTestPatterns" -Default $rule.requiredTestPatterns
        )
        foreach ($pattern in $rulePatterns) {
            $literal = ConvertFrom-WorkflowTestPathPattern -Pattern ([string]$pattern)
            if (-not $literal) {
                continue
            }
            if ($literal -eq $suiteRelative) {
                if (-not $wholeSuiteRules.Contains([string]$rule.id)) {
                    [void]$wholeSuiteRules.Add([string]$rule.id)
                }
                continue
            }
            if ($literal.StartsWith("$suiteRelative/", [System.StringComparison]::OrdinalIgnoreCase)) {
                if (Test-WorkflowPendingSuitePath -Path $literal.Substring($suiteRelative.Length + 1)) {
                    continue
                }
                $full = Join-Path $RepositoryRoot ($literal -replace '/', '\')
                if (Test-Path -LiteralPath $full) {
                    if (-not $targets.Contains($literal)) {
                        [void]$targets.Add($literal)
                    }
                }
                continue
            }
            if (-not $outsideSuite.Contains($literal)) {
                [void]$outsideSuite.Add($literal)
            }
        }
    }

    $wholeSuite = $wholeSuiteRules.Count -gt 0
    if ($wholeSuite) {
        $targets.Clear()
        foreach ($branch in @(Get-WorkflowSuiteRootTargets -RepositoryRoot $RepositoryRoot -SuiteRelativePath $suiteRelative)) {
            [void]$targets.Add($branch)
        }
    }

    return [pscustomobject]@{
        Targets = @($targets)
        WholeSuite = $wholeSuite
        WholeSuiteRules = @($wholeSuiteRules)
        OutsideSuite = @($outsideSuite)
        ImpactedRules = @($impactedRules)
        PolicyReport = $ReportPath
        SuiteRoot = $suiteRelative
    }
}

function Get-WorkflowContractPaths {
    <#
    .SYNOPSIS
    Пути, которые комплект считает общим контрактом команды.

    .DESCRIPTION
    Список один на все проекты и не настраивается: это ровно те файлы, которые
    ставит установщик и про которые `AGENTS.md` говорит «изменение процесса
    вносить в них, а не в личные настройки». Правка любого из них меняет
    поведение у всех разработчиков сразу, а выглядит как правка документации.

    Список используется дважды: им проверяется покрытие `CODEOWNERS` и по нему
    же пишется раздел шаблона merge request. Держать его в одном месте важнее
    гибкости: разошедшиеся копии дают ложное чувство защиты.
    #>
    return @(
        "/AGENTS.md",
        "/CLAUDE.md",
        "/.1c-workflow.json",
        "/.1c-workflow.defaults.json",
        "/.1c-workflow.lock.json",
        "/.gitattributes",
        "/.gitignore",
        "/.claude/settings.json",
        "/.mcp.example.json",
        "/.zcode/config.example.json",
        "/.v8-project.example.json",
        "/docs/",
        "/scripts/",
        "/tools/",
        "/tests/test-maintenance.json",
        "/.gitlab-ci.yml",
        "/.gitlab/",
        "/artifacts/"
    )
}

function Get-WorkflowCodeOwnersProblems {
    <#
    .SYNOPSIS
    Проверяет, что файлы контракта закрыты владельцем в `.gitlab/CODEOWNERS`.

    .DESCRIPTION
    Правило с несуществующим пользователем GitLab игнорирует МОЛЧА. Из-за этого
    отсутствие защиты неотличимо от её наличия по одному лишь виду файла: он
    есть, он выглядит заполненным, и он не действует. Ровно так же не действует
    правило, у которого владельца забыли вписать, и правило с оставшейся
    заглушкой установщика.

    Проверяются три вещи: каждый существующий в репозитории путь контракта
    закрыт правилом, у каждого правила есть владелец, владелец не заглушка.

    Проверяется только то, что в репозитории ЕСТЬ. Проект без `artifacts/` или
    без `.claude/settings.json` — обычное дело, и требовать владельца на
    несуществующий путь значило бы ронять gate на свежей установке.

    Отсутствие самого файла проблемой не считается: `CODEOWNERS` ставится только
    вместе с `-CodeOwner`, а проект может жить не в GitLab. Поле Present
    отдаётся наружу, чтобы вызывающий сказал об этом вслух, а не промолчал.

    Возвращает объект с полями Present, Checked (сколько путей проверено), Rules
    (сколько правил разобрано) и Problems.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [string[]]$ContractPaths
    )

    if (-not $ContractPaths -or $ContractPaths.Count -eq 0) {
        $ContractPaths = @(Get-WorkflowContractPaths)
    }

    $codeownersPath = Join-Path $RepositoryRoot ".gitlab\CODEOWNERS"
    if (-not (Test-Path -LiteralPath $codeownersPath -PathType Leaf)) {
        return [pscustomobject]@{ Present = $false; Checked = 0; Rules = 0; Problems = @() }
    }

    # Заглушка установщика и безличные примеры. Каждое такое значение GitLab
    # отбрасывает, не сказав ни слова.
    $placeholders = @(
        "__code_owner__", "@owner", "@owners", "@handle", "@username",
        "@user", "@group", "@team", "@maintainer", "@ivanov_ii"
    )

    $problems = New-Object System.Collections.ArrayList
    $rules = New-Object System.Collections.ArrayList

    foreach ($line in [System.IO.File]::ReadAllLines($codeownersPath, [System.Text.UTF8Encoding]::new($false))) {
        $trimmed = ([string]$line).TrimStart([char]0xFEFF).Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) {
            continue
        }
        # Заголовок секции: `[Имя]`, `^[Имя]` — необязательная, `[Имя][2]` — с
        # числом обязательных одобрений.
        if ($trimmed -match '^\^?\[') {
            continue
        }

        $tokens = @($trimmed -split '\s+' | Where-Object { $_.Length -gt 0 })
        if ($tokens.Count -eq 0) {
            continue
        }
        [void]$rules.Add([pscustomobject]@{
            Pattern = [string]$tokens[0]
            Owners  = @($tokens | Select-Object -Skip 1)
        })
    }

    $declared = @($rules | ForEach-Object { $_.Pattern })
    $checked = 0
    foreach ($contractPath in $ContractPaths) {
        $relative = ([string]$contractPath).Trim("/")
        if (-not $relative) {
            continue
        }
        $fullPath = Join-Path $RepositoryRoot ($relative -replace '/', '\')
        if (-not (Test-Path -LiteralPath $fullPath)) {
            continue
        }
        $checked++
        if ($declared -notcontains $contractPath) {
            [void]$problems.Add(
                "$contractPath не закрыт правилом: изменить файл контракта сможет любой, кому разрешён merge")
        }
    }

    foreach ($rule in $rules) {
        if ($rule.Owners.Count -eq 0) {
            [void]$problems.Add("$($rule.Pattern): владелец не указан, правило не действует")
            continue
        }
        foreach ($owner in $rule.Owners) {
            $text = [string]$owner
            if ($placeholders -contains $text.ToLowerInvariant()) {
                [void]$problems.Add(
                    "$($rule.Pattern): владелец $text — заглушка, GitLab игнорирует такое правило молча")
                continue
            }
            if (-not $text.Contains("@")) {
                [void]$problems.Add(
                    "$($rule.Pattern): $text не похож на пользователя, группу или адрес почты")
            }
        }
    }

    return [pscustomobject]@{
        Present  = $true
        Checked  = $checked
        Rules    = $rules.Count
        Problems = @($problems)
    }
}

function Get-WorkflowContractGuards {
    <#
    .SYNOPSIS
    Настройки `.1c-workflow.json`, выключение которых снимает контроль.

    .DESCRIPTION
    Kind = "Switch" — выключатель проверки: ослабление это переход из истины в
    ложь либо исчезновение поля. Исчезновение опаснее явной лжи: значение
    подставится из `.1c-workflow.defaults.json`, а там проверки выключены, и
    удалить секцию дешевле, чем написать false.

    Kind = "InvertedSwitch" — выключатель контроля наоборот: ослабление это
    включение. Такой ровно один — `processDevelopment`, он снимает сверку файлов
    процесса.

    Kind = "Scope" — лестница объёмов прогона: ослабление это шаг вниз.

    Списки настроек проекта (исключения подсистем, пути фикстур) сюда НЕ входят
    намеренно. Пополнять их — обычная работа, и требование обосновывать каждое
    пополнение превратило бы проверку в шум, который научатся обходить не глядя.
    #>
    return @(
        [pscustomobject]@{ Setting = "parallel.enabled"; Kind = "Switch" }
        [pscustomobject]@{ Setting = "parallel.perBranchStands"; Kind = "Switch" }
        [pscustomobject]@{ Setting = "functionalTests.enabled"; Kind = "Switch" }
        [pscustomobject]@{ Setting = "functionalTests.httpRequired"; Kind = "Switch" }
        [pscustomobject]@{ Setting = "unitTests.enabled"; Kind = "Switch" }
        [pscustomobject]@{ Setting = "webUiTests.enabled"; Kind = "Switch" }
        [pscustomobject]@{ Setting = "webUiTests.requiredForReview"; Kind = "Switch" }
        [pscustomobject]@{ Setting = "webUiTests.runOnFinish"; Kind = "Switch" }
        [pscustomobject]@{ Setting = "artifacts.storeInGit"; Kind = "Switch" }
        [pscustomobject]@{ Setting = "artifacts.versioned"; Kind = "Switch" }
        [pscustomobject]@{ Setting = "userHelp.enabled"; Kind = "Switch" }
        [pscustomobject]@{ Setting = "processDevelopment"; Kind = "InvertedSwitch" }
        [pscustomobject]@{ Setting = "webUiTests.scope.selfcheck"; Kind = "Scope" }
        [pscustomobject]@{ Setting = "webUiTests.scope.package"; Kind = "Scope" }
        [pscustomobject]@{ Setting = "webUiTests.scope.verify"; Kind = "Scope" }
        [pscustomobject]@{ Setting = "webUiTests.scope.release"; Kind = "Scope" }
        # Kind = "Value" — настройка, которая проверку не включает, но задаёт,
        # ЧТО проверяется. Опустошить её дешевле, чем выключить проверку, а
        # результат тот же: пустой cc1cSkillsVersion принимает любую версию
        # навыков, включая заведомо старую; пустой platformVersion снимает
        # сверку платформы; сменившийся sourceDir уводит все фазы на другое
        # дерево исходников. Ослаблением считается опустошение или смена
        # значения — второе редко и законно объявляется через contractWeakening.
        [pscustomobject]@{ Setting = "platformVersion"; Kind = "Value" }
        [pscustomobject]@{ Setting = "cc1cSkillsVersion"; Kind = "Value" }
        [pscustomobject]@{ Setting = "project"; Kind = "Value" }
        [pscustomobject]@{ Setting = "sourceDir"; Kind = "Value" }
        [pscustomobject]@{ Setting = "mainBranch"; Kind = "Value" }
    )
}

function Get-WorkflowScopeRank {
    <#
    .SYNOPSIS
    Место объёма прогона на лестнице: больше значит шире.

    .DESCRIPTION
    Неизвестное значение получает 0 и поэтому считается ослаблением любого
    известного. Это сделано намеренно: опечатка в объёме не падает валидацией
    нигде, а прогон по ней молча уходит в умолчание.
    #>
    param([string]$Scope)

    switch (([string]$Scope).Trim().ToLowerInvariant()) {
        "affected" { return 1 }
        "smoke" { return 2 }
        "affected+smoke" { return 3 }
        "full" { return 4 }
        default { return 0 }
    }
}

function Get-WorkflowSettingPathValue {
    <#
    .SYNOPSIS
    Значение настройки по составному имени вида `webUiTests.scope.release`.

    .DESCRIPTION
    Отличается от `Get-WorkflowSettingValue` тем, что РАЗЛИЧАЕТ отсутствие
    настройки и значение по умолчанию. Для сравнения двух версий манифеста это
    и есть суть дела: исчезнувший выключатель и выключатель, выставленный в
    ложь, приводят к одному результату, и оба должны быть видны.

    Возвращает объект с полями Found и Value.
    #>
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $current = $Object
    foreach ($part in $Path.Split(".")) {
        if ($null -eq $current) {
            return [pscustomobject]@{ Found = $false; Value = $null }
        }
        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) {
            return [pscustomobject]@{ Found = $false; Value = $null }
        }
        $current = $property.Value
    }
    if ($null -eq $current) {
        return [pscustomobject]@{ Found = $false; Value = $null }
    }
    return [pscustomobject]@{ Found = $true; Value = $current }
}

function Get-WorkflowContractWeakenings {
    <#
    .SYNOPSIS
    Чем настройки проекта стали слабее, чем были в базовой ветке.

    .DESCRIPTION
    Комплект не может требовать конкретных значений: у свежего проекта
    регрессия интерфейса законно выключена, пока он её не завёл, и требование
    «включено у всех» уронило бы gate на первой же установке. Поэтому
    проверяется не значение, а НАПРАВЛЕНИЕ: настройка не может стать слабее,
    чем в ветке, в которую вливается.

    Такое правило не нужно настраивать и не устаревает: планку задаёт сам
    проект тем, что уже влил, а проверка стережёт только её понижение.

    Осознанное понижение объявляется в самом манифесте — массивом
    `contractWeakening` с полями setting, reason и decidedBy. Объявление
    попадает в diff того же MR и требует одобрения владельца из `CODEOWNERS`,
    то есть решение остаётся видимым, а не молчаливым. Ровно так же устроен
    `processDevelopment`, и по той же причине.

    Возвращает массив объектов Setting, Kind, From, To, Approved, Reason,
    DecidedBy. Пустой массив означает, что ослаблений нет.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $BaseConfig,

        [Parameter(Mandatory = $true)]
        $HeadConfig
    )

    $approvals = @{}
    $declared = Get-WorkflowSettingValue -Object $HeadConfig -Name "contractWeakening" -Default @()
    foreach ($entry in @($declared)) {
        if ($null -eq $entry) {
            continue
        }
        $setting = [string](Get-WorkflowSettingValue -Object $entry -Name "setting" -Default "")
        if (-not $setting) {
            continue
        }
        $approvals[$setting] = [pscustomobject]@{
            Reason    = [string](Get-WorkflowSettingValue -Object $entry -Name "reason" -Default "")
            DecidedBy = [string](Get-WorkflowSettingValue -Object $entry -Name "decidedBy" -Default "")
        }
    }

    $weakenings = New-Object System.Collections.ArrayList

    foreach ($guard in @(Get-WorkflowContractGuards)) {
        $base = Get-WorkflowSettingPathValue -Object $BaseConfig -Path $guard.Setting
        $head = Get-WorkflowSettingPathValue -Object $HeadConfig -Path $guard.Setting

        $weakened = $false
        $from = "не задано"
        $to = "не задано"

        if ($guard.Kind -eq "Scope") {
            if (-not $base.Found) {
                continue
            }
            $from = [string]$base.Value
            $to = if ($head.Found) { [string]$head.Value } else { "не задано" }
            $baseRank = Get-WorkflowScopeRank -Scope $from
            # Пропавший объём — это умолчание комплекта, а оно слабее любого
            # объявленного: считаем исчезновение понижением до нуля.
            $headRank = if ($head.Found) { Get-WorkflowScopeRank -Scope $to } else { 0 }
            $weakened = $headRank -lt $baseRank
        }
        elseif ($guard.Kind -eq "Value") {
            # Значения не было и в базовой ветке — требовать его здесь значило бы
            # ронять gate у проекта, который его ещё не завёл.
            $baseValue = if ($base.Found) { [string]$base.Value } else { "" }
            if (-not $baseValue.Trim()) {
                continue
            }
            $headValue = if ($head.Found) { [string]$head.Value } else { "" }
            $from = $baseValue
            $to = if ($headValue.Trim()) { $headValue } else { "не задано" }
            $weakened = $headValue.Trim() -cne $baseValue.Trim()
        }
        elseif ($guard.Kind -eq "InvertedSwitch") {
            $baseOn = $base.Found -and ($base.Value -eq $true)
            $headOn = $head.Found -and ($head.Value -eq $true)
            $from = if ($baseOn) { "true" } else { "false" }
            $to = if ($headOn) { "true" } else { "false" }
            $weakened = $headOn -and (-not $baseOn)
        }
        else {
            if (-not ($base.Found -and $base.Value -eq $true)) {
                continue
            }
            $from = "true"
            $to = if (-not $head.Found) { "не задано" } elseif ($head.Value -eq $true) { "true" } else { "false" }
            $weakened = $to -ne "true"
        }

        if (-not $weakened) {
            continue
        }

        $approval = $null
        if ($approvals.ContainsKey($guard.Setting)) {
            $approval = $approvals[$guard.Setting]
        }
        $approved = ($null -ne $approval) -and
            (-not [string]::IsNullOrWhiteSpace($approval.Reason)) -and
            (-not [string]::IsNullOrWhiteSpace($approval.DecidedBy))

        [void]$weakenings.Add([pscustomobject]@{
            Setting   = $guard.Setting
            Kind      = $guard.Kind
            From      = $from
            To        = $to
            Approved  = $approved
            Reason    = if ($approval) { $approval.Reason } else { "" }
            DecidedBy = if ($approval) { $approval.DecidedBy } else { "" }
        })
    }

    return @($weakenings)
}
