$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$panelServer = Join-Path $repoRoot "Start-CodexModeSwitcher.ps1"
$powershell = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $powershell) {
    $powershell = Get-Command powershell -ErrorAction SilentlyContinue
}
if (-not $powershell) {
    throw "pwsh/powershell was not found on PATH."
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "codex-mode-panel-test-$([Guid]::NewGuid().ToString('N'))"
$codexHome = Join-Path $tempRoot ".codex"
$sessionPath = Join-Path (Join-Path $codexHome "sessions") "sentinel.jsonl"
$testPort = Get-Random -Minimum 31000 -Maximum 38000
$panelJob = $null
$panelUrl = $null

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $sessionPath) -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $codexHome "config.toml") -Encoding UTF8 -Value @'
model = "gpt-test"
model_provider = "custom"

[model_providers.codex_local_access]
name = "Cockpit Test"
wire_api = "responses"

[model_providers.custom]
name = "CC Switch Test"
wire_api = "responses"
'@
    Set-Content -LiteralPath $sessionPath -Encoding UTF8 -Value '{"sentinel":"must not change"}'
    $sessionHash = (Get-FileHash -LiteralPath $sessionPath -Algorithm SHA256).Hash

    $panelJob = Start-Job -ScriptBlock {
        param($PowerShellPath, $PanelServerPath, $TestCodexHome, $Port)

        & $PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $PanelServerPath -CodexHome $TestCodexHome -Port $Port -NoBrowser
    } -ArgumentList $powershell.Source, $panelServer, $codexHome, $testPort

    for ($attempt = 0; $attempt -lt 50 -and -not $panelUrl; $attempt++) {
        Start-Sleep -Milliseconds 200
        $urlLine = @(Receive-Job -Job $panelJob -Keep |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -like "PANEL_URL=*" } |
            Select-Object -Last 1)
        if ($urlLine.Count -gt 0) {
            $panelUrl = $urlLine[0].Substring("PANEL_URL=".Length)
        }
    }

    Assert-True -Condition ([bool]$panelUrl) -Message "The local HTML panel did not start."

    $panelUri = [Uri]$panelUrl
    $accessToken = $panelUri.Fragment.TrimStart("#")
    $baseUrl = "{0}://{1}" -f $panelUri.Scheme, $panelUri.Authority
    $headers = @{ "X-Codex-Mode-Token" = $accessToken }

    $html = Invoke-WebRequest -Uri "$baseUrl/" -UseBasicParsing
    Assert-True -Condition ($html.Content -match "Codex Mode Switcher") -Message "The panel HTML was not served."

    $unauthorizedBlocked = $false
    try {
        Invoke-RestMethod -Uri "$baseUrl/api/status" | Out-Null
    }
    catch {
        $unauthorizedBlocked = $_.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::Forbidden
    }
    Assert-True -Condition $unauthorizedBlocked -Message "The panel accepted an unauthenticated local API request."

    $initialStatus = Invoke-RestMethod -Uri "$baseUrl/api/status" -Headers $headers
    Assert-True -Condition ($initialStatus.provider -eq "custom") -Message "Unexpected initial provider."

    $switched = Invoke-RestMethod -Method Post -Uri "$baseUrl/api/switch" -Headers $headers -ContentType "application/json" -Body '{"mode":"Cockpit"}'
    Assert-True -Condition ($switched.status.provider -eq "codex_local_access") -Message "The panel did not switch providers."
    Assert-True -Condition ($sessionHash -eq (Get-FileHash -LiteralPath $sessionPath -Algorithm SHA256).Hash) -Message "The panel changed session storage."

    Invoke-RestMethod -Method Post -Uri "$baseUrl/api/close" -Headers $headers | Out-Null
    Wait-Job -Job $panelJob -Timeout 10 | Out-Null
    Assert-True -Condition ($panelJob.State -eq "Completed") -Message "The local panel did not stop cleanly."

    Write-Host "Web panel self-test passed."
}
finally {
    if ($panelJob) {
        if ($panelJob.State -eq "Running") {
            Stop-Job -Job $panelJob
        }
        Remove-Job -Job $panelJob -Force
    }

    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
