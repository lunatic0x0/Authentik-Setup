# Authentik on AWS — Step-by-Step Setup Guide

This walks you through deploying Authentik on a hardened EC2 instance in the lab AWS account, then federating it with AWS IAM Identity Center. Written for someone new to both Terraform and Authentik — every step explained, no skipped detail.

**What you end up with:** an Ubuntu 24.04 EC2 (matching MITRE ER8) running Authentik behind Caddy with a real Let's Encrypt TLS cert, no SSH, IMDSv2-only, encrypted disk, VPC flow logs to CloudWatch. About **$37/mo** while running 24/7. Full teardown with one command.

---

## Part 0 — Background (read this once)

**What is Terraform?** A tool that reads `.tf` files describing AWS resources and creates them in the right order via the AWS API. Same files = same infrastructure, every time. No clickops.

**What is Authentik?** An open-source identity provider (IdP) — similar in role to Okta, Auth0, or Ping. Users log in to Authentik; Authentik tells AWS (via SAML) who they are; AWS gives them a session.

**Why are we using sslip.io?** AWS IAM Identity Center won't trust a self-signed cert when it fetches IdP metadata, and we don't have a domain we own. `sslip.io` is a free public DNS service: any hostname like `13-49-1-5.sslip.io` automatically resolves to the IP `13.49.1.5`. Caddy uses that hostname to get a real Let's Encrypt cert. AWS happily trusts it.

**The flow at a glance:**

```
     [User browser]
           |
           v  (1) https://<eip>.sslip.io
   [Caddy on EC2 — TLS termination + LE cert]
           |
           v  (2) plain HTTP on docker network
   [Authentik server + worker]
           |
           v  (3) SAML
   [AWS IAM Identity Center]
           |
           v  (4) STS AssumeRoleWithSAML
       [AWS console / CLI]
```

---

## Part 1 — Install the tools on your Mac

Open Terminal and run each command. If a command says "(verify)", that's just to confirm the install worked.

```bash
# Homebrew — skip if you already have it
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Terraform
brew install terraform
terraform -version            # (verify) should print something like "Terraform v1.9.x"

# AWS CLI
brew install awscli
aws --version                 # (verify) should print "aws-cli/2.x"

# AWS Session Manager plugin — needed to shell into the EC2 (we don't use SSH)
brew install --cask session-manager-plugin
session-manager-plugin        # (verify) should print "The Session Manager plugin was installed successfully"
```

## Part 2 — Configure AWS credentials

The S1 lab account uses **traditional IAM username/password login** (not AWS SSO). For Terraform we don't use the password — we use an **access key pair** (an access key ID + a secret access key) tied to your IAM user.

> **Quick concept:** an IAM user can sign in to the console with a password and sign in to the CLI / Terraform / SDKs with an access key pair. They're two parallel credentials on the same user. Terraform always uses the access key pair.

### 2a. Create an access key pair (if you don't already have one)

1. Log in to the lab AWS console with your username + password.
2. Click your username (top-right corner) → **Security credentials**.
3. Scroll to **Access keys** → **Create access key**.
4. Use case: **Command Line Interface (CLI)** → acknowledge the recommendation → Next.
5. (Optional) tag it `terraform-deploy` so you remember why you made it.
6. Click **Create access key**.
7. You now see an **Access key ID** (starts with `AKIA…`) and a **Secret access key** (long random string).
   - **Download the .csv** or copy both values somewhere safe immediately — AWS will never show the secret key again.

> If your IAM user already has an access key from past work, you can reuse it. AWS limits one user to 2 active keys; rotate by creating a new one and deactivating the old.

### 2b. Configure the AWS CLI with these credentials

```bash
aws configure --profile s1-lab
```

It will prompt:

- **AWS Access Key ID:** paste the `AKIA…` value from step 2a.
- **AWS Secret Access Key:** paste the long secret.
- **Default region name:** the region you set in `terraform.tfvars` (default `us-east-1`).
- **Default output format:** `json`.

This writes two files in your home directory:

- `~/.aws/credentials` — holds your access key pair (chmod 600 — keep secret).
- `~/.aws/config` — holds your default region / output format.

