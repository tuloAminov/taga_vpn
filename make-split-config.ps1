# PowerShell Split-Tunneling Helper for Windows
param(
    [Parameter(Position = 0, Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Position = 1, Mandatory = $false)]
    [ValidateSet("fast", "instant", "full")]
    [string]$Mode = "fast"
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PythonScript = Join-Path $ScriptDir "split_tunnel.py"

if (-not $ConfigFile) {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "   VPN-TAGA: Windows Split-Tunneling Converter              " -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Modes:" -ForegroundColor Yellow
    Write-Host "  fast    - Optimized (connect in under 1s, default)"
    Write-Host "  instant - Ultra-fast (connect in under 0.2s)"
    Write-Host "  full    - Full list (connect in ~5s)"
    Write-Host ""
    $ConfigFile = Read-Host "Drag-and-drop .conf file here or enter path"
    if ($ConfigFile) {
        $ConfigFile = $ConfigFile.Trim('"').Trim("'")
    }
}

if (-not $ConfigFile) {
    Write-Host "[ERROR] No file specified." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $ConfigFile)) {
    Write-Host "[ERROR] File '$ConfigFile' not found!" -ForegroundColor Red
    exit 1
}

$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) {
    $pythonCmd = Get-Command py -ErrorAction SilentlyContinue
}

if (-not $pythonCmd) {
    Write-Host "[ERROR] Python 3 not found in PATH! Please install Python from python.org" -ForegroundColor Red
    exit 1
}

& $pythonCmd.Source $PythonScript $ConfigFile -m $Mode

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "[SUCCESS] Split config ready to share with family and friends!" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "[ERROR] Failed to generate configuration." -ForegroundColor Red
}
