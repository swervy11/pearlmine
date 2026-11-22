<#
pearlmine for Windows - simple on/off/schedule control for Pearl (PRL) GPU mining.

  pearlmine setup      first run: create pearlmine.conf and download the miner
  pearlmine auto       mine only inside your time windows (and while the GPU is free, if enabled)
  pearlmine on         mine 24/7 (starts again when you log in)
  pearlmine off        stop mining
  pearlmine status     mode, hashrate, shares, GPU temperature and power
  pearlmine check      show what the agent would decide right now (changes nothing)
  pearlmine restart    restart the miner in its current mode (after config changes)
  pearlmine log        follow the live miner log (Ctrl+C to exit)
  pearlmine history    what the agent started and stopped recently
  pearlmine balance    pool credits and payouts for your address (pearlhash.xyz)
  pearlmine update     install the newest miner release; "update 0.51.6" picks a version
  pearlmine uninstall  remove the scheduled task and the PATH entry (keeps this folder)
#>
# No param() block: it would swallow -h / --help as unknown parameters.
$Command = 'status'; if ($args.Count -ge 1) { $Command = [string]$args[0] }
$Arg = ''; if ($args.Count -ge 2) { $Arg = [string]$args[1] }
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot 'common.ps1')
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Stop-WithError([string]$Message) { Write-Host "pearlmine: $Message" -ForegroundColor Red; exit 1 }

function Show-Help {
    Get-Content -LiteralPath $PSCommandPath -TotalCount 15 | Select-Object -Skip 1 | ForEach-Object { Write-Host $_ }
}

function Get-Conf {
    $c = Read-PearlConf
    if ($null -eq $c) { Stop-WithError 'no pearlmine.conf yet. Run: pearlmine setup' }
    $problems = @(Get-ConfProblems $c)
    if ($problems.Count -gt 0) { Stop-WithError ("pearlmine.conf needs fixing:`n  " + ($problems -join "`n  ")) }
    return $c
}

function Assert-Miner { if (-not (Get-MinerExe)) { Stop-WithError 'miner not installed. Run: pearlmine setup' } }

# ---- scheduled task --------------------------------------------------------

function Get-AgentTask { return Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue }

function Test-AgentRunning {
    $t = Get-AgentTask
    return ($null -ne $t -and $t.State -eq 'Running')
}

# pearlmine folder an existing task points at ('' if none).
function Get-TaskRoot {
    $t = Get-AgentTask
    if ($null -eq $t) { return '' }
    $a = "$($t.Actions[0].Arguments)"
    if ($a -match '-File "(.+)\\lib\\agent\.ps1"') { return $Matches[1] }
    return ''
}