### 2c. Tell your shell to use this profile for the rest of the session

```bash
export AWS_PROFILE=s1-lab
aws sts get-caller-identity
```

The `get-caller-identity` command should print your AWS account ID, your IAM user ARN, and a `UserId`. If you see that, Terraform will be able to use these credentials.

> **Protect this key like a password.** An IAM access key with admin rights is functionally equivalent to root access on the lab account. Never paste it into Slack, never commit it to a repo, never bake it into a Docker image. If you suspect it leaked, deactivate it in the console immediately.

> **MFA on the IAM user (recommended but optional for the lab):** if the lab IAM policy requires MFA for sensitive actions, you'll need to obtain a session token first with `aws sts get-session-token --serial-number arn:aws:iam::<acct>:mfa/<user> --token-code <6-digit code>`, then export the three temporary creds. Skip if MFA isn't enforced.

### 2d. (Later, separate concern) AWS IAM Identity Center for federation

Don't confuse Part 2 (how *you* authenticate to deploy) with the federation we set up later (how *eval users* will log in via Authentik). Even though your personal admin uses IAM username/password, we still **enable AWS IAM Identity Center inside the lab account** in Part 11 — because that's the service that brokers SAML logins from Authentik for the MITRE eval scenario. They are independent: your IAM user keeps working for Terraform after federation is set up.

## Part 3 — Configure your Terraform variables

```bash
cd "<path to this folder>/aws/terraform"
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` in any editor and set at minimum:

- `aws_region` — must match the region you set during `aws configure sso`
- `owner_tag` — your name/handle, gets tagged on every resource

Everything else can stay default. Save and close the file.

## Part 4 — Initialize Terraform

```bash
terraform init
```

**What this does:** downloads the AWS provider plugin (~80 MB) and the `random` provider into a hidden `.terraform/` folder. Required once before any other Terraform command. Re-run only if you upgrade provider versions.

Expected last line: `Terraform has been successfully initialized!`

## Part 5 — Preview what Terraform will create

```bash
terraform plan -out tf.plan
```

**What this does:** computes the diff between "nothing exists" and "what your .tf files describe" and writes it to a file called `tf.plan`. **Nothing has been created in AWS yet.**

Scroll through the output. You should see roughly:

```
Plan: 21 to add, 0 to change, 0 to destroy.
```

Lines starting with `+` are resources that will be created. Spend 30 seconds skimming — make sure the region and CIDR look right.

If you see anything red or an error about credentials, fix that before continuing.

## Part 6 — Create the infrastructure

```bash
terraform apply tf.plan
```

**What this does:** sends the API calls to AWS to create everything. Takes about **3 minutes**.

When it finishes you'll see something like:

```
Apply complete! Resources: 21 added, 0 changed, 0 destroyed.

Outputs:

authentik_admin_url = "https://13-49-1-5.sslip.io/if/admin/"
authentik_hostname = "13-49-1-5.sslip.io"
authentik_initial_setup_url = "https://13-49-1-5.sslip.io/if/flow/initial-setup/"
elastic_ip = "13.49.1.5"
instance_id = "i-0abc123..."
ssm_session_command = "aws ssm start-session --target i-0abc123... --region us-east-1"
saml_metadata_url_template = "https://13-49-1-5.sslip.io/api/v3/providers/saml/<pk>/metadata/?download"
```

**Save these values somewhere** — `terraform output` can re-print them any time.

> **Important:** the EC2 exists, but Authentik isn't ready yet. The instance is still running its cloud-init script (installing Docker, pulling images, starting containers, requesting a Let's Encrypt cert). This takes **another 3–5 minutes**. Don't refresh the URL repeatedly — give it the full 5 minutes first.

## Part 7 — Wait for cloud-init, then verify

While you wait, you can shell into the box (no SSH — uses AWS SSM) and watch:

```bash
aws ssm start-session --target "$(terraform output -raw instance_id)"
```

Once you're in:

