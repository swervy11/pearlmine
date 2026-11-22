# pearlmine Windows installer. Run in PowerShell (no administrator needed):
#
#   irm https://raw.githubusercontent.com/swervy11/pearlmine/main/windows/install.ps1 | iex
#
# Installs to %LOCALAPPDATA%\pearlmine, adds it to your user PATH and runs `pearlmine setup`.
# Running it again updates the scripts and keeps your pearlmine.conf, miner and logs.
#   PEARLMINE_REF=<branch or tag>   install that version instead of main
#   PEARLMINE_SRC_ZIP=<path>        install from a local source zip (used by the tests)
#   PEARLMINE_SKIP_SETUP=1          copy the files only; do not download the miner
#   PEARLMINE_SKIP_PATH=1           do not touch your PATH (used by the tests)
# Wrapped in a script block so `| iex` does not change settings in your PowerShell session.
& {
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $ref  = if ($env:PEARLMINE_REF) { $env:PEARLMINE_REF } else { 'main' }
    $dest = Join-Path $env:LOCALAPPDATA 'pearlmine'
    $tmp  = Join-Path ([IO.Path]::GetTempPath()) ("pearlmine-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        if ($env:PEARLMINE_SRC_ZIP) {
            $zip = $env:PEARLMINE_SRC_ZIP
            Write-Host "Installing pearlmine from $zip ..."
        } else {
            Write-Host "Downloading pearlmine ($ref)..."
            $zip = Join-Path $tmp 'src.zip'
            $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            try { Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/swervy11/pearlmine/archive/$ref.zip" -OutFile $zip }
            finally { $ProgressPreference = $old }
        }
        $unz = Join-Path $tmp 'src'
        Expand-Archive -LiteralPath $zip -DestinationPath $unz
        $src = Get-ChildItem -LiteralPath $unz -Directory |
               Where-Object { Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $_.FullName 'windows') 'lib') 'pearlmine.ps1') } |
               Select-Object -First 1
        if (-not $src) { throw 'the download does not contain windows\lib\pearlmine.ps1' }

        $win = Join-Path $src.FullName 'windows'
        New-Item -ItemType Directory -Force -Path (Join-Path $dest 'lib') | Out-Null
        foreach ($f in 'pearlmine.cmd', 'pearlmine.conf.example', 'README.md') {
            Copy-Item -Force -LiteralPath (Join-Path $win $f) -Destination $dest
        }
        Get-ChildItem -LiteralPath (Join-Path $win 'lib') -Filter '*.ps1' -File |
            ForEach-Object { Copy-Item -Force -LiteralPath $_.FullName -Destination (Join-Path $dest 'lib') }
        Copy-Item -Force -LiteralPath (Join-Path $src.FullName 'LICENSE') -Destination $dest
        Write-Host "Installed to $dest"
    }
    finally { Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue }

    # Each step runs pearlmine in its own process, so nothing it defines lands in this session.
    $cmd = Join-Path $dest 'pearlmine.cmd'
    if ($env:PEARLMINE_SKIP_PATH -ne '1') { & $cmd _path-add }
    if ((";$env:Path;") -notlike "*;$dest;*") { $env:Path = "$env:Path;$dest" }

    if ($env:PEARLMINE_SKIP_SETUP -eq '1') { return }
    & $cmd setup
    # Already mining from an earlier install? Restart so the new scripts take over.
    $modeFile = Join-Path (Join-Path $dest 'state') 'mode'
    $mode = ''; if (Test-Path -LiteralPath $modeFile) { $mode = "$(Get-Content -LiteralPath $modeFile -Raw)".Trim() }
    if ($mode -eq 'on' -or $mode -eq 'auto') { & $cmd restart }
}
