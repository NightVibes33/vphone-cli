# GitHub Actions remote vphone lab

The workflow at `.github/workflows/vphone-remote-lab.yml` has two modes:

- `hosted-capability-probe` builds and runs the host preflight on GitHub's Apple-silicon `macos-26` runner. It is diagnostic only because the hosted runner is already a virtual machine.
- `boot-bare-metal` builds, creates, restores, and launches the virtual iPhone on a physical Apple-silicon Mac registered as a self-hosted GitHub Actions runner.

The real mode publishes three private Tailscale connection methods:

1. An iPhone Safari page powered by noVNC, showing the virtual iPhone and forwarding touch input.
2. A direct VNC endpoint for a native VNC client.
3. SSH access to the virtual iPhone when the selected firmware variant provides SSH.

## Required physical host

Use a physical Apple-silicon Mac with:

- macOS 15 or newer;
- enough free storage for the source tree, IPSWs, restore artifacts, and a 64 GB sparse virtual disk;
- the SIP/research-guest/AMFI preparation documented in the main `README.md`;
- Homebrew and Python 3;
- Tailscale access;
- passwordless `sudo` for the dedicated runner account.

A hosted Mac, cloud macOS VM, UTM guest, or another nested Mac cannot boot the PV=3 virtual iPhone.

## 1. Register the Mac as a self-hosted runner

In this repository, open:

`Settings → Actions → Runners → New self-hosted runner`

Choose **macOS / ARM64** and run GitHub's displayed commands on the physical Mac. Add the custom label `vphone` during configuration:

```bash
./config.sh --url https://github.com/NightVibes33/vphone-cli --token TOKEN_FROM_GITHUB --labels vphone
sudo ./svc.sh install
sudo ./svc.sh start
```

The resulting runner must show these labels:

```text
self-hosted
macOS
ARM64
vphone
```

Use a dedicated local macOS account for this runner. Do not attach an untrusted public runner to a machine containing personal data.

## 2. Prepare passwordless sudo

The workflow is non-interactive. Give only the dedicated runner account passwordless sudo. Replace `vphone-runner` with its short username:

```bash
sudo visudo -f /etc/sudoers.d/vphone-runner
```

Add:

```text
vphone-runner ALL=(ALL) NOPASSWD: ALL
```

Then verify from that account:

```bash
sudo -n true
```

## 3. Add repository secrets

Open:

`Settings → Secrets and variables → Actions → New repository secret`

Create:

| Secret | Value |
|---|---|
| `TAILSCALE_AUTHKEY` | A reusable or ephemeral pre-authorized Tailscale auth key allowed by your ACLs |
| `VPHONE_VNC_PASSWORD` | Exactly eight characters; used by macOS legacy VNC authentication |

Keep Tailscale ACLs restricted to your own devices. The workflow does not intentionally expose VNC or the browser viewer to the public internet.

## 4. Prepare the Mac once

Follow the main README's host preparation in Recovery and macOS. Reboot after changing SIP, research-guest, AMFI, or NVRAM settings.

Before triggering the real job, these commands must succeed on the physical Mac:

```bash
uname -m                         # arm64
sw_vers -productVersion          # 15 or newer
sysctl -n kern.hv_support        # 1
csrutil status
csrutil allow-research-guests status
sudo -n true
brew --version
python3 --version
```

## 5. Run the workflow

Open:

`Actions → vphone-cli Remote Lab → Run workflow`

For the real VM choose:

```text
mode: boot-bare-metal
vm_name: github-phone
variant: jb
keep_alive_minutes: 300
```

The first successful run downloads and prepares firmware, restores the VM, installs the selected CFW, and boots it. Later runs reuse `$HOME/.vphone/VMs/github-phone` on the physical Mac.

The workflow summary prints the connection addresses after launch.

## 6. View it from your real iPhone

1. Install Tailscale on the iPhone.
2. Sign into the same tailnet used by the physical Mac runner.
3. Enable the Tailscale VPN connection.
4. Open the completed GitHub Actions run and expand its summary.
5. Tap the **Open on your iPhone in Safari** link.

The link has this shape:

```text
http://TAILSCALE_IP:6080/vnc.html?autoconnect=true&resize=scale
```

Safari then displays the virtual iPhone. Touches and keyboard input are forwarded through noVNC to the virtual device. noVNC requires a modern browser; current iPhone Safari exceeds its documented Safari 15 minimum.

The browser address only works while the workflow's `Keep the iPhone-visible lab online` step is running. The selected `keep_alive_minutes` value controls that window.

## Alternative connections

The summary also provides:

```text
vnc://TAILSCALE_IP:5901
ssh -p 22222 mobile@TAILSCALE_IP
```

Use the VNC address with a native iPhone VNC client when preferred. For the `jb` variant, the default guest SSH password documented upstream is `alpine`; change it after first boot.

If automatic guest discovery fails, connect to the physical Mac desktop instead:

```text
vnc://TAILSCALE_IP:5900
```

The vphone window remains visible there.

## What the normal GitHub runner can do

Run `hosted-capability-probe` to build the project and collect host/preflight diagnostics. It cannot boot the virtual iPhone because the GitHub-hosted runner is nested. The workflow deliberately avoids downloading full firmware in probe mode.
