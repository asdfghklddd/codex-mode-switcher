$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$panelServer = Join-Path $repoRoot "Start-CodexModeSwitcher.ps1"
$powershell = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $powershell) {
    $powershell = Get-Command powershell -ErrorAction SilentlyContinue
}
if (-not $powershell) {
    throw "PATH 中找不到 pwsh/powershell。"
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
    Set-Content -LiteralPath $sessionPath -Encoding UTF8 -Value '{"sentinel":"不得改变"}'
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

    Assert-True -Condition ([bool]$panelUrl) -Message "本地 HTML 面板未能启动。"

    $panelUri = [Uri]$panelUrl
    $accessToken = $panelUri.Fragment.TrimStart("#")
    $baseUrl = "{0}://{1}" -f $panelUri.Scheme, $panelUri.Authority
    $headers = @{ "X-Codex-Mode-Token" = $accessToken }

    $html = Invoke-WebRequest -Uri "$baseUrl/" -UseBasicParsing
    Assert-True -Condition ($html.Content -match "Codex 模式切换器") -Message "未能提供面板 HTML。"

    $unauthorizedBlocked = $false
    try {
        Invoke-RestMethod -Uri "$baseUrl/api/status" | Out-Null
    }
    catch {
        $unauthorizedBlocked = $_.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::Forbidden
    }
    Assert-True -Condition $unauthorizedBlocked -Message "面板接受了未认证的本地 API 请求。"

    $initialStatus = Invoke-RestMethod -Uri "$baseUrl/api/status" -Headers $headers
    Assert-True -Condition ($initialStatus.provider -eq "custom") -Message "初始 provider 不符合预期。"

    $switched = Invoke-RestMethod -Method Post -Uri "$baseUrl/api/switch" -Headers $headers -ContentType "application/json" -Body '{"mode":"Cockpit"}'
    Assert-True -Condition ($switched.status.provider -eq "codex_local_access") -Message "面板未能切换 provider。"
    Assert-True -Condition ($sessionHash -eq (Get-FileHash -LiteralPath $sessionPath -Algorithm SHA256).Hash) -Message "面板修改了会话存储。"

    Invoke-RestMethod -Method Post -Uri "$baseUrl/api/close" -Headers $headers | Out-Null
    Wait-Job -Job $panelJob -Timeout 10 | Out-Null
    Assert-True -Condition ($panelJob.State -eq "Completed") -Message "本地面板未能正常停止。"

    Write-Host "网页面板自测通过。"
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
