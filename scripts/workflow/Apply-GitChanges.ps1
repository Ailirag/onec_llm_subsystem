[CmdletBinding()]
param(
    [string]$BasePath = "",
    [string]$Database = "",
    [string]$V8Path = "",
    [switch]$CompileOnly,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Workflow.Common.ps1")

$repositoryRoot = Get-WorkflowRepositoryRoot -StartPath $PSScriptRoot
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
$state = Read-WorkflowState -RepositoryRoot $repositoryRoot -Config $config
if ($null -eq $state) {
    throw "Local workflow state is missing. Run Initialize-Developer.ps1 first."
}

$branchName = Get-WorkflowBranchName -RepositoryRoot $repositoryRoot
if ([string]$state.branch -ne $branchName) {
    throw "The local database belongs to branch '$($state.branch)', but the current branch is '$branchName'."
}

$infoBase = Resolve-WorkflowInfoBase `
    -RepositoryRoot $repositoryRoot `
    -Config $config `
    -BranchName $branchName `
    -Database $Database `
    -ExplicitPath $BasePath `
    -FallbackPath ([string]$state.basePath)
$isFileBase = [string]$infoBase.Kind -ne "server"
$baseFullPath = if ($isFileBase) { [System.IO.Path]::GetFullPath([string]$infoBase.Path) } else { "" }
$infoBaseArguments = @(Get-WorkflowInfoBaseSkillArguments -InfoBase $infoBase)
# Существование проверяется только у файловой базы: у серверной ответ знает
# кластер, и подменять его проверкой пути значило бы отказывать по ложной причине.
if ($isFileBase -and -not (Test-Path -LiteralPath (Join-Path $baseFullPath "1Cv8.1CD") -PathType Leaf)) {
    throw "Branch-specific information base was not found: $baseFullPath"
}

$sourceDirectory = Resolve-WorkflowPath -RepositoryRoot $repositoryRoot -Path ([string]$config.sourceDir)
$extensions = @(Get-WorkflowExtensions -RepositoryRoot $repositoryRoot -Config $config -AllowMissingOptional)
$v8Executable = Resolve-WorkflowV8Path -Config $config -V8Path $V8Path
$ccRoot = Resolve-Cc1CSkillsRoot -Config $config
$statePath = Get-WorkflowStatePath -RepositoryRoot $repositoryRoot -Config $config
$logDirectory = Join-Path (Split-Path $statePath -Parent) "logs"
$headCommit = [string](
    (Invoke-WorkflowGit -RepositoryRoot $repositoryRoot -Arguments @("rev-parse", "HEAD")).Output |
        Select-Object -First 1
)
# Точка отсчёта для инкрементальной загрузки принадлежит БАЗЕ, а не рабочей копии.
# Пока база была одна, разницы не было. Как только их стало несколько (своя база
# разработчика, стенд Web UI, серверная база аналитика), общий loadedCommit стал
# отвечать за чужое состояние: в стенд поехал бы диапазон, посчитанный от коммита,
# который загружали в другую базу. Такая ошибка не падает — часть правок просто не
# доезжает, а прогон идёт по конфигурации, которой нет ни в одном коммите.
$infoBaseState = Get-WorkflowInfoBaseState -InfoBase $infoBase
$loadedCommit = if ($null -ne $infoBaseState -and [string]$infoBaseState.commit) {
    [string]$infoBaseState.commit
}
else {
    [string]$state.loadedCommit
}
$commitRange = if ($loadedCommit -and $loadedCommit -ne $headCommit) {
    "$loadedCommit..$headCommit"
}
else {
    ""
}

$mainChanges = @(
    Get-WorkflowGitChanges `
        -RepositoryRoot $repositoryRoot `
        -SourceDir ([string]$config.sourceDir) `
        -CommitRange $commitRange `
        -IncludeWorkingTree
)
$fullLoadRequired = $false
$fullLoadReasons = @()
foreach ($change in $mainChanges) {
    if ($change.Status -match '^[DR]') {
        $fullLoadRequired = $true
        $fullLoadReasons += "Git change '$($change.Raw)' cannot be applied safely with partial loading."
    }
    if (($change.Paths -join " ") -match 'ParentConfigurations\.bin$') {
        $fullLoadRequired = $true
        $fullLoadReasons += "Support-state changes require a full configuration load."
    }
}

Write-Host "Detected main configuration changes: $($mainChanges.Count)"
foreach ($change in $mainChanges) {
    Write-Host "  $($change.Raw)"
}
if ($fullLoadRequired) {
    Write-Host "Full load is required:"
    $fullLoadReasons | Select-Object -Unique | ForEach-Object { Write-Host "  $_" }
}

$extensionChanges = @{}
$extensionChangeCount = 0
foreach ($extension in $extensions) {
    $extensionChanges[[string]$extension.name] = @(
        Get-WorkflowGitChanges `
            -RepositoryRoot $repositoryRoot `
            -SourceDir ([string]$extension.sourceDir) `
            -CommitRange $commitRange `
            -IncludeWorkingTree
    )
    $extensionChangeCount += $extensionChanges[[string]$extension.name].Count
    Write-Host "Detected extension '$($extension.name)' changes: $($extensionChanges[[string]$extension.name].Count)"
    foreach ($change in @($extensionChanges[[string]$extension.name])) {
        Write-Host "  $($change.Raw)"
    }
}
$previousExtensionNames = if ($null -ne $state.PSObject.Properties["loadedExtensions"]) {
    @($state.loadedExtensions | ForEach-Object { [string]$_ })
}
else {
    @()
}
$currentExtensionNames = @($extensions | Select-Object -ExpandProperty name)
$removedExtensions = @(
    $previousExtensionNames |
        Where-Object { $currentExtensionNames -notcontains $_ }
)
foreach ($removedExtension in $removedExtensions) {
    Write-Host "Extension removed from manifest: $removedExtension"
}

if ($CompileOnly -and $removedExtensions.Count -gt 0 -and -not $DryRun) {
    throw "Removed extensions cannot be applied safely in CompileOnly mode. Run a full apply or restore the manifest entry."
}

if ($DryRun) {
    return
}

if (
    $mainChanges.Count -eq 0 -and
    $extensionChangeCount -eq 0 -and
    $removedExtensions.Count -eq 0
) {
    Write-Host "No configuration or extension changes need to be loaded."
    return
}

if ($mainChanges.Count -gt 0 -and $fullLoadRequired) {
    $loadScript = Resolve-CcSkillScript `
        -Cc1CSkillsRoot $ccRoot `
        -SkillName "db-load-xml" `
        -ScriptName "db-load-xml.ps1"
    $arguments = @("-V8Path", $v8Executable) + $infoBaseArguments + @(
        "-ConfigDir", $sourceDirectory,
        "-Mode", "Full"
    )
    if (-not $CompileOnly) {
        $arguments += "-UpdateDB"
    }
    Invoke-WorkflowPowerShell `
        -ScriptPath $loadScript `
        -Arguments $arguments `
        -LogPath (Join-Path $logDirectory "apply-full.log") | Out-Null
}
elseif ($mainChanges.Count -gt 0) {
    $loadGitScript = Resolve-CcSkillScript `
        -Cc1CSkillsRoot $ccRoot `
        -SkillName "db-load-git" `
        -ScriptName "db-load-git.ps1"

    if ($commitRange) {
        $arguments = @("-V8Path", $v8Executable) + $infoBaseArguments + @(
            "-ConfigDir", $sourceDirectory,
            "-Source", "Commit",
            "-CommitRange", $commitRange
        )
        if (-not $CompileOnly) {
            $arguments += "-UpdateDB"
        }
        Invoke-WorkflowPowerShell `
            -ScriptPath $loadGitScript `
            -Arguments $arguments `
            -LogPath (Join-Path $logDirectory "apply-commits.log") | Out-Null
    }

    $workingChanges = @(
        Get-WorkflowGitChanges `
            -RepositoryRoot $repositoryRoot `
            -SourceDir ([string]$config.sourceDir) `
            -IncludeWorkingTree
    )
    if ($workingChanges.Count -gt 0) {
        $arguments = @("-V8Path", $v8Executable) + $infoBaseArguments + @(
            "-ConfigDir", $sourceDirectory,
            "-Source", "All"
        )
        if (-not $CompileOnly) {
            $arguments += "-UpdateDB"
        }
        Invoke-WorkflowPowerShell `
            -ScriptPath $loadGitScript `
            -Arguments $arguments `
            -LogPath (Join-Path $logDirectory "apply-working-tree.log") | Out-Null
    }
}