# If this user's task belongs to a different pearlmine folder, ask, then stop that one cleanly.
function Resolve-OtherTask {
    $other = Get-TaskRoot
    if ($other -and $other -ne $Root) {
        Write-Host 'A pearlmine task from another folder is already set up for you:'
        Write-Host "  $other"
        $yn = Read-Host 'Stop it and replace it with this folder? [y/N]'
        if ($yn -notmatch '^[Yy]$') { Stop-WithError 'left the existing task alone' }
        $otherState = Join-Path $other 'state'
        if (Test-Path -LiteralPath $otherState) { Set-Mode 'off' $otherState }
        Stop-Agent
        Get-MinerProcess (Join-Path $other 'miner') | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

# Register (or refresh) this user's task. It starts the agent at logon, and every 5 minutes as a
# safety net in case the agent died; the agent's mutex makes extra starts exit at once.
# conhost --headless keeps the console hidden even where Windows Terminal is the default terminal.
function Install-AgentTask {
    $agent = Join-Path $PSScriptRoot 'agent.ps1'
    $argLine = "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$agent`""
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $argLine -WorkingDirectory $Root
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $user
    $desc = 'pearlmine: starts and stops the Pearl miner (see pearlmine.conf)'
    try {
        $every = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5) `
            -RepetitionDuration (New-TimeSpan -Days 3650)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($logon, $every) -Principal $principal `
            -Settings $settings -Description $desc -Force | Out-Null
    } catch {
        # Some Windows builds reject the repeating trigger; the logon trigger alone still works.
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $logon -Principal $principal `
            -Settings $settings -Description $desc -Force | Out-Null
    }
}

function Start-Agent {
    if (Test-AgentRunning) { return }
    try { Start-ScheduledTask -TaskName $TaskName }
    catch { Stop-WithError "could not start the $TaskName task: $($_.Exception.Message)" }
}

# Wait for the agent to see mode=off and exit, then make sure no miner from this folder is left.
function Stop-Agent {
    for ($i = 0; $i -lt 20 -and (Test-AgentRunning); $i++) { Start-Sleep -Seconds 1 }
    if (Test-AgentRunning) { try { Stop-ScheduledTask -TaskName $TaskName } catch { $null = $_ } }   # best effort; miners are killed next
    Get-MinerProcess | Stop-Process -Force -ErrorAction SilentlyContinue
}

# ---- miner download ----------------------------------------------------------

$DefenderHint = "`n  Windows Security often blocks or quarantines crypto miners. See 'Windows Security' in`n  windows\README.md, then run: pearlmine update"

function Invoke-FetchMiner([string]$Want) {
    $script:Switched = $false
    $cur = Get-CurrentMinerVersion
    $path = 'latest'; if ($Want) { $path = "tags/$Want" }
    try { $rel = Invoke-RestMethod -UseBasicParsing -Uri "https://api.github.com/repos/$MinerRepo/releases/$path" }
    catch { Stop-WithError "could not read release $(if ($Want) { $Want } else { 'latest' }) from GitHub (does that version exist?)" }
    $asset = @($rel.assets | Where-Object { $_.name -like 'wildrig-multi-windows-*.zip' }) | Select-Object -First 1
    if (-not $asset) { Stop-WithError "release $($rel.tag_name) has no Windows download" }
    $ver = [string]$rel.tag_name
    if ($ver -notmatch '^[0-9A-Za-z._-]+$') { Stop-WithError "unexpected release name '$ver'" }
    Write-Host "Installed: $(if ($cur) { $cur } else { 'none' })   Available: $ver"
    if ($ver -eq $cur -and (Get-MinerExe)) { Write-Host "Already on $ver."; return }
    $digest = ''
    if ($asset.PSObject.Properties['digest'] -and $asset.digest) { $digest = ([string]$asset.digest) -replace '^sha256:', '' }
    if (-not $digest) { Stop-WithError "release $ver publishes no sha256 digest - refusing to install it" }

    $dl = Join-Path $Root 'dl'; New-Item -ItemType Directory -Force -Path $dl | Out-Null
    $zip = Join-Path $dl $asset.name
    Write-Host "Downloading $ver ..."
    $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'     # the progress bar makes 5.1 downloads crawl
    try { Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $zip }
    catch { Stop-WithError "download failed: $($_.Exception.Message)$DefenderHint" }
    finally { $ProgressPreference = $old }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash -ne $digest.ToUpperInvariant()) {
        Remove-Item -Force -LiteralPath $zip; Stop-WithError 'checksum mismatch - download deleted, nothing changed'
    }
    Write-Host 'Checksum OK.'
    $dest = Join-Path $MinerDir $ver
    if (Test-Path -LiteralPath $dest) {
        try { Remove-Item -Recurse -Force -LiteralPath $dest }
        catch { Stop-WithError "could not replace $dest (is that miner still running? run: pearlmine off)" }
    }
    try { Expand-Archive -LiteralPath $zip -DestinationPath $dest }
    catch { Stop-WithError "unpacking failed: $($_.Exception.Message)$DefenderHint" }
    # The bundled .bat files include start scripts that mine to the developer's address. Remove them all.
    Get-ChildItem -LiteralPath $dest -Filter '*.bat' -File -Recurse | Remove-Item -Force
    $exe = Join-Path $dest 'wildrig.exe'
    if (-not (Test-Path -LiteralPath $exe)) { Stop-WithError "wildrig.exe is missing after unpacking.$DefenderHint" }
    $out = Join-Path $dl 'print-devices.txt'; $err = Join-Path $dl 'print-devices.err.txt'
    try {
        $p = Start-Process -FilePath $exe -ArgumentList '--print-devices' -NoNewWindow -PassThru `
            -RedirectStandardOutput $out -RedirectStandardError $err
    } catch { Stop-WithError "could not run the miner: $($_.Exception.Message)$DefenderHint" }
    if (-not $p.WaitForExit(60000)) { $p.Kill() }
    if (-not (Select-String -LiteralPath $out, $err -Pattern 'GPU #' -Quiet)) {
        Stop-WithError "miner $ver does not detect any GPU on this machine - not switching to it"
    }
    Get-Content -LiteralPath $out | Where-Object { $_ -match 'GPU #' } | ForEach-Object { Write-Host "  $_" }
    Set-Content -LiteralPath (Join-Path $MinerDir 'current.txt') -Value $ver -Encoding Ascii
    $script:Switched = $true
    Write-Host "Miner $ver is now active.$(if ($cur) { " $cur is kept; roll back with: pearlmine update $cur" })"
}

# ---- commands ----------------------------------------------------------------

function Invoke-Setup {
    if (-not (Test-Path -LiteralPath $ConfPath)) {
        Copy-Item -LiteralPath (Join-Path $Root 'pearlmine.conf.example') -Destination $ConfPath
        Write-Host 'Created pearlmine.conf.'
    }
    if (-not (Get-MinerExe)) { Invoke-FetchMiner '' }
    $c = Read-PearlConf
    if (Test-Wallet (Get-Opt $c 'PRL_WALLET')) { Write-Host 'Ready. Start with: pearlmine auto   (or: pearlmine on)' }
    else { Write-Host "Next: run 'notepad `"$ConfPath`"', set PRL_WALLET to your public receive address, then run: pearlmine auto" }
}

function Invoke-Start([string]$Mode) {
    $c = Get-Conf; Assert-Miner
    Resolve-OtherTask
    # Stop the running agent and any leftover miner, so new settings, scripts and task options all apply.
    Set-Mode 'off'; Stop-Agent
    Install-AgentTask
    Set-Mode $Mode
    Start-Agent
    if ($Mode -eq 'on') {
        Write-Host 'Mining on, 24/7 (starts again when you log in).'
    } else {
        $msg = "Auto mode on: nightly $(Get-Opt $c 'NIGHT_START' '22:00')-$(Get-Opt $c 'NIGHT_END' '06:00')"
        if ((Get-Opt $c 'DAY_WINDOW' '0') -eq '1') { $msg += ", plus $(Get-Opt $c 'DAY_START' '09:00')-$(Get-Opt $c 'DAY_END' '17:00') on days $(Get-Opt $c 'DAY_WINDOW_DAYS' '1 2 3 4 5')" }
        $msg += ' (local time)'
        if ((Get-Opt $c 'PAUSE_WHEN_GPU_BUSY' '0') -eq '1') { $msg += ', paused while another program computes on the GPU' }
        Write-Host "$msg."
    }
    $pf = Get-Opt $c 'PAUSE_FOR_PROGRAMS'
    if ($pf) { Write-Host "Pauses while any of these run: $pf" }
}

function Invoke-Status {
    $m = Get-Mode; if ($null -eq $m) { $m = 'off' }
    $mode = $m; if ($m -eq 'on') { $mode = '24/7' }
    $mining = 'not mining'; if (@(Get-MinerProcess).Count -gt 0) { $mining = 'mining now' }
    $agent = 'agent not running'; if (Test-AgentRunning) { $agent = 'agent running' }
    Write-Host "Mode:   $mode ($mining, $agent)"
    if (Test-NvidiaSmi) {
        Invoke-Nvsmi --query-gpu=index,name,temperature.gpu,power.draw,power.limit,utilization.gpu,fan.speed --format=csv,noheader |
            ForEach-Object {
                $f = $_ -split ', '
                if ($f.Count -ge 7) { Write-Host ("GPU {0}:  {1}  {2} C  {3} / {4}  load {5}  fan {6}" -f $f[0], $f[1], $f[2], $f[3], $f[4], $f[5], $f[6]) }
            }
    } else {
        Write-Host 'GPU:    no nvidia-smi found (GPU readings and busy detection are NVIDIA-only)'
    }
    $ver = Get-CurrentMinerVersion; if (-not $ver) { $ver = '?' }
    if (Test-Path -LiteralPath $MinerLog) {
        $line = Get-Content -LiteralPath $MinerLog -Tail 400 | ForEach-Object { $_ -replace '\x1b\[[0-9;]*m', '' } |
                Where-Object { $_ -match '\] +10s:' } | Select-Object -Last 1
        $h = 'no hashrate yet'; $a = '0'
        if ($line -and $line -match '([0-9.]+ [kMGTP]?H/s)') { $h = $Matches[1] }
        if ($line -and $line -match 'Accepted: +([0-9]+)') { $a = $Matches[1] }
        Write-Host "Miner:  $h   accepted shares: $a   ($ver)"
    } else {
        Write-Host "Miner:  no log yet   ($ver)"
    }
    $c = Read-PearlConf
    if ($c) { $p = @(Get-ConfProblems $c); if ($p.Count -gt 0) { Write-Host "Config: $($p -join '; ')" -ForegroundColor Yellow } }
}

function Invoke-Check {
    $c = Get-Conf
    $m = Get-Mode
    if ($null -eq $m -or $m -eq 'off') { Write-Host 'Mode is off; showing what auto mode would do.'; $m = 'auto' }
    $now = Get-Date
    $raw = @(Get-RawGpuApps $c); $apps = @()
    if ((Get-Opt $c 'PAUSE_WHEN_GPU_BUSY' '0') -eq '1') { $apps = Select-OtherGpuApps $raw (Get-Opt $c 'IGNORE_GPU_PROCS') }
    $paused = Select-PausePrograms (Get-Opt $c 'PAUSE_FOR_PROGRAMS') @(Get-Process | ForEach-Object { $_.ProcessName })
    $d = Get-Decision $c $m ($now.Hour * 60 + $now.Minute) (Get-IsoDow $now) $apps $paused
    $verb = 'stay off'; if ($d.Want) { $verb = 'mine' }
    Write-Host "Now $($now.ToString('ddd HH:mm')), mode $m -> $verb ($($d.Why))"
    if ($raw.Count -gt 0) {
        Write-Host 'Programs nvidia-smi reports on the GPU:'
        $raw | ForEach-Object { Write-Host "  $_" }
    }
}

function Invoke-Balance {
    $c = Get-Conf; $a = Get-Opt $c 'PRL_WALLET'
    try {
        $acct = Invoke-RestMethod -UseBasicParsing -Uri "https://pearlhash.xyz/api/account/$a" -UserAgent 'pearlmine'
        $price = 0.0
        $pr = Invoke-RestMethod -UseBasicParsing -Uri 'https://pearlhash.xyz/api/pearl-price' -UserAgent 'pearlmine'
        if ($pr.PSObject.Properties['usd'] -and $pr.usd) { $price = [double]$pr.usd }
    } catch { Stop-WithError "pool lookup failed: $($_.Exception.Message)" }
    $credited = 0.0; $paid = 0.0
    $tx = @(); if ($acct.PSObject.Properties['balance_transactions'] -and $acct.balance_transactions) { $tx = @($acct.balance_transactions) }
    foreach ($t in $tx) {
        $v = 0.0
        foreach ($k in 'amount', 'value', 'prl', 'credit') {
            if ($t.PSObject.Properties[$k] -and ($t.$k -is [double] -or $t.$k -is [int] -or $t.$k -is [long] -or $t.$k -is [decimal])) { $v = [double]$t.$k; break }
        }
        if ($v -gt 0) { $credited += $v } else { $paid -= $v }
    }
    $workers = @(); if ($acct.PSObject.Properties['connected_workers'] -and $acct.connected_workers) { $workers = @($acct.connected_workers) }
    $hr = 0.0
    foreach ($w in $workers) {
        if ($w.PSObject.Properties['gpu_info']) { foreach ($g in @($w.gpu_info)) { if ($g.PSObject.Properties['hashrate']) { $hr += [double]$g.hashrate } } }
    }
    $pending = $credited - $paid
    Write-Host ("Pool (pearlhash.xyz):  {0} worker(s) online, {1:N1} TH/s" -f $workers.Count, ($hr / 1e12))
    Write-Host ("  credited:        {0:N4} PRL" -f $credited)
    Write-Host ("  paid out:        {0:N4} PRL" -f $paid)
    Write-Host ("  pending at pool: {0:N4} PRL" -f $pending)
    Write-Host ("  price:           `${0:N4} per PRL  (pending is about `${1:N2})" -f $price, ($pending * $price))
    Write-Host "Pool page:  https://pearlhash.xyz/account/$a"
    Write-Host "On-chain:   https://explorer.pearlresearch.ai/address/$($a)?network=mainnet"
}

switch ($Command.ToLowerInvariant()) {
    'setup'   { Invoke-Setup }
    'auto'    { Invoke-Start 'auto' }
    'night'   { Invoke-Start 'auto' }
    'on'      { Invoke-Start 'on' }
    'off'     { Set-Mode 'off'; Stop-Agent; Write-Host 'Mining off.' }
    'status'  { Invoke-Status }
    'check'   { Invoke-Check }
    'restart' {
        $m = Get-Mode
        if ($null -eq $m -or $m -eq 'off') { Write-Host 'Mining is off - nothing to restart. Use: pearlmine on   or: pearlmine auto'; break }
        Invoke-Start $m
    }
    'log'     { if (-not (Test-Path -LiteralPath $MinerLog)) { Stop-WithError 'no log yet' }; Get-Content -LiteralPath $MinerLog -Tail 30 -Wait }
    'history' { if (Test-Path -LiteralPath $AgentLog) { Get-Content -LiteralPath $AgentLog -Tail 30 } else { Write-Host 'no history yet' } }
    'balance' { Invoke-Balance }
    'update'  {
        Invoke-FetchMiner $Arg
        if ($script:Switched -and @(Get-MinerProcess).Count -gt 0) {
            New-Item -ItemType File -Force -Path (Join-Path $StateDir 'restart') | Out-Null
            Write-Host 'The agent restarts the miner on the new version within a few seconds.'
        }
    }
    'uninstall' {
        Set-Mode 'off'; Stop-Agent
        if (Get-AgentTask) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Host "Removed the $TaskName task." }
        if (Update-UserPath $Root -Remove) { Write-Host 'Removed pearlmine from your PATH.' }
        Write-Host "The folder $Root is untouched; delete it yourself if you want."
    }
    '_path-add' {     # internal: used by install.ps1
        if (Update-UserPath $Root) { Write-Host 'Added to your PATH. Open a new terminal to use the "pearlmine" command from anywhere.' }
    }
    { $_ -in 'help', '-h', '--help', '/?' } { Show-Help }
    default   { Show-Help; exit 1 }
}
