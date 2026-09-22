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

$connector = New-Object -ComObject "V83.COMConnector"
$connectionString = "File=`"$([System.IO.Path]::GetFullPath($BasePath))`";"
$connection = $connector.Connect($connectionString)
$result = [string]$connection.Run($Mode)
[System.IO.File]::WriteAllText(
    [System.IO.Path]::GetFullPath($ResultPath),
    $result + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)
exit 0
