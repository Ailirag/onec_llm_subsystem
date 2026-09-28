# Правила цикла инструкций по релизу.
#
# Отдельный файл, а не раздел Workflow.Common.ps1: цикл ручной, в фазы задачи не
# входит, и его правила не должны попадать в загрузку каждой фазы. Подключается
# точкой после Workflow.Common.ps1 — пользуется его функциями.
#
# Здесь всё, что решает, какую работу МОЖНО не делать: какой задаче инструкция не
# нужна, какие сценарии относятся к релизу. Ошибка в таком правиле не падает, а
# молча сокращает объём, поэтому оно покрыто поведенческими тестами комплекта
# (scripts/ci/Test-ProcessBehaviour.ps1, раздел G).

function ConvertTo-WorkflowReleaseSlug {
    <#
    .SYNOPSIS
    Имя каталога релиза: читаемое и не совпадающее у разных релизов.

    .DESCRIPTION
    Общий ConvertTo-WorkflowSlug для этого не годится: он оставляет только
    латиницу, и «1С:УТ_02.10.2026» и «1С:БП_02.10.2026» свернулись бы в один
    каталог — второй релиз молча перезаписал бы отчёт первого. Здесь кириллица
    сохраняется, заменяются только символы, недопустимые в имени файла, а
    отпечаток исходного имени исключает совпадения после замены.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Release
    )

    $name = $Release.Trim()
    if (-not $name) {
        throw "Имя релиза пустое."
    }
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $name.ToCharArray()) {
        if ($invalid -contains $character -or [char]::IsWhiteSpace($character)) {
            [void]$builder.Append('-')
        }
        else {
            [void]$builder.Append($character)
        }
    }
    $slug = ($builder.ToString() -replace '-{2,}', '-').Trim('-', '.')
    if ($slug.Length -gt 40) {
        $slug = $slug.Substring(0, 40).TrimEnd('-', '.')
    }
    if (-not $slug) {
        $slug = "release"
    }
    $hash = (Get-WorkflowStableHash -Value $name).Substring(0, 6)
    return "$slug-$hash"
}

function Get-WorkflowGuideChangeKind {
    <#
    .SYNOPSIS
    Вид изменения по пути файла выгрузки: что из этого видит пользователь.

    .DESCRIPTION
    Решение принимается по каталогам выгрузки платформы, а не по именам
    объектов: они одинаковы у любой конфигурации и у расширений. Всё, что не
    распознано как интерфейс, считается логикой — ошибка в эту сторону видна
    (задача помечается «не требуется», и это читается в отчёте), а обратная
    ошибка раздувала бы объём инструкций.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalized = "/" + $Path.Replace('\', '/').TrimStart('/')
    if ($normalized -match '/(CommonForms|Forms)/') { return "форма" }
    if ($normalized -match '/(CommonCommands|Commands)/') { return "команда" }
    if ($normalized -match '/(CommonTemplates|Templates)/') { return "макет" }
    if ($normalized -match '/Reports/') { return "отчёт" }
    if ($normalized -match '/Subsystems/|/Ext/CommandInterface\.xml$') { return "командный интерфейс" }
    if ($normalized -match '/Roles/') { return "права" }
    if ($normalized -match '/Ext/Help/') { return "справка" }
    return "логика"
}

function Get-WorkflowReleaseTaskClass {
    <#
    .SYNOPSIS
    Нужна ли задаче инструкция: ui, background, no-code или unknown.

    .DESCRIPTION
    Отсутствие сведений и отсутствие изменений — разные вещи, и их нельзя
    смешивать. Адаптер, не передавший пути (`paths` нет в манифесте), даёт
    unknown: про задачу ничего не известно, и отчёт говорит об этом вслух.
    Пустой список путей — no-code: задача закрыта без правки кода. Если бы оба
    случая давали «не требуется», сломанный адаптер выглядел бы как релиз без
    единой видимой правки.
    #>
    param(
        [AllowNull()]
        [object]$Paths
    )

    if ($null -eq $Paths) {
        return [pscustomobject]@{ Class = "unknown"; Kinds = @() }
    }
    $list = @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($list.Count -eq 0) {
        return [pscustomobject]@{ Class = "no-code"; Kinds = @() }
    }
    $kinds = @($list | ForEach-Object { Get-WorkflowGuideChangeKind -Path ([string]$_) } | Sort-Object -Unique)
    $visible = @($kinds | Where-Object { $_ -ne "логика" })
    return [pscustomobject]@{
        Class = $(if ($visible.Count -gt 0) { "ui" } else { "background" })
        Kinds = $kinds
    }
}

function Get-WorkflowJsonArrayProperty {
    <#
    .SYNOPSIS
    Значение свойства-массива JSON с различением «нет свойства» и «пустой массив».

    .DESCRIPTION
    Get-WorkflowSettingValue для этого не подходит: пустой массив, возвращённый
    через return, разворачивается конвейером в $null, и «paths: []» становится
    неотличим от отсутствия paths. Здесь возвращается обёртка.
    #>
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return [pscustomobject]@{ Present = $false; Items = @() }
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return [pscustomobject]@{ Present = $false; Items = @() }
    }
    return [pscustomobject]@{ Present = $true; Items = @($property.Value) }
}

