# End-to-end checks for the Windows installer and CLI entry point. No GPU, task, PATH or miner is touched:
# the installer runs from a local zip into a temporary LOCALAPPDATA with setup and PATH skipped.
#   powershell -ExecutionPolicy Bypass -File tests\test_windows_cli.ps1
#   pwsh tests/test_windows_cli.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$shell = (Get-Process -Id $PID).Path
$script:fail = 0; $script:n = 0
. (Join-Path (Join-Path (Join-Path $repo 'windows') 'lib') 'common.ps1')
function Read-PearlConfFile([string]$Path) { $c = Read-PearlConf $Path; if ($null -eq $c) { return @{} }; return $c }
function Check([string]$Name, $Got, $Want) {
    $script:n++
    if ("$Got" -ne "$Want") { $script:fail++; Write-Host "FAIL  $Name  got '$Got' want '$Want'" }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("pm-cli-" + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $work 'pearlmine-test'
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    # A source zip shaped like GitHub's archive: one top folder containing the repo.
    Copy-Item -Recurse -LiteralPath (Join-Path $repo 'windows') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination $stage
    $zip = Join-Path $work 'src.zip'
    Compress-Archive -Path $stage -DestinationPath $zip

    $appdata = Join-Path $work 'appdata'
    New-Item -ItemType Directory -Force -Path $appdata | Out-Null
    $saved = @{}
    foreach ($k in 'LOCALAPPDATA', 'PEARLMINE_SRC_ZIP', 'PEARLMINE_SKIP_SETUP', 'PEARLMINE_SKIP_PATH') { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
    $env:LOCALAPPDATA = $appdata; $env:PEARLMINE_SRC_ZIP = $zip; $env:PEARLMINE_SKIP_SETUP = '1'; $env:PEARLMINE_SKIP_PATH = '1'
    try {
        $out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Join-Path $repo 'windows') 'install.ps1') 2>&1 | Out-String
        Check 'installer exit code' $LASTEXITCODE 0
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    $dest = Join-Path $appdata 'pearlmine'
    foreach ($f in 'pearlmine.cmd', 'pearlmine.conf.example', 'README.md', 'LICENSE', 'lib/pearlmine.ps1', 'lib/agent.ps1', 'lib/common.ps1') {
        Check "installed $f" (Test-Path -LiteralPath (Join-Path $dest $f)) $true
    }
    Check 'installer does not copy itself' (Test-Path -LiteralPath (Join-Path $dest 'install.ps1')) $false
    if ($script:fail) { Write-Host $out }

    $cli = Join-Path (Join-Path $dest 'lib') 'pearlmine.ps1'
    foreach ($h in 'help', '-h', '--help', '/?') {
        $o = & $shell -NoProfile -ExecutionPolicy Bypass -File $cli $h 2>&1 | Out-String
        Check "help via '$h' exit" $LASTEXITCODE 0
        Check "help via '$h' text" ($o -match 'pearlmine setup') $true
    }
    $o = & $shell -NoProfile -ExecutionPolicy Bypass -File $cli bogus 2>&1 | Out-String
    Check 'unknown command exit' $LASTEXITCODE 1
    $o = & $shell -NoProfile -ExecutionPolicy Bypass -File $cli check 2>&1 | Out-String
    Check 'check without config exit' $LASTEXITCODE 1
    Check 'check without config message' ($o -match 'no pearlmine.conf yet') $true

    # Setup prompt: a fake installed miner so setup skips the download.
    $fake = Join-Path (Join-Path $dest 'miner') '9.9.9'
    New-Item -ItemType Directory -Force -Path $fake | Out-Null
    Set-Content -LiteralPath (Join-Path $fake 'wildrig.exe') -Value 'stub'
    Set-Content -LiteralPath (Join-Path (Join-Path $dest 'miner') 'current.txt') -Value '9.9.9'
    $conf = Join-Path $dest 'pearlmine.conf'
    $addr = 'prl1p' + ('q' * 58)
    $seed = 'abandon ability able about above absent absorb abstract absurd abuse access accident'
    $env:PEARLMINE_PROMPT_STDIN = '1'
    try {
        # seed words, then a wrong address, then the real one in capitals, then a worker name
        $o = @($seed, 'prl1pshort', $addr.ToUpperInvariant(), 'gaming-rig') | & $shell -NoProfile -ExecutionPolicy Bypass -File $cli setup 2>&1 | Out-String
        Check 'prompt setup exit' $LASTEXITCODE 0
        $c2 = Read-PearlConfFile $conf
        Check 'prompt saved address (lowercased)' $c2['PRL_WALLET'] $addr
        Check 'prompt saved worker' $c2['PRL_WORKER'] 'gaming-rig'
        Check 'prompt warned about seed words' ($o -match 'looks like seed words') $true
        Check 'prompt explained bad address' ($o -match 'that was 10') $true
        Check 'seed words never echoed' ($o -match 'abandon|absurd') $false
        Check 'seed words never saved' ((Get-Content -LiteralPath $conf -Raw) -match 'abandon') $false
        Check 'prompt points to wallet download' ($o -match 'pearl-research-labs/pearl/releases') $true
        Check 'ready message after prompt' ($o -match 'Ready\. Start with') $true

        # already configured: no prompt on a second run
        $o = @() | & $shell -NoProfile -ExecutionPolicy Bypass -File $cli setup 2>&1 | Out-String
        Check 'no prompt when address set' ($o -match 'Receive address') $false

        # fresh config, Enter skips
        Remove-Item -LiteralPath $conf
        $o = @('') | & $shell -NoProfile -ExecutionPolicy Bypass -File $cli setup 2>&1 | Out-String
        Check 'skip exit' $LASTEXITCODE 0
        Check 'skip message' ($o -match 'Skipped') $true
        Check 'skip leaves address empty' ((Read-PearlConfFile $conf)['PRL_WALLET']) ''
    } finally { Remove-Item Env:\PEARLMINE_PROMPT_STDIN -ErrorAction SilentlyContinue }

    # A broken config is reported in full, not one problem at a time.
    Set-Content -LiteralPath (Join-Path $dest 'pearlmine.conf') -Value @('PRL_WALLET=x', 'PRL_WORKER=my pc')
    $o = & $shell -NoProfile -ExecutionPolicy Bypass -File $cli check 2>&1 | Out-String
    Check 'broken config exit' $LASTEXITCODE 1
    Check 'broken config lists wallet' ($o -match 'PRL_WALLET') $true
    Check 'broken config lists worker' ($o -match 'PRL_WORKER') $true
}
finally { Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue }

Write-Host "$($script:n - $script:fail)/$($script:n) passed"
if ($script:fail) { exit 1 }
