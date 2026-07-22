<#
.SYNOPSIS
    Hosts the dependency-free Codex mode panel on loopback only.

.DESCRIPTION
    Serves CodexModeSwitcher.html at a local 127.0.0.1 address and exposes only
    authenticated local status/switch endpoints. It delegates mode changes to
    Switch-CodexMode.ps1, which does not read or alter conversation data.
#>

param(
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }),

    [ValidateRange(0, 65535)]
    [int]$Port = 0,

    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSCommandPath
$switcherPath = Join-Path $repoRoot "Switch-CodexMode.ps1"
$htmlPath = Join-Path $repoRoot "CodexModeSwitcher.html"

foreach ($requiredPath in @($switcherPath, $htmlPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required launcher file not found: $requiredPath"
    }
}

function Resolve-CodexHome {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "CodexHome not found: $Path"
    }

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if (-not (Test-Path -LiteralPath (Join-Path $resolved "config.toml") -PathType Leaf)) {
        throw "config.toml not found: $(Join-Path $resolved "config.toml")"
    }

    return $resolved
}

function Get-TopLevelConfigValue {
    param(
        [string]$Config,
        [string]$Name
    )

    foreach ($line in ($Config -split "`r?`n")) {
        if ($line -match '^\s*\[') {
            break
        }

        $pattern = '^\s*' + [regex]::Escape($Name) + '\s*=\s*"([^"]+)"\s*$'
        $match = [regex]::Match($line, $pattern)
        if ($match.Success) {
            return $match.Groups[1].Value
        }
    }

    return $null
}

function Get-PanelStatus {
    param([string]$ResolvedCodexHome)

    $configPath = Join-Path $ResolvedCodexHome "config.toml"
    $config = [System.IO.File]::ReadAllText($configPath)
    return [pscustomobject]@{
        provider = Get-TopLevelConfigValue -Config $config -Name "model_provider"
        model = Get-TopLevelConfigValue -Config $config -Name "model"
        codexHome = $ResolvedCodexHome
    }
}

function New-AccessToken {
    $bytes = New-Object byte[] 32
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    }
    finally {
        $generator.Dispose()
    }

    return [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function Start-LoopbackListener {
    param([int]$RequestedPort)

    $candidatePorts = if ($RequestedPort -eq 0) { @(8765..8785) } else { @($RequestedPort) }
    foreach ($candidatePort in $candidatePorts) {
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://127.0.0.1:$candidatePort/")
        try {
            $listener.Start()
            return [pscustomobject]@{
                Listener = $listener
                Port = $candidatePort
            }
        }
        catch {
            $listener.Close()
        }
    }

    throw "No local port is available. Try again or start with -Port <unused-port>."
}

function Write-BytesResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [byte[]]$Bytes,
        [string]$ContentType
    )

    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    $response.ContentEncoding = [System.Text.Encoding]::UTF8
    $response.Headers["Cache-Control"] = "no-store"
    $response.Headers["X-Content-Type-Options"] = "nosniff"
    $response.ContentLength64 = $Bytes.Length
    $response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $response.Close()
}

function Write-JsonResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        $Data
    )

    $json = $Data | ConvertTo-Json -Depth 4 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Write-BytesResponse -Context $Context -StatusCode $StatusCode -Bytes $bytes -ContentType "application/json; charset=utf-8"
}

function Test-RequestToken {
    param(
        [System.Net.HttpListenerRequest]$Request,
        [string]$ExpectedToken
    )

    $providedToken = $Request.Headers["X-Codex-Mode-Token"]
    return -not [string]::IsNullOrEmpty($providedToken) -and $providedToken -ceq $ExpectedToken
}

function Read-RequestJson {
    param([System.Net.HttpListenerRequest]$Request)

    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try {
        $body = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($body)) {
        throw "Request body is required."
    }

    return $body | ConvertFrom-Json
}

$resolvedCodexHome = Resolve-CodexHome -Path $CodexHome
$token = New-AccessToken
$listenerResult = Start-LoopbackListener -RequestedPort $Port
$listener = $listenerResult.Listener
$portNumber = $listenerResult.Port
$panelUrl = "http://127.0.0.1:$portNumber/#$token"
$keepRunning = $true

Write-Output "PANEL_URL=$panelUrl"
Write-Host "Codex Mode Switcher is running locally. Close this terminal or use '关闭本地面板' when finished."

if (-not $NoBrowser) {
    try {
        Start-Process -FilePath $panelUrl
    }
    catch {
        Write-Warning "Could not open the browser automatically. Open this address manually: $panelUrl"
    }
}

try {
    while ($keepRunning) {
        $context = $listener.GetContext()
        $request = $context.Request
        $path = $request.Url.AbsolutePath

        try {
            if ($path -eq "/" -and $request.HttpMethod -eq "GET") {
                Write-BytesResponse -Context $context -StatusCode 200 -Bytes ([System.IO.File]::ReadAllBytes($htmlPath)) -ContentType "text/html; charset=utf-8"
                continue
            }

            if (-not (Test-RequestToken -Request $request -ExpectedToken $token)) {
                Write-JsonResponse -Context $context -StatusCode 403 -Data @{ error = "Unauthorized local request." }
                continue
            }

            if ($path -eq "/api/status" -and $request.HttpMethod -eq "GET") {
                Write-JsonResponse -Context $context -StatusCode 200 -Data (Get-PanelStatus -ResolvedCodexHome $resolvedCodexHome)
                continue
            }

            if ($path -eq "/api/switch" -and $request.HttpMethod -eq "POST") {
                $payload = Read-RequestJson -Request $request
                $mode = [string]$payload.mode
                if ($mode -notin @("Normal", "Cockpit", "CCSwitch")) {
                    throw "Unsupported mode: $mode"
                }

                & $switcherPath -Mode $mode -CodexHome $resolvedCodexHome *>&1 | Out-Null
                Write-JsonResponse -Context $context -StatusCode 200 -Data @{ ok = $true; status = (Get-PanelStatus -ResolvedCodexHome $resolvedCodexHome) }
                continue
            }

            if ($path -eq "/api/close" -and $request.HttpMethod -eq "POST") {
                Write-JsonResponse -Context $context -StatusCode 200 -Data @{ ok = $true }
                $keepRunning = $false
                continue
            }

            Write-JsonResponse -Context $context -StatusCode 404 -Data @{ error = "Unknown local endpoint." }
        }
        catch {
            Write-JsonResponse -Context $context -StatusCode 400 -Data @{ error = $_.Exception.Message }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