function Read-WorkflowReleaseManifest {
    <#
    .SYNOPSIS
    Читает и проверяет манифест релиза, который отдал адаптер проекта.

    .DESCRIPTION
    Схема 1:
      { "schemaVersion": 1, "release": "<имя>", "title": "<необязательно>",
        "tasks": [ { "key": "<ключ>", "title": "...", "url": "...",
                     "paths": ["<путь файла выгрузки>", ...] } ] }

    `paths` необязателен: без него задача классифицируется как unknown. Повтор
    ключа — отказ: два описания одной задачи дали бы в отчёте две строки с
    разной классификацией, и какая верна, не сказать.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Манифест релиза не найден: $Path"
    }
    try {
        $manifest = Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Манифест релиза не читается как JSON: $Path. $($_.Exception.Message)"
    }
    if ([int](Get-WorkflowSettingValue -Object $manifest -Name "schemaVersion" -Default 0) -ne 1) {
        throw "Неподдерживаемая схема манифеста релиза (нужна 1): $Path"
    }
    $release = [string](Get-WorkflowSettingValue -Object $manifest -Name "release" -Default "")
    if (-not $release.Trim()) {
        throw "В манифесте нет имени релиза (release): $Path"
    }
    $tasksProperty = Get-WorkflowJsonArrayProperty -Object $manifest -Name "tasks"
    if (-not $tasksProperty.Present) {
        throw "В манифесте нет списка задач (tasks): $Path"
    }

    $seen = @{}
    $tasks = New-Object System.Collections.ArrayList
    foreach ($item in $tasksProperty.Items) {
        $key = [string](Get-WorkflowSettingValue -Object $item -Name "key" -Default "")
        $key = $key.Trim()
        if (-not $key) {
            throw "В манифесте задача без ключа (key): $Path"
        }
        $normalizedKey = $key.ToUpperInvariant()
        if ($seen.ContainsKey($normalizedKey)) {
            throw "В манифесте задача $key описана дважды: $Path"
        }
        $seen[$normalizedKey] = $true
        # Присваивание, а не выражение if: пустой массив, вышедший из выражения,
        # разворачивается в $null, и «paths: []» стал бы «paths нет».
        $paths = Get-WorkflowJsonArrayProperty -Object $item -Name "paths"
        $taskPaths = $null
        if ($paths.Present) {
            $taskPaths = [string[]]@($paths.Items | ForEach-Object { [string]$_ })
        }
        [void]$tasks.Add([pscustomobject]@{
            Key = $key
            Title = [string](Get-WorkflowSettingValue -Object $item -Name "title" -Default "")
            Url = [string](Get-WorkflowSettingValue -Object $item -Name "url" -Default "")
            Paths = $taskPaths
        })
    }

    return [pscustomobject]@{
        Release = $release.Trim()
        Title = [string](Get-WorkflowSettingValue -Object $manifest -Name "title" -Default "")
        Tasks = @($tasks)
    }
}

