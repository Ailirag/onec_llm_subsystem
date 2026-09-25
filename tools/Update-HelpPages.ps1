[CmdletBinding()]
param(
    [string]$ExtensionPath = "",
    [string]$ScreenshotsPath = "",
    [string]$DiagramsPath = "",
    [int]$MaxWidth = 1000,
    [int]$JpegQuality = 82,
    [int]$CropTop = 32,
    [int]$CropBottom = 32
)

# Готовит встроенную справку расширения (F1) к веб-клиенту. Веб-клиент
# обходится со справкой расширения иначе, чем со справкой конфигурации:
#
# 1. Картинки из папки _files справки расширения он не отдает (404), а
#    картинку, встроенную в саму страницу адресом data:, показывает. Поэтому в
#    страницах справки картинка задается тегом с именем файла:
#
#        <img data-file="place-main.png" alt="Место запуска">
#
#    а скрипт подставляет в тег src="data:...". Откуда берутся файлы:
#      *.svg — схемы, исходники в docs/help-images;
#      *.png — снимки экранов, их снимает tests/ui/help-screens.mjs в .build/help.
#    Снимок веб-клиента обрезается сверху и снизу (заголовок окна и панель
#    открытых форм), уменьшается до MaxWidth и кодируется в JPEG. Нет файла —
#    тег остается как был: скрипт можно запускать и без снимков.
#
# 2. Страницу справки расширения он открывает только с параметрами сеанса, а
#    ссылки на другие страницы («Catalog.X/Help») платформа строит без них — и
#    по такой ссылке показывает «Указанная страница отсутствует». В конец
#    каждой страницы вставляется короткий скрипт, который дописывает к таким
#    ссылкам параметры из адреса текущей страницы. В тонком клиенте адрес
#    страницы параметров не несет, и скрипт ничего не меняет.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$repositoryPath = Split-Path $PSScriptRoot -Parent
if (-not $ExtensionPath) { $ExtensionPath = Join-Path $repositoryPath "cfe llm" }
if (-not $ScreenshotsPath) { $ScreenshotsPath = Join-Path $repositoryPath ".build\help" }
if (-not $DiagramsPath) { $DiagramsPath = Join-Path $repositoryPath "docs\help-images" }

$jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
    Where-Object { $_.MimeType -eq "image/jpeg" } | Select-Object -First 1
$cache = @{}

function Get-ScreenshotDataUri {
    param([string]$Path)

    $source = [System.Drawing.Image]::FromFile($Path)
    try {
        $height = $source.Height - $CropTop - $CropBottom
        if ($height -le 0) { throw "Снимок меньше обрезки: $Path" }
        $scale = [Math]::Min(1.0, $MaxWidth / $source.Width)
        $width = [int][Math]::Round($source.Width * $scale)
        $targetHeight = [int][Math]::Round($height * $scale)
        $target = New-Object System.Drawing.Bitmap($width, $targetHeight)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($target)
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.DrawImage($source,
                (New-Object System.Drawing.Rectangle(0, 0, $width, $targetHeight)),
                (New-Object System.Drawing.Rectangle(0, $CropTop, $source.Width, $height)),
                [System.Drawing.GraphicsUnit]::Pixel)
            $graphics.Dispose()

            $parameters = New-Object System.Drawing.Imaging.EncoderParameters(1)
            $parameters.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
                [System.Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)
            $stream = New-Object System.IO.MemoryStream
            $target.Save($stream, $jpegCodec, $parameters)
            return "data:image/jpeg;base64," + [Convert]::ToBase64String($stream.ToArray())
        } finally {
            $target.Dispose()
        }
    } finally {
        $source.Dispose()
    }
}

function Get-DataUri {
    param([string]$Name)

    if ($cache.ContainsKey($Name)) { return $cache[$Name] }
    $uri = $null
    if ($Name -like "*.svg") {
        $path = Join-Path $DiagramsPath $Name
        if (Test-Path -LiteralPath $path) {
            $uri = "data:image/svg+xml;base64," + [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($path))
        }
    } else {
        $path = Join-Path $ScreenshotsPath $Name
        if (Test-Path -LiteralPath $path) {
            $uri = Get-ScreenshotDataUri $path
        }
    }
    $cache[$Name] = $uri
    return $uri
}

$encoding = New-Object System.Text.UTF8Encoding($true)
$imagePattern = '(?s)<img\b[^>]*?\bdata-file="([^"]+)"[^>]*>'
$linksPattern = '(?s)\s*<!--session-links-->.*?<!--/session-links-->'
$linksBlock = @'
<!--session-links-->
<script type="text/javascript">
(function () {
    var parameters = window.location.search;
    if (!parameters) return;
    for (var i = 0; i < document.links.length; i++) {
        var link = document.links[i];
        if (link.href.indexOf('/mdobject/') >= 0 && link.href.indexOf('?') < 0) {
            link.href = link.href + parameters;
        }
    }
})();
</script>
<!--/session-links-->
'@
$pages = Get-ChildItem -LiteralPath $ExtensionPath -Recurse -Filter "ru.html" |
    Where-Object { $_.FullName -match '\\Ext\\Help\\ru\.html$' }

$missing = New-Object System.Collections.Generic.List[string]
foreach ($page in $pages) {
    $text = [System.IO.File]::ReadAllText($page.FullName, $encoding)
    $updated = [regex]::Replace($text, $imagePattern, {
        param($match)
        $tag = $match.Value
        $uri = Get-DataUri $match.Groups[1].Value
        if (-not $uri) {
            $missing.Add($match.Groups[1].Value + " (" + $page.FullName.Substring($ExtensionPath.Length + 1) + ")")
            return $tag
        }
        if ($tag -match '\bsrc="[^"]*"') {
            return [regex]::Replace($tag, '\bsrc="[^"]*"', 'src="' + $uri + '"')
        }
        return $tag -replace '^<img\b', ('<img src="' + $uri + '"')
    })
    $updated = [regex]::Replace($updated, $linksPattern, '')
    $updated = $updated.Replace('</body>', $linksBlock + "`r`n</body>")
    if ($updated -ne $text) {
        [System.IO.File]::WriteAllText($page.FullName, $updated, $encoding)
        Write-Host ("[OK] {0} — {1:N0} КБ" -f $page.FullName.Substring($ExtensionPath.Length + 1),
            ($encoding.GetByteCount($updated) / 1KB))
    }
}

foreach ($item in ($missing | Select-Object -Unique)) {
    Write-Warning "Нет файла картинки, тег оставлен как был: $item"
}
