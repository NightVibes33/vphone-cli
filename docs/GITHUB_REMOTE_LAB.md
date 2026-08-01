# Verified virtual-iPhone remote lab

The workflow at `.github/workflows/vphone-remote-lab.yml` can create, restore, launch, and verify a persistent virtual iPhone. A real boot is considered successful only after the guest answers on its VNC framebuffer port (`5901`). It then publishes both connection choices for a real iPhone:

1. **noVNC:** open the virtual iPhone in Safari and control it with touch.
2. **Native VNC:** open the virtual iPhone in an iOS VNC client.

The guest is an iPhone/iOS VM. The workflow does not expose a macOS desktop as the normal interface.

## Hard requirement

A real boot requires a **physical, non-virtual Apple-silicon Mac** running macOS 15 or newer. GitHub-hosted macOS runners are already virtual machines, and Apple's PV=3 virtualization used by vphone cannot be nested inside them.

The physical Mac also needs:

- the SIP/research-guest/AMFI preparation from the main `README.md`;
- enough disk space for IPSWs, restore artifacts, and the sparse VM disk;
- Homebrew and Python 3;
- a dedicated logged-in macOS runner account;
- passwordless `sudo` for that dedicated account;
- access to the same Tailscale network as the real iPhone.

## 1. Prepare macOS boot policy

Choose one supported path from the main README.

### Most permissive

Run in Recovery:

```bash
csrutil disable
csrutil allow-research-guests enable
```

Then boot macOS, run this, and reboot again:

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
```

### More restricted

Run in Recovery:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

After building vphone, allowlist the app with the bundled `vphone-amfidont` helper as documented upstream.

## 2. Register the physical Mac runner

Open this repository and go to:

`Settings → Actions → Runners → New self-hosted runner`

Choose **macOS / ARM64**. Run GitHub's displayed download/configuration commands and add the custom `vphone` label:

```bash
./config.sh \
  --url https://github.com/NightVibes33/vphone-cli \
  --token TOKEN_FROM_GITHUB \
  --labels vphone
```

The runner must have these labels:

```text
self-hosted
macOS
ARM64
vphone
```

### Important: run it interactively

Log into the dedicated macOS account at the physical Mac desktop and start the runner with:

```bash
./run.sh
```

Do **not** install this runner with `svc.sh`. A background LaunchDaemon does not reliably have the logged-in GUI/WindowServer session needed by the visible vphone process. The workflow checks this and stops with a clear error when the runner is not interactive.

## 3. Configure passwordless sudo

Replace `vphone-runner` with the dedicated account's short username:

```bash
sudo visudo -f /etc/sudoers.d/vphone-runner
```

Add:

```text
vphone-runner ALL=(ALL) NOPASSWD: ALL
```

Verify:

```bash
sudo -n true
```

Use a dedicated account and Mac. Do not give an automation runner unrestricted sudo on a machine containing sensitive personal files.

## 4. Add the Tailscale secret

Create this repository secret under:

`Settings → Secrets and variables → Actions`

| Secret | Value |
|---|---|
| `TAILSCALE_AUTHKEY` | A pre-authorized Tailscale auth key restricted by ACLs to your devices |

The direct VNC and noVNC listeners bind to the Mac's private Tailscale address. They are not intentionally exposed on the public internet.

## 5. Verify the physical Mac

Run these commands from the same logged-in account that starts `./run.sh`:

```bash
uname -m                         # arm64
sw_vers -productVersion          # 15 or newer
sysctl -n kern.hv_support        # 1
sysctl -n kern.hv_vmm_present    # must not be 1
stat -f '%Su' /dev/console       # must equal the runner account
csrutil status
csrutil allow-research-guests status
sudo -n true
brew --version
python3 --version
```

## 6. Start the real boot

Open:

`Actions → vphone-cli iPhone Remote Lab → Run workflow`

Select:

```text
mode: boot-bare-metal
vm_name: github-phone
variant: jb
boot_timeout_seconds: 1800
keep_alive_minutes: 120
```

The first run performs the full upstream sequence:

```text
download → firmware preparation → patch → DFU restore → CFW install → first boot
```

Later runs reuse the persistent VM under:

```text
~/.vphone/VMs/github-phone
```

The workflow uses the documented launch form:

```bash
vphone-cli vm launch github-phone
```

The firmware variant is applied during `vm create`; it is not incorrectly passed to `vm launch`.

## 7. Connect from the real iPhone

Install Tailscale on the real iPhone, sign into the same tailnet, and enable its VPN connection.

A successful Actions summary shows **Virtual iPhone boot verified** and prints both options.

### noVNC option

Open the printed address in iPhone Safari:

```text
http://TAILSCALE_IP:6080/vnc.html?autoconnect=true&resize=scale
```

### Native VNC option

Enter this in an iOS VNC client:

```text
vnc://TAILSCALE_IP:5901
```

For the `jb` variant, SSH is also printed when port `22222` becomes available:

```text
ssh -p 22222 mobile@TAILSCALE_IP
```

The upstream default jailbreak password is `alpine`; change it after first boot.

## What green means

The real boot job cannot reach its green state merely because the project compiled. Before publishing the links, it verifies all of the following:

- the host is physical Apple silicon rather than a nested Mac VM;
- the signed vphone binary passes the upstream boot preflight;
- `vm create` completed or an existing persistent VM was found;
- the `vm launch` process stayed alive;
- the virtual iPhone became reachable on guest VNC port `5901`;
- both the Tailscale native-VNC listener and noVNC listener started successfully.

`hosted-capability-probe` remains diagnostic only. It never claims to boot an iPhone and deliberately does not download or restore firmware.
