# Tests for the Windows scheduling logic. Runs on Windows PowerShell 5.1 or PowerShell 7 (also on Linux/macOS):
#   powershell -ExecutionPolicy Bypass -File tests\test_windows.ps1
#   pwsh tests/test_windows.ps1
# Touches no GPU, task or miner.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2      # same as pearlmine.ps1
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'windows/lib/common.ps1')

$script:fail = 0; $script:n = 0
function Check([string]$Name, $Got, $Want) {
    $script:n++
    if ("$Got" -ne "$Want") { $script:fail++; Write-Host "FAIL  $Name  got '$Got' want '$Want'" }
}

# Every script must parse.
foreach ($f in Get-ChildItem -Recurse -LiteralPath (Join-Path $repo 'windows') -Filter *.ps1) {
    $errs = $null
    [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs) | Out-Null
    Check "parse $($f.Name)" $errs.Count 0
    # Windows PowerShell 5.1 reads BOM-less files as ANSI, so keep them ASCII.
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    Check "ascii $($f.Name)" (@($bytes | Where-Object { $_ -gt 127 }).Count) 0
}

# Config parsing
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("pm-test-" + [guid]::NewGuid().ToString('N') + '.conf')
Set-Content -LiteralPath $tmp -Encoding Ascii -Value @(
    '# comment', '', ('PRL_WALLET=prl1p' + ('a' * 58)), 'DAY_WINDOW_DAYS="1 2 3"', "IGNORE_GPU_PROCS='chrome|msedge'",
    'EMPTY=', 'POWER_LIMIT_W=  160  ', 'NOEQUALS', 'MINER_EXTRA_ARGS="-d 0,1"',
    'TEMP_LIMIT=80   # degrees', 'PRL_WORKER="pc-2"  # quoted then comment', 'PAUSE_FOR_PROGRAMS="a #b"')
$c = Read-PearlConf $tmp
Remove-Item -LiteralPath $tmp
Check 'conf wallet valid' (Test-Wallet $c['PRL_WALLET']) $true
Check 'conf double quotes' $c['DAY_WINDOW_DAYS'] '1 2 3'
Check 'conf single quotes' $c['IGNORE_GPU_PROCS'] 'chrome|msedge'
Check 'conf trims' $c['POWER_LIMIT_W'] '160'
Check 'conf empty -> default' (Get-Opt $c 'EMPTY' 'dflt') 'dflt'
Check 'conf missing -> default' (Get-Opt $c 'NOPE' 'x') 'x'
Check 'conf skips junk' $c.ContainsKey('NOEQUALS') $false
Check 'conf inline comment stripped' $c['TEMP_LIMIT'] '80'
Check 'conf quoted then comment' $c['PRL_WORKER'] 'pc-2'
Check 'conf hash inside quotes kept' $c['PAUSE_FOR_PROGRAMS'] 'a #b'
Check 'conf problems none' (@(Get-ConfProblems $c).Count) 0
Check 'wallet uppercase rejected' (Test-Wallet ('prl1p' + ('A' * 58))) $false
Check 'wallet short rejected' (Test-Wallet 'prl1pabc') $false
Check 'missing conf' ($null -eq (Read-PearlConf (Join-Path $repo 'no-such.conf'))) $true

# Config validation
$good = @{ PRL_WALLET = 'prl1p' + ('a' * 58) }
Check 'valid defaults' (@(Get-ConfProblems $good).Count) 0
$bad = @{ PRL_WALLET = 'nope'; PRL_WORKER = 'my pc'; PRL_POOL = 'pool --x'; TEMP_LIMIT = 'hot'; NIGHT_START = '25:00'; DAY_END = 'noon'; IGNORE_GPU_PROCS = 'chrome(' }
$probs = @(Get-ConfProblems $bad)
Check 'invalid config: 7 problems' $probs.Count 7
Check 'pool with scheme ok' (@(Get-ConfProblems @{ PRL_WALLET = $good.PRL_WALLET; PRL_POOL = 'stratum+tcp://pool.example.com:3333' }).Count) 0
Check 'bad regex ignored by filter' ((Select-OtherGpuApps @('C:\x\ollama.exe') 'chrome(') -join ',') 'ollama.exe'

# Mode file: atomic write, unreadable -> $null
$sd = Join-Path ([IO.Path]::GetTempPath()) ("pm-state-" + [guid]::NewGuid().ToString('N'))
Check 'mode missing' ($null -eq (Get-Mode $sd)) $true
Set-Mode 'on' $sd;   Check 'mode on' (Get-Mode $sd) 'on'
Set-Mode 'auto' $sd; Check 'mode replaced' (Get-Mode $sd) 'auto'
Check 'no temp files left' (@(Get-ChildItem -LiteralPath $sd -Filter '*.tmp').Count) 0
Set-Content -LiteralPath (Join-Path $sd 'mode') -Value '' -NoNewline
Check 'mode empty -> null' ($null -eq (Get-Mode $sd)) $true
Set-Content -LiteralPath (Join-Path $sd 'mode') -Value 'banana'
Check 'mode junk -> null' ($null -eq (Get-Mode $sd)) $true
Remove-Item -Recurse -Force -LiteralPath $sd

