param(
    [Parameter(Mandatory)][string]$ByondBin,
    [Parameter(Mandatory)][string]$NativeDirectory,
    [Parameter(Mandatory)][string]$ServerRoot,
    [ValidateSet("A","B","Both")][string]$Side = "Both"
)
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$daemon = (Resolve-Path (Join-Path $ByondBin 'dd.exe')).Path
$nativeFiles = @('rust_g.dll','rust_utils.dll','dreamluau.dll','transit_crypto.dll')
foreach ($name in $nativeFiles) {
    if (!(Test-Path -LiteralPath (Join-Path $NativeDirectory $name))) { throw "Missing native library: $name" }
}
foreach ($name in @('tgstation.dmb','tgstation.rsc')) {
    if (!(Test-Path -LiteralPath (Join-Path $repository $name))) { throw "Build missing: $name" }
}
function Get-OwnedProcess([string]$name) {
    $recordPath = Join-Path $ServerRoot "$name/process.json"
    if (!(Test-Path -LiteralPath $recordPath)) { return $null }
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    $process = Get-Process -Id $record.id -ErrorAction SilentlyContinue
    if ($process -and $process.Path -eq $record.executable -and $process.StartTime.ToUniversalTime().Ticks -eq ([DateTimeOffset]$record.started).UtcTicks) { return $process }
    return $null
}
[IO.Directory]::CreateDirectory($ServerRoot) | Out-Null
$ServerRoot = (Resolve-Path $ServerRoot).Path
$launchLock = [Threading.Mutex]::new($false, 'Local\BandstationInterserverTestLaunch')
if (!$launchLock.WaitOne(30000)) { throw 'Another server launcher is busy' }
try {
$pairPath = Join-Path $ServerRoot 'pair.json'
if ((Test-Path -LiteralPath $pairPath) -and ((Get-OwnedProcess 'A') -or (Get-OwnedProcess 'B'))) {
    $pair = Get-Content -LiteralPath $pairPath -Raw | ConvertFrom-Json
} else {
    # Both game processes are gone: start a NEW test round pair. Old journals stay on disk.
    if (Test-Path -LiteralPath $pairPath) {
        $archive = Join-Path $ServerRoot ('pair-' + (Get-Date -Format 'yyyyMMdd-HHmmss-ffff') + '.json')
        Copy-Item -LiteralPath $pairPath -Destination $archive
    }
    $pair = [ordered]@{
        pair_id = [Guid]::NewGuid().ToString('N')
        secret = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    }
    [IO.File]::WriteAllText($pairPath,($pair | ConvertTo-Json))
}
$started = @()
try {
    $selectedSides = if ($Side -eq 'Both') { @('A','B') } else { @($Side) }
    foreach ($currentSide in $selectedSides) {
        $port = if ($currentSide -eq 'A') { 1337 } else { 1338 }
        $stationName = if ($currentSide -eq 'A') { 'Кибериада' } else { 'Метастейшен' }
        $destinationName = if ($currentSide -eq 'A') { 'Метастейшен' } else { 'Кибериада' }
        if (Get-OwnedProcess $currentSide) {
            Write-Output "Server $currentSide is already running: byond://127.0.0.1:$port"
            continue
        }
        if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { throw "Port $port is occupied by another process" }

        $runtime = Join-Path $ServerRoot $currentSide
        [IO.Directory]::CreateDirectory($runtime) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $runtime 'data')) | Out-Null
        $configPath = Join-Path $runtime 'config'
        if (!(Test-Path -LiteralPath $configPath)) {
            Copy-Item -LiteralPath (Join-Path $repository 'config') -Destination $configPath -Recurse
            [IO.File]::WriteAllText((Join-Path $configPath 'dev_overrides.txt'),"SERVERNAME Bandstation $currentSide - interserver test`nHUB 0`nSQL_ENABLED 0`nLOBBY_COUNTDOWN 60`nRESUME_AFTER_INITIALIZATIONS 1`nFORBID_STATION_TRAITS`n")
        }
        $devOverridesPath = Join-Path $configPath 'dev_overrides.txt'
        $devOverrides = [IO.File]::ReadAllText($devOverridesPath)
        $devOverrides = [regex]::Replace($devOverrides, '(?m)^SERVERNAME .*$', "SERVERNAME Станция $stationName")
        [IO.File]::WriteAllText($devOverridesPath, $devOverrides)
        foreach ($directory in @('_maps','build','code','html','icons','interface','lua','modular_bandastation','sound','strings')) {
            $linkPath = Join-Path $runtime $directory
            if (!(Test-Path -LiteralPath $linkPath)) {
                New-Item -ItemType Junction -Path $linkPath -Target (Join-Path $repository $directory) | Out-Null
            }
        }
        # Non-TGS assets load from disk on demand. A shared public directory lets a
        # rebuild silently serve a new interface to an old DMB, so freeze this bundle.
        $runtimeGui = Join-Path $runtime 'tgui'
        if (Test-Path -LiteralPath $runtimeGui) {
            $guiEntry = Get-Item -LiteralPath $runtimeGui
            if ($guiEntry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $expectedGui = [IO.Path]::GetFullPath((Join-Path $repository 'tgui'))
                if ($guiEntry.LinkType -ne 'Junction' -or [IO.Path]::GetFullPath($guiEntry.Target) -ne $expectedGui -or ![IO.Path]::GetFullPath($runtimeGui).StartsWith($ServerRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Unexpected runtime GUI link; refusing to replace it'
                }
                # Delete only this verified junction, without traversing its target.
                [IO.Directory]::Delete($runtimeGui)
            }
        }
        [IO.Directory]::CreateDirectory($runtimeGui) | Out-Null
        Copy-Item -LiteralPath (Join-Path $repository 'tgui/public') -Destination $runtimeGui -Recurse -Force
        $guiPackages = Join-Path $runtimeGui 'packages'
        if (!(Test-Path -LiteralPath $guiPackages)) {
            New-Item -ItemType Junction -Path $guiPackages -Target (Join-Path $repository 'tgui/packages') | Out-Null
        }
        foreach ($name in @('tgstation.dmb','tgstation.rsc')) {
            Copy-Item -LiteralPath (Join-Path $repository $name) -Destination $runtime
        }
        foreach ($name in $nativeFiles) {
            Copy-Item -LiteralPath (Join-Path $NativeDirectory $name) -Destination $runtime
        }
        # The Windows detector in this build uses the Unix-style base name.
        Copy-Item -LiteralPath (Join-Path $NativeDirectory 'rust_utils.dll') -Destination (Join-Path $runtime 'librust_utils.dll')
        # Greenshift and a static latejoin landmark are deliberate local-test restrictions.
        $dynamic = Get-Content -LiteralPath (Join-Path $repository 'config/dynamic.toml') -Raw
        $dynamic = [regex]::Replace($dynamic, '(?m)^weight = [0-9]+', 'weight = 0')
        $dynamic = [regex]::Replace($dynamic, '(?s)(\["Greenshift"\].*?weight = )0', '${1}100')
        [IO.File]::WriteAllText((Join-Path $configPath 'dynamic.toml'), $dynamic)
        $nextMap = Join-Path $runtime 'data/next_map.json'
        $mapConfig = if ($currentSide -eq 'A') { 'interserver_test_cyberiad.json' } else { 'interserver_test_metastation.json' }
        Copy-Item -LiteralPath (Join-Path $repository "_maps/map_jsons/$mapConfig") -Destination $nextMap
        $port = if ($currentSide -eq 'A') { 1337 } else { 1338 }
        $peerPort = if ($currentSide -eq 'A') { 1338 } else { 1337 }
        $peerId = if ($currentSide -eq 'A') { 'B' } else { 'A' }
        $settings = [ordered]@{ enabled = $true; server_id = $currentSide; peer_id = $peerId; pair_id = $pair.pair_id; secret = $pair.secret; peer_address = "127.0.0.1:$peerPort"; test_autostart = $true; diagnostic_mode = $true; warning_seconds = 5; flight_seconds = 5; station_name = $stationName; destination_name = $destinationName }
        [IO.File]::WriteAllText((Join-Path $configPath 'interserver_transit.json'),($settings | ConvertTo-Json))
        $process = Start-Process -FilePath $daemon -ArgumentList @('tgstation.dmb',"$port",'-trusted','-close','-verbose','-ip','127.0.0.1','-invisible') -WorkingDirectory $runtime -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runtime 'daemon.stdout.log') -RedirectStandardError (Join-Path $runtime 'daemon.stderr.log')
        $started += $process
        [IO.File]::WriteAllText((Join-Path $runtime 'process.json'),([ordered]@{ id = $process.Id; started = $process.StartTime.ToUniversalTime().ToString('o'); executable = $daemon } | ConvertTo-Json))
        Write-Output "Started $currentSide PID $($process.Id), byond://127.0.0.1:$port (controlled interserver test)"
    }
} catch {
    foreach ($process in $started) {
        if (!$process.HasExited) { $process.Kill() }
    }
    throw
}

} finally {
    $launchLock.ReleaseMutex()
    $launchLock.Dispose()
}
