# Extended attack tooling + defused malware samples

The default Atomic Runner schedule (24 techniques, 6 h rotation) is the
baseline drumbeat. This doc covers the *extended* layer: ~70-technique
expanded Atomic schedule, three additional red-team frameworks, and a
controlled path for detonating real-but-defused malware samples.

All of it is installed by `scripts/install-extended-attacks.sh`, which
runs **automatically during the unattended ISO bootstrap** (between
`deploy-range` and `lock-down-egress` phases). You can also run it
manually if you set up the range step-by-step.

## What gets installed

### On `win-client1`

| Tool | What it does | Source |
|---|---|---|
| **Extended Atomic schedule** | Replaces the 24-technique CSV with a curated ~70-technique set covering Discovery, Persistence, Defense Evasion, Credential Access, Lateral Movement, C2 simulation, Defense impairment. Atomic Runner picks it up on restart. | `ansible/files/atomic-schedule-extended.csv` |
| **APT Simulator** (Florian Roth, NextronSystems) | Inert artifacts that look like real APT activity — HOSTS edits, scheduled tasks named like known APT toolkits, registry runners using APT IOC names, files in known malware paths. Rich detection telemetry without actual malware. | `github.com/NextronSystems/APTSimulator` |
| **PurpleSharp** | C#/.NET red-team simulation. Runs ATT&CK techniques end-to-end with realistic timing. Compiled binary, no network calls. | `github.com/mvelazc0/PurpleSharp` |
| **CALDERA Sandcat agent** | MITRE's adversary-emulation implant. Connects back to the CALDERA server on `kali` for fully scripted attack chains. | `github.com/mitre/caldera` |
| **EICAR test file** | Universal AV/EDR test string. Triggers Defender alerts; Sysmon TA forwards them to Splunk. | `eicar.org` |
| **Defused malware samples** (optional) | Real samples pulled from abuse.ch MalwareBazaar in password-protected ZIPs, staged in `C:\Quarantine\` with Defender excluded so they don't auto-delete. Detonated one at a time via `scripts/detonate-sample.sh`. | `bazaar.abuse.ch` |

### On `kali`

| Tool | What it does |
|---|---|
| **MITRE CALDERA server** | Web UI on `http://<kali>:8888`, controls the Sandcat agent on `win-client1`. Pre-loaded with `sandcat`, `stockpile`, `atomic`, `response`, `training` plugins. Default login `red` / `${CALDERA_PASSWORD}`. |

## Bootstrap window — what needs egress

The extended tooling needs to pull binaries during the install. These
domains are reachable during the bootstrap allowlist window:

- `github.com` / `objects.githubusercontent.com` — APT Simulator, PurpleSharp, CALDERA git clone
- `bazaar.abuse.ch` / `mb-api.abuse.ch` — MalwareBazaar API
- The Ubuntu apt mirrors that ship with Kali for CALDERA's build deps

`scripts/lock-down.sh` runs AFTER `install-extended-attacks.sh`, so the
allowlist closes once everything is on disk. After lockdown, nothing
here can phone home — even if a malware sample tries to call its real
C2, the Ludus router drops it.

## Defused malware samples — handling

"Defused" here is a four-layer safety model:

1. **Password-protected ZIP** — `abuse.ch` archives the binary with a
   password (default: `infected`). They can't accidentally execute on
   transit or be triggered by an autoplay handler.
2. **Quarantine directory with Defender excluded** — staged in
   `C:\Quarantine\` so Defender doesn't auto-delete during the pull,
   but the *containing* directory has an outbound firewall rule that
   blocks any program executing from it from reaching the network.
3. **Lab is air-gapped** — `scripts/lock-down.sh` runs first; sample
   detonation only allowed if `scripts/verify-isolation.sh` exits 0.
4. **Operator must type `DETONATE`** — `scripts/detonate-sample.sh`
   refuses without explicit confirmation, runs the sample with a 60-second
   watchdog, then kills it.

### Configuring the sample set

1. Get a free abuse.ch MalwareBazaar Auth-Key:
   <https://bazaar.abuse.ch/account/>
2. Add to `.env`:
   ```
   MALWARE_BAZAAR_API_KEY=...
   MALWARE_ARCHIVE_PASSWORD=infected
   ```
3. Edit `ansible/malware-samples.yml` → `bazaar_hashes:` list. Use
   SHA-256 hashes from [MalwareBazaar's search](https://bazaar.abuse.ch/browse/).
   **Recommended**: older, well-characterised samples — Emotet,
   Trickbot, Cobalt Strike beacons, older Conti. Avoid fresh samples
   and avoid wipers / ransomware actually capable of damage.
4. `scripts/install-extended-attacks.sh` pulls them on next run.

### Detonating

```bash
# See what's staged
scripts/list-samples.sh

# Drop EICAR (universal, totally safe — good first test)
scripts/detonate-sample.sh --eicar

# Detonate one real sample (with confirmation prompt + 60s watchdog)
scripts/detonate-sample.sh 4e7c5a3b5fbf85eb4d5d4b71e1c4d9e9f5e8a7b3c2d1e0f9a8b7c6d5e4f3a2b1c
```

### What you'll see in Splunk

```spl
# Defender / EDR detections
index=* host=*winclient1* sourcetype="WinEventLog:Microsoft-Windows-Windows Defender/Operational"
  EventCode IN (1116, 1117)
| table _time, Threat_Name, Path, Action

# Sysmon process creation chains
index=* host=*winclient1* sourcetype="WinEventLog:Sysmon" EventCode=1
  Image="*\\Quarantine\\*"
| table _time, ParentImage, Image, CommandLine

# CALDERA agent comms
index=* host=*winclient1* DestinationIp="*kali*" DestinationPort=8888
```

## Using CALDERA

1. Browse to <http://`<RANGE_ID>`-kali:8888> over Tailscale
2. Login `red` / `${CALDERA_PASSWORD}`
3. **Agents** → confirm the Sandcat from `winclient1` is checked in
4. **Adversaries** → pick a profile (the `Hunter` profile is a good
   detection-engineering starter; `Discovery` is gentle)
5. **Operations** → New operation, target the `red` group, start
6. Splunk: `index=* host=*winclient1* | stats count by Image, CommandLine`
   will now show the full operation chain.

## Disabling extended tooling

If you want to roll back to just the baseline 24-technique Atomic Runner:

```bash
# On win-client1 via Tailscale SSH:
ansible -i ansible/inventory.yml -m ansible.windows.win_powershell \
  -a "script: 'Remove-Item C:\\AttackTools -Recurse -Force; Stop-ScheduledTask -TaskName caldera-sandcat'" \
  windows
# Restore the small CSV:
cp ansible/files/atomic-schedule.csv /tmp/ && \
  ansible -i ansible/inventory.yml -m ansible.windows.win_copy \
    -a "src=/tmp/atomic-schedule.csv dest=C:\\AtomicRunner\\schedule.csv" windows
```

## Why this matters for detection engineering

Atomic Red Team techniques are deterministic — they always look the
same, so detection rules trained on them get brittle. APT Simulator
adds noise from realistic-looking IOCs. PurpleSharp adds a CLR-loaded
detection surface. CALDERA adds adaptive multi-step operations. Defused
malware samples close the loop: rules tested against pure simulation
need real binaries to validate against. Together they exercise far
more of the EDR/SIEM detection surface than ART alone.
