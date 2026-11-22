# Shared by pearlmine.ps1 and agent.ps1. Dot-sourced, not run directly.
# Must stay compatible with Windows PowerShell 5.1 and plain ASCII (5.1 reads BOM-less files as ANSI).

$script:Root      = Split-Path -Parent $PSScriptRoot
$script:ConfPath  = Join-Path $script:Root 'pearlmine.conf'
$script:StateDir  = Join-Path $script:Root 'state'
$script:LogDir    = Join-Path $script:Root 'logs'
$script:MinerDir  = Join-Path $script:Root 'miner'
$script:MinerLog  = Join-Path $script:LogDir 'miner.log'
$script:AgentLog  = Join-Path $script:LogDir 'agent.log'
$script:MinerRepo = 'andru-kun/wildrig-multi'
$script:WalletRe  = '^prl1p[0-9a-z]{58}$'
# One task per Windows user, so two accounts on one PC do not overwrite each other.
$script:TaskName  = 'pearlmine-' + ("$env:USERNAME" -replace '[\\/:*?"<>|]', '_')

# ---- config --------------------------------------------------------------

# Parse KEY=value lines. Quoted values keep everything inside the quotes; for unquoted
# values a " #" starts a comment, so `TEMP_LIMIT=80   # degrees` reads as 80.
function Read-PearlConf([string]$Path = $script:ConfPath) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $c = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $t.Substring(0, $i).Trim()
        $v = $t.Substring($i + 1).Trim()
        if ($v.Length -ge 1 -and ($v[0] -eq '"' -or $v[0] -eq "'")) {
            $end = $v.IndexOf($v[0], 1)
            if ($end -gt 0) { $v = $v.Substring(1, $end - 1) } else { $v = $v.Substring(1) }
        } else {
            $v = ($v -replace '\s+#.*$', '').Trim()
        }
        $c[$k] = $v
    }
    return $c
}

# Config value with a default for missing or empty keys.
function Get-Opt($Conf, [string]$Key, [string]$Default = '') {
    if ($Conf -and $Conf.ContainsKey($Key) -and $Conf[$Key] -ne '') { return [string]$Conf[$Key] }
    return $Default
}

function Test-Wallet([string]$Address) { return [bool]($Address -cmatch $script:WalletRe) }

function Test-Regex([string]$Pattern) {
    try { [void][regex]::new($Pattern); return $true } catch { return $false }
}

# Everything wrong with a config, as readable messages. Empty when it is fine.
function Get-ConfProblems($Conf) {
    $p = @()
    if (-not (Test-Wallet (Get-Opt $Conf 'PRL_WALLET'))) { $p += 'PRL_WALLET is not a 63-character prl1p address' }
    if ((Get-Opt $Conf 'PRL_WORKER' 'pc1') -notmatch '^[A-Za-z0-9._-]{1,64}$') { $p += 'PRL_WORKER may only use letters, digits, dot, dash and underscore' }
    if ((Get-Opt $Conf 'PRL_POOL' 'pool.pearlhash.xyz:9000') -notmatch '^([a-z0-9+]+://)?[A-Za-z0-9.-]+:\d{1,5}$') { $p += 'PRL_POOL must look like host:port' }
    foreach ($k in 'TEMP_LIMIT', 'TEMP_RESUME') {
        if ((Get-Opt $Conf $k '80') -notmatch '^\d{2,3}$') { $p += "$k must be a temperature in degrees C" }
    }
    foreach ($k in 'NIGHT_START', 'NIGHT_END', 'DAY_START', 'DAY_END') {
        $v = Get-Opt $Conf $k '00:00'
        if ($v -notmatch '^\d{1,2}(:\d{2})?$' -or (ConvertTo-Minutes $v) -ge 1440) { $p += "$k must be a time like 22:00" }
    }
    $ig = Get-Opt $Conf 'IGNORE_GPU_PROCS'
    if ($ig -and -not (Test-Regex $ig)) { $p += 'IGNORE_GPU_PROCS is not a valid regular expression' }
    return $p
}

# Set KEY=value in a config file: replaces the first KEY= line, or appends one. Other lines are untouched.
# Only call it with values already checked to be plain (addresses, worker names).
function Set-ConfValue([string]$Path, [string]$Key, [string]$Value) {
    $lines = @(Get-Content -LiteralPath $Path)
    $done = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $done -and $lines[$i] -match "^\s*$([regex]::Escape($Key))\s*=") { $lines[$i] = "$Key=$Value"; $done = $true }
    }
    if (-not $done) { $lines += "$Key=$Value" }
    [IO.File]::WriteAllLines($Path, [string[]]$lines)
}

# True when pasted text looks like a wallet's seed words (many plain words) rather than an address.
function Test-SeedLike([string]$Text) {
    $w = @($Text.Trim() -split '\s+' | Where-Object { $_ -match '^[A-Za-z]+$' })
    return ($w.Count -ge 8)
}

