param(
    [Parameter(Mandatory)]
    [string]$Version,

    [Parameter(Mandatory)]
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$versionNumber = $Version -replace '^v', ''
$versionTag = "v$versionNumber"
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) "codex-mode-release-$([Guid]::NewGuid().ToString('N'))"
$bundlePath = Join-Path $stageRoot "Codex Mode Switcher"
$archivePath = Join-Path $resolvedOutput "codex-mode-switcher-$versionTag-windows.zip"

try {
    New-Item -ItemType Directory -Path $bundlePath -Force | Out-Null
    New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
    foreach ($name in @(
        "CodexModeSwitcher.html",
        "session_provider_sync.py",
        "Start-CodexModeSwitcher.ps1",
        "Switch-CodexMode.bat",
        "Switch-CodexMode.ps1"
    )) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $name) -Destination (Join-Path $bundlePath $name)
    }

    $readmeTemplate = Get-Content -LiteralPath (Join-Path $repoRoot "packaging/windows/README.txt") -Raw -Encoding UTF8
    $readme = $readmeTemplate.Replace("__VERSION__", $versionTag)
    [System.IO.File]::WriteAllText(
        (Join-Path $bundlePath "README.txt"),
        $readme,
        [System.Text.UTF8Encoding]::new($true)
    )

    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    Compress-Archive -LiteralPath $bundlePath -DestinationPath $archivePath -CompressionLevel Optimal
    Write-Output $archivePath
}
finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
}