$extensionMutation = $false
foreach ($extension in $extensions) {
    $changesForExtension = @($extensionChanges[[string]$extension.name])
    if ($changesForExtension.Count -eq 0) {
        continue
    }
    $extensionMutation = $true
    Invoke-WorkflowLoadExtension `
        -Cc1CSkillsRoot $ccRoot `
        -V8Executable $v8Executable `
        -InfoBase $infoBase `
        -Extension $extension `
        -UpdateDB:(-not $CompileOnly) `
        -LogPath (Join-Path $logDirectory "apply-extension-$($extension.name).log") | Out-Null
}
foreach ($removedExtension in $removedExtensions) {
    $extensionMutation = $true
    Invoke-WorkflowDeleteExtension `
        -V8Executable $v8Executable `
        -InfoBase $infoBase `
        -ExtensionName $removedExtension `
        -LogPath (Join-Path $logDirectory "apply-extension-delete-$removedExtension.log") | Out-Null
}
if (($mainChanges.Count -gt 0 -or $extensionMutation) -and -not $CompileOnly -and $extensions.Count -gt 0) {
    Invoke-WorkflowCheckExtensions `
        -V8Executable $v8Executable `
        -InfoBase $infoBase `
        -Extensions $extensions `
        -LogPath (Join-Path $logDirectory "apply-extensions-applicability.log") | Out-Null
}

