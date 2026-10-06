<!--
  RustDesk Client Updater - README
  Author: https://github.com/Leproide
  License: GPL-3.0
-->

# RustDesk support portal with client updater

Publishes the latest **RustDesk** clients for **Windows, macOS and Linux** on your own server, preconfigured (or easy to configure) for your self-hosted ID/relay server.

It also ships a **download page** that detects the visitor's OS, starts the right download and explains the setup steps. The page is in Italian for Italian browsers and in English otherwise.

| File | Description |
|---|---|
| `Update-RustDeskClient.ps1` | Updater for Windows servers (Windows PowerShell 5.1 / PowerShell 7+) |
| `update-rustdesk-client.sh` | Updater for Linux servers (Bash 4+) |
| `web/index.html` | Remote support download page |
| `LICENSE` | GNU GPL v3 |

## How RustDesk picks up a custom server

| Client | Mechanism | What this project does |
|---|---|---|
| **Windows** | The configuration is read from the **executable file name**: `rustdesk-host=<host>,key=<key>[,relay=<relay>][,api=<api>],.exe`, or an encoded form `rustdesk--<config>--.exe`. | Publishes the `.exe` already renamed. Users just download and run it. |
| **macOS / Linux** | File names are **ignored**. The client must import a configuration string from the clipboard (*Settings → Network → ID/Relay Server → Import server config*), or run `sudo rustdesk --config '<config>'` on an installed client. | Publishes the packages under stable names. Exports the configuration in `rustdesk.json`. The page offers a **Copy configuration** button, the terminal command and step-by-step instructions. |

This behavior was verified on the RustDesk 1.5.0 sources. The file-name parser exists only in the Windows code path, and `--config` requires an installed client and root privileges. The clipboard format is the same as RustDesk's own *Export server config*: reversed, URL-safe Base64 of `{"host","relay","api","key"}`.

**Relay server:** if no relay is set (`-RelayServer` / `--relay`), the macOS/Linux configuration (clipboard and terminal command) uses the ID server host as relay. The Windows file name omits it, and RustDesk then uses the relay announced by the ID server, normally the same host. An explicit relay goes everywhere, Windows file names included.

## How the updater works

On each run the updater:

1. Queries the GitHub API for the latest **stable** release.
2. Exits if nothing changed. It compares the version, the selected platforms, the file names and the server configuration.
3. Downloads every selected asset and verifies size, SHA-256 digest (when published by GitHub) and file signature (magic bytes). On Windows it also checks the Authenticode signature of `.exe` files.
4. Backs up the previously published files, then swaps in the new ones. Nothing in the target folder is touched until all downloads are verified.
5. Removes files published by the previous run that are no longer part of the set. For example, the old Windows `.exe` is removed when the relay setting changes its name.
6. Writes the `rustdesk.json` manifest and, optionally, a line in the public `update.log`.

### Platforms

| ID | Asset | Published as |
|---|---|---|
| `windows-x64` * | `rustdesk-<v>-x86_64.exe` | `rustdesk-host=…,key=…,.exe` |
| `windows-arm64` | `rustdesk-<v>-aarch64.exe` | `rustdesk-arm64-host=…,key=…,.exe` |
| `macos-arm64` * | `rustdesk-<v>-aarch64.dmg` | `rustdesk-macos-arm64.dmg` |
| `macos-x64` * | `rustdesk-<v>-x86_64.dmg` | `rustdesk-macos-x64.dmg` |
| `linux-x64-deb` * | `rustdesk-<v>-x86_64.deb` | `rustdesk-linux-x64.deb` |
| `linux-arm64-deb` | `rustdesk-<v>-aarch64.deb` | `rustdesk-linux-arm64.deb` |
| `linux-x64-rpm` * | `rustdesk-<v>-<n>.x86_64.rpm` | `rustdesk-linux-x64.rpm` |
| `linux-arm64-rpm` | `rustdesk-<v>-<n>.aarch64.rpm` | `rustdesk-linux-arm64.rpm` |
| `linux-x64-suse-rpm` | `rustdesk-<v>-<n>.x86_64-suse.rpm` | `rustdesk-linux-x64-suse.rpm` |
| `linux-arm64-suse-rpm` | `rustdesk-<v>-<n>.aarch64-suse.rpm` | `rustdesk-linux-arm64-suse.rpm` |
| `linux-x64-appimage` * | `rustdesk-<v>-x86_64.AppImage` | `rustdesk-linux-x64.AppImage` |
| `linux-arm64-appimage` | `rustdesk-<v>-aarch64.AppImage` | `rustdesk-linux-arm64.AppImage` |

\* Selected by default.

### Windows file name styles

With `Auto` (the default), the updater uses the readable `Plain` style when every value is valid in a Windows file name. Otherwise it switches to `Encoded`, for example when the relay has a port (`relay.example.com:21117`), the API is a URL, or the key contains `/`. Both forms end with a delimiter, so a browser renaming duplicates (`… (1).exe`) does not corrupt the key.

```
Plain:   rustdesk-host=rd.example.com,key=ABC…=,relay=relay.example.com,.exe
Encoded: rustdesk--<encoded-config>--.exe
```