function Get-WorkflowGuidePassports {
    <#
    .SYNOPSIS
    Паспорта сценариев инструкций: к каким задачам относится сценарий и как его
    запускать.

    .DESCRIPTION
    Паспорт — `<сценарий>.guide.json` рядом с `<сценарий>.mjs`. Схема 1:
      { "schemaVersion": 1, "tasks": ["<ключ>", ...], "title": "...",
        "persona": "<пользователь ИБ публикации>", "seeds": ["<сид>", ...],
        "status": "draft" | "reviewed" }

    Ошибочный паспорт не бросает исключение, а попадает в Problems: цикл идёт по
    всему релизу, и один сломанный файл не должен останавливать остальные. Но и
    пропадать молча он не должен — отчёт показывает его отдельной строкой.
    `status` по умолчанию draft: «проверено человеком» ставится только явно.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScenarioRoot
    )

    $passports = New-Object System.Collections.ArrayList
    $problems = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $ScenarioRoot -PathType Container)) {
        return [pscustomobject]@{ Passports = @(); Problems = @() }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $ScenarioRoot -Filter "*.guide.json" -File | Sort-Object Name)) {
        $scenario = $file.Name.Substring(0, $file.Name.Length - ".guide.json".Length)
        $scenarioFile = Join-Path $ScenarioRoot "$scenario.mjs"
        if (-not (Test-Path -LiteralPath $scenarioFile -PathType Leaf)) {
            [void]$problems.Add("$($file.Name): нет сценария $scenario.mjs")
            continue
        }
        try {
            $data = Get-Content -Raw -LiteralPath $file.FullName -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            [void]$problems.Add("$($file.Name): не читается как JSON")
            continue
        }
        if ([int](Get-WorkflowSettingValue -Object $data -Name "schemaVersion" -Default 0) -ne 1) {
            [void]$problems.Add("$($file.Name): неподдерживаемая схема (нужна 1)")
            continue
        }
        $tasks = @((Get-WorkflowJsonArrayProperty -Object $data -Name "tasks").Items |
            ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
        if ($tasks.Count -eq 0) {
            [void]$problems.Add("$($file.Name): не указаны задачи (tasks)")
            continue
        }
        $status = [string](Get-WorkflowSettingValue -Object $data -Name "status" -Default "draft")
        if (@("draft", "reviewed") -notcontains $status) {
            [void]$problems.Add("$($file.Name): статус '$status' не из draft|reviewed")
            continue
        }
        $seeds = @((Get-WorkflowJsonArrayProperty -Object $data -Name "seeds").Items |
            ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
        [void]$passports.Add([pscustomobject]@{
            Scenario = $scenario
            Tasks = $tasks
            Title = [string](Get-WorkflowSettingValue -Object $data -Name "title" -Default "")
            Persona = [string](Get-WorkflowSettingValue -Object $data -Name "persona" -Default "")
            Seeds = $seeds
            Status = $status
        })
    }

    return [pscustomobject]@{ Passports = @($passports); Problems = @($problems) }
}

function Get-WorkflowReleasePlan {
    <#
    .SYNOPSIS
    План релиза: каждая задача с классом, сценариями и покрытием.

    .DESCRIPTION
    Покрытие — то, что увидит человек в отчёте:
      scenario    — у задачи есть сценарий, он будет собран;
      needed      — задача меняет интерфейс, а сценария нет;
      no-data     — адаптер не сообщил, что изменилось; решить нельзя;
      not-needed  — изменений интерфейса нет (фон или без кода).

    Задача ui без сценария НЕ пропускается молча: она и есть работа, которую
    цикл обязан показать. Сценарий, чьи задачи в релиз не входят, в план не
    попадает — он относится к другому релизу.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [object[]]$Passports = @()
    )

    $byTask = @{}
    foreach ($passport in @($Passports)) {
        foreach ($key in @($passport.Tasks)) {
            $normalized = ([string]$key).ToUpperInvariant()
            if (-not $byTask.ContainsKey($normalized)) {
                $byTask[$normalized] = New-Object System.Collections.ArrayList
            }
            [void]$byTask[$normalized].Add($passport.Scenario)
        }
    }

    $tasks = foreach ($task in @($Manifest.Tasks)) {
        $class = Get-WorkflowReleaseTaskClass -Paths $task.Paths
        $normalized = $task.Key.ToUpperInvariant()
        $scenarios = @()
        if ($byTask.ContainsKey($normalized)) {
            $scenarios = @($byTask[$normalized] | Sort-Object -Unique)
        }
        $coverage = if ($scenarios.Count -gt 0) {
            "scenario"
        }
        elseif ($class.Class -eq "ui") {
            "needed"
        }
        elseif ($class.Class -eq "unknown") {
            "no-data"
        }
        else {
            "not-needed"
        }
        [pscustomobject]@{
            Key = $task.Key
            Title = $task.Title
            Url = $task.Url
            Class = $class.Class
            Kinds = @($class.Kinds)
            Scenarios = @($scenarios)
            Coverage = $coverage
        }
    }

    return [pscustomobject]@{
        Release = $Manifest.Release
        Title = $Manifest.Title
        Tasks = @($tasks)
    }
}

