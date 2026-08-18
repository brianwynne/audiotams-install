# AudioTAMS — install

A TAMS-native audio editor and publishing service: cut across archive sources in the browser, render
and measure on the server, publish with a quality report that says what was done to the audio.

**One command.** Debian or Ubuntu, x86_64 or arm64, no credential needed:

```bash
curl -fsSL https://raw.githubusercontent.com/brianwynne/audiotams-install/main/install.sh | sudo bash
```

It installs ffmpeg and nginx, fetches the release for this machine's architecture and verifies its
checksum, creates a locked-down service account, installs a hardened systemd service, puts nginx in
front of it, closes the firewall to 22/80/443, and adds an `audiotams` command and a login banner.

**The only step left is HTTPS**, which needs a domain that resolves to the machine:

```bash
sudo audiotams cert radio.example.com
```

## After that

```
audiotams status                     is it up, reachable, on HTTPS
audiotams logs [n|-f]                last n lines, or follow
sudo audiotams restart               also: start, stop
sudo audiotams upgrade [--tag vX.Y.Z]
sudo audiotams config                edit the configuration, then restart
sudo audiotams uninstall             removes the service; keeps data and config
audiotams help                       all of it
```

Upgrades re-run the installer deliberately — one code path, so an upgrade cannot drift from a fresh
install — and keep your configuration, your data and your certificate.

A pre-release is skipped by `latest`, so ask for one by `--tag v1.2.3-rc1`.

## What this repository is

The installer and the release bundles. **The source lives in a private repository**; this one exists so
that installing needs no token and no key. `install.sh` here is a copy — it is generated from the
source repository with every release, so the two cannot drift.

Full installation and operations documentation: [INSTALL.md](INSTALL.md).

Current release: `v1.0.0-rc23`
