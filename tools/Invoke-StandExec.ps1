<#
.SYNOPSIS
    Выполняет код BSL на стенде ветки через исполнитель кода стенда и печатает
    ответ в JSON.

.DESCRIPTION
    Исполнитель — расширение комплекта с HTTP-сервисом, которое стоит только на
    стендах (раздел standExec в .1c-workflow.json). Код получает переменную
    Параметры и кладёт ответ в переменную Результат — любое значение: ссылки,
    таблицы, структуры, даты исполнитель приводит к JSON сам.

    Режимы:
      commit   — код в одной транзакции, при ошибке ничего не записано (по умолчанию);
      rollback — код выполняется, результат снимается, транзакция отменяется:
                 эксперимент, не оставляющий следов на стенде;
      none     — без транзакции исполнителя: код управляет ею сам.

    Печатается тело ответа как есть: {ok, mode, result, messages, elapsedMs} и при
    ошибке error и details. В messages — сообщения пользователю, которые код и
    вызванные им обработчики выдали по ходу: проверка заполнения объясняет отказ
    именно так.

    Коды выхода: 0 — код выполнен; 1 — код упал (ok=false); 2 — исполнитель
    отказал или недоступен.

    Тело ответа читается через HttpClient, а не Invoke-WebRequest: Windows
    PowerShell 5.1 при ответе 4xx/5xx тело теряет, и отказ исполнителя выглядел бы
    пустым.

.PARAMETER Code
    Текст кода BSL.

.PARAMETER File
    Файл с кодом BSL (UTF-8). Сиды проекта лежат файлами.

.PARAMETER ParametersJson
    Параметры для кода, объект JSON: '{"Имя": "Товар 1", "Цена": 10}'.

.PARAMETER ParametersFile
    Файл с параметрами, объект JSON.

.PARAMETER Url
    Корень публикации базы, например http://localhost:8200/app. По умолчанию —
    стенд Web UI текущей ветки.

.PARAMETER Ping
    Только проверить исполнитель: версия, метка стенда, пользователь.

.PARAMETER Anonymous
    Не представляться. Нужно для базы, где пользователей нет вовсе: платформа
    отказывает входу по имени в такую базу. На стендах комплекта администратор
    есть всегда, и ключ не нужен.

.EXAMPLE
    tools\Invoke-StandExec.ps1 -Code 'Результат = Справочники.Валюты.НайтиПоКоду("643");'

.EXAMPLE
    tools\Invoke-StandExec.ps1 -File tests\seed\currencies.bsl -Mode commit

.EXAMPLE
    tools\Invoke-StandExec.ps1 -Mode rollback -File probe.bsl -ParametersJson '{"Документ": "..."}'
#>
[CmdletBinding()]
param(
    [string]$Code = "",
    [string]$File = "",
    [string]$ParametersJson = "",
    [string]$ParametersFile = "",
    [ValidateSet("commit", "rollback", "none")]
    [string]$Mode = "commit",
    [string]$Url = "",
    [int]$Port = 0,
    [string]$AppName = "",
    [string]$UserName = "",
    [string]$Password = "",
    [int]$TimeoutSeconds = 1800,
    [switch]$Ping,
    [switch]$Anonymous
)

$ErrorActionPreference = "Stop"

# Отказ до выполнения кода — код выхода 2, как отказ исполнителя: вызывающему
# важно отличать «код упал» (1) от «код не выполнялся» (2).
function Stop-StandExec([string]$Message) {
    [Console]::Error.WriteLine($Message)
    exit 2
}

$repositoryRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repositoryRoot "scripts\workflow\Workflow.Common.ps1")
$config = Get-WorkflowConfig -RepositoryRoot $repositoryRoot