## Requirements

**Windows**
- Windows PowerShell 5.1 or PowerShell 7+.
- Outbound HTTPS to `api.github.com`, `github.com` and `release-assets.githubusercontent.com`.

**Linux**
- `bash` 4+, `curl`, `jq`, and coreutils (`sha256sum`, `mktemp`, `od`, `tail`).
- `flock` (util-linux), optional but recommended to prevent concurrent runs.
- The same outbound HTTPS access.

On Debian/Ubuntu: `apt install curl jq util-linux`.

**Disk space:** the default platform set is about 240 MB per release, plus backups (`KeepBackups`, default 1).

## Windows updater

```powershell
.\Update-RustDeskClient.ps1 -TargetDir 'D:\www\support' -ServerHost 'rd.example.com' -Key 'YOUR_PUBLIC_KEY='
```

Full help: `Get-Help .\Update-RustDeskClient.ps1 -Full`

| Parameter | Default | Description |
|---|---|---|
| `-TargetDir` | *(required)* | Folder where the clients are published. |
| `-ServerHost` | *(required)* | ID server (hbbs) host/IP. |
| `-Key` | *(required)* | Server public key (`id_ed25519.pub`). |
| `-RelayServer` | | Relay server (hbbr), optionally with port. |
| `-ApiServer` | | API server URL. |
| `-Platforms` | see table | Platform IDs, as an array or a comma-separated string. |
| `-NameStyle` | `Auto` | Windows file names: `Auto`, `Plain`, `Encoded`. |
| `-Repository` | `rustdesk/rustdesk` | GitHub repository `owner/name`. |
| `-StateDir` | script folder | State, log and backups. |
| `-KeepBackups` | `1` | Previous releases to keep (`0` = none). |
| `-WriteUpdateLog` | `$true` | Public update log. Disable with `-WriteUpdateLog:$false`. |
| `-UpdateLogName` | `update.log` | Public update log file name. |
| `-ManifestName` | `rustdesk.json` | Manifest file name. |
| `-RequireValidSignature` | off | Abort if a Windows `.exe` has no valid Authenticode signature. |
| `-Force` | off | Publish even if nothing changed. |

### Scheduling (Task Scheduler)

Create a daily task running as `SYSTEM`:

- **Program:** `powershell.exe`
- **Arguments:**
  ```
  -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Tools\rustdesk-client-updater\Update-RustDeskClient.ps1" -TargetDir "D:\www\support" -ServerHost "rd.example.com" -Key "YOUR_PUBLIC_KEY="
  ```

With `-File`, pass platform lists as a single comma-separated value, e.g. `-Platforms windows-x64,macos-arm64`. If the script was downloaded from the internet, unblock it once with `Unblock-File`.

## Linux updater

```bash
./update-rustdesk-client.sh -d /var/www/support -s rd.example.com -k 'YOUR_PUBLIC_KEY='
```

Full help: `./update-rustdesk-client.sh --help`

| Option | Default | Description |
|---|---|---|
| `-d, --target-dir DIR` | *(required)* | Folder where the clients are published. |
| `-s, --server-host HOST` | *(required)* | ID server (hbbs) host/IP. |
| `-k, --key KEY` | *(required)* | Server public key (`id_ed25519.pub`). |
| `--relay HOST[:PORT]` | | Relay server (hbbr). |
| `--api URL` | | API server URL. |
| `-P, --platforms LIST` | see table | Comma-separated platform IDs. |
| `--name-style STYLE` | `auto` | Windows file names: `auto`, `plain`, `encoded`. |
| `-r, --repository OWNER/REPO` | `rustdesk/rustdesk` | GitHub repository. |
| `--manifest-name NAME` | `rustdesk.json` | Manifest file name. |
| `--state-dir DIR` | `/var/lib/rustdesk-client-updater` (root)<br>`$XDG_STATE_HOME/rustdesk-client-updater` (user) | State, log and backups. |
| `--keep-backups N` | `1` | Previous releases to keep (`0` = none). |
| `--update-log BOOL` | `true` | Public update log (`true`/`false`). |
| `--update-log-name NAME` | `update.log` | Public update log file name. |
| `--mode MODE` | `0644` | Permissions of published files. |
| `--owner USER[:GROUP]` | | Owner of published files (needs privileges). |
| `-f, --force` | off | Publish even if nothing changed. |
| `-q, --quiet` | off | Only warnings/errors on output (cron friendly). |

Authenticode verification is not available on Linux.

### Scheduling with cron

```cron
# /etc/cron.d/rustdesk-client-updater
15 4 * * * root /opt/rustdesk-client-updater/update-rustdesk-client.sh -q -d /var/www/support -s rd.example.com -k 'YOUR_PUBLIC_KEY='
```

### Scheduling with a systemd timer

`/etc/systemd/system/rustdesk-client-updater.service`

```ini
[Unit]
Description=RustDesk Client Updater
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/rustdesk-client-updater/update-rustdesk-client.sh -d /var/www/support -s rd.example.com -k 'YOUR_PUBLIC_KEY='
```