```bash
# Tail the bootstrap log
sudo tail -f /var/log/cloud-init-output.log
# Ctrl-C when you see "authentik bootstrap finished"

# Confirm containers are up
sudo docker compose -f /opt/authentik/docker-compose.yml ps
# Should show 4 services: postgresql, redis, authentik-server, authentik-worker, caddy — all "running" and (most) "healthy"

# Watch Caddy get the cert
sudo docker compose -f /opt/authentik/docker-compose.yml logs -f caddy
# Look for: "certificate obtained successfully"
# Ctrl-C when you see it

# Exit the SSM session
exit
```

When Caddy reports the cert was obtained, open the initial setup URL in your browser:

```bash
open "$(terraform output -raw authentik_initial_setup_url)"
```

Your browser should load without any TLS warning — that's the proof Let's Encrypt worked end-to-end.

## Part 8 — Initial Authentik setup

The setup page is a one-shot flow that only works the very first time. It bootstraps the built-in `akadmin` account.

1. Set a strong password for `akadmin`. Save it in your password manager.
2. After submitting, you're dropped into the user interface.
3. Visit the **Admin UI** at `terraform output authentik_admin_url` (or click the gear icon in the top-right corner).

You're now logged in as the IdP super-admin.

## Part 9 — Create a test user and group in Authentik

Before we federate AWS, let's have a test user to log in with.

**Create a group:**

1. Admin UI → **Directory → Groups → Create**
2. Name: `aws-lab-admins`
3. Save.

**Create a user:**

