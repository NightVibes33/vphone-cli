# GitHub-hosted jailbroken iPhone

This repository includes `.github/workflows/corellium-jailbroken-iphone.yml`.
It runs entirely from a normal GitHub-hosted Ubuntu runner and controls a real
jailbroken virtual iPhone hosted by Corellium.

This replaces the impossible attempt to nest `vphone-cli` inside a GitHub-hosted
macOS VM. GitHub performs the automation; Corellium supplies the ARM iPhone
virtualization host.

## What the workflow does

1. Installs Corellium's official CLI on `ubuntu-latest`.
2. Logs in with a repository API-token secret.
3. Creates an iPhone VM or reuses an existing instance ID.
4. Waits until the instance is fully powered on.
5. Waits until the Corellium agent is ready.
6. checks the instance, app list, and file list for jailbreak/root evidence.
7. Publishes the instance name, ID, and browser portal in the Actions summary.
8. Leaves the device running by default so it can be controlled from an iPhone.

The default new device is:

```text
Hardware flavor: iphone16pm
Firmware: 18.0
Patch type: jailbroken (Corellium's default iOS create mode)
Name: github-jailbroken-iphone
```

The hardware flavor and iOS version are workflow inputs, so they can be changed
to any combination currently available on the connected Corellium account.

## Required account

A Corellium cloud or enterprise account with an available iOS device allocation
is required. GitHub does not provide this account or its device capacity.

Create a user API token in the Corellium web interface and copy the project ID
that owns the device allocation.

## Add GitHub repository secrets

Open:

`NightVibes33/vphone-cli → Settings → Secrets and variables → Actions`

Create these repository secrets:

| Secret | Required | Value |
|---|---:|---|
| `CORELLIUM_API_TOKEN` | Yes | Corellium user API token |
| `CORELLIUM_PROJECT` | Yes | Corellium project UUID |
| `CORELLIUM_ENDPOINT` | No | Leave absent for `https://app.corellium.com`; enterprise users set their own web endpoint without `/api` |

The token is only passed to the workflow as a masked secret. It is not written
to artifacts or committed to the repository.

## Run it

Open:

`Actions → GitHub Jailbroken iPhone (Corellium) → Run workflow`

Use the defaults for the first run:

```text
existing_instance_id:              (blank)
instance_name: github-jailbroken-iphone
device_flavor: iphone16pm
ios_version: 18.0
wait_timeout_seconds: 3600
cleanup_mode: keep-running
```

`keep-running` leaves the device powered on after GitHub finishes. Corellium may
charge for active-device time, so stop or delete it from Corellium when finished.
The workflow can also be rerun with `cleanup_mode: stop` or `delete`.

## Open the jailbroken iPhone from a real iPhone

After the workflow is green:

1. Open the workflow's Summary page.
2. Tap the Corellium browser link.
3. Sign in to the same Corellium account in Safari.
4. Select `github-jailbroken-iphone`, or use the instance ID shown in the summary.
5. Tap the virtual display to connect and control iOS.

Corellium's jailbroken iOS images provide root filesystem read/write access,
relaxed AMFI and sandbox protections, SSH, Frida, Substitute tweak support, and
Cydia. The Corellium web interface sends touch and keyboard input directly to
the VM.

## Reuse an existing device

To prevent a new billable VM from being created on every run, copy an existing
instance UUID and supply it as `existing_instance_id`. The workflow will power
it on if necessary and then verify the boot and jailbreak state again.

## Important differences from vphone-cli

- The virtual iPhone runs on Corellium's ARM infrastructure, not inside GitHub.
- GitHub still performs every provisioning and verification command.
- The screen is Corellium's browser display rather than a public VNC server.
- App Store and iCloud login are not supported by Corellium virtual iPhones.
- Metal/GPU-dependent apps may not work correctly.
