# Installing and releasing AudioTAMS

One command on a fresh Debian or Ubuntu machine, x86_64 or arm64 — **no credential needed**:

```bash
curl -fsSL https://raw.githubusercontent.com/brianwynne/audiotams-install/main/install.sh | sudo bash
```

It installs ffmpeg and nginx, fetches the release for this machine's architecture, verifies its
checksum, lays out the filesystem, creates a locked-down service account, installs and starts a
hardened systemd service, puts nginx in front of it, closes the firewall to 22/80/443, installs the
`audiotams` command and adds a login banner listing every command.

**The only step left is HTTPS**, because a certificate needs a domain that resolves here:

```bash
sudo audiotams cert radio.example.com
```

## Why there are two repositories

The source repository is **private**: it names an internal archive host, how that host is
authenticated, and the full station list — infrastructure detail that is not ours to publish.

The bundles and the installer are published to the **public** `brianwynne/audiotams-install`, so an
install needs no token and no deploy key, and an upgrade at three in the morning cannot fail because a
credential expired. Nothing about the archive, the stations or the internal hostnames travels with a
bundle: it carries the built binary, the deploy assets and the installer.

`install.sh` has one source of truth — `deploy/install.sh` here — and the release workflow copies it
into the public repository with every release, so the public copy cannot be a version behind the
bundles it installs.

**Setting it up needs one secret**, once: a fine-grained PAT with *Contents: Read and write* on
`brianwynne/audiotams-install` **only**, stored in this repository as the Actions secret
`INSTALL_REPO_TOKEN`. `github.token` cannot be used — it is scoped to the repository the workflow runs
in. The release job fails loudly if the secret is missing rather than publishing half a release.

## What ends up where

| | |
|---|---|
| `/opt/audiotams` | **both** binaries (`audiotams`, `audiotams-ingest`), the version, and the templates the CLI renders from |
| `/etc/audiotams/audiotams.yaml` | configuration — **written once, never overwritten by an upgrade** — read by both |
| `/etc/audiotams/audiotams.env` | secrets and the sign-in decision. **0600, root-owned**, written once. See below |
| `/var/lib/audiotams/data` | the archive: sources, flows, media |
| `/var/lib/audiotams/media` | the radio recordings. The ingest connector is the only writer |
| `/var/lib/audiotams/quarantine` | recordings preserved rather than truncated — never swept by retention |
| `/var/lib/audiotams/tmp` | render scratch |
| `/var/log/audiotams/audiotams.log` | the log |
| `/var/log/audiotams/ingest.log` | ...and the ingest connector's |
| `/usr/local/bin/audiotams` | the management command |
| `/etc/nginx/sites-available/audiotams` | the site, plus `snippets/audiotams-proxy.conf` |

## The Rotter ingest connector

Every release ships it and installs it **switched off**: a fresh config names no Rotters, and a
service that starts and exits every ten seconds is worse than one an operator turns on when they mean
to. Turn it on when you have somewhere to point it:

```bash
sudo audiotams config            # fill in the `ingest:` block the template already left you
sudo audiotams ingest enable
audiotams ingest status
```

Everything about it is a verb on the same command — `status`, `lag`, `logs`, `quarantine`, `enable`,
`disable`, `start`, `stop`, `restart`, `once` — and `audiotams status` reports it alongside the API,
so the ordinary "is everything up?" check covers both. The login banner shows whether it is running,
the free space on the media volume, and a warning if anything is sitting in quarantine.

