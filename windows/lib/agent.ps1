# pearlmine agent: runs hidden from the user's "pearlmine-<user>" scheduled task.
# Every 2 seconds it reads state\mode; every 30 seconds it re-reads pearlmine.conf and decides:
#   mode on   : mine all the time (except while a PAUSE_FOR_PROGRAMS program runs)
#   mode auto : mine inside the time windows (and while the GPU is free, if enabled)
#   mode off  : stop the miner and exit
# It also restarts the miner if it exits, backing off if it keeps exiting straight away.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')

$mutex = New-Object Threading.Mutex($false, 'Local\pearlmine-agent')
if (-not $mutex.WaitOne(0)) { exit 0 }      # an agent is already running in this session

$CheckSeconds = 30
$QuickExit    = 90      # a miner that dies sooner than this after starting counts as a failed start
$MaxQuick     = 3       # after this many failed starts in a row, wait BackoffMin before trying again
$BackoffMin   = 10
$restartFlag  = Join-Path $StateDir 'restart'

$script:last = ''
function Write-Once([string]$Message) {      # log a state, not every repeat of it
    if ($Message -ne $script:last) { Write-AgentLog $Message }
    $script:last = $Message
}

function Stop-Miner([string]$Why) {
    $p = @(Get-MinerProcess)
    if ($p.Count -eq 0) { return }
    Write-AgentLog "$Why -> stopping miner"
    $p | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $script:startedAt = $null
}

$script:startedAt = $null; $script:quick = 0; $script:holdUntil = [datetime]::MinValue
function Start-Miner($Conf, [string]$Why) {
    if ((Get-Date) -lt $script:holdUntil) { return }
    if ($script:startedAt -and ((Get-Date) - $script:startedAt).TotalSeconds -lt $QuickExit) { $script:quick++ } else { $script:quick = 0 }
    if ($script:quick -ge $MaxQuick) {
        $script:holdUntil = (Get-Date).AddMinutes($BackoffMin); $script:quick = 0; $script:startedAt = $null
        Write-AgentLog "the miner keeps exiting right after it starts; see logs\miner.log. Trying again in $BackoffMin minutes"
        return
    }
    $exe = Get-MinerExe
    if (-not $exe) {
        Write-Once 'miner not found (run: pearlmine update). If Windows Security removed it, see windows\README.md'
        return
    }
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    if ((Test-Path -LiteralPath $MinerLog) -and (Get-Item -LiteralPath $MinerLog).Length -gt 20MB) {
        Move-Item -Force -LiteralPath $MinerLog -Destination "$MinerLog.1"
    }
    try {
        Start-Process -FilePath $exe -ArgumentList (Get-MinerArgs $Conf) -WorkingDirectory (Split-Path -Parent $exe) `
            -WindowStyle Hidden -ErrorAction Stop | Out-Null
        Write-AgentLog "$Why -> starting miner"
        $script:startedAt = Get-Date
    } catch {
        Write-Once "could not start the miner: $($_.Exception.Message). If Windows Security blocked it, see windows\README.md"
        $script:startedAt = Get-Date
    }
}

Write-AgentLog "agent started (pid $PID)"
# A miner left over from an agent that was killed is not ours to adopt: its settings may be stale.
Stop-Miner 'agent start, clearing a leftover miner'
$mode = Get-Mode
$next = [datetime]::MinValue
try {
    while ($true) {
        $m = Get-Mode
        if ($null -ne $m) { $mode = $m }          # unreadable for a moment: keep the last known mode
        if ($null -eq $mode -or $mode -eq 'off') { Stop-Miner 'mode off'; break }

        if (Test-Path -LiteralPath $restartFlag) {
            Remove-Item -Force -LiteralPath $restartFlag -ErrorAction SilentlyContinue
            Stop-Miner 'restart requested'
            $script:quick = 0; $script:holdUntil = [datetime]::MinValue
            $next = [datetime]::MinValue
        }

        if ((Get-Date) -ge $next) {
            $next = (Get-Date).AddSeconds($CheckSeconds)
            try {
                $conf = Read-PearlConf
                if ($null -eq $conf) { throw 'pearlmine.conf is missing' }
                $problems = @(Get-ConfProblems $conf)
                if ($problems.Count -gt 0) {
                    Stop-Miner 'config problem'
                    Write-Once "pearlmine.conf: $($problems -join '; ') -> not mining"
                } else {
                    $now = Get-Date
                    $gpuApps = @()
                    if ($mode -eq 'auto' -and (Get-Opt $conf 'PAUSE_WHEN_GPU_BUSY' '0') -eq '1') {
                        $gpuApps = Select-OtherGpuApps (Get-RawGpuApps $conf) (Get-Opt $conf 'IGNORE_GPU_PROCS')
                    }
                    $paused = Select-PausePrograms (Get-Opt $conf 'PAUSE_FOR_PROGRAMS') @(Get-Process | ForEach-Object { $_.ProcessName })
                    $d = Get-Decision $conf $mode ($now.Hour * 60 + $now.Minute) (Get-IsoDow $now) $gpuApps $paused
                    $running = @(Get-MinerProcess).Count -gt 0

                    if ($d.Want -and -not $running) { Start-Miner $conf $d.Why }
                    elseif (-not $d.Want -and $running) { Stop-Miner $d.Why }
                    elseif (-not $d.Want) { $script:startedAt = $null; $script:quick = 0 }
                    if ($running -or -not $d.Want) { Write-Once "$($d.Why) -> $(if ($d.Want) { 'mining' } else { 'not mining' })" }
                }
            } catch {
                # Keep running: one bad check must not kill the agent.
                Write-Once "check failed: $($_.Exception.Message)"
            }
        }
        Start-Sleep -Seconds 2
    }
}
finally {
    Write-AgentLog 'agent exiting'
    $mutex.ReleaseMutex()
}
