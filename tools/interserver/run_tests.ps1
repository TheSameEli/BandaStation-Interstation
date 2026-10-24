param(
    [Parameter(Mandatory)][string]$ByondBin,
    [Parameter(Mandatory)][string]$NativeDirectory
)
$ErrorActionPreference = 'Stop'
$ByondBin = (Resolve-Path -LiteralPath $ByondBin).Path
$NativeDirectory = (Resolve-Path -LiteralPath $NativeDirectory).Path
$testRoot = $PSScriptRoot
$compiler = Join-Path $ByondBin 'dm.exe'
$daemon = Join-Path $ByondBin 'dd.exe'
Copy-Item -LiteralPath (Join-Path $NativeDirectory 'rust_g.dll'),(Join-Path $NativeDirectory 'transit_crypto.dll') -Destination $testRoot

function Build-Test([string]$name) {
    Push-Location $testRoot
    try {
        & $compiler "$name.dme"
        if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $name" }
    } finally { Pop-Location }
}

function Start-Test([string]$name, [string]$label, [string[]]$extra = @()) {
    Start-Process -FilePath $daemon -ArgumentList (@("$name.dmb", '-close', '-trusted', '-verbose', '-ip', '127.0.0.1', '-invisible') + $extra) -WorkingDirectory $testRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $testRoot "$label.stdout.log") -RedirectStandardError (Join-Path $testRoot "$label.stderr.log")
}

function Assert-Test([string]$result, [string[]]$labels) {
    $text = Get-Content -LiteralPath (Join-Path $testRoot $result) -Raw
    if ($text -notmatch '^PASS' -or $text -match 'FAIL') { throw "Failed test: $result" }
    foreach ($label in $labels) {
        $log = Get-Content -LiteralPath (Join-Path $testRoot "$label.stderr.log") -Raw
        if ($log -match 'runtime error|FAIL:') { throw "Runtime in $label" }
    }
    Write-Output $text.Trim()
}

Build-Test 'protocol_test'
$protocolProcess = Start-Test 'protocol_test' 'protocol-test'
try {
    if (!$protocolProcess.WaitForExit(30000)) { throw 'Protocol test timed out' }
    Assert-Test 'protocol-test-result.txt' @('protocol-test')
} finally {
    if (!$protocolProcess.HasExited) { $protocolProcess.Kill() }
}

Build-Test 'peer_test'
if (Get-NetTCPConnection -State Listen -LocalPort 1537,1538 -ErrorAction SilentlyContinue) { throw 'Peer test ports 1537/1538 occupied' }
$testKey = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
$keyPath = Join-Path $testRoot 'peer-test.key'
[IO.File]::WriteAllText($keyPath,$testKey)
$receiver = $null
$sender = $null
try {
    $receiver = Start-Test 'peer_test' 'peer-B' @('1538','-params','side=B&peer-port=1537')
    $sender = Start-Test 'peer_test' 'peer-A' @('1537','-params','side=A&peer-port=1538')
    if (!$sender.WaitForExit(30000)) { throw 'Peer sender timed out' }
    if (!$receiver.WaitForExit(5000)) { throw 'Peer receiver did not shut down' }
    Assert-Test 'peer-test-result.txt' @('peer-A','peer-B')
} finally {
    foreach ($process in @($sender,$receiver)) {
        if ($process -and !$process.HasExited) { $process.Kill() }
    }
    Remove-Item -LiteralPath $keyPath -ErrorAction SilentlyContinue
}
