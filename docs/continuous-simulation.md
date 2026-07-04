# Continuous fire-and-forget attack simulation

Two complementary paths. Pick whichever fits — they can run together.

## Path A — Atomic Runner (recommended, resilient)

Red Canary's `invoke-atomicredteam` ships a feature called the [Atomic
Runner](https://github.com/redcanaryco/invoke-atomicredteam/wiki/Continuous-Atomic-Testing)
that runs as a Windows service, reads a CSV schedule, executes the next
enabled technique, sleeps, and reboots into the next one. Survives host
reboots and laptop disconnections.

### Install

```bash
scripts/start-continuous-sim.sh --windows
```

This runs `ansible/atomic-runner.yml` against `win-client1`:

1. Clones `redcanaryco/invoke-atomicredteam` to `C:\AtomicRedTeam\`
   (uses bootstrap-window egress — must run BEFORE `lock-down.sh`)
2. Drops `ansible/files/atomic-schedule.csv` onto the host as
   `C:\AtomicRunner\schedule.csv`
3. Calls `Install-AtomicRunner -InstallAsService` with a 6-hour
   `scheduleTimeSpan` (the runner spreads enabled techniques evenly over
   that window)
4. Starts the `atomicrunnerservice` Windows service and sets it to
   auto-start on boot

### Curating the schedule

`ansible/files/atomic-schedule.csv` is a deliberately conservative list.
**Excluded by policy**:

- `T1485` Data Destruction
- `T1486` Data Encrypted for Impact (ransomware)
- `T1490` Inhibit System Recovery
- `T1491` Defacement
- `T1561` Disk Wipe
- `T1565` Data Manipulation
- `T1529` System Shutdown/Reboot
- `T1003.001` LSASS dump (one-shot only; too noisy/risky in a loop)

Add techniques by appending rows to the CSV and re-running the playbook
(`Install-AtomicRunner` is idempotent).

### Stopping the loop

SSH to `win-client1` over Tailscale and create a sentinel file:

```powershell
New-Item C:\AtomicRunner\stop -Force
```

The runner checks for this file at the start of every iteration and
exits cleanly. To resume, delete the file and `Start-Service atomicrunnerservice`.

### Observing in Splunk

Each technique tagged in Splunk by `host` and by the Sysmon EID it
generates. Useful searches:

```spl
index=* host=*winclient1* | stats count by SourceName, EventID
index=* sourcetype="WinEventLog:Sysmon" host=*winclient1* EventCode=1 | table _time, Image, CommandLine
index=* AtomicGuid=*    | table _time, AtomicGuid, host
```

## Path B — `attack_range simulate --loop --random`

The patched fork (Patch 4 in `attack-range-patches.md`) adds four flags
to the `simulate` subcommand. Drive it from your laptop:

```bash
scripts/start-continuous-sim.sh --laptop
```

Which under the hood runs:

```bash
docker compose exec attack_range python attack_range.py simulate \
  --target winclient1 --techniques T1082 \
  --random --loop --interval 30 \
  --exclude T1485,T1486,T1490,T1491,T1561,T1565,T1529
```

`--target` is the bare role name from `templates/local_ludus/default.yml`'s
`attack_range:` list (`winclient1`, not `${RANGE_ID}-winclient1`) — that's
what `AttackRangeController.simulate()` matches against, and what the
per-host singleton group in `ansible/inventory.yml.j2` is named.
`--techniques` is required by argparse even with `--random` set (its value
is ignored — `--random` overrides it with a technique picked from the
Atomic Red Team indexes).

Pros: easier to retarget, easier to tweak the exclude list, controlled
from your laptop. Cons: stops when your laptop sleeps or loses Tailscale.

## Combining both

Atomic Runner provides the always-on baseline. Drop into the laptop loop
when you want to push a specific technique cluster manually:

```bash
docker compose exec attack_range python attack_range.py simulate \
  --target winclient1 \
  --techniques T1003.001,T1059.001,T1003.006
```

Then return to the long-running Atomic Runner for the steady drumbeat.

## Going further

For richer attack surface — APT Simulator inert artifacts, PurpleSharp
.NET techniques, CALDERA adversary emulation, and detonating real (but
defused) malware samples — see [`extended-attacks.md`](extended-attacks.md).
The extended tooling installs automatically during unattended ISO boot.
