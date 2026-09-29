[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$BasePath = "",

    # Корень, в котором эта машина держит базы и стенды. Задаётся один раз:
    # дальше ответ берётся из профиля пользователя. Ключ нужен там, где вопрос
    # задать некому — развёртывание скриптом, CI, запуск из-под агента.
    [string]$BaseRoot = "",
    [string]$Database = "",
    [string]$V8Path = "",
    [string]$OnecLiteUrl = "",
    [string]$BspSourcePath = "",
    [switch]$Reload,
    # Прежнее имя ключа. Означало «удалить каталог базы и создать заново», что для
    # серверной базы невыполнимо. Сохранено как синоним -Reload.
    [switch]$Recreate,
    [switch]$CompileOnly,
    [switch]$ForceAgentConfig,
    [switch]$AdoptResources
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Workflow.Common.ps1")

function Write-WorkflowAgentConfigs {
    <#
    .SYNOPSIS
    Разворачивает персональные конфиги MCP-агентов из общих шаблонов репозитория.

    .DESCRIPTION
    В Git хранятся только шаблоны (.mcp.example.json, .zcode/config.example.json).
    Здесь из них создаются персональные файлы с workspace ИМЕННО этого worktree,
    чтобы агент никогда не работал с чужой рабочей копией. Существующий файл не
    перезаписывается молча: расхождение показывается предупреждением.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$WorkspaceName,

        [Parameter(Mandatory = $true)]
        [string]$OnecLiteUrl,

        [switch]$Force
    )

    if (-not $WorkspaceName) {
        return @()
    }
    $settings = Get-WorkflowParallelSettings -Config $Config
    $results = @()
    foreach ($entry in @($settings.agentConfigTemplates)) {
        $templateRelative = [string](Get-WorkflowSettingValue -Object $entry -Name "template" -Default "")
        $targetRelative = [string](Get-WorkflowSettingValue -Object $entry -Name "target" -Default "")
        if (-not $templateRelative -or -not $targetRelative) {
            continue
        }
        $templatePath = Resolve-WorkflowPath -RepositoryRoot $RepositoryRoot -Path $templateRelative
        $targetPath = Resolve-WorkflowPath -RepositoryRoot $RepositoryRoot -Path $targetRelative
        if (-not (Test-WorkflowPathUnderRoot -Path $targetPath -Root $RepositoryRoot)) {
            throw "Agent config target must stay inside the repository: $targetRelative"
        }
        if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
            Write-Warning "Agent config template is missing and was skipped: $templatePath"
            continue
        }

        $rendered = (Get-Content -Raw -LiteralPath $templatePath -Encoding UTF8).
            Replace('${ONEC_LITE_WORKSPACE}', $WorkspaceName).
            Replace('${ONEC_LITE_URL}', $OnecLiteUrl)
        if ($rendered -match '\$\{[A-Z_]+\}') {
            throw "Agent config template '$templateRelative' still has unresolved placeholders after rendering."
        }

        $exists = Test-Path -LiteralPath $targetPath -PathType Leaf
        if ($exists -and -not $Force) {
            $current = Get-Content -Raw -LiteralPath $targetPath -Encoding UTF8
            if ($current.Replace("`r`n", "`n") -eq $rendered.Replace("`r`n", "`n")) {
                $results += [pscustomobject]@{ path = $targetPath; action = "up-to-date" }
                continue
            }
            Write-Warning (
                "Personal agent config differs from the template for workspace " +
                "'$WorkspaceName' and was left untouched: $targetPath. " +
                "Run Invoke-TaskWorkflow.ps1 -Phase Start -ForceAgentConfig to regenerate it."
            )
            $results += [pscustomobject]@{ path = $targetPath; action = "kept-existing" }
            continue
        }

        [System.IO.Directory]::CreateDirectory((Split-Path $targetPath -Parent)) | Out-Null
        [System.IO.File]::WriteAllText($targetPath, $rendered, [System.Text.UTF8Encoding]::new($false))
        $results += [pscustomobject]@{
            path = $targetPath
            action = if ($exists) { "regenerated" } else { "created" }
        }
    }
    return @($results)
}