function Update-WorkflowReleasePlan {
    <#
    .SYNOPSIS
    Строит план по манифесту в каталоге релиза и текущим паспортам и сохраняет его.

    .DESCRIPTION
    План — чистая функция двух входов: состава релиза и паспортов сценариев. Состав
    меняется только шагом plan (адаптер или -Manifest), а паспорта — каждый раз,
    когда агент дописывает сценарий. Поэтому план пересчитывается при КАЖДОМ
    запуске по сохранённому манифесту: иначе запуск с -From guides после нового
    сценария работает по старому плану и отвечает «сценариев для сборки нет».
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,

        [Parameter(Mandatory = $true)]
        [string]$Release,

        [object[]]$Passports = @(),

        [Parameter(Mandatory = $true)]
        [string]$PlanPath
    )

    $manifestData = Read-WorkflowReleaseManifest -Path $ManifestPath
    if ($manifestData.Release -ne $Release.Trim()) {
        # Манифест другого релиза в каталоге этого — ошибка вызова, а не данные.
        throw "Манифест описывает релиз '$($manifestData.Release)', а запрошен '$Release'."
    }
    $plan = Get-WorkflowReleasePlan -Manifest $manifestData -Passports @($Passports)
    Write-WorkflowJson -Value $plan -Path $PlanPath | Out-Null
    return $plan
}

function Test-WorkflowGuidePublication {
    <#
    .SYNOPSIS
    Отвечает, поднята ли публикация: пустая строка — да, иначе причина.

    .DESCRIPTION
    Любой HTTP-ответ, включая 401 и 404, значит «веб-сервер работает». Отказ в
    соединении — нет: чаще всего Apache стенда не пережил перезагрузку машины.
    Без этой проверки цикл заливает данные и собирает инструкции по очереди, и
    каждый сценарий падает отдельно, с сообщением исполнителя или раннера вместо
    одной понятной причины.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [int]$TimeoutSeconds = 60
    )

    try {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Method = "GET"
        $request.Timeout = $TimeoutSeconds * 1000
        $response = $request.GetResponse()
        $response.Close()
        return ""
    }
    catch [System.Net.WebException] {
        if ($null -ne $_.Exception.Response) {
            $_.Exception.Response.Close()
            return ""
        }
        return "публикация недоступна ($($_.Exception.Status)): $Url"
    }
    catch {
        return "публикация недоступна: $Url — $($_.Exception.Message)"
    }
}

function ConvertFrom-WorkflowPersonaUrls {
    <#
    .SYNOPSIS
    Разбирает «Имя=URL;Имя2=URL» в таблицу публикаций по персонам.

    .DESCRIPTION
    Строкой, а не хеш-таблицей: оркестратор запускают и через `powershell -File`,
    где хеш-таблицу не передать. Персона без публикации — отказ сценария, а не
    подстановка общей: снимок под администратором покажет всё, что разрешено
    администратору, и про роль персоны ничего не скажет.
    #>
    param(
        [string]$Value = ""
    )

    $map = @{}
    foreach ($pair in @($Value -split ';')) {
        $text = $pair.Trim()
        if (-not $text) {
            continue
        }
        $separator = $text.IndexOf('=')
        if ($separator -le 0 -or $separator -eq ($text.Length - 1)) {
            throw "Публикация персоны задана неверно: '$text'. Нужно «Имя=URL»."
        }
        $map[$text.Substring(0, $separator).Trim()] = $text.Substring($separator + 1).Trim()
    }
    return $map
}