1. Admin UI → **Directory → Users → Create**
2. Username: `test.user`
3. Name: `Test User`
4. Email: any address you control (or a fake one — Authentik doesn't verify)
5. Save.
6. Click the new user → **Set password** → pick a strong one.
7. Click **Groups** tab → add `aws-lab-admins`.

You now have a user we'll soon federate into AWS.

## Part 10 — Configure AWS IAM Identity Center as a SAML provider in Authentik

This step has to happen **before** the AWS side, because AWS needs to fetch Authentik's metadata.

1. Admin UI → **Applications → Providers → Create → pick `SAML Provider`** (NOT "SAML Provider from Metadata" — that wizard wants AWS's XML, which we don't have yet).
2. Name: `aws-identity-center`.
3. Authorization flow: `default-provider-authorization-explicit-consent`.
4. Invalidation flow: `default-provider-invalidation-flow` (Logout). *Required in Authentik 2024.x and later.*
5. ACS URL: **placeholder for now** — Authentik 2024.x and later requires this field be non-empty. Use:
   `https://signin.aws.amazon.com/saml`
   You'll replace this with the real value AWS gives you in Part 11.
6. Issuer: `authentik`.
7. Service Provider Binding: `Post`.
8. Audience: same placeholder if required — `https://signin.aws.amazon.com/saml`. Replace in Part 11.
9. Signing certificate: select `authentik Self-signed Certificate`. Authentik generates this for you.
10. Property mappings — add these from the list:
    - `authentik default SAML Mapping: Email`
    - `authentik default SAML Mapping: Username`
    - `authentik default SAML Mapping: Name`
    - `authentik default SAML Mapping: UPN`
    - `authentik default SAML Mapping: Groups`
11. NameID Property Mapping: pick the `Email` mapping.
12. Save (Finish).

After saving, click the provider you just created → **Download Metadata** (or the **Metadata** tab → copy the URL). You'll get a URL like:

```
https://13-49-1-5.sslip.io/api/v3/providers/saml/1/metadata/?download
```

That's the URL AWS will fetch. Test it from your laptop:

```bash
curl -s "<that URL>" | head -20
```

You should see an XML document starting with `<md:EntityDescriptor ...>`. If you get an HTML error page instead, double-check the provider was saved.

**Wrap the provider in an Application:**

1. Admin UI → **Applications → Applications → Create**.
2. Name: `AWS Identity Center`.
3. Slug: `aws-sso`.
4. Provider: pick the `aws-identity-center` provider you just created.
5. Save.

## Part 11 — Configure AWS IAM Identity Center

Switch to the AWS console (in the S1 lab account).

1. Make sure Identity Center is enabled. **IAM Identity Center → Get started → Enable** if not already.
2. **Settings → Identity source → Actions → Change identity source → External identity provider → Next**.
3. AWS shows you three values it needs from Authentik, and three values it will give you back:
   - **From AWS to Authentik:**
     - **AWS SSO sign-in URL**  ⟶ paste into Authentik provider's **ACS URL** (replacing your `https://signin.aws.amazon.com/saml` placeholder).
     - **AWS SSO issuer URL**   ⟶ paste into Authentik provider's **Audience** (same — replace the placeholder).
     - **AWS SAML metadata file** (XML)  ⟶ extract AWS's X.509 signing cert from it (see below), upload it under **System → Certificates → Create** in Authentik, then reference it from the SAML provider's **Verification certificate** dropdown. The Verification certificate field is a *dropdown of pre-uploaded certs*, not a file upload.
   - **From Authentik to AWS:**
     - **IdP sign-in URL:** `https://<your-hostname>/application/saml/aws-sso/sso/binding/redirect/`
     - **IdP issuer URL:** `authentik`
     - **IdP certificate:** download Authentik's signing cert from the provider page's "Related objects → Download signing certificate" button.
       Alternative (easier): in the AWS form there's an **"Upload metadata file"** option — give it the Authentik metadata URL (`https://<your-hostname>/api/v3/providers/saml/<pk>/metadata/?download`) and AWS auto-fills all three fields.

   **Extracting AWS's cert from the metadata XML (if AWS doesn't give you a standalone .pem):**

   ```bash
   python3 -c "
   import re, sys
   xml = open(sys.argv[1]).read()
   cert = re.search(r'<ds:X509Certificate>(.+?)</ds:X509Certificate>', xml, re.DOTALL).group(1).strip()
   cert = ''.join(cert.split())
   lines = [cert[i:i+64] for i in range(0, len(cert), 64)]
   print('-----BEGIN CERTIFICATE-----')
   print('\n'.join(lines))
   print('-----END CERTIFICATE-----')
   " aws-saml-metadata.xml > aws-idc.pem
   openssl x509 -in aws-idc.pem -noout -subject -dates   # sanity check
   ```

   Then **System → Certificates → Create** in Authentik: paste the PEM into the Certificate field, leave Private key blank (you only have AWS's public cert), save.
4. Confirm. AWS will validate the metadata and switch the identity source.

> Heads-up: switching identity source signs out any existing Identity Center sessions. In a lab account with only you in it, that's fine — just log back in afterward.

5. Back in Authentik, **finish** editing the SAML provider: ACS URL and Audience are now set. Save.

## Part 12 — Provision the test user into AWS Identity Center

By default Identity Center supports SCIM auto-provisioning of users from the IdP. For a lab, manual is faster:

1. **IAM Identity Center → Users → Add user.**
2. Username **must exactly match** the `test.user` username from Authentik (this is how AWS correlates the SAML assertion).
3. Email: same as in Authentik.
4. Skip group / MFA for now.
5. **Permission sets**: create one if you don't have any. **Multi-account permissions → Permission sets → Create**. Pick e.g. `AdministratorAccess` for the lab. Name it `LabAdmin`.
6. **AWS accounts → Select your lab account → Assign users or groups → Users → pick `test.user` → Permission set → `LabAdmin` → Submit.**

## Part 13 — Test the end-to-end flow

1. Open the AWS access portal URL (shown in Identity Center → Settings → Identity source) in a fresh incognito window.
2. You should be redirected to Authentik.
3. Log in as `test.user` with the password you set.
4. You should be redirected back to the AWS access portal showing the lab account and the `LabAdmin` permission set.
5. Click it → "Open AWS Console" → you should land in the AWS console assumed as the federated role.

If you get this far, **federation is working**. CloudTrail will now show `sts:AssumeRoleWithSAML` events tagged with `test.user` whenever they log in — that's the joint Authentik + CloudTrail dataset we'll build detections against next.

## Part 14 — Day-2 operations

```bash
# Shell into the host (no SSH)
aws ssm start-session --target "$(terraform output -raw instance_id)"

# Inside the SSM session:
sudo docker compose -f /opt/authentik/docker-compose.yml logs -f authentik-server
sudo docker compose -f /opt/authentik/docker-compose.yml logs -f authentik-worker
sudo docker compose -f /opt/authentik/docker-compose.yml restart   # after editing .env

# Browse the events table — this is the gold detection-engineering source
sudo docker compose -f /opt/authentik/docker-compose.yml exec postgresql \
  psql -U authentik -d authentik \
  -c "SELECT action, user, created FROM authentik_events_event ORDER BY created DESC LIMIT 25;"
```

**Bump Authentik version:** edit `authentik_image_tag` in `terraform.tfvars` and `terraform apply` again. The instance does **not** get replaced — cloud-init only runs on first boot. To pull the new images: SSM in and `sudo docker compose -f /opt/authentik/docker-compose.yml pull && sudo docker compose -f /opt/authentik/docker-compose.yml up -d`.

**Stop the instance while not in use (save ~$25/mo):**

```bash
aws ec2 stop-instances --instance-ids "$(terraform output -raw instance_id)"
# Restart later:
aws ec2 start-instances --instance-ids "$(terraform output -raw instance_id)"
```

Note: the EIP keeps the same address across stop/start, so the `sslip.io` hostname stays valid.

## Part 15 — Teardown (when you're done with the lab)

```bash
cd "<this folder>/aws/terraform"
terraform destroy
# Type 'yes' when prompted
```

Removes **everything** — VPC, EC2, EBS, EIP, IAM role, CloudWatch logs. The S1 lab AWS account otherwise untouched.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `terraform apply` says "InvalidClientTokenId" or "signature expired" | Wrong access key, clock skew, or deactivated key | Re-run `aws sts get-caller-identity` to confirm. If that fails, check `~/.aws/credentials` and regenerate the key in the console if needed. |
| Browser says cert is invalid on sslip.io URL | Caddy hasn't issued the cert yet | Wait 5 minutes after `apply`. Check `docker compose logs caddy`. |
| Caddy log says `acme: error: 429 :: POST :: too many failed authorizations recently` | You hit Let's Encrypt's rate limit by destroying/recreating too fast | Uncomment the `acme_ca` line in `cloud-init.yaml.tftpl` to switch to LE staging, or wait an hour. |
| `terraform plan` says "could not find AMI" | Wrong region | Make sure `aws_region` matches your SSO region. |
| Initial setup URL 404s | Already used once | Use `akadmin` + the password you set. Forgot it? SSM in and reset via Django shell: `sudo docker compose -f /opt/authentik/docker-compose.yml exec authentik-server ak shell` then `from authentik.core.models import User; u = User.objects.get(username='akadmin'); u.set_password('newpw'); u.save()`. |
| AWS Identity Center "Failed to validate signature" | Wrong cert uploaded | Make sure the cert in AWS is Authentik's signing cert (download it from the SAML provider page), and the cert in Authentik is AWS's metadata. |
| Login redirects in a loop | NameID mismatch | The username in Authentik must exactly match the username in Identity Center. |
| `docker compose ps` shows authentik-worker restarting | Postgres not ready yet on first boot | Wait — the worker retries until Postgres is healthy. Should stabilize in 1–2 minutes. |

## What this $37/mo gets you

| Item | Cost |
|---|---|
| EC2 t3.medium (24/7) | ~$30.37 |
| 30 GB encrypted EBS gp3 | ~$2.40 |
| Detailed monitoring | ~$2.10 |
| VPC flow logs to CloudWatch | ~$0.50–$2 |
| Data transfer (light Authentik usage) | ~$0–$1 |
| EIP (attached to running instance) | $0 |
| **Total** | **~$35–37/mo** |

## What's next

Once federation is working and you've logged in as `test.user` a few times to generate events, ping me and we'll:

1. Wire Authentik's `authentik_events_event` rows + CloudTrail into the same pipeline.
2. Build the first detection candidates around `sts:AssumeRoleWithSAML`, MFA bypass, impersonation, and unusual session role chaining — the ER8 in-scope identity techniques.
