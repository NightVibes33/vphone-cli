# Free public GitHub jailbroken iPhone

The workflow at `.github/workflows/inferno-public-jailbroken-iphone.yml` attempts
a complete iPhone 11 / iOS 14 beta 5 restore and jailbroken boot using only a
public GitHub repository and a standard GitHub-hosted macOS runner.

No physical Mac, self-hosted runner, paid virtualization account, repository
secret, firmware upload, or user-supplied file is required.

## What is downloaded at run time

The workflow fetches rather than commits:

- the compatible iPhone IPSW directly from Apple's CDN;
- ChefKiss Inferno from its public GitHub repository;
- the public qemu-t8030 helper scripts and ticket seed;
- the public checkra1n bootstrap;
- an Ubuntu ARM64 cloud image for the emulated USB restore companion;
- noVNC, websockify, Cloudflare Quick Tunnel, and a free TCP tunnel client.

Apple firmware, the modified restore ramdisk, and the restored NAND are not
uploaded as workflow artifacts.

## Architecture

```text
GitHub-hosted Apple-silicon macOS runner
    |
    +-- Inferno/QEMU TCG: emulated iPhone 11 (T8030/A13)
    |       |
    |       +-- Apple iOS 14 beta 5 restore
    |       +-- research kernel and AMFI/root-auth patches
    |       +-- checkra1n bootstrap written to emulated NAND
    |       +-- VNC framebuffer on localhost:5901
    |
    +-- Inferno/QEMU TCG: tiny Ubuntu ARM64 USB companion
            |
            +-- usb-tcp-remote through /tmp/usbqemu
            +-- patched idevicerestore
            +-- usbmuxd and iproxy for root SSH verification
```

This is full software emulation. It does not use Apple's
`Virtualization.framework`, so it does not require nested virtualization.

## Success requirements

The job does not report a jailbroken boot merely because QEMU starts or VNC
opens. Every check below must pass:

1. the restore completes successfully;
2. the installer ramdisk writes the jailbreak bootstrap and marker to NAND;
3. the final kernel reports AMFI research mode;
4. SpringBoard or backboardd appears in the boot log;
5. OpenSSH becomes reachable through the emulated USB connection;
6. `ssh root@... id` returns UID 0;
7. the persistent `/.inferno-jailbroken` marker is present.

A failed check produces a red workflow and uploads only diagnostic logs.

## Run it

Open:

`Actions → Free Public Jailbroken iPhone (Inferno) → Run workflow`

Choose how long to keep the verified viewer online after boot. The first run
performs a complete build and restore and can consume most of GitHub's maximum
hosted-job duration.

## Connect from an iPhone

After all boot checks pass, the workflow summary displays:

- a temporary HTTPS noVNC link for Safari;
- a randomly generated one-time VNC password;
- a temporary native TCP VNC address when the free TCP tunnel allocates one.

The temporary tunnel addresses are public Internet endpoints protected by the
one-time VNC password. They terminate when the workflow ends.

## Current status

This pipeline is experimental until a GitHub run produces all verification
markers. A green build means the complete jailbroken boot was proven. A green
Inferno compiler build alone does not mean iOS booted.
