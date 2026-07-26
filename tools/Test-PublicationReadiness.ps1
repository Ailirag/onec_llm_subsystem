[CmdletBinding()]
param(
    [string]$RepositoryPath = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = "Stop"

$repositoryFullPath = [System.IO.Path]::GetFullPath($RepositoryPath)
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([string]$Message)

    $failures.Add($Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Write-Pass {
    param([string]$Message)

    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Get-GitFiles {
    param([switch]$IncludeUntracked)

    $arguments = @("-c", "core.quotePath=false", "ls-files")
    if ($IncludeUntracked) {
        $arguments += @("--cached", "--others", "--exclude-standard")
    }

    $result = @(& git @arguments)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read the Git file list."
    }

    return @($result | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

Push-Location $repositoryFullPath
try {
    if (-not (Test-Path -LiteralPath ".git" -PathType Container)) {
        throw "The directory is not a Git repository: $repositoryFullPath"
    }

    $requiredFiles = @(
        "LICENSE",
        "NOTICE",
        "README.md",
        "SECURITY.md",
        "CONTRIBUTING.md",
        ".gitignore",
        "cfe llm/Configuration.xml",
        "manifest/llm-subsystem.json"
    )

    foreach ($requiredFile in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            Add-Failure "Required publication file is missing: $requiredFile"
        }
    }

    if ($failures.Count -eq 0) {
        Write-Pass "Required publication files are present."
    }

    $trackedFiles = @(Get-GitFiles)
    $candidateFiles = @(Get-GitFiles -IncludeUntracked)

    $forbiddenArtifactPattern = '(?i)\.(cf|cfe|epf|erf|dt|1cd|bak|pfx|pem|key)$'
    foreach ($file in $candidateFiles) {
        if ($file -match $forbiddenArtifactPattern) {
            Add-Failure "Binary, database or secret artifact is visible to Git: $file"
        }
    }

    foreach ($file in $trackedFiles) {
        if ($file -like "cf llm/*") {
            Add-Failure "Generated embedded configuration is tracked: $file"
        }
    }

    if (-not ($failures | Where-Object { $_ -like "*artifact*" -or $_ -like "*Generated*" })) {
        Write-Pass "Generated and sensitive artifacts are excluded from Git."
    }

    $textExtensions = @(
        ".bsl", ".os", ".xml", ".json", ".md", ".txt",
        ".ps1", ".yml", ".yaml", ".html", ".css", ".js"
    )
    $scannerPath = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
    $secretPatterns = @(
        @{
            Name = "OpenAI-style API key"
            Regex = '(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}'
        },
        @{
            Name = "GitHub access token"
            Regex = '(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{20,}'
        },
        @{
            Name = "Google API key"
            Regex = '(?<![A-Za-z0-9])AIza[0-9A-Za-z_-]{20,}'
        },
        @{
            Name = "Yandex API key"
            Regex = '(?<![A-Za-z0-9])AQVN[A-Za-z0-9_-]{20,}'
        },
        @{
            Name = "Yandex OAuth token"
            Regex = '(?<![A-Za-z0-9])y0_[A-Za-z0-9_-]{20,}'
        },
        @{
            Name = "Static bearer token"
            Regex = '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{20,}'
        },
        @{
            Name = "Private key"
            Regex = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
        },
        @{
            Name = "Local Windows user path"
            Regex = '(?i)\b[A-Z]:\\Users\\[^\\\r\n]+'
        },
        @{
            Name = "Deployment-specific model URI"
            Regex = '(?i)\bgpt://[a-z0-9]{12,}/'
        }
    )

    foreach ($file in $candidateFiles) {
        $extension = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
        if ($extension -notin $textExtensions) {
            continue
        }
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            continue
        }

        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $repositoryFullPath $file))
        if ($fullPath -eq $scannerPath) {
            continue
        }

        $content = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8
        foreach ($pattern in $secretPatterns) {
            if ($content -match $pattern.Regex) {
                Add-Failure "$($pattern.Name) was found in: $file"
            }
        }
    }

    if (-not ($failures | Where-Object {
        $_ -like "*key*" -or
        $_ -like "*token*" -or
        $_ -like "*Private*" -or
        $_ -like "*path*" -or
        $_ -like "*model URI*"
    })) {
        Write-Pass "No known secret or deployment-specific value was found."
    }

    foreach ($file in $candidateFiles | Where-Object {
        [System.IO.Path]::GetExtension($_).ToLowerInvariant() -eq ".xml"
    }) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            continue
        }

        try {
            [xml](Get-Content -LiteralPath $file -Raw -Encoding UTF8) | Out-Null
        }
        catch {
            Add-Failure "Invalid XML file: $file. $($_.Exception.Message)"
        }
    }

    foreach ($file in $candidateFiles | Where-Object {
        [System.IO.Path]::GetExtension($_).ToLowerInvariant() -eq ".json"
    }) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            continue
        }

        try {
            Get-Content -LiteralPath $file -Raw -Encoding UTF8 |
                ConvertFrom-Json |
                Out-Null
        }
        catch {
            Add-Failure "Invalid JSON file: $file. $($_.Exception.Message)"
        }
    }

    if (-not ($failures | Where-Object { $_ -like "Invalid XML*" -or $_ -like "Invalid JSON*" })) {
        Write-Pass "XML and JSON files are well-formed."
    }

    $notice = Get-Content -LiteralPath "NOTICE" -Raw -Encoding UTF8
    $requiredAttributions = @(
        "Anton Tsitavets",
        "Vladimir Bondarevskiy",
        "Vasily Pintov",
        "CC BY 4.0"
    )
    foreach ($attribution in $requiredAttributions) {
        if (-not $notice.Contains($attribution)) {
            Add-Failure "NOTICE does not contain attribution for: $attribution"
        }
    }

    if (-not ($failures | Where-Object { $_ -like "NOTICE*" })) {
        Write-Pass "Known third-party attributions are present."
    }

    if ($failures.Count -gt 0) {
        throw "Publication readiness check failed with $($failures.Count) issue(s)."
    }

    Write-Host ""
    Write-Host "Publication readiness checks passed for $($candidateFiles.Count) files." -ForegroundColor Green
}
finally {
    Pop-Location
}
