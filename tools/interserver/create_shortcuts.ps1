param(
    [Parameter(Mandatory)][string]$ByondBin,
    [Parameter(Mandatory)][string]$NativeDirectory,
    [Parameter(Mandatory)][string]$ServerRoot
)
$ErrorActionPreference = 'Stop'
$ByondBin = (Resolve-Path -LiteralPath $ByondBin).Path
$NativeDirectory = (Resolve-Path -LiteralPath $NativeDirectory).Path
$ServerRoot = (Resolve-Path -LiteralPath $ServerRoot).Path
$launcher = Join-Path $PSScriptRoot 'start_local.ps1'
$powershell = (Get-Process -Id $PID).Path
$client = Join-Path $ByondBin 'dreamseeker.exe'
$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell
foreach ($side in @('A','B')) {
    $station = if ($side -eq 'A') { 'Кибериада' } else { 'Метастейшен' }
    $fileStation = if ($side -eq 'A') { 'Cyberiad' } else { 'MetaStation' }
    $port = if ($side -eq 'A') { 1337 } else { 1338 }
    $serverLink = $shell.CreateShortcut((Join-Path $desktop "Bandstation $side - $fileStation - Server.lnk"))
    $serverLink.TargetPath = $powershell
    $serverLink.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$launcher`" -ByondBin `"$ByondBin`" -NativeDirectory `"$NativeDirectory`" -ServerRoot `"$ServerRoot`" -Side $side"
    $serverLink.WorkingDirectory = $ServerRoot
    $serverLink.Description = "Запуск локального тестового сервера $side ($station), порт $port. Повторный запуск не создаёт второй процесс."
    $serverLink.IconLocation = "$(Join-Path $ByondBin 'dd.exe'),0"
    $serverLink.Save()
    $clientLink = $shell.CreateShortcut((Join-Path $desktop "Bandstation $side - $fileStation - Client.lnk"))
    $clientLink.TargetPath = $client
    $clientLink.Arguments = "byond://127.0.0.1:$port"
    $clientLink.WorkingDirectory = $ByondBin
    $clientLink.Description = "Подключение BYOND 516.1685 к локальному серверу $side ($station)"
    $clientLink.IconLocation = "$client,0"
    $clientLink.Save()
    Write-Output "Created server/client shortcuts for $side ($station)"
}
