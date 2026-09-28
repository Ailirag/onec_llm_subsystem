<#
.SYNOPSIS
Проверяет целостность XML-выгрузки 1С без запуска платформы.

.DESCRIPTION
Проверка предназначена для CI и для контроля после разрешения конфликтов слияния.
Она ловит именно те дефекты, которые возникают при параллельной разработке и
которые компилятор 1С обнаружит слишком поздно (или не обнаружит вовсе):

1. Маркеры конфликтов слияния, попавшие в исходники.
2. Некорректный XML (обрыв структуры при ручном разрешении конфликта).
3. Объект объявлен в Configuration.xml, но файла нет — конфигурация не загрузится.
4. Файл объекта есть, но объявления в Configuration.xml нет — САМЫЙ частый
   молчаливый дефект слияния: объект «исчезает» из конфигурации, при этом Git
   diff выглядит чисто, а рабочая копия коллеги теряет чужую доработку.
5. Дубли объявлений в Configuration.xml.

Сопоставление вида метаданных с каталогом выводится из самой выгрузки, а не из
захардкоженного словаря: для каждого каталога читается первый XML и берётся имя
элемента внутри MetaDataObject. Поэтому проверка не зависит от версии платформы и
работает для любой конфигурации.

.PARAMETER ReportPath
Куда записать JSON-отчёт. По умолчанию — в localStateDir.

.PARAMETER Strict
Считать предупреждения (нерешённые ссылки подсистем) ошибками.
#>
[CmdletBinding()]
param(
    [string]$ReportPath = "",
    [switch]$Strict
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Workflow.Common.ps1")

function Get-ComponentMetadataMap {
    <#
    Возвращает соответствие каталог <-> вид метаданных, выведенное из выгрузки.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComponentPath
    )

    $kindByDirectory = @{}
    $directoriesByKind = @{}
    $skippedDirectories = @()
    # 'Ext' хранит модули и настройки уровня конфигурации, а не объекты
    # метаданных, и в ChildObjects не объявляется.
    $ignoredDirectories = @("Ext")
    foreach ($directory in @(Get-ChildItem -LiteralPath $ComponentPath -Directory -ErrorAction SilentlyContinue)) {
        if ($ignoredDirectories -contains $directory.Name) {
            continue
        }
        $candidates = @(
            Get-ChildItem -LiteralPath $directory.FullName -Filter "*.xml" -File -ErrorAction SilentlyContinue |
                Sort-Object Name
        )
        if ($candidates.Count -eq 0) {
            continue
        }

        # Вид метаданных определяется по ПЕРВОМУ файлу, у которого корневой
        # элемент — MetaDataObject. Перебор, а не единственный пробный файл:
        # один посторонний XML (недоразобранный конфликт, чужая выгрузка,
        # временный файл) иначе молча исключил бы весь каталог из проверки и
        # отчёт остался бы успешным.
        $kind = ""
        foreach ($candidate in $candidates) {
            try {
                $reader = [System.Xml.XmlReader]::Create($candidate.FullName)
            }
            catch {
                continue
            }
            try {
                $rootSeen = $false
                while ($reader.Read()) {
                    if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element) {
                        continue
                    }
                    if (-not $rootSeen) {
                        $rootSeen = $true
                        if ($reader.LocalName -ne "MetaDataObject") {
                            break
                        }
                        continue
                    }
                    $kind = $reader.LocalName
                    break
                }
            }
            finally {
                $reader.Dispose()
            }
            if ($kind) {
                break
            }
        }
        if (-not $kind) {
            $skippedDirectories += $directory.Name
            continue
        }

        $kindByDirectory[$directory.Name] = $kind
        # Один вид может лежать в нескольких каталогах: рядом с Catalogs может
        # оказаться Catalogs.bak или Catalogs (copy) после неудачного слияния.
        # Храним все, иначе поиск объявленного файла уходит в неверный каталог.
        if (-not $directoriesByKind.ContainsKey($kind)) {
            $directoriesByKind[$kind] = New-Object System.Collections.ArrayList
        }
        [void]$directoriesByKind[$kind].Add($directory.Name)
    }

    return [pscustomobject]@{
        KindByDirectory = $kindByDirectory
        DirectoriesByKind = $directoriesByKind
        SkippedDirectories = @($skippedDirectories)
    }
}

