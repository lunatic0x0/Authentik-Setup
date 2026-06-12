# Authentik Local Lab — MITRE Eval 2026 (ER8) Prep

A minimal, reproducible local Authentik deployment for detection-engineering work against the same IdP MITRE is using in ER8. Targeted at macOS + Docker Desktop.

---

## 1. Prerequisites

- macOS 13+ with **Docker Desktop** (or OrbStack — works the same).
- 4 GB RAM available to the container runtime (Authentik server + worker + Postgres + Redis are not heavy, but the Python worker spikes during bootstrap).
- `openssl` (ships with macOS).
- Port `9000` / `9443` free on localhost (override in `.env` if not).

Verify:

```bash
docker version
docker compose version
openssl version
```

## 2. Bring up the stack

```bash
cd "<this folder>"
./bootstrap.sh           # generates .env with strong secrets
docker compose pull
docker compose up -d
docker compose ps
```

First-time pull is ~1.5 GB. The `worker` container will run database migrations on first start — give it 30–60 seconds and watch `docker compose logs -f worker` until you see `Startup complete`.

## 3. Initial setup

Open the **initial setup flow** (this only works once — it's how you bootstrap the `akadmin` account):

```
http://localhost:9000/if/flow/initial-setup/
```

Set a strong password for `akadmin`. Afterwards, the admin UI is at:

```
http://localhost:9000/if/admin/
```

If you'd rather use HTTPS with the self-signed cert: `https://localhost:9443/if/admin/`.

## 4. Useful one-liners

```bash
# Tail server + worker
docker compose logs -f server worker

# Open a Django shell inside the server (great for poking models)
docker compose exec server ak shell

# Dump current Authentik version
docker compose exec server ak --version

# Reset everything (destroys data!)
docker compose down -v && rm -rf media custom-templates certs .env
```

## 5. Where the audit data lives

Authentik writes **`authentik_events_event`** rows to Postgres for every meaningful action: logins, failed logins, MFA challenges, policy executions, password resets, token issuance, OAuth/SAML grants, group changes, impersonation, etc. These are the rows you'll eventually want to ship into S1 (or whatever pipeline you use for MITRE eval visibility). We'll wire that up in the next iteration — the env already runs at `info` and supports flipping to `debug` for richer signal.

A quick browse:

```bash
docker compose exec postgresql \
  psql -U authentik -d authentik \
  -c "SELECT action, user, context FROM authentik_events_event ORDER BY created DESC LIMIT 25;"
```

The web UI also surfaces these at **Events → Logs** and **Events → System Tasks**.

---

## 6. Connecting local Authentik to your AWS account

**Short answer: yes, it can be done — but AWS needs to reach your Authentik metadata URL.** That's the gotcha with running an IdP on a laptop. Three patterns, in order of how closely they likely match the MITRE ER8 setup:

### Option A — SAML 2.0 to AWS IAM Identity Center (recommended)

This is what most enterprises run today and is the cleanest fit for an "Authentik = corporate IdP" model.

- In **Identity Center → Settings → Identity source → Change identity source → External identity provider**, AWS gives you a SAML metadata XML / ACS URL / Issuer URL.
- In **Authentik → Applications → Providers → Create → SAML Provider**, you import AWS's metadata, set the ACS URL, and configure `NameID = email` (or persistent — match what Identity Center expects).
- Attribute mappings you'll want: `https://aws.amazon.com/SAML/Attributes/Role` and `RoleSessionName`. Authentik has "SAML Property Mappings" — there are pre-shipped ones; the role-mapping one you'll build by hand pointing at a user attribute or group.
- AWS pulls Authentik's metadata from `http://<your-authentik>/api/v3/providers/saml/<pk>/metadata/?download`. **AWS cannot reach `localhost`.** You expose Authentik through one of:
  - Cloudflare Tunnel (`cloudflared tunnel --url http://localhost:9000`) — free, no firewall config, gives you a stable `*.trycloudflare.com` URL.
  - `ngrok http 9000` — same idea.
  - A small EC2 / Lightsail reverse proxy in the eval AWS account pointing back at a tailnet'd Authentik (cleanest, but more work).

> Pin a static hostname before you wire up SAML. SAML metadata embeds the IdP entity ID — if the hostname changes you re-import metadata everywhere.

### Option B — SAML 2.0 directly to IAM roles (classic federation)

Same shape as Option A but you create a SAML IdP entity inside the AWS account directly (`IAM → Identity providers → Add provider → SAML`). You then create one or more roles that **trust** that SAML provider and Authentik users assume them via the AWS console SSO landing page. Lower blast radius and easier to spin up for a single account, but it's the older pattern — MITRE eval emulation may or may not follow this depending on how the target enterprise is modeled.

### Option C — OIDC web identity to IAM roles

Authentik exposes an OIDC issuer; AWS supports OIDC IdPs for role assumption (`sts:AssumeRoleWithWebIdentity`). Less common for human-user SSO; more common for CI / workload federation. Skip unless ER8 specifically scopes this.

### My recommendation

Start with **Option A (Identity Center via SAML)**, fronted by a **Cloudflare Tunnel**. It mirrors the realistic enterprise topology MITRE is likely emulating, gives you both Authentik audit logs and CloudTrail `sts:AssumeRoleWithSAML` events to correlate against, and the tunnel sidesteps the "AWS can't reach my laptop" wall without opening any inbound ports.

What you'll need from the AWS lab:

1. Confirmation Identity Center is enabled (or willingness to enable it) in the lab account.
2. Permission to add an external identity provider in Identity Center.
3. One or two permission sets to map Authentik groups to (e.g., `LabAdmin`, `LabReadOnly`).
4. The CloudTrail trail name — so we can later subscribe a forwarder to its events.

## 7. What's next

Once the stack is healthy and you've confirmed the lab AWS prerequisites, the next steps are:

1. Stand up a Cloudflare Tunnel and a stable hostname.
2. Wire Authentik ↔ AWS Identity Center (Option A) end-to-end with a single test user.
3. Drive sample logons (success + failure + MFA + impersonation) and verify both Authentik `authentik_events_event` rows **and** CloudTrail `sts:AssumeRoleWithSAML` / `Federate` events are produced.
4. Sketch the first detection candidates from those two correlated streams — that's where the red-team / detection-engineering work starts paying off for ER8.

---

## 8. Troubleshooting cheatsheet

| Symptom | Likely cause | Fix |
|---|---|---|
| `worker` exits with `connection refused` | Postgres still initializing | Wait — healthcheck gates `worker`; should self-recover. |
| `Initial setup` URL 404s | You've already run it once | Use `akadmin` + the password you set. Reset via Django shell if forgotten. |
| Browser warns on `:9443` | Self-signed cert | Expected. Use `:9000` HTTP locally or import the cert. |
| `docker compose pull` is slow | Pulling 1.5 GB of layers from ghcr.io | One-time cost; subsequent pulls are deltas. |
| `Permission denied` on `media/` | Container UID mismatch | `chmod 777 media/` is fine for a local lab. |

## 9. References

- Authentik docs: https://docs.goauthentik.io/
- Compose install reference: https://docs.goauthentik.io/docs/install-config/install/docker-compose
- AWS Identity Center external IdP: https://docs.aws.amazon.com/singlesignon/latest/userguide/manage-your-identity-source-idp.html
- MITRE ATT&CK Evaluations ER8 scope: https://evals.mitre.org/enterprise/er8