`/etc/systemd/system/rustdesk-client-updater.timer`

```ini
[Unit]
Description=Daily RustDesk Client Updater

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl daemon-reload
systemctl enable --now rustdesk-client-updater.timer
```

## Download page

Copy `web/index.html` into the target folder, next to `rustdesk.json`. Optional settings are in the `CONFIG` object at the top of the script:

| Setting | Default | Description |
|---|---|---|
| `brand` | `""` | Appended to the page title, e.g. `Remote support - ACME`. |
| `manifestUrl` | `rustdesk.json` | Manifest location, relative to the page. |
| `autoDownload` | `true` | Start the download automatically. |
| `autoDownloadDelayMs` | `3000` | Delay before the automatic download. |

What the page does:

- **Language:** Italian if the browser's preferred language is Italian, English otherwise.
- **OS detection:** Windows, macOS or Linux, from the User-Agent string, falling back to `navigator.platform` / User-Agent Client Hints. Phones and tablets get a message to open the page on a computer. For testing, force the result with `?os=windows|macos|linux|mobile` and `?arch=x64|arm64`, e.g. `index.html?os=macos&arch=arm64`.
- **Architecture:** ARM64 vs x64.
  - Chromium-based browsers report it exactly.
  - On macOS in other browsers, the page assumes Apple Silicon unless the GPU reveals an Intel Mac. A link to the other Mac version is always shown.
- **Linux distribution:** browsers usually do not reveal it. Firefox packaged by Fedora, Ubuntu and others includes the distribution name in the User-Agent, so the page downloads the matching package automatically: `.deb`, `.rpm`, openSUSE `.rpm` (if published, otherwise AppImage). Otherwise (e.g. Chrome), nothing is downloaded automatically and the visitor picks a package family: Ubuntu/Debian/Mint, Fedora/RHEL, openSUSE, or other distributions (AppImage). A link always allows switching package. Override for tests: `?distro=deb|rpm|suse|appimage|unknown`.
- **Automatic download:** after a short delay, once per browser session, so going back does not download again.
- **Setup steps:**
  - Windows: run the file and read out the ID and one-time password.
  - macOS/Linux: install, then **Copy configuration** and import it in RustDesk (one action per step), check that RustDesk shows *Ready*. Terminal commands (install, and `sudo … --config` as an alternative configuration) are in collapsible sections.

The clipboard button needs HTTPS; a fallback is used on plain HTTP.

## Manifest (`rustdesk.json`)

```json
{
  "version": "1.5.0",
  "published": "2026-10-06T04:00:12Z",
  "server": { "host": "rd.example.com", "relay": "", "api": "", "key": "ABC…=" },
  "config": "<encoded configuration, as produced by RustDesk Export server config>",
  "files": {
    "windows-x64": { "file": "rustdesk-host=rd.example.com,key=ABC…=,.exe", "asset": "rustdesk-1.5.0-x86_64.exe", "size": 25887600, "sha256": "…" },
    "macos-arm64": { "file": "rustdesk-macos-arm64.dmg", "asset": "rustdesk-1.5.0-aarch64.dmg", "size": 29874038, "sha256": "…" }
  }
}
```

Both updaters produce identical manifests for the same input.

## Logs and state

The **public update log** (`<TargetDir>/update.log`) is written only when files are published:

```
2026-10-06 04:00:12 | 1.4.2 -> 1.5.0 | windows-x64, macos-arm64, macos-x64, linux-x64-deb, linux-x64-rpm, linux-x64-appimage
```

The **technical log** (`<StateDir>/rustdesk-client-updater.log`) records every run, tagged with the target ID.

**State directory layout**, where `<id>` is a short hash of the target folder path:

```
<StateDir>/
├── rustdesk-client-updater.log
├── state-<id>.json         # published version + change fingerprint
├── <id>.lock               # Linux only (flock)
└── backup/<id>/<timestamp>_<version>/   # previously published files
```

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Published, already up to date, or another run in progress |
| `1` | Runtime error (network, verification, file replacement) |
| `2` | Configuration error (invalid/missing parameters or dependencies) |
| `3` | Published, but some platforms were skipped because their asset was not found |

## Notes

- **GitHub rate limit:** unauthenticated API calls are limited to 60 per hour per IP. On shared IPs, set the `GITHUB_TOKEN` environment variable; a fine-grained token with no permissions is enough.
- **Upgrading from 1.x:** the old `-TargetName`, `-AssetPattern` and `--target-name`/`--asset-pattern` options are gone. The Windows file now ends with `,.exe`, and the state file format changed, so the first run publishes everything again. Files published by 1.x are not in a manifest, so delete the old `.exe` manually.
- **Asset names:** if RustDesk renames its release assets, the affected platforms are skipped with a warning (exit code `3`) until the catalog in the script is updated.

## License

This project is licensed under the **GNU General Public License v3.0** (GPL-3.0). See [LICENSE](LICENSE) for the full text.

## Author

[https://github.com/Leproide](https://github.com/Leproide)

RustDesk is a trademark of its respective owners. This project is not affiliated with or endorsed by the RustDesk project.