function Test-ComponentIntegrity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComponentName,

        [Parameter(Mandatory = $true)]
        [string]$ComponentPath
    )

    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $configurationFile = Join-Path $ComponentPath "Configuration.xml"
    if (-not (Test-Path -LiteralPath $configurationFile -PathType Leaf)) {
        [void]$errors.Add("[$ComponentName] Configuration.xml was not found: $configurationFile")
        return [pscustomobject]@{
            component = $ComponentName
            declared = 0
            onDisk = 0
            errors = @($errors)
            warnings = @($warnings)
        }
    }

    # ── 1. Well-formed XML по всей выгрузке ───────────────────────────────────
    $xmlFiles = @(Get-ChildItem -LiteralPath $ComponentPath -Filter "*.xml" -File -Recurse)
    foreach ($xmlFile in $xmlFiles) {
        try {
            $reader = [System.Xml.XmlReader]::Create($xmlFile.FullName)
            try {
                while ($reader.Read()) { }
            }
            finally {
                $reader.Dispose()
            }
        }
        catch {
            $relative = $xmlFile.FullName.Substring($ComponentPath.Length).TrimStart('\', '/')
            [void]$errors.Add("[$ComponentName] Malformed XML in ${relative}: $($_.Exception.Message)")
        }
    }

    # ── 2. Объявления в Configuration.xml ─────────────────────────────────────
    [xml]$configurationXml = Get-Content -Raw -LiteralPath $configurationFile -Encoding UTF8
    $childObjectsNode = $configurationXml.SelectSingleNode(
        '/*[local-name()="MetaDataObject"]/*[local-name()="Configuration"]/*[local-name()="ChildObjects"]'
    )
    if ($null -eq $childObjectsNode) {
        [void]$errors.Add("[$ComponentName] Configuration.xml has no ChildObjects section.")
        return [pscustomobject]@{
            component = $ComponentName
            declared = 0
            onDisk = 0
            errors = @($errors)
            warnings = @($warnings)
        }
    }

    $map = Get-ComponentMetadataMap -ComponentPath $ComponentPath

    # Два каталога одного вида в выгрузке 1С невозможны: платформа выгружает
    # ровно один каталог на вид. Дубль означает копию, оставленную человеком или
    # инструментом (Catalogs.bak, "Catalogs (copy)", недоразобранный конфликт).
    # Сам по себе он не ломает загрузку, но делает результат проверки
    # неоднозначным, поэтому сообщаем о нём всегда.
    foreach ($kindName in @($map.DirectoriesByKind.Keys)) {
        $directories = @($map.DirectoriesByKind[$kindName])
        if ($directories.Count -gt 1) {
            [void]$errors.Add(
                "[$ComponentName] Metadata kind '$kindName' is present in more than one directory: " +
                "$($directories -join ', '). A 1C dump has exactly one directory per kind, so the " +
                "extra one is a leftover copy and makes every other check on this kind ambiguous. " +
                "Delete the copy, then re-run this check."
            )
        }
    }

    $declared = @{}
    $declaredCount = 0
    foreach ($node in @($childObjectsNode.ChildNodes)) {
        if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element) {
            continue
        }
        $kind = $node.LocalName
        $name = ([string]$node.InnerText).Trim()
        if (-not $name) {
            continue
        }
        $declaredCount++
        $key = "$kind|$name"
        if ($declared.ContainsKey($key)) {
            [void]$errors.Add(
                "[$ComponentName] Duplicate declaration in Configuration.xml: $kind.$name. " +
                "Typical result of resolving a merge conflict by keeping both sides."
            )
            continue
        }
        $declared[$key] = $true

        if (-not $map.DirectoriesByKind.ContainsKey($kind)) {
            # Ни один каталог не опознан как каталог этого вида. Причины две:
            # объектов вида действительно нет, либо каталог не удалось разобрать
            # (см. skipped ниже). Сообщаем обе возможности, чтобы не отправлять
            # разработчика искать несуществующий каталог.
            $hint = if (@($map.SkippedDirectories).Count -gt 0) {
                " Unparsed directories that could contain it: $(@($map.SkippedDirectories) -join ', ')."
            }
            else {
                ""
            }
            [void]$errors.Add(
                "[$ComponentName] Configuration.xml declares $kind.$name, but no directory " +
                "for metadata kind '$kind' was recognized in the dump.$hint"
            )
            continue
        }
        # Ищем ТОЛЬКО в основном каталоге вида. Поиск по всем каталогам маскировал
        # реальную потерю: при наличии копии (Catalogs.bak) удалённый из Catalogs
        # объект считался присутствующим, хотя 1С такую конфигурацию не загрузит.
        # Наличие второго каталога вида — отдельная ошибка выше.
        $primaryDirectory = @($map.DirectoriesByKind[$kind])[0]
        $objectXmlPath = Join-Path (Join-Path $ComponentPath $primaryDirectory) "$name.xml"
        if (-not (Test-Path -LiteralPath $objectXmlPath -PathType Leaf)) {
            [void]$errors.Add(
                "[$ComponentName] Configuration.xml declares $kind.$name, but the file is missing: " +
                "$primaryDirectory/$name.xml"
            )
            continue
        }

        # Вложенные объекты объекта: формы, макеты, команды. Уровнем выше проверка
        # доходила только до файла самого объекта, а рукописная форма ломается
        # именно здесь — объявление есть, дескриптора нет.
        foreach ($problem in @(Find-WorkflowChildObjectProblems -ObjectXmlPath $objectXmlPath)) {
            [void]$errors.Add("[$ComponentName] $primaryDirectory/$problem")
        }
    }

    # ── 3. Файлы на диске без объявления ──────────────────────────────────────
    $onDiskCount = 0
    foreach ($directoryName in @($map.KindByDirectory.Keys)) {
        $kind = $map.KindByDirectory[$directoryName]
        $directoryPath = Join-Path $ComponentPath $directoryName
        $files = @(Get-ChildItem -LiteralPath $directoryPath -Filter "*.xml" -File)
        $declaredHere = @(
            $files | Where-Object {
                $declared.ContainsKey("$kind|$([System.IO.Path]::GetFileNameWithoutExtension($_.Name))")
            }
        )
        if ($files.Count -gt 0 -and $declaredHere.Count -eq 0 -and @($map.DirectoriesByKind[$kind]).Count -gt 1) {
            # Каталог того же вида, из которого не объявлен НИ ОДИН объект, при
            # наличии другого каталога этого вида — почти наверняка копия или
            # остаток разбора конфликта (Catalogs.bak, "Catalogs (copy)").
            # Считать каждый его файл потерянным объявлением значит выдать
            # десятки ложных ошибок, поэтому предупреждаем.
            [void]$warnings.Add(
                "[$ComponentName] Directory '$directoryName' holds $($files.Count) '$kind' file(s), " +
                "none of which are declared in Configuration.xml. It looks like a leftover copy " +
                "rather than a metadata directory. Remove it or declare its objects."
            )
            continue
        }
        foreach ($file in $files) {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $onDiskCount++
            if (-not $declared.ContainsKey("$kind|$name")) {
                [void]$errors.Add(
                    "[$ComponentName] $directoryName/$name.xml exists on disk but is NOT declared in " +
                    "Configuration.xml. The object will silently disappear from the configuration. " +
                    "This is the usual outcome of a lost ChildObjects line during a merge."
                )
            }
        }
    }

    # ── 4. Каталоги, вид которых определить не удалось ────────────────────────
    # Это ОШИБКА, а не предупреждение. Неразобранный каталог означает, что для его
    # объектов проверка не выполнялась вовсе, а отчёт при этом был бы успешным —
    # ровно та ложная уверенность, против которой написана вся проверка. Выгрузка
    # 1С состоит только из каталогов метаданных и Ext, поэтому любой другой
    # каталог с XML внутри исходников требует объяснения.
    foreach ($skipped in @($map.SkippedDirectories)) {
        # Если по этому каталогу уже есть ошибка о некорректном XML, второе
        # сообщение об одном и том же файле только запутывает: причина одна.
        $alreadyReported = @(
            $errors | Where-Object { "$_" -match "Malformed XML in $([Regex]::Escape($skipped))[\\/]" }
        ).Count -gt 0
        if ($alreadyReported) {
            continue
        }
        [void]$errors.Add(
            "[$ComponentName] Directory '$skipped' contains XML files but none with a " +
            "MetaDataObject root element, so its contents were NOT checked against " +
            "Configuration.xml. A 1C dump contains only metadata directories and Ext. " +
            "Remove the directory or move it outside the source tree."
        )
    }

    # ── 5. Ссылки подсистем ───────────────────────────────────────────────────
    $subsystemsDirectory = Join-Path $ComponentPath "Subsystems"
    if (Test-Path -LiteralPath $subsystemsDirectory -PathType Container) {
        foreach ($subsystemFile in @(Get-ChildItem -LiteralPath $subsystemsDirectory -Filter "*.xml" -File -Recurse)) {
            [xml]$subsystemXml = Get-Content -Raw -LiteralPath $subsystemFile.FullName -Encoding UTF8
            $contentNodes = @(
                $subsystemXml.SelectNodes(
                    '//*[local-name()="Subsystem"]/*[local-name()="Properties"]/*[local-name()="Content"]/*'
                )
            )
            foreach ($contentNode in $contentNodes) {
                $reference = ([string]$contentNode.InnerText).Trim()
                if (-not $reference -or $reference -notmatch '^([A-Za-z]+)\.(.+)$') {
                    continue
                }
                $referenceKind = $Matches[1]
                $referenceName = $Matches[2]
                if ($referenceName -match '\.') {
                    # Вложенные пути (например Subsystem.A.Subsystem.B) не разбираем.
                    continue
                }
                if (-not $map.DirectoriesByKind.ContainsKey($referenceKind)) {
                    continue
                }
                if (-not $declared.ContainsKey("$referenceKind|$referenceName")) {
                    [void]$warnings.Add(
                        "[$ComponentName] Subsystem $($subsystemFile.BaseName) references " +
                        "$referenceKind.$referenceName, which is not declared in Configuration.xml."
                    )
                }
            }
        }
    }

    return [pscustomobject]@{
        component = $ComponentName
        declared = $declaredCount
        onDisk = $onDiskCount
        errors = @($errors)
        warnings = @($warnings)
    }
}

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
$stateDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.localStateDir)
if (-not $ReportPath) {
    $ReportPath = Join-Path $stateDirectory (
        "reports\source-integrity-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID.json"
    )
}