# A pool worker name from a computer name: lowercase, only [a-z0-9._-], at most 32 characters.
function ConvertTo-WorkerName([string]$Name, [string]$Default = 'pc1') {
    $n = ($Name.ToLowerInvariant() -replace '[^a-z0-9._-]+', '-').Trim('-', '.', '_')
    if ($n.Length -gt 32) { $n = $n.Substring(0, 32).Trim('-', '.', '_') }
    if (-not $n) { return $Default }
    return $n
}

# ---- schedule ------------------------------------------------------------

function ConvertTo-Minutes([string]$HHMM) {
    if ($HHMM -notmatch ':') { $HHMM = "$($HHMM):00" }
    $p = $HHMM.Split(':')
    return ([int]$p[0]) * 60 + [int]$p[1]
}

# True when minute-of-day $Now is inside start..end. Windows may cross midnight; start == end is empty.
function Test-InWindow([int]$Now, [string]$Start, [string]$End) {
    $s = ConvertTo-Minutes $Start; $e = ConvertTo-Minutes $End
    if ($s -eq $e) { return $false }
    if ($s -gt $e) { return ($Now -ge $s -or $Now -lt $e) }
    return ($Now -ge $s -and $Now -lt $e)
}

# 1 = Monday ... 7 = Sunday, same numbering as the Linux version.
function Get-IsoDow([datetime]$When) { $d = [int]$When.DayOfWeek; if ($d -eq 0) { return 7 }; return $d }

function Split-List([string]$Text) { return @($Text -split '[\s,]+' | Where-Object { $_ -ne '' }) }

# Pure decision used by the agent and by `pearlmine check`.
#   Mode       : on | auto
#   Now/Dow    : minute of day, ISO weekday
#   GpuApps    : names of other programs computing on the GPU (already filtered)
#   PausedBy   : names of PAUSE_FOR_PROGRAMS entries that are running
function Get-Decision($Conf, [string]$Mode, [int]$Now, [int]$Dow, [string[]]$GpuApps, [string[]]$PausedBy) {
    $GpuApps = @($GpuApps | Where-Object { $_ })
    $PausedBy = @($PausedBy | Where-Object { $_ })
    if ($PausedBy.Count -gt 0) {
        return @{ Want = $false; Why = "paused while running: $($PausedBy -join ', ')" }
    }
    if ($Mode -eq 'on') { return @{ Want = $true; Why = '24/7 mode' } }

    $in = $false; $why = ''
    if (Test-InWindow $Now (Get-Opt $Conf 'NIGHT_START' '22:00') (Get-Opt $Conf 'NIGHT_END' '06:00')) {
        $in = $true; $why = 'night window'
    }
    if ((Get-Opt $Conf 'DAY_WINDOW' '0') -eq '1' -and
        (Split-List (Get-Opt $Conf 'DAY_WINDOW_DAYS' '1 2 3 4 5')) -contains [string]$Dow -and
        (Test-InWindow $Now (Get-Opt $Conf 'DAY_START' '09:00') (Get-Opt $Conf 'DAY_END' '17:00'))) {
        $in = $true; $why = 'day window'
    }
    if (-not $in) { return @{ Want = $false; Why = 'outside mining windows' } }
    if ($GpuApps.Count -gt 0) { return @{ Want = $false; Why = "GPU in use by: $($GpuApps -join ', ')" } }
    return @{ Want = $true; Why = "$why, GPU free" }
}

# Filter raw nvidia-smi compute-app names: drop the miner itself and IGNORE_GPU_PROCS matches.
# An invalid IGNORE_GPU_PROCS pattern is ignored here (Get-ConfProblems reports it).
function Select-OtherGpuApps([string[]]$Raw, [string]$IgnoreRegex) {
    $skip = 'wildrig'
    if ($IgnoreRegex -and (Test-Regex $IgnoreRegex)) { $skip = "$skip|$IgnoreRegex" }
    return @($Raw | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne '' -and $_ -notmatch $skip } |
             ForEach-Object { ($_ -split '[\\/]')[-1] })
}

# Which PAUSE_FOR_PROGRAMS names (with or without .exe) are in a list of running process names.
function Select-PausePrograms([string]$List, [string[]]$Running) {
    $have = @{}
    foreach ($r in $Running) { $have[$r.ToLowerInvariant()] = $true }
    return @(Split-List $List | ForEach-Object { ($_ -replace '\.exe$', '') } |
             Where-Object { $have.ContainsKey($_.ToLowerInvariant()) })
}

# ---- state ---------------------------------------------------------------

# on | auto | off, or $null when the file is missing, empty, half-written or locked.
function Get-Mode([string]$Dir = $script:StateDir) {
    $f = Join-Path $Dir 'mode'
    try {
        if (-not (Test-Path -LiteralPath $f)) { return $null }
        $m = "$(Get-Content -LiteralPath $f -Raw -ErrorAction Stop)".Trim()
        if ($m -in @('on', 'auto', 'off')) { return $m }
    } catch { $null = $_ }      # locked or half-written: report "unknown" and let the caller decide
    return $null
}

