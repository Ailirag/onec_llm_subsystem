<#
.SYNOPSIS
Проектный адаптер HTTP-публикации функционального стенда.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BasePath,
    [string]$V8Path = ""
)

$ErrorActionPreference = "Stop"
throw "Публикация функционального стенда не настроена проектом: tools\Publish-FunctionalTestEnvironment.ps1."