$allErrors = New-Object System.Collections.ArrayList
$allWarnings = New-Object System.Collections.ArrayList

# ── Маркеры конфликтов слияния во всех отслеживаемых текстовых файлах ─────────
$conflictFiles = New-Object System.Collections.ArrayList
$trackedFiles = @(
    (Invoke-WorkflowGit -RepositoryRoot $repositoryRoot -Arguments @(
        "-c", "core.quotePath=false", "ls-files", "--eol"
    )).Output
)
foreach ($line in $trackedFiles) {
    # Формат: "i/lf    w/crlf  attr/text=auto  <путь>"
    if ($line -notmatch '^i/(lf|crlf|mixed)\s') {
        continue
    }
    $relativePath = ($line -split '\t', 2)[-1].Trim()
    if (-not $relativePath) {
        continue
    }
    $fullPath = Join-Path $repositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        continue
    }
    # Ищем только однозначные маркеры: '=======' встречается в обычных
    # комментариях 1С и сам по себе признаком конфликта не является.
    $match = @(
        Select-String -LiteralPath $fullPath -Pattern '^(<{7}|>{7})\s' -List -ErrorAction SilentlyContinue
    )
    if ($match.Count -gt 0) {
        [void]$conflictFiles.Add($relativePath)
        [void]$allErrors.Add(
            "Unresolved merge conflict markers in $relativePath (line $($match[0].LineNumber))."
        )
    }
}