function Sync-WorkflowOnecLiteCorpora {
    <#
    .SYNOPSIS
    Регистрирует проектный workspace и его дополнительные корпуса в onec-lite.

    .DESCRIPTION
    Вызывается только когда проект явно включил platformDocs или bspSources. Старый
    onec-lite без машинного endpoint не принимается молча: иначе Start завершился бы
    успешно, а агент искал бы без обещанной документации или в глобальном чужом корпусе.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Config,
        [Parameter(Mandatory = $true)][string]$OnecLiteUrl,
        [Parameter(Mandatory = $true)][string]$WorkspaceName,
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Extensions,
        [Parameter(Mandatory = $true)][object]$Corpora
    )

    if ([string]$Config.onecLite.transport -ne "http") {
        throw "Project corpora require onecLite.transport=http: a shared workspace must own their indexes."
    }
    $mcpUrl = $OnecLiteUrl
    if (-not $mcpUrl) {
        throw "onecLite.url is required when project corpora are enabled."
    }
    $adminUrl = $mcpUrl -replace '/mcp/?$', '/admin/workspace'
    if ($adminUrl -eq $mcpUrl) {
        throw "onecLite.url must end with /mcp when project corpora are enabled: $mcpUrl"
    }

    $help = @()
    foreach ($path in @($Corpora.platformDocsPaths)) {
        $help += [ordered]@{ version = [string]$Config.platformVersion; path = [string]$path }
    }
    $payload = [ordered]@{
        name = $WorkspaceName
        root = $SourceDirectory
        ext_roots = @($Extensions | ForEach-Object { [string]$_.sourcePath })
        platform_help = $help
        bsp_roots = @($Corpora.bspSourcePaths)
        build = $false
    }
    try {
        return Invoke-RestMethod `
            -Method Post `
            -Uri $adminUrl `
            -ContentType "application/json; charset=utf-8" `
            -Body ($payload | ConvertTo-Json -Depth 8) `
            -TimeoutSec 30
    }
    catch {
        throw (
            "Не удалось настроить проектные корпуса onec-lite для workspace '$WorkspaceName' " +
            "через $adminUrl. Нужен запущенный onec-lite с включённой админкой и поддержкой " +
            "POST /admin/workspace. Установка: uv tool install --from " +
            "'git+https://github.com/Ailirag/onec-vecgraph.git' onec-vecgraph; " +
            "запуск для стандартного URL комплекта: onec-lite admin --port 18010. " +
            "Ошибка подключения: $($_.Exception.Message)"
        )
    }
}

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
$branchName = Get-WorkflowBranchName -RepositoryRoot $repositoryRoot

# Первая подготовка рабочего места на новой машине: где держать базы, знает
# только человек за ней. Вопрос задаётся здесь и только здесь — дальше ответ
# лежит в профиле пользователя и в репозиторий не попадает.
$machineRoots = Resolve-WorkflowBaseRoots -Config $config -Explicit $BaseRoot
if ($BaseRoot) {
    $baseRootProblem = Test-WorkflowBaseRootProblem -RepositoryRoot $repositoryRoot -BaseRoot $BaseRoot
    if ($baseRootProblem) {
        throw "Ключ -BaseRoot не годится: $baseRootProblem"
    }
    $savedPath = Save-WorkflowMachineBaseRoot -Config $config -BaseRoot $BaseRoot
    Write-Host "Корень баз этой машины записан: $([System.IO.Path]::GetFullPath($BaseRoot)) ($savedPath)"
}
elseif (-not $machineRoots.DevRoot) {
    if (-not (Test-WorkflowInteractiveHost)) {
        Assert-WorkflowBaseRoot -Root ""
    }
    $answer = Request-WorkflowBaseRoot -RepositoryRoot $repositoryRoot -Config $config
    $savedPath = Save-WorkflowMachineBaseRoot -Config $config -BaseRoot $answer
    Write-Host "Корень баз этой машины записан: $answer ($savedPath)"
}
else {
    Write-Host "Корень баз: $($machineRoots.DevRoot) [$($machineRoots.Source)]"
}
if (-not $branchName) {
    throw "Developer initialization requires a named Git branch."
}

$infoBase = Resolve-WorkflowInfoBase `
    -RepositoryRoot $repositoryRoot `
    -Config $config `
    -BranchName $branchName `
    -Database $Database `
    -ExplicitPath $BasePath
$isFileBase = [string]$infoBase.Kind -ne "server"
$baseFullPath = if ($isFileBase) { [System.IO.Path]::GetFullPath([string]$infoBase.Path) } else { "" }
if ($isFileBase) {
    $pathRoot = [System.IO.Path]::GetPathRoot($baseFullPath)
    if ($baseFullPath.TrimEnd('\') -eq $pathRoot.TrimEnd('\')) {
        throw "Refusing to use a filesystem root as an information base path: $baseFullPath"
    }
}
$reloadRequested = [bool]$Reload -or [bool]$Recreate

$sourceDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.sourceDir)
$extensions = @(Get-WorkflowExtensions -RepositoryRoot $repositoryRoot -Config $config -AllowMissingOptional)
$v8Executable = Resolve-WorkflowV8Path -Config $config -V8Path $V8Path
$onecLiteEnabled = (
    $null -ne $config.PSObject.Properties["onecLite"] -and
    $null -ne $config.onecLite -and
    (
        $null -eq $config.onecLite.PSObject.Properties["enabled"] -or
        [bool]$config.onecLite.enabled
    )
)
$resolvedOnecLiteUrl = if ($onecLiteEnabled) {
    Resolve-WorkflowOnecLiteUrl -Config $config -Explicit $OnecLiteUrl
}
else {
    ""
}
if (-not $WhatIfPreference) {
    $machineSettingsPath = Save-WorkflowMachinePlatformPath `
        -Version ([string]$config.platformVersion) `
        -V8Path $v8Executable
    Write-Host "Платформа $($config.platformVersion): $v8Executable ($machineSettingsPath)"
    if ($onecLiteEnabled) {
        $machineSettingsPath = Save-WorkflowMachineOnecLiteUrl -Url $resolvedOnecLiteUrl
        Write-Host "onec-lite endpoint: $resolvedOnecLiteUrl ($machineSettingsPath)"
    }
}
$ccRoot = Resolve-Cc1CSkillsRoot -Config $config
$statePath = Get-WorkflowStatePath -RepositoryRoot $repositoryRoot -Config $config
$logDirectory = Join-Path (Split-Path $statePath -Parent) "logs"

# Проект объявляет версию БСП, но физический каталог принадлежит машине. Явный
# ключ и env нужны CI/агенту; живого разработчика спрашиваем один раз и сохраняем
# соответствие версии пути в machine.json.
$bspSection = Get-WorkflowSettingValue -Object $config.onecLite -Name "bspSources" -Default $null
$bspEnabled = (
    $null -ne $bspSection -and
    [bool](Get-WorkflowSettingValue -Object $bspSection -Name "enabled" -Default $false)
)
$resolvedBspSourcePath = ""
if ($bspEnabled) {
    $bspVersion = [string](Get-WorkflowSettingValue -Object $bspSection -Name "version" -Default "")
    if (-not $bspVersion) {
        throw "onecLite.bspSources.enabled is true, but version is empty in .1c-workflow.json."
    }
    $resolvedBspSourcePath = if ($BspSourcePath) {
        $BspSourcePath
    }
    elseif ([string]$env:ONEC_WORKFLOW_BSP_SOURCE_ROOT) {
        [string]$env:ONEC_WORKFLOW_BSP_SOURCE_ROOT
    }
    else {
        Get-WorkflowMachineBspSourcePath -Version $bspVersion
    }
    $bspProblem = Test-WorkflowBspSourcePathProblem -SourcePath $resolvedBspSourcePath
    if ($bspProblem) {
        if (-not (Test-WorkflowInteractiveHost)) {
            throw (
                "Для БСП $bspVersion не настроен локальный каталог ($bspProblem). " +
                "Передайте -BspSourcePath <путь> или задайте ONEC_WORKFLOW_BSP_SOURCE_ROOT."
            )
        }
        $resolvedBspSourcePath = Request-WorkflowBspSourcePath -Version $bspVersion
    }
    $machineSettingsPath = Save-WorkflowMachineBspSourcePath `
        -Version $bspVersion `
        -SourcePath $resolvedBspSourcePath
    Write-Host "Исходники БСП ${bspVersion}: $resolvedBspSourcePath ($machineSettingsPath)"
}

# База закрепляется за этой рабочей копией ДО любых разрушительных действий.
# Путь файловой базы выводится из слага ветки, а слаг не взаимно однозначен:
# `feature/AB-1` и `feature-AB-1` дают один путь, отдельные клоны с одинаковой
# веткой — тоже. Серверная база вдобавок называется в реестре явно, и указать
# одну и ту же из двух рабочих копий ещё проще. Без этой проверки два агента
# работали бы в одной базе, молча уничтожая работу друг друга.
$sourceStamp = Get-WorkflowSourceStamp -RepositoryRoot $repositoryRoot -Config $config
$baseDecision = Get-WorkflowInfoBaseReloadReason `
    -InfoBase $infoBase `
    -RepositoryRoot $repositoryRoot `
    -Config $config `
    -BranchName $branchName `
    -WorktreePath $repositoryRoot `
    -SourceStamp $sourceStamp `
    -RequireDatabaseUpdate:(-not $CompileOnly)

if ($baseDecision.Conflict -and -not $AdoptResources) {
    throw (
        "The task information base '$($infoBase.Display)' is taken: $($baseDecision.Reason). " +
        "Continuing would destroy the other working copy's state. Fix it in one of these ways: " +
        "use a branch name whose slug differs, pass an explicit -BasePath or -Database, or re-run " +
        "with -AdoptResources to take the base over."
    )
}

# Перезаливка файловой базы — это пересоздание: каталог удаляется целиком.
# Серверная база НЕ удаляется никогда: она заведена в кластере, её могли выдать
# аналитику или разработчику насовсем, и восстановить её удалением каталога
# невозможно. Для неё перезаливка означает повторную загрузку исходников.
if ($reloadRequested -and $isFileBase -and (Test-Path -LiteralPath $baseFullPath)) {
    $marker = Join-Path $baseFullPath "1Cv8.1CD"
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        throw "Refusing to recreate a directory that is not a file information base: $baseFullPath"
    }
    if ($PSCmdlet.ShouldProcess($baseFullPath, "Remove the branch-specific file information base")) {
        Remove-Item -LiteralPath $baseFullPath -Recurse -Force
    }
}

$baseCreated = $false
if ($isFileBase -and -not (Test-Path -LiteralPath (Join-Path $baseFullPath "1Cv8.1CD") -PathType Leaf)) {
    $createScript = Resolve-CcSkillScript `
        -Cc1CSkillsRoot $ccRoot `
        -SkillName "db-create" `
        -ScriptName "db-create.ps1"

    if ($PSCmdlet.ShouldProcess($baseFullPath, "Create a branch-specific file information base")) {
        Invoke-WorkflowPowerShell `
            -ScriptPath $createScript `
            -Arguments @("-V8Path", $v8Executable, "-InfoBasePath", $baseFullPath) `
            -LogPath (Join-Path $logDirectory "initialize-create.log") | Out-Null
        $baseCreated = $true
    }
}

# Пустая база исходников не содержит, сколько бы ни совпадали отметки.
$loadRequired = $reloadRequested -or $baseCreated -or $baseDecision.Reload

$loadScript = Resolve-CcSkillScript `
    -Cc1CSkillsRoot $ccRoot `
    -SkillName "db-load-xml" `
    -ScriptName "db-load-xml.ps1"
$loadArguments = @("-V8Path", $v8Executable) +
    (Get-WorkflowInfoBaseSkillArguments -InfoBase $infoBase) +
    @("-ConfigDir", $sourceDirectory, "-Mode", "Full")
if (-not $CompileOnly) {
    $loadArguments += "-UpdateDB"
}

if (-not $loadRequired) {
    Write-Host "Load skipped: the infobase already holds these sources ($($infoBase.Display))."
}
elseif ($PSCmdlet.ShouldProcess($infoBase.Display, "Load the complete Git configuration")) {
    Invoke-WorkflowPowerShell `
        -ScriptPath $loadScript `
        -Arguments $loadArguments `
        -LogPath (Join-Path $logDirectory "initialize-load.log") | Out-Null
}

if ($loadRequired) {
    foreach ($extension in $extensions) {
        if ($PSCmdlet.ShouldProcess($infoBase.Display, "Load extension '$($extension.name)' from Git")) {
            Invoke-WorkflowLoadExtension `
                -Cc1CSkillsRoot $ccRoot `
                -V8Executable $v8Executable `
                -InfoBase $infoBase `
                -Extension $extension `
                -UpdateDB:(-not $CompileOnly) `
                -LogPath (Join-Path $logDirectory "initialize-extension-$($extension.name).log") | Out-Null
        }
    }
    if (-not $CompileOnly -and $extensions.Count -gt 0 -and $PSCmdlet.ShouldProcess($infoBase.Display, "Check extension applicability")) {
        Invoke-WorkflowCheckExtensions `
            -V8Executable $v8Executable `
            -InfoBase $infoBase `
            -Extensions $extensions `
            -LogPath (Join-Path $logDirectory "initialize-extensions-applicability.log") | Out-Null
    }
}

if ($WhatIfPreference) {
    Write-Host "WhatIf completed. No local state or client configuration was written."
    return
}

$headCommit = (
    Invoke-WorkflowGit -RepositoryRoot $repositoryRoot -Arguments @("rev-parse", "HEAD")
).Output | Select-Object -First 1

if ($loadRequired) {
    Set-WorkflowInfoBaseState `
        -InfoBase $infoBase `
        -Config $config `
        -BranchName $branchName `
        -WorktreePath $repositoryRoot `
        -Commit ([string]$headCommit) `
        -SourceStamp $sourceStamp `
        -CompileOnly:$CompileOnly | Out-Null
}
$branchSlug = ConvertTo-WorkflowSlug -Value $branchName
$workspaceName = if ($onecLiteEnabled) {
    "$($config.onecLite.workspacePrefix)_$branchSlug"
}
else {
    ""
}
$onecLiteCorpora = Get-WorkflowOnecLiteCorpusSettings `
    -RepositoryRoot $repositoryRoot `
    -Config $config `
    -V8Executable $v8Executable `
    -BspSourcePath $resolvedBspSourcePath
$previousWorkflowState = Read-WorkflowState -RepositoryRoot $repositoryRoot -Config $config
$corporaRequested = (
    [bool]$onecLiteCorpora.platformDocsEnabled -or [bool]$onecLiteCorpora.bspSourcesEnabled
)
$corporaPreviouslyManaged = (
    $null -ne $previousWorkflowState -and
    [bool](Get-WorkflowSettingValue `
        -Object $previousWorkflowState `
        -Name "onecLiteCorporaConfigured" `
        -Default $false)
)
if ($onecLiteEnabled -and $workspaceName -and ($corporaRequested -or $corporaPreviouslyManaged)) {
    $syncResult = Sync-WorkflowOnecLiteCorpora `
        -Config $config `
        -OnecLiteUrl $resolvedOnecLiteUrl `
        -WorkspaceName $workspaceName `
        -SourceDirectory $sourceDirectory `
        -Extensions $extensions `
        -Corpora $onecLiteCorpora
    Write-Host (
        "onec-lite corpora: platformDocs=$($onecLiteCorpora.platformDocsPaths.Count), " +
        "bspSources=$($onecLiteCorpora.bspSourcePaths.Count) " +
        $(if ($corporaRequested) { "(индексация запущена)" } else { "(корпуса отключены)" })
    )
}
$state = [pscustomobject]@{
    project = [string]$config.project
    branch = $branchName
    basePath = $baseFullPath
    infoBase = [pscustomobject]@{
        kind = [string]$infoBase.Kind
        display = [string]$infoBase.Display
        id = [string]$infoBase.Id
        source = [string]$infoBase.Source
    }
    loadedCommit = [string]$headCommit
    compileOnly = [bool]$CompileOnly
    loadedExtensions = @($extensions | Select-Object -ExpandProperty name)
    onecLiteWorkspace = $workspaceName
    onecLiteCorporaConfigured = $corporaRequested
    updatedAt = [DateTimeOffset]::Now.ToString("o")
}
Write-WorkflowState -RepositoryRoot $repositoryRoot -Config $config -State $state | Out-Null

$v8ProjectPath = Join-Path $repositoryRoot ".v8-project.json"
if ($isFileBase -and -not (Test-Path -LiteralPath $v8ProjectPath -PathType Leaf)) {
    $localRegistry = [pscustomobject]@{
        v8path = Split-Path $v8Executable -Parent
        databases = @(
            [pscustomobject]@{
                id = "dev"
                name = "$($config.project) - $branchName"
                type = "file"
                path = $baseFullPath
                user = ""
                password = ""
                aliases = @("dev", $branchSlug)
                branches = @($branchName)
                configSrc = $sourceDirectory
                extensionSources = @(
                    $extensions | ForEach-Object {
                        [pscustomobject]@{
                            name = [string]$_.name
                            path = [string]$_.sourcePath
                        }
                    }
                )
            }
        )
        default = "dev"
    }
    Write-WorkflowJson -Value $localRegistry -Path $v8ProjectPath | Out-Null
}

$onecClientPath = ""
if ($onecLiteEnabled) {
    $onecClientPath = Join-Path (Split-Path $statePath -Parent) "onec-lite-client.json"
    $onecClient = [pscustomobject]@{
        type = [string]$config.onecLite.transport
        url = $resolvedOnecLiteUrl
        headers = [pscustomobject]@{
            "X-Workspace" = $workspaceName
        }
    }
    Write-WorkflowJson -Value $onecClient -Path $onecClientPath | Out-Null
}

$agentConfigs = @(
    Write-WorkflowAgentConfigs `
        -RepositoryRoot $repositoryRoot `
        -Config $config `
        -WorkspaceName $workspaceName `
        -OnecLiteUrl $resolvedOnecLiteUrl `
        -Force:$ForceAgentConfig
)

Write-Host "Developer workspace initialized."
Write-Host "Branch: $branchName"
Write-Host "Base: $($infoBase.Display) [$($infoBase.Kind), $($infoBase.Source)]"
Write-Host "Local state: $statePath"
if ($extensions.Count -gt 0) {
    Write-Host "Extensions: $($extensions.name -join ', ')"
}
if ($onecLiteEnabled) {
    Write-Host "onec-lite workspace: $workspaceName"
    Write-Host "onec-lite URL:       $resolvedOnecLiteUrl"
    Write-Host "onec-lite client snippet: $onecClientPath"
}
else {
    Write-Host "onec-lite integration is disabled for this project."
}
foreach ($agentConfig in $agentConfigs) {
    Write-Host "Agent config [$($agentConfig.action)]: $($agentConfig.path)"
}

$parallelSettings = Get-WorkflowParallelSettings -Config $config
if ($parallelSettings.perBranchStands) {
    Write-Host "Functional stand:  $(Get-WorkflowStandBasePath -Config $config -BranchName $branchName -Kind 'functional')"
    Write-Host "Web UI stand:      $(Get-WorkflowStandBasePath -Config $config -BranchName $branchName -Kind 'functional-ui')"
    Write-Host "Reserved ports:    web-ui $(Get-WorkflowStandPort -Config $config -BranchName $branchName -Kind 'web-ui'), http $(Get-WorkflowStandPort -Config $config -BranchName $branchName -Kind 'http')"
}
