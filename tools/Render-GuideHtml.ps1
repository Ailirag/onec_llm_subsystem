<#
.SYNOPSIS
    Встроенный оформитель пользовательских инструкций: артефакт съёмки — в HTML.

.DESCRIPTION
    Комплект отделяет съёмку от оформления. Съёмка производит артефакт —
    guide.json и кадры рядом с ним, — а документ из артефакта делает оформитель.
    Этот оформитель работает всегда и ничего не требует: комплект, который из
    коробки не производит готовую инструкцию, бесполезен.

    Проект, которому нужен другой формат или публикация в корпоративную вики,
    объявляет свой оформитель ключом `userGuides.renderScript`. Договор один и
    тот же, и описан он в разделе «Пользовательские инструкции» файла
    docs/1c-development-workflow.md.

    Файл получается самодостаточным: стили внутри, картинки вставлены строкой
    data:. Инструкцию пересылают почтой и кладут на портал, и внешняя ссылка на
    картинку превратила бы её в набор битых рамок на второй неделе. Ужимаются
    кадры на съёмке — здесь обрабатывать их нечем и не нужно.

.PARAMETER GuidePath
    Каталог артефакта одной инструкции: guide.json и кадры.

.PARAMETER IndexPath
    Отчёт релизного прохода (report.json) — тогда собирается сводная страница по
    релизу вместо одной инструкции.

.PARAMETER Template
    Шаблон оформления. Встроенный оформитель шаблоны не поддерживает и отказывает
    явно: молча проигнорированный шаблон хуже отсутствующего — проект считает,
    что документ оформлен по правилам компании, а это не так.

.PARAMETER ReportPath
    Куда записать отчёт о том, что получилось.
#>
[CmdletBinding()]
param(
    [string]$GuidePath = "",
    [string]$IndexPath = "",
    [string]$Template = "",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path $PSScriptRoot -Parent) "scripts\workflow\Workflow.Common.ps1")

if (-not $GuidePath -and -not $IndexPath) {
    throw "Нужен либо -GuidePath (одна инструкция), либо -IndexPath (сводка по релизу)."
}
if ($GuidePath -and $IndexPath) {
    throw "-GuidePath и -IndexPath взаимоисключающие: это два разных документа."
}
if ($Template) {
    throw ("Встроенный оформитель не умеет шаблоны. Задан userGuides.template — " +
        "объявите и оформитель проекта ключом userGuides.renderScript.")
}

function ConvertTo-GuideHtmlText {
    param([AllowEmptyString()][string]$Value)

    return [string]$Value `
        -replace '&', '&amp;' `
        -replace '<', '&lt;' `
        -replace '>', '&gt;' `
        -replace '"', '&quot;'
}

function Get-GuideHtmlStyle {
    return "body{font:15px/1.55 -apple-system,'Segoe UI',Roboto,sans-serif;color:#1d1d1f;" +
        'max-width:1000px;margin:32px auto;padding:0 20px}' +
        'h1{font-size:26px;margin:0 0 4px}' +
        '.meta{color:#6e6e73;font-size:13px;margin:0 0 26px}' +
        '.step{margin:0 0 30px;padding-top:18px;border-top:1px solid #e3e3e6}' +
        '.step h2{font-size:17px;margin:0 0 6px}' +
        '.step h2 span{display:inline-block;min-width:26px;color:#6e6e73;font-weight:400}' +
        '.note{color:#3c3c43;margin:0 0 10px}' +
        'img{width:100%;border:1px solid #d8d8dc;border-radius:6px;display:block}' +
        '@media (prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}' +
        '.step{border-color:#3a3a3c}.note{color:#d1d1d6}.meta{color:#98989d}' +
        'img{border-color:#3a3a3c}}'
}

$produced = New-Object System.Collections.ArrayList