It is a separate unit on purpose: it is the only writer of `/var/lib/audiotams/media`, and the API
only reads it. That is what makes it impossible for two things to append to the same growing file.
The unit is hardened the same way as `audiotams.service`, with a narrower `ReadWritePaths` — the media
and quarantine directories and its own log, and **not** the API's data. `systemd-analyze security
audiotams-ingest` rates it **1.5, "OK"**, the same as the main unit.

An upgrade installs both binaries and **restarts the connector if you had enabled it**. Leaving the
old one running would be worse than doing nothing: it would go on writing the media volume while its
replacement sat unused beside it, and the version the banner reports would not be the version doing
the work.

`audiotams uninstall` removes both units. It keeps the recordings and anything in quarantine, as it
keeps everything else under `/var/lib/audiotams`.

See **[docs/ingest.md](../docs/ingest.md)** — installed on the machine as
`/opt/audiotams/docs/INGEST.md` — for the mechanism and the full runbook.

## The service account

`audiotams` is a system account: its own group, a locked password, `/usr/sbin/nologin`, no home of its
own beyond the data it owns, and membership of nothing else. It exists so the service is not root; it
is not for a person.

The unit drops everything it can. `ProtectSystem=strict` makes the whole filesystem read-only except
`ReadWritePaths=/var/lib/audiotams /var/log/audiotams`; the capability bounding set is **empty** (the
port is above 1024, so none are needed, and a compromise cannot regain any); plus `NoNewPrivileges`,
`PrivateTmp`, `PrivateDevices`, `ProtectHome`, `RestrictAddressFamilies`, a `@system-service` syscall
filter and `UMask=0027`. systemd's own audit rates it **1.5, "OK"**:

```bash
systemd-analyze security audiotams
```

The application listens on **127.0.0.1 only**. nginx is the only thing that talks to it, and the
firewall allows 22, 80 and 443 and nothing else.

## Upgrading

```bash
sudo audiotams upgrade              # the latest release
sudo audiotams upgrade --tag v1.2.0 # a specific one
```

`upgrade` re-runs the installer, which is deliberate: one code path, so an upgrade cannot drift from a
fresh install. Re-running is safe — it keeps your config, your data, and HTTPS if you have it.

## HTTPS, and the reload nothing else does

`sudo audiotams cert <domain>` gets a certificate and switches the site to TLS. On a host that an
internal ACME server issues for, get the certificate however that server expects and then point the
watcher at it:

```bash
sudo audiotams cert-watch                 # takes the path from the nginx site
sudo audiotams cert-watch /path/to/tls.crt
```

**Renewal writes the file; nothing reloads nginx.** certbot's timer renews and stops there, and an
ACME client that drops files into place has never heard of nginx — so the server goes on presenting
the old certificate until it expires, with a valid one on the disk beside it. It is the failure that
arrives ninety days after everybody watched HTTPS work, and `audiotams status` now says which state
this machine is in.

`cert-watch` installs a systemd path unit watching **both the certificate file and its directory**,
because clients replace a certificate in three ways and no single watch sees them all:

| how the client replaces it | what changes | seen by |
|---|---|---|
| certbot: new file in `archive/`, symlink repointed | the directory entry | the directory watch |
| rewritten in place | the file | the file watch |
| written to a temp file and renamed over | the directory entry | the directory watch |

All three were tested by driving a real path unit, not reasoned about: the directory-only version was
written first and **did not fire on a rewrite in place**, which is the shape an internal ACME server
usually takes. It would have looked correct and done nothing for exactly the deployment it was
written for.

## Configuring it: one command per job

Nothing on this machine needs a file edited by hand. Every setting has a command that **asks for what
it needs**, and the login banner says which ones are outstanding — so an engineer who has never seen
the system can be finished without reading this document at all.

| the job | the command |
|---|---|
| set up sign-in for the first time | `sudo audiotams entra setup` |
| **a new client secret** — the job that recurs | `sudo audiotams entra secret` |
| correct the recorded expiry, without touching the secret | `sudo audiotams entra expires` |
| change where Entra returns to (the server moved) | `sudo audiotams entra redirect` |
| stop requiring sign-in, and put it back | `sudo audiotams entra off` / `on` |
| what sign-in is configured, and until when | `audiotams entra` |
| set up HTTPS for the first time | `sudo audiotams cert setup` |
| **renew the certificate now** | `sudo audiotams cert renew` |
| make renewals reload nginx | `sudo audiotams cert watch` |
| what certificate is served, and until when | `audiotams cert` |

They are separate on purpose. The two jobs that actually recur — a new client secret every couple of
years, and a certificate renewed by hand when the ACME server was unreachable — are done by somebody
who was not here when it was set up, and neither should mean re-answering questions about tenant ids
or where certificates come from. `entra secret` asks for two things: the secret and its expiry date.

Each of them: defaults to the current value, never echoes a secret, writes nothing until every answer
is in, and ends by saying how to tell whether it worked.

### The client secret expiry, and why it is typed in

The banner counts down to the date the Entra client secret expires, because when it lapses **every
sign-in stops at once** and the failure reads as an outage rather than as a diary entry.

That date is typed in rather than looked up. Asking Entra for it would need `Application.Read.All` on
Microsoft Graph, and this application deliberately holds **no Graph permission at all** — identity
comes from the validated token and nothing else is asked of the directory. The date is not a secret,
so it lives in its own world-readable file (`/etc/audiotams/entra-secret-expires`); the secret stays
0600 in the environment file, and the login banner never reads that.

## Authentication, and the file that decides it

The server **refuses to start** with neither Entra sign-in configured nor anonymous access explicitly
allowed. That is deliberate: AudioTAMS has no authentication of its own, so anyone who reaches it can
create, delete and publish, and a build that is *capable* of authenticating but quietly is not, is more
dangerous than one that cannot — it looks protected. The choice therefore has to be written down.

It is written in `/etc/audiotams/audiotams.env`, 0600 and root-owned, read by systemd before the
service drops to the `audiotams` account. The installer creates it saying:

```sh
AUDIOTAMS_ALLOW_ANONYMOUS=1
```

...because that is what the machine was already doing. **An upgrade must not turn a running service
into a stopped one** — that is an outage, not a security improvement — so the decision is recorded on
the operator's behalf, in a file they can read, and changing it is one edit.

To require sign-in, fill in the four Entra settings in that file and comment the anonymous line out:

```sh
ENTRA_TENANT_ID=…
ENTRA_CLIENT_ID=…
ENTRA_CLIENT_SECRET=…
ENTRA_REDIRECT_URI=https://your.domain/auth/callback
```

All four present means sign-in is **required**. There is no way to have a tenant configured here and
authentication silently off. The environment beats the YAML file deliberately: a client secret in a
config file is a client secret in a backup, in whatever copied the file, and in the configuration
repository. Registration steps, including the four App Role values, are in
[docs/entra-setup.md](../docs/entra-setup.md).

The unit reads it as `EnvironmentFile=-/etc/audiotams/audiotams.env` — the leading `-` makes it
optional, so a missing file is not a second, sillier way to arrive at a server that will not start.

### What "no sign-in" actually means

Not "no checking". A server with sign-in off treats every visitor as **one anonymous user with a
role**, and the permission table decides for that user exactly as it does for a real one. The guard is
mounted either way; what changes is who the caller is taken to be, not whether anybody looks.

```sh
AUDIOTAMS_ALLOW_ANONYMOUS=1
AUDIOTAMS_ANONYMOUS_ROLE=Publisher    # optional; Administrator by default
```

Everything done in that state is still written to the audit trail, attributed to `anonymous` and
naming the role that allowed it — so a trail read months later says what the door was open to.

### Break-glass: Entra is unavailable and work has to continue

1. Edit `/etc/audiotams/audiotams.env`
2. Comment out the four `ENTRA_*` lines — **this matters**: while a tenant is configured, the
   anonymous setting is not consulted at all, and the server will keep trying to require a sign-in
   nobody can complete
3. Ensure `AUDIOTAMS_ALLOW_ANONYMOUS=1`
4. `sudo systemctl restart audiotams`

Reverse it the same way when Entra returns. Two things worth knowing before you need them:

- **You may not need to.** A running server rides out an Entra outage: sessions are locally-signed
  cookies carrying claims, and validating one contacts nobody. Only NEW sign-ins fail, and they fail
  with a page that says so. The server also starts and runs normally while Entra is unreachable —
  discovery is lazy and retries — so a restart mid-outage is no longer a reason to break the glass.
- **Anonymous is Administrator by default**, which means anyone who can reach the server can delete
  archive content and change its configuration. On an internal-only host for a few hours that is a
  reasonable trade and is the intended use. If the host is reachable more widely than the people who
  should hold those rights, set `AUDIOTAMS_ANONYMOUS_ROLE` to something narrower first.

## Cutting a release

The workflow builds on a **published Release**, not on a pushed tag. A tag alone does nothing:

```bash
git tag v1.2.0 && git push origin v1.2.0
gh release create v1.2.0 --generate-notes      # ← this starts the build
```

It builds the editor once (it is architecture-independent), runs gofmt/vet/tests, cross-compiles for
`linux/amd64` and `linux/arm64` with `CGO_ENABLED=0`, bundles each binary **with the deploy assets that
were tested against it**, writes `SHA256SUMS`, and attaches everything to the release. A pre-release
works the same way; the installer's "latest" skips pre-releases, so one has to be asked for by `--tag`.

To build the bundles locally exactly as CI does: `make bundle VERSION=v0.0.0-local`.

## How this was verified

Not by reading it. A systemd container was brought up, the CI-built bundle installed into it, and the
result checked: the editor served through nginx with gzip, the application listening on loopback only,
the service account locked, `systemd-analyze security` at 1.5, the firewall closed, the CLI and banner
working, an upgrade leaving a hand-edited config and a hand-made file untouched, the HTTPS switch
rendering and reloading, and an uninstall removing the service while keeping data and config.

The ingest connector was added to that same test rather than asserted: installed from the bundle,
enabled through `audiotams ingest enable`, replicating from a stand-in Rotter under systemd, its
recordings written as the service account at 0640, its log where the unit says, `systemd-analyze
security audiotams-ingest` at **1.5**, both services reported by `audiotams status`, the banner
showing it, and an uninstall taking both units while keeping the recordings.

One thing that check caught, and reading would not have: **an upgrade must restart the connector.**
The installer put the new binary in place beside a running old one, which would have gone on writing
the media volume while its replacement sat unused — and the banner would have reported the new
version the whole time. The upgrade path now restarts it if it was enabled, and the test compares the
service's PID either side to prove it.

Two further faults were found the same way, on the original install path:

* **`http2 on;` is a directive only from nginx 1.25.1.** Ubuntu 24.04 ships 1.24.0, where nginx refuses
  to start with `unknown directive "http2"`. `nginx-render.sh` now picks the form that matches the
  installed nginx, and both install and `cert` render through it so they cannot differ.
* **The release bundle did not include `nginx-render.sh`**, because the workflow named its files one by
  one. An install would have worked and the HTTPS switch would have failed. The workflow copies
  `deploy/pkg/*` wholesale now and then asserts every expected file is present, so it fails in CI
  rather than in front of an operator.
