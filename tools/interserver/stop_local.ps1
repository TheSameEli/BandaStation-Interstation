param(
    [Parameter(Mandatory)][string]$ServerRoot,
    [ValidateSet('A','B','Both')][string]$Side = 'Both'
)
$ErrorActionPreference = 'Stop'
$selectedSides = if ($Side -eq 'Both') { @('A','B') } else { @($Side) }
foreach ($currentSide in $selectedSides) {
    $recordPath = Join-Path $ServerRoot "$currentSide/process.json"
    if (!(Test-Path -LiteralPath $recordPath)) { continue }
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    $process = Get-Process -Id $record.id -ErrorAction SilentlyContinue
    if (!$process) { continue }
    if ($process.Path -ne $record.executable -or $process.StartTime.ToUniversalTime().Ticks -ne ([DateTimeOffset]$record.started).UtcTicks) {
        throw "PID for $currentSide has been reused; refusing to stop it"
    }
    Stop-Process -Id $process.Id
    Write-Output "Stopped local test server $currentSide"
}
