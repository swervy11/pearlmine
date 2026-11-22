# pearlmine for Windows

The Windows version of pearlmine. It uses the same commands as the Linux version and runs on Windows 10 and 11 with the PowerShell that comes with Windows.

```
pearlmine auto     # mine at night (and any other windows you set)
pearlmine on       # mine 24/7
pearlmine off      # stop and put the GPU back how it was
pearlmine status
```

## Install

You need a Pearl wallet address first. pearlmine does not create one: get the official Pearl Wallet and write down its seed words, as in [Before you start](../README.md#before-you-start-get-a-pearl-wallet).

Open **PowerShell** (Start menu, type `powershell`; administrator is not needed) and paste:

```powershell
irm https://raw.githubusercontent.com/swervy11/pearlmine/main/windows/install.ps1 | iex
```

This puts pearlmine in `%LOCALAPPDATA%\pearlmine`, adds it to your PATH, downloads the miner and checks its SHA-256. Then:

1. Run `notepad "$env:LOCALAPPDATA\pearlmine\pearlmine.conf"` and set `PRL_WALLET` to your public receive address. Give this PC its own `PRL_WORKER` name.
2. Open a **new** terminal and run `pearlmine auto` (or `pearlmine on`).

Running the install line again updates pearlmine. It keeps your config, miner and logs, and restarts mining if it was on. The line always installs the latest `main`; to pin a version, set `$env:PEARLMINE_REF = '<tag>'` first.

**Without the one-liner:** download the repository ZIP from GitHub, unzip it, and run `windows\pearlmine.cmd setup` from that folder. The folder can live anywhere.

## Windows Security

Windows Defender often flags crypto miners as "potentially unwanted" and may block the download or delete `wildrig.exe`. pearlmine reports it when the download, unpacking or start of the miner is blocked (at setup in the terminal, while mining in `pearlmine history`). It never turns Defender off and never adds exclusions for you.

If you choose to allow the miner, exclude **only the miner folder**:

- Windows Security > Virus & threat protection > Manage settings > Exclusions > Add an exclusion > Folder, and pick `%LOCALAPPDATA%\pearlmine\miner`.
- Or, in an Administrator PowerShell: `Add-MpPreference -ExclusionPath "$env:LOCALAPPDATA\pearlmine\miner"`

Then run `pearlmine update`. If the miner was quarantined, restore it under Protection history.

pearlmine downloads only the official WildRig Multi release and refuses any file whose SHA-256 does not match the digest GitHub publishes. That proves the file is the one the developer released. It does not prove what the program does.

## How it differs from Linux

| | Linux | Windows |
|---|---|---|
| Runs from | systemd units, from boot | a "pearlmine" task in Task Scheduler, from when you log in |
| Runs while | the machine is on | you are logged in. A locked screen is fine; signing out stops mining |
| Pause for a program | `PAUSE_WHEN_GPU_BUSY` (compute jobs) | `PAUSE_FOR_PROGRAMS` (any program you list: games, editors), plus optional `PAUSE_WHEN_GPU_BUSY` |
| Power cap, clock locks, fan curve | yes, only while mining | no (see [Power limit](#power-limit)) |
| Admin needed | sudo to install units | never |
| `PAUSE_WHEN_GPU_BUSY` default | 1 | 0 |

### Pause while you game

On a PC you also use, list the programs that need the GPU:

```ini
PAUSE_FOR_PROGRAMS="cs2 eldenring blender"
```

The names come from Task Manager's Details tab, with or without `.exe`. The miner stops within 30 seconds of one starting and resumes within 30 seconds of the last one closing. This works in both `on` and `auto` mode.

`PAUSE_WHEN_GPU_BUSY` is off by default on Windows. Desktop apps such as browsers can show up as GPU users, and that would keep the miner off. Run `pearlmine check` to see what your PC reports. Then put the harmless ones in `IGNORE_GPU_PROCS` before you turn it on.

### Power limit

pearlmine for Windows does not change power, clock or fan settings. On Windows that would need a task running as administrator, and that task would be running scripts in your user folder. Any program running as you could edit those scripts and get administrator rights without a prompt. So the Windows version always runs as you, with normal rights.

To cap the power, which is the main efficiency gain:

- **MSI Afterburner** (or your card vendor's tool): set the power limit and save it as a profile that applies at startup. This is the usual Windows approach.
- **Or, until the next reboot:** in an Administrator terminal, run `nvidia-smi -q -d POWER` to see the allowed range, then `nvidia-smi -pl 160`.

Either way the cap also applies while you game, not only while mining. Watch the temperature with `pearlmine status`. A 12 GB card has less memory headroom than a 24 GB one, so start low (about 110 to 160 W) and raise it if the hashrate drops a lot.

## Commands

| Command | What it does |
|---|---|
| `setup` | Create the config and download the miner |
| `auto` | Mine inside your time windows |
| `on` | Mine 24/7, starting again whenever you log in |
| `off` | Stop mining and restore the GPU settings |
| `status` | Mode, hashrate, accepted shares, temperature, power |
| `check` | Show what the agent would decide right now, and what nvidia-smi sees on the GPU. Changes nothing |
| `restart` | Restart in the current mode after a config change |
| `log` | Follow the miner log |
| `history` | What the agent started and stopped recently |
| `balance` | Pool credits and payouts for your address |
| `update [version]` | Install the newest miner, or a specific version to roll back |
| `uninstall` | Remove the scheduled task and the PATH entry |

`pearlmine status` also warns if `pearlmine.conf` has a mistake. The agent will not mine with a broken config, and `pearlmine history` shows why.

## How it works

- `pearlmine.cmd` runs `lib\pearlmine.ps1` with `-ExecutionPolicy Bypass` for that one process only, so your PowerShell policy is unchanged.
- `on` and `auto` register a task named **pearlmine-&lt;your user name&gt;** (Task Scheduler > Task Scheduler Library). It runs as you, with normal rights. It starts `lib\agent.ps1` hidden when you log in, and checks every 5 minutes that the agent is still running. Extra starts exit straight away.
- Every 30 seconds the agent decides whether to mine, from your mode, time windows and paused programs. It starts or stops `wildrig.exe` and restarts it if it exits. If the miner keeps exiting right after starting, the agent waits 10 minutes before trying again. `off` tells the agent to stop the miner and exit.
- Files: `pearlmine.conf` (settings), `state\mode`, `logs\miner.log`, `logs\agent.log`, and `miner\<version>\` (every downloaded version, kept for rollback).
- After downloading, setup deletes every `.bat` file that ships with WildRig. The bundled start scripts mine to the developer's address.
- If the task was set up from a different pearlmine folder, `on` and `auto` ask before replacing it, and stop the old folder's miner first.

## Uninstall

```powershell
pearlmine off
pearlmine uninstall
Remove-Item -Recurse "$env:LOCALAPPDATA\pearlmine"
```

If you added a Defender exclusion, remove it too.

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File tests\test_windows.ps1
powershell -ExecutionPolicy Bypass -File tests\test_windows_cli.ps1
```

The first checks config parsing and validation, the time windows, pause decisions, the mode file and the miner command line. The second installs from a local zip into a temporary folder and runs the CLI entry point. Neither touches the GPU, Task Scheduler, your PATH or the miner. Both also run on PowerShell 7 on Linux and macOS (`pwsh tests/test_windows.ps1`).
