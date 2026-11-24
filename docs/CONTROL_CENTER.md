# SysGuard V1.1 terminal control center

The launcher calls SysGuard's monitoring, configuration, alert, cron, reporting, and rotation scripts. It opens the numbered menu immediately. Run it from the checkout or pass its absolute path to Bash from another directory. Paths can contain spaces.

## Get started

In a fresh development checkout, review V1.1 before installing a schedule. After the feature branch is published, clone and launch it with:

```bash
git clone --branch feature/interactive-control-center --single-branch https://github.com/Jana1350/SCRIPTING-WS.git SysGuard
cd SysGuard
bash sysguard.sh
```

Use `./sysguard.sh` when executable permissions are available. Use **0** to exit or return from a submenu. Enter at a confirmation declines it. Ctrl+C stops the live view and returns to the main menu. EOF exits cleanly. The header shows the last saved main-history sample if one is available. Redirected input or output uses plain text, as do unsupported terminals or terminals with `NO_COLOR` set.

Use Linux or WSL Ubuntu with Bash, Git, Linux procfs, awk, compatible GNU coreutils, and util-linux `flock`. Automatic monitoring also needs a running cron daemon and the user's `crontab` command. Install gnuplot with pngcairo for charts. PDF generation uses compatible WeasyPrint, `file`, and Poppler tools. Rotation expects gzip and GNU-compatible `sync` with both file and directory arguments. The dependency menu reports what's available and the status of each version probe. [Reporting dependencies](REPORTS.md#dependencies)

## Menu and delegated commands

| Main option | What it runs |
|---|---|
| 1. Setup and configuration | `bash scripts/setup.sh` after safety checks. When another checkout owns cron, offers settings for this checkout only. |
| 2. Start automatic monitoring | `setup_cron.sh --print`, then guarded `--install` after approval. The `--mail-mode real` flag requires separate approval and valid settings. |
| 3. Monitor system now | `main.sh --once --data-dir DIR`. Mock is the default. When effective mail is enabled, an affirmative answer adds `--mail-mode real`. |
| 4. Live monitoring | Follows newly saved CSV rows if an owned schedule is active or there is evidence of recent collection. If ownership is unverified it also prefers the saved view. Otherwise it calls `monitor.sh --watch`. |
| 5. Email and alert settings | Validates and atomically publishes private config edits through `sysguard_config_load`. An authorized OFF operation can call `setup_cron.sh --install` to move an owned local-config schedule to mock first. |
| 6. Generate reports | `report.sh today\|daily\|weekly` using UTC. Prints the generated paths. |
| 7. View reports and charts | Opens selected artifacts under `reports/today/`, `reports/daily/`, `reports/weekly/`, and `reports/charts/` with approval. |
| 8. Historical data and archives | Lists stored rows and gzip archives, runs `rotate_logs.sh --dry-run` for retention preview, or calls `rotate_logs.sh` after approval to archive completed dates. |
| 9. System status | Uses Git, the shared config loader, daemon and crontab inspection, and local files to report status and availability. |
| 10. Stop automatic monitoring | Guarded `setup_cron.sh --uninstall` after owner verification and approval. |
| 11. Diagnostics and testing | Checks executable availability and versions. Runs `bash tests/run_all.sh` upon request. |

## Recipient, thresholds, and delivery

Use **5 → 1** to enter the recipient privately. Use **5 → 2** to enable real alerts in this checkout's settings. Option **3** asks about real processing for one manual sample. Option **2** asks about real processing for its schedule, then asks for installation approval. The existing setup wizard may offer its own email test and confirmation.

The installed sender is the account already configured in the Linux user's mail transport. The recipient can change independently. On a fresh machine, configure and verify its SMTP transport separately if real email is needed. A fresh checkout can monitor and process mock alerts with the tracked defaults and no `config/local.conf`. Keep transport credentials outside the repository. [SMTP and mail setup](../README.md#real-email-alerts)

Both mock and real processing record alert transitions. State and duplicate suppression follow the data directory. A sample without a qualifying new transition sends nothing, and recorded transitions are never replayed. With mail enabled, manual mock uses `data/manual/` to preserve the main alert state. It also uses this directory if cron ownership is unknown or unavailable or if an owned schedule uses real mail or an explicit config. Manual real shares `data/` only with this checkout's verified real schedule using local settings, so both use the same duplicate suppression. That history may already contain the current transition. Otherwise manual real uses `data/manual-real/`, separate from mock history. Each manual directory maintains its own metrics and alert state. The reports and main menu read the main history in `data/` by default. The launcher prints when it selects a separate history.

A delivery ledger status of `submitted` means mailx accepted the submission. Verify arrival in the inbox separately. Exit 5 means delivery or mock capture failed. The measurement and alert transition can already be saved in this case.

Use **5 → 4/5/6** to set a warning and a critical level for one metric. The shared loader enforces a positive warning strictly below critical, critical at most 100, and valid hysteresis. **5 → 7** resets the six thresholds from tracked defaults. It preserves other settings. Changes are staged in the private config directory, validated, and published by rename. Existing `config/local.conf` must be owned by the current user, ignored and untracked, singly linked, and mode 0600 or 0400.

**5 → 3** clears the recipient and disables local mail. For an owned real schedule using local settings, the launcher switches the schedule to mock first. A failed schedule update preserves local settings. If publishing the settings fails after the switch, inspect the schedule before retrying. The launcher reports that an explicit real schedule remains enabled. Use its original configuration in the owning checkout or stop that checkout's verified schedule to change its delivery mode.

## Schedule ownership

Option **2** previews before installing. Option **10** removes only a verified schedule owned by the selected checkout. The launcher compares the entire managed block with the legacy generated format and refuses writes for foreign or unrecognized entries. The wizard is guarded too. The launcher preserves explicit-config installations and refuses to replace them. An explicit schedule owned here can still be removed deliberately with option **10**.

If another checkout owns the schedule, **1** offers a local-only settings menu. It can save the recipient and thresholds or turn local email off. The active checkout retains its schedule and settings. A local file used by an explicit schedule remains protected.

The cron guard rechecks the entire table before writing and preserves unrelated entries. This guards against observed concurrent edits. Crontab offers no atomic compare-and-swap, so avoid simultaneous edits by other tools. A private config file selected explicitly by an installed schedule is protected from ordinary launcher settings edits. The launcher requires UTC host time and no crontab timezone override for installation. Nothing changes the system timezone or controls the daemon service. On WSL, an active distro, running cron daemon, and awake host are needed when jobs are due.

## Reports and archives

| Generate Reports (6) | Window in the launcher | Artifacts |
|---|---|---|
| 1. Generate today's report | UTC midnight inclusive to a single captured current instant exclusive. Incomplete current-day report. | `reports/today/YYYY-MM-DD.html`, `reports/today/YYYY-MM-DD.pdf`, `reports/charts/today-YYYY-MM-DD-<sha256>.png` |
| 2. Generate previous day's report | Previous completed UTC day | `reports/daily/YYYY-MM-DD.{html,pdf}` |
| 3. Generate previous week's report | Previous completed UTC Monday–Sunday | `reports/weekly/YYYY-MM-DD_to_YYYY-MM-DD.{html,pdf}` |
| 4. Generate daily and weekly reports | Both completed windows | Daily and weekly paths above |
| 0. Return | | |

The engine writes a chart when there are valid samples and a PDF when PDF output is enabled. **NO DATA** is a valid result for an empty window. Wait a second after a new sample if generating immediately, since the cutoff is exclusive and timestamps have second precision. Today's generation leaves completed daily and weekly reports and historical measurements intact. The existing UTC cron schedule still runs daily at 00:10, weekly on Mondays at 00:20, and rotation at 00:30.

Use **7 → 1** for the PDF dated today in UTC. If it is absent, generate today's report with **6 → 1**. Use **7 → 4** to browse older partial reports in their folder. The latest completed daily and weekly PDFs are under **7 → 2/3**, their folders under **7 → 5/6**, and HTML and PNG browsing under **7 → 7**. All open requests require confirmation. PDFs also pass a local readability check. Existing PDFs are viewable with PDF creation switched off. For missing artifacts, the menu can take you to **Generate Reports** after confirmation.

On WSL, the launcher translates the path and asks Windows PowerShell to open it using the default file association. It can also use `wslview` where available. On Linux, it tries `xdg-open` or `gio open`. Acceptance by an opener is only confirmation that the request was handed off. A failure prints the exact absolute path and a paste-ready command. For example, from the checkout:

```bash
explorer.exe "$(wslpath -w "$PWD/reports/today")"   # WSL
xdg-open "$PWD/reports/today"                       # Linux desktop
```

Use **8 → 3** for a read-only retention preview before choosing rotation. Rotation archives completed UTC dates while preserving current-day measurements. Retention remains preview-only.

For development review, run the launcher suite separately from the seven-suite regression runner. Launcher automation uses fake cron, mail, and desktop openers.

```bash
bash tests/test_launcher.sh
bash tests/run_all.sh
```