function ConvertTo-WorkflowHtmlText {
    param([AllowNull()][object]$Value)

    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-WorkflowReleaseReportHtml {
    <#
    .SYNOPSIS
    Сводная страница релиза: задача, класс, покрытие, сценарии и их результат.

    .DESCRIPTION
    Самодостаточный HTML, как и сами инструкции: страницу пересылают и кладут на
    портал. Ссылки на инструкции — относительные, от каталога релиза.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [hashtable]$Results = @{},

        [hashtable]$Passports = @{},

        [string[]]$Problems = @()
    )

    $coverageText = @{
        "scenario" = "есть сценарий"
        "needed" = "нужен сценарий"
        "no-data" = "нет данных об изменениях"
        "not-needed" = "не требуется"
    }
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">')
    [void]$parts.Add("<title>Инструкции релиза $(ConvertTo-WorkflowHtmlText $Plan.Release)</title>")
    [void]$parts.Add('<style>' +
        "body{font:14px/1.5 -apple-system,'Segoe UI',Roboto,sans-serif;color:#1d1d1f;max-width:1100px;margin:28px auto;padding:0 18px}" +
        'h1{font-size:22px;margin:0 0 4px}.meta{color:#6e6e73;margin:0 0 18px}' +
        'table{border-collapse:collapse;width:100%}th,td{text-align:left;vertical-align:top;padding:6px 8px;border-bottom:1px solid #e3e3e6}' +
        'th{font-weight:600;color:#3c3c43}.bad{color:#b3261e}.warn{color:#8a5a00}.ok{color:#1b6e3a}.muted{color:#6e6e73}' +
        '@media (prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}th{color:#d1d1d6}th,td{border-color:#3a3a3c}' +
        '.meta,.muted{color:#98989d}.bad{color:#ff8a80}.warn{color:#ffcc80}.ok{color:#81c995}}' +
        '</style></head><body>')
    [void]$parts.Add("<h1>Инструкции релиза $(ConvertTo-WorkflowHtmlText $Plan.Release)</h1>")

    $tasks = @($Plan.Tasks)
    $counts = @{}
    foreach ($task in $tasks) {
        $counts[$task.Coverage] = 1 + [int]$(if ($counts.ContainsKey($task.Coverage)) { $counts[$task.Coverage] } else { 0 })
    }
    $summary = @($coverageText.Keys | Where-Object { $counts.ContainsKey($_) } | Sort-Object |
        ForEach-Object { "$($coverageText[$_]): $($counts[$_])" }) -join " · "
    [void]$parts.Add("<p class=""meta"">Задач: $($tasks.Count). $(ConvertTo-WorkflowHtmlText $summary). Сформировано $(ConvertTo-WorkflowHtmlText ((Get-Date).ToString('dd.MM.yyyy HH:mm'))).</p>")

    if (@($Problems).Count -gt 0) {
        [void]$parts.Add('<p class="bad">Паспорта с ошибками (сценарии не учтены):</p><ul>')
        foreach ($problem in @($Problems)) {
            [void]$parts.Add("<li class=""bad"">$(ConvertTo-WorkflowHtmlText $problem)</li>")
        }
        [void]$parts.Add('</ul>')
    }

    [void]$parts.Add('<table><thead><tr><th>Задача</th><th>Изменения</th><th>Покрытие</th><th>Сценарий и результат</th></tr></thead><tbody>')
    foreach ($task in $tasks) {
        $keyCell = ConvertTo-WorkflowHtmlText $task.Key
        if ($task.Url) {
            $keyCell = "<a href=""$(ConvertTo-WorkflowHtmlText $task.Url)"">$keyCell</a>"
        }
        if ($task.Title) {
            $keyCell += "<br><span class=""muted"">$(ConvertTo-WorkflowHtmlText $task.Title)</span>"
        }
        $kinds = if (@($task.Kinds).Count -gt 0) { " (" + (@($task.Kinds) -join ", ") + ")" } else { "" }
        $coverageClass = switch ($task.Coverage) { "needed" { "warn" } "no-data" { "warn" } "scenario" { "" } default { "muted" } }

        $scenarioLines = foreach ($scenario in @($task.Scenarios)) {
            $line = "<b>$(ConvertTo-WorkflowHtmlText $scenario)</b>"
            if ($Passports.ContainsKey($scenario)) {
                $status = [string]$Passports[$scenario].Status
                $line += $(if ($status -eq "reviewed") { " <span class=""ok"">проверено</span>" } else { " <span class=""warn"">черновик</span>" })
            }
            if ($Results.ContainsKey($scenario)) {
                $result = $Results[$scenario]
                if ([string]$result.Status -eq "built") {
                    $line += " — <a href=""$(ConvertTo-WorkflowHtmlText $result.Guide)"">инструкция</a>"
                }
                else {
                    $line += " — <span class=""bad"">$(ConvertTo-WorkflowHtmlText $result.Detail)</span>"
                }
                $line += " <span class=""muted"">$(ConvertTo-WorkflowHtmlText $result.At)</span>"
            }
            else {
                $line += " <span class=""muted"">не собирался</span>"
            }
            $line
        }

        [void]$parts.Add("<tr><td>$keyCell</td><td>$(ConvertTo-WorkflowHtmlText ($task.Class + $kinds))</td>" +
            "<td class=""$coverageClass"">$(ConvertTo-WorkflowHtmlText $coverageText[$task.Coverage])</td>" +
            "<td>$(@($scenarioLines) -join '<br>')</td></tr>")
    }
    [void]$parts.Add('</tbody></table></body></html>')
    return (@($parts) -join "`n")
}
