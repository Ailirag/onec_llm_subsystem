[CmdletBinding()]
param(
    # Каталог выгрузки. По умолчанию — sourceDir из манифеста.
    [string]$SourceDir = "",

    # Где лежат картинки, на которые ссылаются страницы. По умолчанию —
    # userHelp.imagesDir.
    [string]$ImagesDir = "",

    # Проверить и ничего не менять.
    [switch]$WhatIfOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "..\scripts\workflow\Workflow.Common.ps1")

<#
Готовит страницы встроенной справки к показу в веб-клиенте.

Зачем это нужно. Тонкий клиент открывает справку как есть, а веб-клиент — нет, и
ровно двумя способами:

  картинки — файлы из каталога _files веб-клиент не отдаёт. Страница, которая
             ссылается на картинку файлом, показывается без неё, и виноватым
             выглядит автор справки;
  ссылки   — переход на соседнюю страницу веб-клиент открывает без параметров
             сеанса и отвечает «страница отсутствует». Пользователь считает, что
             справки нет.

Обе поправки механические, поэтому их делает скрипт, а не человек при каждой
правке. Скрипт ИДЕМПОТЕНТЕН: повторный запуск ничего не портит и не раздувает
страницу — картинка узнаётся по data-file, скрипт ссылок по метке.

Автор пишет <img data-file="имя.png"> и не думает про data:. Имя ищется в
каталоге картинок справки.
#>

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot

if (-not $SourceDir) {
    $SourceDir = [string]$config.sourceDir
}
$sourcePath = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $SourceDir

$helpSettings = Get-WorkflowUserHelpSettings -Config $config
if (-not $ImagesDir) {
    $ImagesDir = $helpSettings.ImagesDir
}
$imagesPath = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path $ImagesDir

$linkFixMarker = "onec-help-link-fix"
$linkFixScript = @"
<script data-mark="$linkFixMarker">
// Веб-клиент открывает ссылку между страницами справки без параметров сеанса и
// показывает «страница отсутствует». Параметры берутся из адреса самой страницы
// и возвращаются ссылкам при клике: иначе каждая вторая ссылка справки ведёт в
// пустоту, и пользователь решает, что справки нет.
(function () {
  var query = window.location.search || "";
  if (!query) { return; }
  document.addEventListener("click", function (event) {
    var link = event.target && event.target.closest ? event.target.closest("a[href]") : null;
    if (!link) { return; }
    var href = link.getAttribute("href") || "";
    if (!href || href.charAt(0) === "#" || href.indexOf("?") >= 0 || /^[a-z]+:/i.test(href)) { return; }
    link.setAttribute("href", href + query);
  }, true);
})();
</script>
"@

$mimeByExtension = @{
    ".png" = "image/png"
    ".jpg" = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".gif" = "image/gif"
    ".svg" = "image/svg+xml"
}

$pages = @()
if (Test-Path -LiteralPath $sourcePath -PathType Container) {
    $pages = @(
        Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Filter "*.html" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName.Replace([string][char]92, "/") -match "/Ext/Help/" }
    )
}

if ($pages.Count -eq 0) {
    Write-Host "Страниц справки не найдено в $sourcePath — править нечего."
    return
}

Write-Host "Страниц справки: $($pages.Count)"
Write-Host "Картинки: $imagesPath"
Write-Host ""

$missingImages = New-Object System.Collections.ArrayList
$heavyPages = New-Object System.Collections.ArrayList
$changed = 0

foreach ($page in $pages) {
    $text = Get-Content -Raw -LiteralPath $page.FullName -Encoding UTF8
    $original = $text

    # Картинка вставляется по data-file и ПЕРЕВСТАВЛЯЕТСЯ при повторном запуске:
    # так обновлённый снимок доезжает до страницы, а не остаётся в каталоге.
    foreach ($match in [regex]::Matches($text, '<img\b[^>]*data-file="([^"]+)"[^>]*>')) {
        $fileName = $match.Groups[1].Value
        $imageFile = Join-Path $imagesPath $fileName
        if (-not (Test-Path -LiteralPath $imageFile -PathType Leaf)) {
            [void]$missingImages.Add("$($page.Name): $fileName")
            continue
        }

        $extension = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()
        $mime = if ($mimeByExtension.ContainsKey($extension)) { $mimeByExtension[$extension] } else { "image/png" }
        $data = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($imageFile))

        $tag = $match.Value
        $withoutSrc = [regex]::Replace($tag, '\s+src="[^"]*"', "")
        $updated = $withoutSrc -replace '<img\b', ('<img src="data:' + $mime + ';base64,' + $data + '"')
        $text = $text.Replace($tag, $updated)
    }

    # Скрипт ссылок ставится один раз: метка отличает его от чужого скрипта на
    # странице, а повторная вставка раздувала бы страницу с каждым запуском.
    if ($text -notmatch [regex]::Escape($linkFixMarker)) {
        if ($text -match "</body>") {
            $text = $text -replace "</body>", ($linkFixScript + "</body>")
        }
        else {
            $text = $text + $linkFixScript
        }
    }

    if ($text -ne $original) {
        $changed = $changed + 1
        if (-not $WhatIfOnly) {
            # Без BOM: 1С читает страницу справки как UTF-8, а метка порядка
            # байтов выводится в начале страницы видимым мусором.
            [System.IO.File]::WriteAllText($page.FullName, $text, (New-Object System.Text.UTF8Encoding($false)))
        }
    }

    $sizeKb = [Math]::Round(([System.Text.Encoding]::UTF8.GetByteCount($text) / 1KB), 0)
    if ($sizeKb -gt $helpSettings.PageWarnKb) {
        [void]$heavyPages.Add("$($page.Directory.Parent.Parent.Name): $sizeKb КБ")
    }
}

Write-Host "Обновлено страниц: $changed$(if ($WhatIfOnly) { ' (проверка, файлы не тронуты)' })"

if ($missingImages.Count -gt 0) {
    Write-Host ""
    Write-Host "Картинки не найдены — страница покажется без них:"
    foreach ($item in $missingImages) {
        Write-Host "  $item"
    }
}

if ($heavyPages.Count -gt 0) {
    Write-Host ""
    Write-Host "Тяжёлые страницы (больше $($helpSettings.PageWarnKb) КБ). Картинка внутри страницы"
    Write-Host "растёт на треть от кодирования, и такую страницу неудобно читать и править:"
    foreach ($item in $heavyPages) {
        Write-Host "  $item"
    }
    Write-Host "Уменьшите снимок до ширины окна справки или снимите фрагмент, а не весь экран."
}

if ($missingImages.Count -gt 0) {
    throw "Не найдено картинок: $($missingImages.Count). Страницы справки ссылаются на то, чего нет."
}
