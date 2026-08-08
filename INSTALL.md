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
| `/opt/audiotams` | the binary, its version, and the templates the CLI renders from |
| `/etc/audiotams/audiotams.yaml` | configuration — **written once, never overwritten by an upgrade** |
| `/var/lib/audiotams/data` | the archive: sources, flows, media |
| `/var/lib/audiotams/tmp` | render scratch |
| `/var/log/audiotams/audiotams.log` | the log |
| `/usr/local/bin/audiotams` | the management command |
| `/etc/nginx/sites-available/audiotams` | the site, plus `snippets/audiotams-proxy.conf` |

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

Two faults were found that way and would not have been found by reading:

* **`http2 on;` is a directive only from nginx 1.25.1.** Ubuntu 24.04 ships 1.24.0, where nginx refuses
  to start with `unknown directive "http2"`. `nginx-render.sh` now picks the form that matches the
  installed nginx, and both install and `cert` render through it so they cannot differ.
* **The release bundle did not include `nginx-render.sh`**, because the workflow named its files one by
  one. An install would have worked and the HTTPS switch would have failed. The workflow copies
  `deploy/pkg/*` wholesale now and then asserts every expected file is present, so it fails in CI
  rather than in front of an operator.