# Task name is per user and safe
Check 'task name per user' ($TaskName -like 'pearlmine-*') $true
Check 'task name has no bad chars' ($TaskName -notmatch '[\\/:*?"<>|]') $true

# Time helpers
Check 'minutes 08:09' (ConvertTo-Minutes '08:09') 489
Check 'minutes bare hour' (ConvertTo-Minutes '7') 420
Check 'dow sunday' (Get-IsoDow ([datetime]'2026-11-22')) 7
Check 'dow monday' (Get-IsoDow ([datetime]'2026-11-23')) 1

# Decisions: [name, conf, mode, HH:MM, dow, gpuApps, pausedBy, want]
$night = @{ NIGHT_START = '22:00'; NIGHT_END = '06:00' }
$work  = @{ NIGHT_START = '22:00'; NIGHT_END = '06:00'; DAY_WINDOW = '1'; DAY_WINDOW_DAYS = '1 2 3 4 5'; DAY_START = '06:00'; DAY_END = '16:30' }
$cases = @(
    @('night 23:00',            $night, 'auto', '23:00', 3, @(), @(), $true),
    @('night 05:59',            $night, 'auto', '05:59', 3, @(), @(), $true),
    @('night end 06:00',        $night, 'auto', '06:00', 3, @(), @(), $false),
    @('night start 22:00',      $night, 'auto', '22:00', 3, @(), @(), $true),
    @('before night 21:59',     $night, 'auto', '21:59', 3, @(), @(), $false),
    @('midday no day window',   $night, 'auto', '12:00', 3, @(), @(), $false),
    @('weekday work 16:29',     $work,  'auto', '16:29', 2, @(), @(), $true),
    @('weekday work end 16:30', $work,  'auto', '16:30', 2, @(), @(), $false),
    @('saturday 12:00',         $work,  'auto', '12:00', 6, @(), @(), $false),
    @('saturday 05:59 night',   $work,  'auto', '05:59', 6, @(), @(), $true),
    @('gpu busy in window',     $night, 'auto', '23:00', 3, @('ollama.exe'), @(), $false),
    @('24/7 midday',            $night, 'on',   '12:00', 3, @(), @(), $true),
    @('24/7 ignores gpu apps',  $night, 'on',   '12:00', 3, @('x.exe'), @(), $true),
    @('24/7 paused for game',   $night, 'on',   '12:00', 3, @(), @('cs2'), $false),
    @('auto paused for game',   $night, 'auto', '23:00', 3, @(), @('cs2'), $false),
    @('empty window',           @{ NIGHT_START = '22:00'; NIGHT_END = '22:00' }, 'auto', '23:00', 3, @(), @(), $false),
    @('defaults',               @{}, 'auto', '01:00', 1, @(), @(), $true)
)
foreach ($t in $cases) {
    $d = Get-Decision $t[1] $t[2] (ConvertTo-Minutes $t[3]) $t[4] $t[5] $t[6]
    Check "decide $($t[0]) ($($d.Why))" $d.Want $t[7]
}

# GPU app filtering and pause-program matching
$raw = @('C:\Program Files\Ollama\ollama.exe', 'C:\pm\miner\0.52.3\wildrig.exe', ' ', 'C:\Apps\chrome.exe')
Check 'gpu filter drops miner + ignored' ((Select-OtherGpuApps $raw 'chrome') -join ',') 'ollama.exe'
Check 'gpu filter no ignore' ((Select-OtherGpuApps $raw '') -join ',') 'ollama.exe,chrome.exe'
Check 'gpu filter empty' (@(Select-OtherGpuApps @() '').Count) 0
Check 'pause match' ((Select-PausePrograms 'CS2.exe blender, steam' @('cs2', 'explorer', 'Blender')) -join ',') 'CS2,blender'
Check 'pause none' (@(Select-PausePrograms '' @('cs2')).Count) 0

# Miner command line
$args1 = Get-MinerArgs @{ PRL_WALLET = 'prl1pw'; PRL_WORKER = 'rtx4070s'; MINER_EXTRA_ARGS = '-d 0' }
Check 'args worker' ($args1 -match '--worker rtx4070s') $true
Check 'args log quoted' ($args1 -match '--log-file ".+miner\.log"') $true
Check 'args extra last' ($args1.EndsWith(' -d 0')) $true
Check 'args default pool' ($args1 -match '--url pool\.pearlhash\.xyz:9000') $true

Write-Host "$($script:n - $script:fail)/$($script:n) passed"
if ($script:fail) { exit 1 }
