[CmdletBinding()]
param(
    [string]$BasePath = "",

    # Имя или псевдоним базы из .v8-project.json. Позволяет опубликовать стенд,
    # который живёт в кластере, а не файлом в testBaseRoot.
    [string]$Database = "",

    [string]$V8Path = "",
    [string]$ApachePath = "",
    [string]$AppName = "",
    [int]$Port = 0,
    [string]$UserName = "",
    [string]$Password = "",
    [switch]$SkipLock
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repositoryRoot "scripts\workflow\Workflow.Common.ps1")
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot
$ccRoot = Resolve-Cc1CSkillsRoot -Config $config
$v8Executable = Resolve-WorkflowV8Path -Config $config -V8Path $V8Path

# Это публикатор ИМЕННО Web UI стенда (на него ссылается webUiTests.publishScript),
# поэтому все три ресурса берутся согласованно из одного вида стенда. Раньше здесь
# смешивались функциональная база, имя приложения Web UI и порт HTTP-стенда — при
# прямом запуске это гарантированно конфликтовало с HTTP-публикацией той же ветки.
$standBranch = Get-WorkflowStandBranchName -RepositoryRoot $repositoryRoot
if (-not $BasePath) {
    $BasePath = Get-WorkflowStandBasePath `
        -Config $config `
        -BranchName $standBranch `
        -Kind "functional-ui"
}
if (-not $AppName) {
    $AppName = Get-WorkflowStandAppName `
        -Config $config `
        -BranchName $standBranch `
        -DefaultAppName ([string]$config.webUiTests.defaultAppName)
}
if ($Port -eq 0) {
    $Port = Get-WorkflowStandPort `
        -Config $config `
        -BranchName $standBranch `
        -Kind "web-ui" `
        -FallbackPort ([int]$config.webUiTests.defaultPort)
}
$standInfoBase = if ($Database) {
    Resolve-WorkflowInfoBase `
        -RepositoryRoot $repositoryRoot `
        -Config $config `
        -BranchName $standBranch `
        -Database $Database
}
else {
    # Файловый стенд публикуется под администратором стенда: без учётных данных
    # публикация на базе с пользователями поднимается, а вход в неё отказан.
    ConvertTo-WorkflowStandInfoBase -BasePath ([System.IO.Path]::GetFullPath($BasePath))
}
if ($UserName) {
    $standInfoBase.UserName = $UserName
    $standInfoBase.Password = $Password
    $standInfoBase.Source = "web-ui-role-test"
}
# Наличие проверяется только у файлового стенда: серверный отвечает кластер.
if ([string]$standInfoBase.Kind -ne "server" -and -not (Test-Path -LiteralPath (Join-Path $BasePath "1Cv8.1CD"))) {
    throw "Functional test base does not exist. Initialize the test stand first."
}
if (-not $Database) {
    $administratorOutcome = Initialize-WorkflowStandAdministrator -BasePath ([System.IO.Path]::GetFullPath($BasePath))
    Write-Host "Администратор стенда: $administratorOutcome"
}

$publishScript = Resolve-CcSkillScript `
    -Cc1CSkillsRoot $ccRoot `
    -SkillName "web-publish" `
    -ScriptName "web-publish.ps1"
if (-not $ApachePath) {
    $ApachePath = Resolve-WorkflowPath `
        -RepositoryRoot $repositoryRoot `
        -Path ".build\workflow\http-apache"
}

$publishAction = {
    # Строка подключения в vrd берётся из описателя: для серверной базы это
    # Srvr/Ref, и подставить вместо неё путь нельзя — публикация поднимется, а
    # обращение к ней будет отказано на несуществующем файле.
    $publishArguments = @("-V8Path", $v8Executable) +
        (Get-WorkflowInfoBaseSkillArguments -InfoBase $standInfoBase) +
        @("-AppName", $AppName, "-ApachePath", $ApachePath, "-Port", $Port)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publishScript @publishArguments
    if ($LASTEXITCODE -ne 0) {
        throw "cc-1c-skills web-publish failed with exit code $LASTEXITCODE."
    }
    # web-publish публикует HTTP-сервисы только основной конфигурации: сервисы
    # РАСШИРЕНИЙ — проекта и исполнителя кода стенда — отвечали бы 404
    # (docs/known-issues.md комплекта, п. 12). Атрибут дописывается после навыка,
    # и Apache перезапускается: модуль 1С читает default.vrd при запуске.
    $vrdPath = Join-Path $ApachePath "publish\$AppName\default.vrd"
    if (Set-WorkflowVrdExtensionServices -VrdPath $vrdPath) {
        Restart-WorkflowApache -ApachePath $ApachePath
    }
    if (Test-WorkflowStandExecEnabled -Config $config) {
        Write-Host "Исполнитель кода стенда: http://localhost:$Port/$AppName/hs/stand-exec"
    }
}

# -SkipLock передаёт вызывающий скрипт, который уже держит блокировку
# 'stand-publish' (иначе процесс заблокировал бы сам себя).
if ($SkipLock) {
    & $publishAction
}
else {
    Invoke-WithWorkflowLock -Config $config -Name "stand-publish" -Action $publishAction
}

Write-Host ""
Write-Host "[OK] Web test publication:"
Write-Host "     http://localhost:$Port/$AppName"