# ── Целостность основной конфигурации и расширений ────────────────────────────
$componentResults = New-Object System.Collections.ArrayList
$components = @(
    [pscustomobject]@{
        Name = "configuration"
        Path = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.sourceDir)
    }
)
foreach ($extension in @(Get-WorkflowExtensions -RepositoryRoot $repositoryRoot -Config $config -AllowMissingOptional)) {
    $components += [pscustomobject]@{
        Name = [string]$extension.name
        Path = [string]$extension.sourcePath
    }
}
foreach ($component in $components) {
    $result = Test-ComponentIntegrity -ComponentName $component.Name -ComponentPath $component.Path
    [void]$componentResults.Add($result)
    foreach ($message in @($result.errors)) {
        [void]$allErrors.Add($message)
    }
    foreach ($message in @($result.warnings)) {
        [void]$allWarnings.Add($message)
    }
}

$success = ($allErrors.Count -eq 0) -and (-not ($Strict -and $allWarnings.Count -gt 0))
$report = [pscustomobject]@{
    operation = "source-integrity"
    project = [string]$config.project
    branch = Get-WorkflowStandBranchName -RepositoryRoot $repositoryRoot
    commit = Get-WorkflowHeadCommit -RepositoryRoot $repositoryRoot
    success = $success
    strict = [bool]$Strict
    conflictFiles = @($conflictFiles)
    components = @($componentResults)
    errors = @($allErrors)
    warnings = @($allWarnings)
    completedAt = [DateTimeOffset]::Now.ToString("o")
}
Write-WorkflowJson -Value $report -Path $ReportPath | Out-Null

foreach ($component in $componentResults) {
    Write-Host (
        "[{0}] declared={1} onDisk={2} errors={3} warnings={4}" -f `
            $component.component, $component.declared, $component.onDisk,
            @($component.errors).Count, @($component.warnings).Count
    )
}
foreach ($message in $allWarnings) {
    Write-Warning $message
}
Write-Host "Source integrity report: $ReportPath"
if (-not $success) {
    foreach ($message in $allErrors) {
        Write-Host "ERROR: $message"
    }
    $reason = if ($allErrors.Count -gt 0) {
        "$($allErrors.Count) error(s)"
    }
    else {
        "$($allWarnings.Count) warning(s) in -Strict mode"
    }
    throw "Source integrity check failed with ${reason}. Report: $ReportPath"
}
Write-Host "Source integrity check passed."
