# Active Directory forest

Ludus builds the forest in-line with the range deploy. The forest topology
is defined entirely by `domain:` blocks in `ludus/range-config.yml.j2`.

## Topology

| Host | OS | `domain.role` | Notes |
|---|---|---|---|
| `dc01` | Win Server 2022 | `primary-dc` | Holds all FSMO roles, AD DNS |
| `win-client1` | Win 11 Enterprise | `member` | Domain-joined, attack target |
| `win-srv1` | Win Server 2022 | `member` | Domain-joined, file/IIS server |

Forest root domain: `range.local` (override via `AD_DOMAIN_FQDN` in `.env`).

## Credentials

- **Domain admin**: `${AD_DOMAIN_ADMIN}` / `${AD_PASSWORD}` (from `.env`)
- **Local admin on each Windows host**: Ludus default, see
  `ludus users credentials` after deploy

## What Ludus does for you

1. Promotes `dc01` to a DC, creates the `range.local` forest
2. Sets up AD DNS, points the DC's DNS to itself
3. Domain-joins every VM with `domain.role: member`
4. Creates the domain admin user with `defaults.ad_domain_admin*` from
   the range config
5. Applies sane group policies (firewall on but allowing intra-VLAN,
   WinRM enabled on member hosts, etc.)

The Tailscale role sets `tailscale_dns: false` on `dc01` so it stays
DNS-authoritative for its zone — clients still resolve internal names via
AD, not MagicDNS, when on the lab VLAN.

## Extending the forest

To add more domain-joined hosts, append more VM entries to
`range-config.yml.j2` with `domain: { fqdn: range.local, role: member }`.
Each gets joined automatically.

For a vulnerable AD-with-misconfigurations overlay, layer
[Game of Active Directory](https://docs.ludus.cloud/docs/environment-guides/goad/)
on top — its Ansible roles are compatible with this range.

For a multi-domain forest, add a second VM with
`domain: { fqdn: child.range.local, role: alt-dc }`.

## Verifying the forest

From the DC (Tailscale SSH):

```powershell
Get-ADDomain
Get-ADUser rangeadmin
Get-ADComputer -Filter *
```

From a member host:

```powershell
nltest /dsgetdc:range.local
gpresult /r
```

From Splunk: `index=* sourcetype="WinEventLog:Security" EventCode=4624` to
see successful logons across the forest.
