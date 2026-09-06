![Repo Views](https://komarev.com/ghpvc/?username=on-nick&repo=SnapVault=Repo%20Views&color=blue&style=flat)
# SnapVault

Back up photos and videos from an Android phone (connected via USB/MTP) to a
pendrive, SD card, or external drive — no cloud, no app, just `rsync`.

- **Zero config to get started** — on first run it detects your phone and
  your removable drive, and asks you which folders to back up.
- **Never re-copies or duplicates files** — uses `rsync --ignore-existing`,
  so re-running the script only copies what's new since last time.
- **Remembers your setup** — your choices are saved to
  `~/.config/snapvault/config.sh`, so after the first run it's just one
  command.
- **Safe by default** — always asks for confirmation before copying, and
  supports `--dry-run` to preview first.

Two versions are included:

| Script            | Platform | Requirements |
|--------------------|----------|--------------|
| `snapvault.sh`  | Linux    | `rsync`, `gio` (part of `glib2.0-bin`) |
| `snapvault.ps1` | Windows  | Windows PowerShell 5.1 (`powershell.exe`) |

Both work the same way and are configured independently — pick the one for
your OS.

## Usage — Linux

```bash
chmod +x snapvault.sh

# First run — detects your phone & drive, asks what to back up
./snapvault.sh

# Preview what would be copied without copying anything
./snapvault.sh --dry-run

# Reconfigure later (pick a different drive or folders)
./snapvault.sh --setup
```

## Usage — Windows

```powershell
# First run — detects your phone & drive, asks what to back up
.\snapvault.ps1

# Preview what would be copied without copying anything
.\snapvault.ps1 -DryRun

# Reconfigure later (pick a different drive or folders)
.\snapvault.ps1 -Setup
```

Run it from **Windows PowerShell** (`powershell.exe`), not PowerShell 7+
(`pwsh.exe`) — the phone-browsing COM interface it uses is most reliable
there. If your system blocks running local scripts, you may need to allow
it for this session first:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

On your phone (both platforms): unlock the screen and set the USB
connection mode to **File Transfer (MTP)**. Opening the Files
app/File Explorer once helps it auto-detect.

## How it works

**Linux** (`snapvault.sh`): detects the phone over MTP via `gio`/`gvfs`,
which mounts it as a normal folder path. Copying is done with
`rsync -a --ignore-existing`, which skips any file already present in the
destination by name.

**Windows** (`snapvault.ps1`): Windows doesn't expose MTP phones as a
filesystem path, so the script browses the phone through the same Shell COM
interface Windows Explorer uses ("This PC" → your phone). For each file, it
checks whether a same-named file already exists in the destination and only
copies it if not — the same "no duplicates" idea as `--ignore-existing`.

Both scripts, on first run:
1. Scan for connected removable drives and let you pick one (or type a
   custom path).
2. Look for common photo/video folders on the phone (`DCIM/Camera`,
   `Pictures`, `Movies`, etc.) and let you choose which to back up.
3. Save your choices to a config file (`~/.config/snapvault/config.sh` on
   Linux, `%USERPROFILE%\.config\snapvault\config.json` on Windows).

Every run after that just confirms and syncs — no re-picking needed, and no
file already backed up is copied again.

## Known limitations

- **Linux**: relies on `gvfs`'s MTP support (default on GNOME/KDE). No
  macOS support yet — PRs welcome.
- **Windows**: copying goes through Explorer's Shell COM interface, which
  doesn't give a clean "copy finished" signal for large files — the script
  polls for the file to appear as a safeguard, but this is less battle-tested
  than the Linux/`rsync` path. If you hit issues with large videos, please
  open an issue.
- Both rely on phone camera filenames being unique (they are, by default, on
  stock Android/most camera apps).

## License

MIT — do whatever you want with it.