$dirtyStatus = (
    Invoke-WorkflowGit -RepositoryRoot $repositoryRoot -Arguments @("status", "--porcelain")
).Output

Set-WorkflowInfoBaseState `
    -InfoBase $infoBase `
    -Config $config `
    -BranchName $branchName `
    -WorktreePath $repositoryRoot `
    -Commit $headCommit `
    -SourceStamp (Get-WorkflowSourceStamp -RepositoryRoot $repositoryRoot -Config $config) `
    -CompileOnly:$CompileOnly | Out-Null

# Общее состояние рабочей копии описывает ОДНУ базу — ту, что подняли на Start.
# Загрузка в другую базу (стенд, запасную) его не касается: перезаписав его, мы
# сообщили бы фазам, что база задачи содержит коммит, которого она не видела.
$stateInfoBaseId = if (
    $null -ne $state.PSObject.Properties["infoBase"] -and
    $null -ne $state.infoBase -and
    $null -ne $state.infoBase.PSObject.Properties["id"]
) {
    [string]$state.infoBase.id
}
else {
    ""
}
$describesSameBase = if ($stateInfoBaseId) {
    $stateInfoBaseId -eq [string]$infoBase.Id
}
else {
    # Состояние старого образца идентификатора не несёт: сверяем по пути, как и
    # писалось раньше. Для серверной базы такого совпадения быть не может.
    $isFileBase -and [string]$state.basePath -and (
        [System.IO.Path]::GetFullPath([string]$state.basePath) -eq $baseFullPath
    )
}

if ($describesSameBase) {
    $newState = [pscustomobject]@{
        project = [string]$config.project
        branch = $branchName
        basePath = $baseFullPath
        infoBase = [pscustomobject]@{
            kind = [string]$infoBase.Kind
            display = [string]$infoBase.Display
            id = [string]$infoBase.Id
            source = [string]$infoBase.Source
        }
        loadedCommit = $headCommit
        loadedWithWorkingTree = [bool]($dirtyStatus.Count -gt 0)
        compileOnly = [bool]$CompileOnly
        loadedExtensions = @($currentExtensionNames)
        onecLiteWorkspace = [string]$state.onecLiteWorkspace
        updatedAt = [DateTimeOffset]::Now.ToString("o")
    }
    Write-WorkflowState -RepositoryRoot $repositoryRoot -Config $config -State $newState | Out-Null
}
else {
    Write-Host "Workflow state was left untouched: it describes another infobase."
}
Write-Host "Git component changes were applied to $($infoBase.Display)"
