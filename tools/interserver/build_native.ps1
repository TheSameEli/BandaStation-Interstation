param(
    [Parameter(Mandatory)][string]$Zig,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$Zig = (Resolve-Path -LiteralPath $Zig).Path
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$output = Join-Path (Resolve-Path -LiteralPath $OutputDirectory).Path 'transit_crypto.dll'
& $Zig cc -target x86-windows-gnu -shared (Join-Path $PSScriptRoot 'transit_crypto.c') -lbcrypt -O2 -o $output
if ($LASTEXITCODE -ne 0) { throw 'Native transit library compilation failed' }
Write-Output "Built $output"