if (-not $Url) {
    if (-not (Test-WorkflowStandExecEnabled -Config $config)) {
        Stop-StandExec "Исполнитель кода стенда выключен: standExec.enabled в .1c-workflow.json."
    }
    $standBranch = Get-WorkflowStandBranchName -RepositoryRoot $repositoryRoot
    if (-not $AppName) {
        $AppName = Get-WorkflowStandAppName `
            -Config $config `
            -BranchName $standBranch `
            -DefaultAppName ([string]$config.webUiTests.defaultAppName)
    }
    if ($Port -eq 0) {
        $Port = Get-WorkflowSavedStandPort `
            -RepositoryRoot $repositoryRoot `
            -Config $config `
            -Kind "web-ui" `
            -BranchName $standBranch
    }
    if ($Port -eq 0) {
        Stop-StandExec ("Стенд Web UI этой ветки не опубликован, адрес брать неоткуда. " +
            "Опубликуйте: tools\Publish-WebTestStand.ps1 — или передайте -Url.")
    }
    $Url = "http://localhost:$Port/$AppName"
}
$serviceUrl = $Url.TrimEnd('/') + "/hs/stand-exec"

$body = ""
if (-not $Ping) {
    if ($File) {
        if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
            Stop-StandExec "Файл с кодом не найден: $File"
        }
        $Code = [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($File), [System.Text.Encoding]::UTF8)
    }
    if (-not $Code.Trim()) {
        Stop-StandExec "Код не передан: -Code или -File."
    }
    if ($ParametersFile) {
        if (-not (Test-Path -LiteralPath $ParametersFile -PathType Leaf)) {
            Stop-StandExec "Файл с параметрами не найден: $ParametersFile"
        }
        $ParametersJson = [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($ParametersFile), [System.Text.Encoding]::UTF8)
    }
    # Параметры вставляются в тело готовым JSON, а не пересериализуются:
    # ConvertTo-Json в Windows PowerShell 5.1 по умолчанию обрезает вложенность
    # глубже двух уровней. Разбор здесь — только проверка, что это объект JSON.
    $parametersText = "{}"
    if ($ParametersJson) {
        try {
            $parsed = $ParametersJson | ConvertFrom-Json
        }
        catch {
            Stop-StandExec "Параметры — не JSON: $($_.Exception.Message)"
        }
        if ($parsed -isnot [System.Management.Automation.PSCustomObject]) {
            Stop-StandExec "Параметры должны быть объектом JSON: {""Имя"": значение}."
        }
        $parametersText = $ParametersJson.Trim()
    }
    $codeText = (New-Object PSObject -Property @{ v = $Code } | ConvertTo-Json -Compress)
    $codeValue = $codeText.Substring(5, $codeText.Length - 6)
    $body = '{"code":' + $codeValue + ',"params":' + $parametersText + ',"mode":"' + $Mode + '"}'
}

# Учётные данные: явные, иначе администратор стенда — он есть на любом стенде
# комплекта (Get-WorkflowStandAdministrator, без пароля). -Anonymous — для базы без
# пользователей вовсе: вход по имени в такую базу платформа отклоняет.
if ($Anonymous) {
    $UserName = ""
}
elseif (-not $UserName -and (Get-Command -Name "Get-WorkflowStandAdministrator" -ErrorAction SilentlyContinue)) {
    $administrator = Get-WorkflowStandAdministrator
    $UserName = [string]$administrator.UserName
    $Password = [string]$administrator.Password
}

Add-Type -AssemblyName System.Net.Http
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
if ($UserName) {
    $token = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${UserName}:${Password}"))
    $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Basic", $token)
}

try {
    if ($Ping) {
        $response = $client.GetAsync("$serviceUrl/ping").GetAwaiter().GetResult()
    }
    else {
        $content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, "application/json")
        $response = $client.PostAsync("$serviceUrl/run", $content).GetAwaiter().GetResult()
    }
    $status = [int]$response.StatusCode
    $raw = [System.Text.Encoding]::UTF8.GetString($response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
}
catch {
    Stop-StandExec "Исполнитель недоступен: $serviceUrl. $($_.Exception.GetBaseException().Message)"
}
finally {
    $client.Dispose()
}

Write-Output $raw
if ($status -ne 200) {
    $hint = if ($status -eq 404) { " Опубликован ли стенд с исполнителем (tools\Publish-WebTestStand.ps1)?" } else { "" }
    Stop-StandExec "Исполнитель ответил $status.$hint"
}
$answer = $raw | ConvertFrom-Json
if (-not $Ping -and -not [bool]$answer.ok) {
    exit 1
}
exit 0
