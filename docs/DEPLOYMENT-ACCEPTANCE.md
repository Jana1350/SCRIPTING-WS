# Deployment acceptance, 24 November 2026

Member B verified the integrated scripts from base commit `e992eb2` on Ubuntu 24.04.4 LTS under WSL2. The cron daemon was active and enabled. All times below are UTC.

| Check | Observation |
|---|---|
| Scheduled monitoring | The production daemon dispatched at 09:01:07. Both the metrics CSV and cron log contained the 09:01:08 reading of 0.9% CPU, 19.4% memory and 1.0% disk. Earlier mock-mode runs were 60 seconds apart. |
| Sender and recipient | The operator confirmed receipt of the setup message. The sender is configured in the Linux user's mail transport. The recipient is stored in the ignored local configuration. Each deployment machine needs its own transport setup. |
| Scheduled threshold alert | Cron started the isolated test at 09:00:07. A genuine 20.2% memory reading crossed the test-only 1% warning threshold at 09:00:08. The event changed from NORMAL to WARNING. The delivery ledger recorded successful submission, and the operator confirmed that specific alert in Gmail. |
| Isolation and recovery | The test used its own checkout, metrics, locks and state, with a single-use submission guard. The temporary entry was removed, the original crontab compared equal byte for byte, and production continued the next minute. A separate fake-crontab rehearsal exercised switching to mock and uninstalling while preserving unrelated jobs. |
| Fresh-checkout onboarding | The wizard collected a real first sample in a checkout with spaces and no private config. This was a fresh checkout on a machine with prerequisites already installed. Independent fresh-machine deployment remains pending. |
| Wizard regression tests | Fake mail and crontab cover monitoring without Gmail credentials, explicit approvals, recipient changes, private config, `OFF`, repeat execution and unrelated job preservation. Failure and interruption fixtures cover partial `OFF` completion and candidate cleanup. These tests do not contact SMTP or change the real crontab. |
| Local reports and rotation | The installed jobs matched the contract. Daily reports run at 00:10, weekly reports on Monday at 00:20, and rotation daily at 00:30. HTML, PDF, charts, gzip and archive consistency passed isolated tests. No scheduled maintenance execution had occurred by the evidence cutoff. Member C should confirm the first live outputs and corresponding daemon times. |

The release regression runner includes the wizard and the five existing suites. The live delivery and cron evidence above applies to the stated deployment baseline.

For mail or cron recovery, see [alert and cron operations](OPERATIONS.md). A failed submission retains its transition and is not automatically retried for that transition.

On WSL, scheduled jobs require the Ubuntu instance and cron daemon to be running at the scheduled time. A stopped instance or sleeping host can miss slots. To recover from partial `OFF` completion, keep the mock schedule and rerun setup to clear the recipient. If the schedule state is uncertain, inspect the managed crontab block before retrying.
