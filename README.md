# pearlmine

One command to run a Pearl GPU miner on Linux or Windows without giving up your graphics card.

```
pearlmine auto     # mine at night, stop the moment something else needs the GPU
pearlmine on       # mine 24/7
pearlmine off      # stop and put the GPU back how it was
pearlmine status
```

It wraps [WildRig Multi](https://github.com/andru-kun/wildrig-multi) in a few small scripts: shell scripts and systemd units on Linux, PowerShell and a Task Scheduler task on Windows. Nothing to compile.

## Quick install

**Windows 10 / 11.** Paste this into PowerShell (administrator not needed), then follow the [Windows guide](windows/README.md):

```powershell
irm https://raw.githubusercontent.com/swervy11/pearlmine/main/windows/install.ps1 | iex
```

**Linux (systemd):**

```bash
git clone https://github.com/swervy11/pearlmine.git && cd pearlmine && ./pearlmine setup
```

Both versions use the same commands and the same style of `pearlmine.conf`. The rest of this page covers Linux. The [Windows guide](windows/README.md#how-it-differs-from-linux) lists what differs.

## Before you start: get a Pearl wallet

pearlmine does **not** create a wallet. It only needs your wallet's public receive address, and the pool pays straight to that address. The wallet can be on any computer.

1. Download the official **Pearl Wallet** from the [Pearl releases page](https://github.com/pearl-research-labs/pearl/releases). Pick a release named "Pearl Wallet" (the newest one may be the node instead). There is a Windows installer (`Pearl-Wallet-Setup-*.exe`), a Mac `.dmg` and a Linux `.deb`, plus a `checksums.txt` to check the download against.
2. Create a new wallet and **write the seed words on paper**. Anyone with those words can take your coins, and without them a lost wallet cannot be recovered. Never type them into pearlmine, a website or a chat.
3. Copy the receive address. It starts with `prl1p` and is 63 characters long. That address goes in `PRL_WALLET`.

Mining from several computers? Use the same address on all of them, with a different `PRL_WORKER` name on each. The pool adds them up.

## What it does

- **Schedules mining.** A nightly window, plus an optional second window on the days you choose.
- **Shares the GPU.** In auto mode it checks every 2 minutes. If another program is computing on the card (a local AI model, a render, any CUDA job), the miner stops. When that program is gone, the miner starts again.
- **Tunes the card only while mining.** Optional power cap, clock locks and fan curve. All of it is undone when mining stops.
- **Installs and updates the miner safely.** Downloads the official release, checks its SHA-256 against the digest GitHub publishes, confirms the new version can see your GPU, and keeps the old version for rollback.

## What it does not do

- It never touches a wallet. It needs only your public receive address. There are no seed words, keys or passwords anywhere in it.
- It does not detect games or desktop use. The busy check sees compute workloads, not graphics ones. If you game on the card, use the time windows or run `pearlmine off`. (The Windows version can pause while programs you list are running: `PAUSE_FOR_PROGRAMS`.)
- It does not pick settings for you. Out of the box it changes no power, clock or fan setting.

## Requirements (Linux)

For Windows, see [windows/README.md](windows/README.md).

- Linux with systemd, and `sudo` for installing the units
- `bash`, `curl`, `python3`
- A Pearl receive address (see [Before you start](#before-you-start-get-a-pearl-wallet))
- A GPU that WildRig supports for the `pearlhash` algorithm

**GPU support**

| | NVIDIA | AMD / Intel |
|---|---|---|
| Mining, on/off, time windows | yes | untested |
| Pause while the GPU is busy | yes | no |
| Power cap, clock locks | yes | no |
| Fan curve | yes | no |

The tuning, fan and busy-check features use `nvidia-smi` and the NVIDIA driver library. On a machine without them those features switch themselves off and the rest still runs. Any NVIDIA model should work; multi-GPU rigs are supported in the code but untested.

## Install

Linux. For Windows, use the one-line installer in [windows/README.md](windows/README.md).

```bash
git clone https://github.com/swervy11/pearlmine.git
cd pearlmine
./pearlmine setup
```

`setup` creates `pearlmine.conf`, asks for your wallet's receive address and a name for this computer on the pool page, then downloads the miner. Press Enter to skip the questions and set `PRL_WALLET` in `pearlmine.conf` later. Then run `./pearlmine auto` (or `./pearlmine on`). The first run asks for your sudo password to install five systemd units.

To call it from anywhere: `ln -s "$PWD/pearlmine" ~/.local/bin/pearlmine`

The folder can live wherever you like. The units are generated for its location, so if you move it, run `pearlmine restart` and confirm when it asks to replace the old units.

## Commands

| Command | What it does |
|---|---|
| `setup` | Create the config and download the miner |
| `auto` | Mine inside your time windows, only while the GPU is free |
| `on` | Mine 24/7, including after a reboot |
| `off` | Stop mining and restore the GPU settings |
| `status` | Mode, hashrate, accepted shares, temperature, power |
| `check` | Show what auto mode would decide right now. Changes nothing |
| `restart` | Restart the miner in its current mode after a config change |
| `log` | Follow the miner log |
| `history` | What auto mode started and stopped in the last two days |
| `balance` | Pool credits and payouts for your address (pearlhash.xyz) |
| `update [version]` | Install the newest miner, or a specific version to roll back |
| `uninstall` | Remove the systemd units |

## Settings

Everything is in `pearlmine.conf`, and every setting is explained there. The ones most people change:

```ini
PRL_WALLET=prl1p...

NIGHT_START=22:00
NIGHT_END=06:00

DAY_WINDOW=1
DAY_WINDOW_DAYS="1 2 3 4 5"
DAY_START=09:00
DAY_END=17:00

PAUSE_WHEN_GPU_BUSY=1
IGNORE_GPU_PROCS="ollama"
```

- `PRL_WALLET` is the only required setting.
- The nightly window may cross midnight.
- `DAY_WINDOW=1` turns on the second window. Days are numbered 1 (Monday) to 7 (Sunday).
- `IGNORE_GPU_PROCS` names background GPU programs that should not pause mining.
- Put comments on their own lines. A comment after a value on the same line is not supported.

Times use the machine's local time zone.

### Tuning

All optional, NVIDIA only, and empty by default.

```ini
POWER_LIMIT_W=250
CORE_CLOCK_MHZ=
MEM_CLOCK_MHZ=
FAN_CURVE="50:45 60:55 65:65 70:75 75:85 80:100"
```

- **Start with the power cap alone.** It is the safest setting and gives most of the efficiency gain. `nvidia-smi -q -d POWER` shows the range your card accepts; a value outside it is refused and mining does not start.
- **Clock locks** depend on the card and the algorithm. A wrong value costs hashrate or stability. Change one at a time and watch `pearlmine status`.
- **The fan curve** is a list of `temperature:percent` points. The fans are never driven below `FAN_MIN_PCT`, and if the fan script stops or fails it hands control back to the card.

Try a curve before using it:

```bash
set -a; . ./pearlmine.conf; set +a
python3 lib/fan.py --dry-run
```

The miner also has its own cut-out: it pauses a GPU at `TEMP_LIMIT` (82 °C by default) and resumes at `TEMP_RESUME`.

## How it works

| Unit | Runs as | Job |
|---|---|---|
| `pearl-miner.service` | you | Runs the miner |
| `pearl-gpu-tune.service` | root | Applies tuning before the miner starts, undoes it after |
| `pearl-fan.service` | root | Fan curve, only while the miner runs |
| `pearl-auto.service` + `.timer` | root | The 2-minute scheduler for auto mode |

`on` enables the miner unit. `auto` enables the timer instead, and the scheduler starts and stops the miner. `off` disables both.

## Security notes

- Three of the units run as root and read `pearlmine.conf`. Keep that file owned by you and not writable by anyone else. The scripts refuse a config that is group- or world-writable.
- WildRig Multi is closed-source, third-party software, and it may charge a developer fee. pearlmine verifies that the download matches the published digest. It cannot tell you what the binary does. Read the miner's own documentation before running it.
- Read the scripts before giving them sudo. They are short. (The Windows version never asks for administrator rights.)

## Tests

```bash
bash tests/test_guard.sh      # auto-mode decisions for fixed times, days and GPU states
python3 tests/test_fan.py     # fan-curve maths
pwsh tests/test_windows.ps1       # Windows scheduling logic (also runs in Windows PowerShell 5.1)
pwsh tests/test_windows_cli.ps1   # Windows installer + CLI entry point, into a temp folder
```

None of the tests touches a GPU or starts a miner. GitHub Actions runs them on Ubuntu and on Windows.

## Uninstall

```bash
./pearlmine off
./pearlmine uninstall
```

Then delete the folder.

## License

MIT
