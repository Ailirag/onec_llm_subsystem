[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BasePath,
    [Parameter(Mandatory = $true)]
    [ValidateSet("seed", "smoke")]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [string]$ResultPath
)

$ErrorActionPreference = "Stop"

$repositoryPath = Split-Path $PSScriptRoot -Parent
. (Join-Path $repositoryPath "scripts\workflow\Workflow.Common.ps1")
$administrator = Get-WorkflowStandAdministrator

$connector = New-Object -ComObject "V83.COMConnector"
$connectionString = "File=`"$([System.IO.Path]::GetFullPath($BasePath))`";" +
    "Usr=`"$([string]$administrator.UserName)`";"
$connection = $connector.Connect($connectionString)
$result = [string]$connection.Run($Mode)
[System.IO.File]::WriteAllText(
    [System.IO.Path]::GetFullPath($ResultPath),
    $result + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)
exit 0