# Write the mode atomically (temp file + replace) so the agent never reads a half-written file.
function Set-Mode([string]$Mode, [string]$Dir = $script:StateDir) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $f = Join-Path $Dir 'mode'
    $tmp = Join-Path $Dir ("mode." + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($tmp, $Mode)      # note: $null would become "" for .NET string args, hence [NullString] below
    for ($i = 0; ; $i++) {      # the agent may be reading the file this instant; retry briefly
        try {
            if (Test-Path -LiteralPath $f) { [IO.File]::Replace($tmp, $f, [NullString]::Value) } else { [IO.File]::Move($tmp, $f) }
            return
        } catch {
            if ($i -ge 20) { Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue; throw }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Write-AgentLog([string]$Message) {
    New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    if ((Test-Path -LiteralPath $script:AgentLog) -and (Get-Item -LiteralPath $script:AgentLog).Length -gt 5MB) {
        Move-Item -Force -LiteralPath $script:AgentLog -Destination "$($script:AgentLog).1"
    }
    Add-Content -LiteralPath $script:AgentLog -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding Ascii
}

# ---- miner ---------------------------------------------------------------

function Get-CurrentMinerVersion {
    $f = Join-Path $script:MinerDir 'current.txt'
    if (Test-Path -LiteralPath $f) { return "$(Get-Content -LiteralPath $f -Raw)".Trim() }
    return ''
}

function Get-MinerExe {
    $v = Get-CurrentMinerVersion
    if (-not $v) { return $null }
    $exe = Join-Path (Join-Path $script:MinerDir $v) 'wildrig.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    return $null
}

# Miner processes started from a pearlmine miner folder (this one by default), any version.
function Get-MinerProcess([string]$Dir = $script:MinerDir) {
    $sep = [IO.Path]::DirectorySeparatorChar
    $prefix = $Dir.TrimEnd($sep) + $sep
    return @(Get-Process -Name 'wildrig' -ErrorAction SilentlyContinue |
             Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
}

# Command-line string for wildrig.exe. Values are checked by Get-ConfProblems; the log path is quoted.
function Get-MinerArgs($Conf) {
    $a = @(
        '--algo', 'pearlhash',
        '--url', (Get-Opt $Conf 'PRL_POOL' 'pool.pearlhash.xyz:9000'),
        '--user', (Get-Opt $Conf 'PRL_WALLET'),
        '--worker', (Get-Opt $Conf 'PRL_WORKER' 'pc1'),
        '--print-time', '60',
        '--gpu-temp-limit', (Get-Opt $Conf 'TEMP_LIMIT' '82'),
        '--gpu-temp-resume', (Get-Opt $Conf 'TEMP_RESUME' '65'),
        '--log-file', ('"' + $script:MinerLog + '"')
    )
    $extra = Get-Opt $Conf 'MINER_EXTRA_ARGS'
    if ($extra) { $a += $extra }
    return ($a -join ' ')
}

# ---- GPU (NVIDIA only, read-only) ------------------------------------------

function Test-NvidiaSmi { return [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue) }

# Run nvidia-smi and return its stdout lines. Never throws: Windows PowerShell 5.1 turns stderr
# into terminating errors when the caller uses ErrorActionPreference=Stop, so shield it here.
function Invoke-Nvsmi {
    if (-not (Test-NvidiaSmi)) { return @() }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { return @(& nvidia-smi @args 2>$null | ForEach-Object { "$_" }) }
    catch { return @() }
    finally { $ErrorActionPreference = $old }
}

function Get-GpuList($Conf) {
    $spec = Get-Opt $Conf 'GPUS' 'all'
    if ($spec -eq 'all') {
        return @(Invoke-Nvsmi --query-gpu=index --format=csv,noheader | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
    }
    return @(Split-List $spec | Where-Object { $_ -match '^\d+$' })
}

function Get-RawGpuApps($Conf) {
    $ids = @(Get-GpuList $Conf)
    if ($ids.Count -eq 0) { return @() }
    return @(Invoke-Nvsmi -i ($ids -join ',') --query-compute-apps=process_name --format=csv,noheader)
}

# ---- PATH ----------------------------------------------------------------

# Add or remove a folder in the user's PATH. Reads the raw registry value so entries such as
# %USERPROFILE%\bin stay unexpanded, and writes it back as REG_EXPAND_SZ. Returns $true if changed.
function Update-UserPath([string]$Dir, [switch]$Remove) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        $cur = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $parts = @($cur -split ';' | Where-Object { $_ -ne '' })
        $has = $parts -contains $Dir
        if ($Remove) {
            if (-not $has) { return $false }
            $parts = @($parts | Where-Object { $_ -ne $Dir })
        } else {
            if ($has) { return $false }
            $parts += $Dir
        }
        $key.SetValue('Path', ($parts -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally { $key.Close() }
    # Setting any user variable makes Windows tell Explorer the environment changed, so new terminals see it.
    [Environment]::SetEnvironmentVariable('PEARLMINE_PATH_REFRESH', '1', 'User')
    [Environment]::SetEnvironmentVariable('PEARLMINE_PATH_REFRESH', $null, 'User')
    return $true
}
