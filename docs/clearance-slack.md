# Clearance Slack: the Slack surface of Clearance, from `cluster.yaml`

`clearance-slack` is a small service from the clearance chart (`slack.*`, clearance v0.47.1+; clearance `docs/slack.md` says what it does and
what it never does). It tells people what is waiting on them in Slack and lets a person whose Slack account is linked to their
people-dex sign-in clear (tier 2) or deny from the message. It is a surface on Clearance, never a dependency: nothing about the
core, Tower or the CLI changes if it is off or down.

Apron renders it **off by default** and an off cluster renders byte for byte what it did before. Everything below is one block of
`cluster.yaml`; the lab (hangar-dev) and the EKS clusters use the same keys, and only the `tls` and `idp` keys differ.

## What turning it on renders

| Where | What |
|---|---|
| clearance Application (`55-clearance/clearance`) | the chart's `slack.*` values (`existingSecret: clearance-slack`, `idpClientId: clearance-slack`, `idpClientSecret: true`, the public URL, routes, web URL, the Slack client id, the image digest) and `networkPolicy.slack` (ingress from the Gateway's namespace; egress to people-dex's keys in-cluster and to its public issuer URL). The chart adds the pod's service account to `delegates`, `api.notifiers` and `api.observationReaders`, opens the core's and api's ingress to it, and gives it Slack on 443 outbound |
| `clearance-config/postgres.yaml` | a CloudNativePG **managed role** `clearance_slack` on `clearance-pg` (password in the Secret `clearance-pg-slack`) |
| `clearance-config/slack-secret.yaml` | the generated password (ESO `Password` generator, created once, as clearance-api's reader's is), the `Database` `clearance_slack` owned by that role (never dropped with the object), and the ExternalSecret `clearance-slack` that builds the Secret the chart mounts: `bot-token`, `app-token` (or `signing-secret` on `events`), `client-secret`, `idp-client-secret` from Infisical, and `dsn` from the generated Secret. There is **no `dsn` secret in Infisical**, and the role has no grant on the evidence database's tables |
| `clearance-config/slack-route.yaml` | the HTTPRoute for the public host |
| `clearance-config/slack-tls.yaml` | `tls.mode: dns01-route53` only: an `Issuer` (Let's Encrypt, Route 53 DNS-01) and a `Certificate` `clearance-slack-tls` in the Gateway's namespace, and for `auth: serviceAccount` the ServiceAccount `clearance-dns01` with a Role that lets cert-manager create tokens for it and no other account (for `auth: static` an ExternalSecret of the key pair instead) |
| `10-crds-operators/traefik/gateway.yaml` | `tls.mode: dns01-route53` only: an https listener `clearance-slack-https` for that one host on the Gateway, referencing `clearance-slack-tls` (the route attaches to it by name, so the host is never served in clear text) |
| `55-identity/people-dex` | the confidential static client `clearance-slack` (redirect `<publicUrl>/link/idp`), its secret read by Dex from the Secret `clearance-slack-idp` (ExternalSecret, same Infisical key as the service's `idp-client-secret`) |

Apron creates no secret and does no DNS. `apron check` refuses an enabled cluster that is missing what it needs, by name.

## The knobs

```yaml
# Lab (hangar-dev): the Gateway serves the certificate itself.
versions:
  clearance:
    chart: 0.47.1                     # first chart with slack.*; bump with imageDigest (below)
    imageDigest: sha256:7565fa9ceac82bd222f3cc4d8557e53561b67476e26d35b395508ee09ae02179   # clearance v0.47.1's index
clearance:
  slack:
    enabled: true
    publicUrl: https://slack.clearance.hangarplatform.dev
    slackClientId: "<the Slack app's Client ID>"       # Basic Information > App Credentials; not secret
    routes:                                              # channel ids (C...), not names
      groups: {"group:default/admins": C0XXXXXXXXX}      # owner or outside group -> where its holds go
      security: C0XXXXXXXXX                              # break-glass, monitoring-protection, blind/degraded coverage
      ops: C0XXXXXXXXX                                   # stuck attestations (security when empty)
      default: C0XXXXXXXXX                               # a group with no entry
    webUrl: https://clearance.hangar-dev.local/changes/{id}   # optional; default: the web UI's page when clearance.web.enabled
    tls:
      mode: dns01-route53
      dns01:
        hostedZoneID: Z0XXXXXXXXXXXXXXXXXXX            # the clearance.hangarplatform.dev hosted zone
        email: you@example.com                           # Let's Encrypt contact
        roleARN: arn:aws:iam::<account>:role/hangar-dev-clearance-dns01     # auth: serviceAccount (default)
    idp:
      hostAlias: 192.168.1.NN       # an address where dex.hangar-dev.local answers, on the URL's port, for the pod (the lab has no DNS for it)
```

```yaml
# EKS (later): the same host, TLS ends at the load balancer. No tls block, no idp.hostAlias (dex.<domain> is public DNS).
clearance:
  slack:
    enabled: true
    publicUrl: https://slack.clearance.hangarplatform.dev
    slackClientId: "<the same Client ID>"
    routes: {...}
```

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `false` | the switch |
| `publicUrl` | required | `https://<host>` only. Slack accepts no other redirect for Sign in with Slack |
| `slackClientId` | required | Client ID of the Slack app, quoted (`1234.5678`) |
| `routes` | none | `groups`, `apps`, `scopes` (name -> channel id), `default`, `security`, `ops` (channel id). No routes: DMs only |
| `webUrl` | web UI page if `clearance.web.enabled`, else empty | tier 3 cannot be cleared from Slack; the message links here, or names the CLI command when empty. Must contain `{id}` |
| `transport` | `socket` | `socket`: outbound websocket, nothing inbound from Slack. `events`: Slack POSTs `<publicUrl>/slack/*` (needs the signing secret, not the app token) |
| `tls.mode` | `gateway-existing` | `gateway-existing`: TLS already ends in front of the Gateway (`gateway.scheme: https`, the EKS NLB with its ACM certificate); Apron renders the route only. `dns01-route53`: the Gateway serves the certificate (`gateway.scheme` stays `http`; needs `components.certManager`). Each mode is refused where the other applies |
| `tls.dns01.hostedZoneID`, `email` | required with `dns01-route53` | the zone cert-manager writes the challenge into, and the ACME contact |
| `tls.dns01.region` | `us-east-1` | the region the solver signs with (Route 53 is global) |
| `tls.dns01.server` | Let's Encrypt production | the ACME directory (use the staging URL while trying it) |
| `tls.dns01.auth` | `serviceAccount` | `serviceAccount`: no stored key (see below). `static`: an IAM user's key pair in Infisical |
| `tls.dns01.roleARN` | required with `serviceAccount` | the IAM role cert-manager assumes |
| `idp.hostAlias` | none | an IP for `dex.<domain>` in the pod's `hostAliases`, and egress narrowed to that `/32` on the issuer URL's port (80 on a plain-http gateway, 443 on https) |
| `idp.cidrs` | `["0.0.0.0/0"]` | without a hostAlias: the CIDRs that name resolves to; egress to them on that port |

## The owner's steps, in order

Nothing here is done by Apron or the service.

### 1. DNS (Route 53)

1. Create the public hosted zone **`clearance.hangarplatform.dev`** in Route 53. Note its **zone id** (`Z...`; the `hostedZoneID` knob).
2. Delegate it: at the parent zone `hangarplatform.dev`, add an `NS` record for `clearance` with the four name servers Route 53
   shows for the new zone.
3. In the new zone create the record for the one host the service uses:

   | Where it runs | Record | Value |
   |---|---|---|
   | Lab (today) | `slack.clearance.hangarplatform.dev` `A` | the lab Gateway's LAN address. A private address in public DNS is fine: only browsers on the LAN need the link pages, and Slack uses Socket Mode (outbound). Nothing is exposed |
   | EKS (later) | `slack.clearance.hangarplatform.dev` `A` (alias) or `CNAME` | the cluster's public endpoint: the Traefik Service's NLB. Change the record; nothing else moves |

   Do **not** create `_acme-challenge.slack...`: cert-manager creates and removes that TXT record itself.
4. Lab only: the LAN address must answer on **443** and forward it to Traefik's https NodePort (`traefik.httpsNodePort`, 30443 on
   kiac). The lab's ingress relays today carry 80; add the same relay for 443 if it is not there.

### 2. The certificate's credential (Route 53 DNS-01)

cert-manager proves control of the host by writing a TXT record into the zone, so it needs a credential limited to that zone. Both
variants use this permission policy (replace `Z0XXXXXXXXXXXXXXXXXXX` with the zone id and the host if it differs); it can only
touch `_acme-challenge.slack.clearance.hangarplatform.dev` TXT records in that one zone:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": "route53:GetChange", "Resource": "arn:aws:route53:::change/*"},
    {"Effect": "Allow", "Action": "route53:ListResourceRecordSets",
     "Resource": "arn:aws:route53:::hostedzone/Z0XXXXXXXXXXXXXXXXXXX"},
    {"Effect": "Allow", "Action": "route53:ChangeResourceRecordSets",
     "Resource": "arn:aws:route53:::hostedzone/Z0XXXXXXXXXXXXXXXXXXX",
     "Condition": {
       "ForAllValues:StringEquals": {
         "route53:ChangeResourceRecordSetsNormalizedRecordNames": ["_acme-challenge.slack.clearance.hangarplatform.dev"],
         "route53:ChangeResourceRecordSetsRecordTypes": ["TXT"],
         "route53:ChangeResourceRecordSetsActions": ["UPSERT", "DELETE"]
       }
     }}
  ]
}
```

**Preferred, no stored key (`auth: serviceAccount`, the default).** cert-manager asks this cluster's API server for a token of the
ServiceAccount `clearance-dns01` in the Gateway's namespace (audience `sts.amazonaws.com`) and exchanges it with
`AssumeRoleWithWebIdentity`. It works wherever the cluster's issuer is already an IAM OIDC provider (on EKS it is the cluster's
own provider; for the lab, the keyless AWS deploys rely on the same federation: confirm under IAM > Identity providers). Create an IAM role with the policy above and this **trust policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::<account>:oidc-provider/<issuer without https://>"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {
      "<issuer without https://>:aud": "sts.amazonaws.com",
      "<issuer without https://>:sub": "system:serviceaccount:hangar-gateway:clearance-dns01"
    }}
  }]
}
```

`<issuer>` is the cluster's `issuer` (`apron render --print-values`; `https://hangarplatform.dev/oidc/hangar-dev` for the lab, so
`hangarplatform.dev/oidc/hangar-dev`) and the namespace is `gateway.namespace` (default `hangar-gateway`). Put the role's ARN in
`clearance.slack.tls.dns01.roleARN`. If the cluster's issuer is not an IAM OIDC provider yet, register it first (audience
`sts.amazonaws.com`) or use the fallback.

**Fallback (`auth: static`).** An IAM **user** with only the policy above and one access key. Put the pair in Infisical as
`clearance-dns01-route53-access-key-id` and `clearance-dns01-route53-secret-access-key` (step 3). Rotate it like any key.

### 3. Slack app and Infisical keys

Create the app from clearance `docs/slack.md`'s manifest (Slack: *Create New App > From a manifest*), with the redirect URL
**`https://slack.clearance.hangarplatform.dev/link/slack`** (the manifest's `oauth_config.redirect_urls`; Slack's own validation at
import is the first check), install it to the workspace, and invite the bot to each channel it posts in. Create these in Infisical,
project **glidepath-hangar-dev**, environment **shared**, path **/** (the `platform-secret-store` reads them); Apron never creates
or stores them:

| Infisical key | Slack screen (or how) | Needed |
|---|---|---|
| `clearance-slack-bot-token` | *OAuth & Permissions* > Bot User OAuth Token (`xoxb-`) | always |
| `clearance-slack-app-token` | *Basic Information* > App-Level Tokens: generate one with scope `connections:write` (`xapp-`) | `transport: socket` (default) |
| `clearance-slack-signing-secret` | *Basic Information* > App Credentials > Signing Secret | `transport: events` only |
| `clearance-slack-signin-client-secret` | *Basic Information* > App Credentials > Client Secret (Sign in with Slack). The Client ID next to it is the `slackClientId` knob | always |
| `clearance-slack-idp-client-secret` | no Slack screen: a random value you generate (`openssl rand -hex 32`). people-dex's confidential client `clearance-slack` and the service both read this one key | always |
| `clearance-dns01-route53-access-key-id`, `clearance-dns01-route53-secret-access-key` | the IAM user's key (step 2, fallback) | `tls.dns01.auth: static` only |

There is no database secret: the role, database and password are rendered and generated in the cluster.

### 4. Channel ids

In Slack, open each channel > *View channel details* > the id at the bottom (`C0...`). They go in `routes`. Names are refused.

### 5. Enable it

1. In the cluster repo's `cluster.yaml`, set the block above (the lab's is the first example). It also needs the chart pinned at
   0.47.1 with `versions.clearance.imageDigest` of the same release (`apron check` says so otherwise). Those two are Apron's
   `versions.yaml` (the usual Clearance release bump, its own change: the bump also re-renders the core's Application); for a
   single cluster they can be set in its `cluster.yaml` as in the example.
2. `apron check`, then `apron render`; review the diff: only the objects in the table at the top appear.
3. Merge the cluster repo PR. Argo CD applies `clearance-config` (role, database, secrets, route, certificate), `traefik` (the
   listener), `autopilot-people-dex` (the client) and `clearance` (the pod).

### 6. Verify

- `kubectl get externalsecret -A | grep clearance-slack` all Ready; the Secret `clearance-slack` has the keys `bot-token`, `app-token`, `client-secret`,
  `idp-client-secret` and `dsn` (`signing-secret` instead of `app-token` on `events`).
- `kubectl -n clearance-system get database clearance-slack` applied; `kubectl -n hangar-gateway get certificate clearance-slack-tls`
  Ready (the first issuance takes a minute or two for the TXT record to propagate).
- `kubectl -n hangar-gateway get gateway hangar -o yaml`: the listener `clearance-slack-https` is Programmed and its route Accepted.
- `curl https://slack.clearance.hangarplatform.dev/healthz` from a LAN host (lab) answers 200 with a publicly trusted certificate.
- `kubectl -n clearance-system logs deploy/clearance-slack` shows the Socket Mode connection. Then `/clearance link` in Slack and open
  a tier 2 change you did not propose.

### 7. Moving to EKS (later)

Point the record at the cluster's NLB (step 1), make the NLB's ACM certificate cover `slack.clearance.hangarplatform.dev` (add it
as a SAN of the `traefik.loadBalancer.certificateArn` certificate), set `tls.mode: gateway-existing` (or omit it: with
`gateway.scheme: https` that is the default) and drop `tls` and `idp.hostAlias`. The same Slack app, tokens and Infisical keys
serve it (one Socket Mode connection: run it on one cluster at a time, and turn it off on the other).

## Things to know

- **Not verified live.** Apron's tests render and parse every object; nothing here has run against a cluster, a Route 53 zone or a
  Slack workspace. Three things worth watching on the first apply: the `Secret` `clearance-slack` carries `dsn` (the ExternalSecret
  merges it from the generated Secret with `templateFrom`), the pod reaches `dex.<domain>` (the issuer URL it discovers and posts
  the code to; `idp.hostAlias`/`idp.cidrs`), and the certificate's first DNS-01 challenge.
- The link flow needs the browser to reach both `https://slack.clearance.hangarplatform.dev` and people-dex (`dex.<domain>`).
- The service's database is not in the nightly dump of `clearance-pg`: it holds links and message ids, never evidence; people
  re-link after a rebuild.
- One replica: one Socket Mode connection, one stream cursor.
