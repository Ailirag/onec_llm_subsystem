<#
.SYNOPSIS
    Настраивает расширения на стенде через COM: снимает безопасный режим и защиту
    от опасных действий, по ключам — выставляет метку исполнителя кода стенда и
    публикует всё в OData.

.DESCRIPTION
    Вызывается комплектом в дочернем процессе (Enable-WorkflowStandExec,
    Disable-WorkflowExtensionSafeMode из scripts/workflow/Workflow.Common.ps1).
    Руками — только для починки стенда.

    Работает через COM-соединение, а не через конфигуратор и не через запуск
    клиента с обработкой: свойства расширения пакетный конфигуратор не меняет, ibcmd
    умеет это только для файловой базы, а запуск клиента с /Execute стоит десятков
    секунд на большой конфигурации и проходит через стартовые окна. Как именно
    вызываются объекты 1С через COM и почему так — функции *-WorkflowCom* в общем
    модуле комплекта.

    Строка подключения приходит переменной окружения ONEC_WORKFLOW_STAND_CONNECTION,
    а не аргументом: в ней может быть пароль, а аргументы попадают в лог и в список
    процессов.

    Метка и OData — во втором соединении: свойства расширения применяются к НОВЫМ
    сеансам, а метку пишет привилегированный режим, недоступный под безопасным.

.PARAMETER ExtensionName
    Имена расширений через запятую: запуск через -File массивы не разбирает.

.PARAMETER ArmExecutor
    Выставить метку стенда исполнителя кода (ИС_МеткаСтенда.ВключитьИсполнение).

.PARAMETER ODataContent
    Опубликовать в стандартном интерфейсе OData все объекты конфигурации и
    расширений (ИС_ODataСтенда.ОпубликоватьВсё). Требует исполнителя на стенде.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExtensionName,

    [switch]$ArmExecutor,

    [switch]$ODataContent
)

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "scripts\workflow\Workflow.Common.ps1")

$connectionString = [string]$env:ONEC_WORKFLOW_STAND_CONNECTION
if (-not $connectionString) {
    throw "Строка подключения не передана: переменная ONEC_WORKFLOW_STAND_CONNECTION пуста."
}
$names = @($ExtensionName.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($names.Count -eq 0) {
    throw "Не передано ни одного имени расширения."
}

Invoke-WorkflowComConnection -ConnectionString $connectionString -Action {
    param($connection)
    foreach ($name in $names) {
        Disable-WorkflowComExtensionSafeMode -Connection $connection -ExtensionName $name
        Write-Host "stand-extensions: безопасный режим и защита от опасных действий сняты ($name)"
    }
}

if (-not $ArmExecutor -and -not $ODataContent) {
    return
}

Invoke-WorkflowComConnection -ConnectionString $connectionString -Action {
    param($connection)
    if ($ArmExecutor) {
        $marker = Get-WorkflowComProperty -Object $connection -Name "ИС_МеткаСтенда"
        $result = [string](Invoke-WorkflowComMethod -Object $marker -Name "ВключитьИсполнение")
        if ($result -ne "OK") {
            throw "Метка стенда не выставлена: $result"
        }
        if (-not [bool](Invoke-WorkflowComMethod -Object $marker -Name "ИсполнениеРазрешено")) {
            throw "Метка стенда записана, но не читается."
        }
        Write-Host "stand-extensions: метка стенда выставлена"
    }
    if ($ODataContent) {
        $odata = Get-WorkflowComProperty -Object $connection -Name "ИС_ODataСтенда"
        $published = [int](Invoke-WorkflowComMethod -Object $odata -Name "ОпубликоватьВсё")
        Write-Host "stand-extensions: в OData опубликовано объектов: $published"
    }
}
