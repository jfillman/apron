# cert-manager

Apron installs cert-manager with `components.certManager: true` (on in every profile): jetstack's chart, pinned in
`templates/10-crds-operators/cert-manager/application.yaml`, with its CRDs. Settings for it live under `certManager:` in
`cluster.yaml`. There is one today.

## DNS-01 self-check resolvers (`certManager.dns01RecursiveNameservers`)

Before cert-manager tells the ACME server a DNS-01 challenge is ready, it checks that the `_acme-challenge` TXT record
has propagated. To do that it finds the zone's authoritative nameservers (an SOA lookup) and asks them. By default
those lookups go through the controller pod's `/etc/resolv.conf`, which on Kubernetes is the cluster DNS (CoreDNS)
and whatever it forwards to.

That fails when the cluster's DNS cannot answer for the public zone:

- **split-horizon DNS**: the cluster's resolver has a private view of the zone (or of a parent zone), so the SOA or
  TXT answer is not the public one and the check never passes;
- **unreliable in-cluster DNS**: the upstream that CoreDNS forwards to times out or returns SERVFAIL for the SOA query,
  so the challenge sits with `Could not determine the zone ... SERVFAIL` while the TXT record is already public.

cert-manager's answer for both ([Setting nameservers for DNS01 self check](https://cert-manager.io/docs/configuration/acme/dns01/#setting-nameservers-for-dns01-self-check))
is to name the recursive resolvers it should use. Apron's knob:

```yaml
certManager:
  dns01RecursiveNameservers: ["1.1.1.1:53", "8.8.8.8:53"]
```

| Key | Default | Meaning |
|---|---|---|
| `certManager.dns01RecursiveNameservers` | unset (off) | a list of `host:port` recursive resolvers. Set, the controller runs with `--dns01-recursive-nameservers=<the list, comma-joined>` and `--dns01-recursive-nameservers-only` (the chart's `dns01RecursiveNameservers` and `dns01RecursiveNameserversOnly`), so every DNS-01 self-check lookup goes to these resolvers and none to the pod's `resolv.conf`. Unset or empty, nothing is rendered and cert-manager uses `resolv.conf` as before |

`apron check` refuses the key unless it is a list, refuses any entry that is not `host:port` (an IPv4 address, a DNS
name or a bracketed IPv6 address such as `[2606:4700:4700::1111]:53`, and a port 1-65535), refuses a resolver listed
twice, and refuses a non-empty list without `components.certManager`. Plain DNS only: cert-manager also takes
DNS-over-HTTPS URLs here, which Apron does not accept today.

It changes only cert-manager's self-check. It does not change how pods resolve names, what CoreDNS forwards to, or how the
ACME server validates the challenge (it always uses public DNS).

### Security note

With the key set, cert-manager sends its DNS-01 propagation queries (the SOA and TXT lookups for each challenged name,
such as `_acme-challenge.<host>`) to the resolvers you list, not to the cluster's DNS. Those resolvers, and the network
path to them, see which names this cluster is getting certificates for and when. Choose resolvers you trust with that
(a public resolver whose privacy policy you accept, or your own recursive resolver), and make sure the controller pod's
egress allows them on the port you give. A resolver that lies can only delay or pass the self-check early; it cannot
issue a certificate, since the ACME server validates the challenge itself. The names are public once the certificate
is in the Certificate Transparency logs anyway, but the timing and the resolver's view of them are not.

Because `--dns01-recursive-nameservers-only` is set, cert-manager does not fall back to the cluster's DNS when the listed
resolvers are unreachable: the challenge waits until one answers. The self-check can also take longer, since a recursive
resolver may cache a negative or old answer until its TTL runs out.
