# Tailscale ACLs for lab isolation

Even though every lab VM is joined to your tailnet, only your operator
device should be able to reach them. Paste this into your tailnet ACL
policy editor (Admin Console → Access Controls).

```jsonc
{
  "tagOwners": {
    "tag:lab-range":    ["autogroup:admin"],
    "tag:lab-operator": ["autogroup:admin"]
  },

  "acls": [
    // Operators can reach all lab hosts on any port.
    { "action": "accept",
      "src": ["tag:lab-operator"],
      "dst": ["tag:lab-range:*"] },

    // Lab hosts can reach each other (so Splunk UF can forward, Kali can
    // pivot, etc). Tailscale only matters for laptop access — the VMs talk
    // over the VLAN normally.
    { "action": "accept",
      "src": ["tag:lab-range"],
      "dst": ["tag:lab-range:*"] }

    // No other rules. Everything else is implicitly denied. This is the
    // important bit: random devices on your tailnet CANNOT reach lab hosts.
  ],

  "ssh": [
    // Operators get Tailscale SSH to every lab host as root/Admin.
    { "action": "accept",
      "src":    ["tag:lab-operator"],
      "dst":    ["tag:lab-range"],
      "users":  ["root", "ubuntu", "kali", "Administrator", "rangeadmin"] }
  ]
}
```

Then tag your operator laptop:

```bash
tailscale set --advertise-tags=tag:lab-operator
```

The lab VMs receive `tag:lab-range` automatically because the auth key
the `NocteDefensor.ludus_tailscale` role uses was generated with that tag
(set via `TS_TAG` in `.env`).

## Verifying ACL behaviour

From a tailnet device that is **NOT** tagged `lab-operator`:

```bash
tailscale ping <RANGE_ID>-splunk    # should fail (no path)
ssh <RANGE_ID>-splunk               # should fail (denied by ACL)
```

From your operator laptop:

```bash
tailscale ping <RANGE_ID>-splunk    # should succeed
ssh ubuntu@<RANGE_ID>-splunk        # should work via Tailscale SSH
```