if ($GuidePath) {
    $artifactPath = Join-Path $GuidePath "guide.json"
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        throw "Артефакт инструкции не найден: $artifactPath. Вызывает ли сценарий saveGuide()?"
    }

    $artifact = Get-Content -Raw -LiteralPath $artifactPath -Encoding UTF8 | ConvertFrom-Json
    $steps = @(Get-WorkflowSettingValue -Object $artifact -Name "steps" -Default @())
    if ($steps.Count -eq 0) {
        throw "В артефакте нет ни одного шага: $artifactPath"
    }

    $title = [string](Get-WorkflowSettingValue -Object $artifact -Name "title" -Default "Инструкция")
    $format = [string](Get-WorkflowSettingValue -Object $artifact -Name "imageFormat" -Default "png")
    $mime = if ($format -eq "jpeg") { "image/jpeg" } else { "image/png" }

    # Время берётся из артефакта, а не из часов оформителя: документ говорит,
    # когда он снят с системы, а не когда его в очередной раз переверстали.
    $capturedAt = [string](Get-WorkflowSettingValue -Object $artifact -Name "capturedAt" -Default "")
    $capturedText = if ($capturedAt) {
        try { ([DateTimeOffset]::Parse($capturedAt)).LocalDateTime.ToString("g", [System.Globalization.CultureInfo]::GetCultureInfo("ru-RU")) }
        catch { $capturedAt }
    }
    else { "" }

    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">')
    [void]$parts.Add('<title>' + (ConvertTo-GuideHtmlText -Value $title) + '</title>')
    [void]$parts.Add('<style>' + (Get-GuideHtmlStyle) + '</style></head><body>')
    [void]$parts.Add('<h1>' + (ConvertTo-GuideHtmlText -Value $title) + '</h1>')
    [void]$parts.Add('<p class="meta">Снято автоматически из рабочей базы ' +
        (ConvertTo-GuideHtmlText -Value $capturedText) + '. Шагов: ' + $steps.Count + '.</p>')

    # Человеческие разделы из паспорта: назначение, роли, предусловия и прочее,
    # чего из прогона не добыть. Их состав объявляет проект в
    # userGuides.templateFields, а сюда они приходят уже проверенными.
    foreach ($field in @(Get-WorkflowSettingValue -Object $artifact -Name "sections" -Default @())) {
        $heading = [string](Get-WorkflowSettingValue -Object $field -Name "title" -Default "")
        $body = [string](Get-WorkflowSettingValue -Object $field -Name "text" -Default "")
        if (-not $heading -and -not $body) {
            continue
        }
        [void]$parts.Add('<div class="step"><h2>' + (ConvertTo-GuideHtmlText -Value $heading) + '</h2>')
        [void]$parts.Add('<p class="note">' + (ConvertTo-GuideHtmlText -Value $body) + '</p></div>')
    }

    foreach ($step in $steps) {
        $caption = [string](Get-WorkflowSettingValue -Object $step -Name "caption" -Default "")
        $number = [string](Get-WorkflowSettingValue -Object $step -Name "number" -Default "")
        $note = [string](Get-WorkflowSettingValue -Object $step -Name "note" -Default "")
        $image = [string](Get-WorkflowSettingValue -Object $step -Name "image" -Default "")

        [void]$parts.Add('<div class="step">')
        [void]$parts.Add('<h2><span>' + $number + '.</span> ' + (ConvertTo-GuideHtmlText -Value $caption) + '</h2>')
        if ($note) {
            [void]$parts.Add('<p class="note">' + (ConvertTo-GuideHtmlText -Value $note) + '</p>')
        }
        if ($image) {
            $imagePath = Join-Path $GuidePath $image
            if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
                throw "Кадр шага $number не найден: $imagePath"
            }
            $encoded = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($imagePath))
            [void]$parts.Add('<img alt="' + (ConvertTo-GuideHtmlText -Value $caption) +
                '" src="data:' + $mime + ';base64,' + $encoded + '">')
        }
        [void]$parts.Add('</div>')
    }
    [void]$parts.Add('</body></html>')

    $outputFile = Join-Path $GuidePath "index.html"
    [System.IO.File]::WriteAllText($outputFile, ($parts -join "`n"), [System.Text.UTF8Encoding]::new($false))
    [void]$produced.Add($outputFile)
}
else {
    if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) {
        throw "Отчёт релизного прохода не найден: $IndexPath"
    }
    $report = Get-Content -Raw -LiteralPath $IndexPath -Encoding UTF8 | ConvertFrom-Json
    $releaseRoot = Split-Path $IndexPath -Parent

    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">')
    [void]$parts.Add('<title>Инструкции релиза</title>')
    [void]$parts.Add('<style>' + (Get-GuideHtmlStyle) + '</style></head><body>')
    [void]$parts.Add('<h1>Инструкции релиза</h1>')

    foreach ($item in @(Get-WorkflowSettingValue -Object $report -Name "guides" -Default @())) {
        $name = [string](Get-WorkflowSettingValue -Object $item -Name "scenario" -Default "")
        $link = [string](Get-WorkflowSettingValue -Object $item -Name "guide" -Default "")
        $status = [string](Get-WorkflowSettingValue -Object $item -Name "status" -Default "")
        [void]$parts.Add('<div class="step"><h2>' + (ConvertTo-GuideHtmlText -Value $name) + '</h2>')
        if ($link) {
            [void]$parts.Add('<p><a href="' + (ConvertTo-GuideHtmlText -Value $link) + '">' +
                (ConvertTo-GuideHtmlText -Value $link) + '</a></p>')
        }
        [void]$parts.Add('<p class="note">' + (ConvertTo-GuideHtmlText -Value $status) + '</p></div>')
    }
    [void]$parts.Add('</body></html>')

    $outputFile = Join-Path $releaseRoot "index.html"
    [System.IO.File]::WriteAllText($outputFile, ($parts -join "`n"), [System.Text.UTF8Encoding]::new($false))
    [void]$produced.Add($outputFile)
}

if ($ReportPath) {
    Write-WorkflowJson -Value ([pscustomobject]@{
        renderer = "builtin-html"
        format = "html"
        files = @($produced)
        url = ""
        createdAt = [DateTimeOffset]::Now.ToString("o")
    }) -Path $ReportPath | Out-Null
}

foreach ($file in $produced) {
    Write-Host "Оформлено: $file"
}
