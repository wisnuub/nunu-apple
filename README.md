# nunu-apple

macOS engine for [nunu](https://github.com/wisnuub/nunu) — runs ARM64 Android natively on Apple Silicon via `Virtualization.framework` and Google Cuttlefish.

No QEMU. No translation layer. Native ARM64-on-ARM64.

---

## How it works

```
nunu (Electron launcher)
    │
    └─ macOS Apple Silicon → nunu-apple (this repo)
            Virtualization.framework → Cuttlefish ARM64
```

The `NunuVM` binary boots a Cuttlefish AOSP image (`aosp_cf_arm64_only_phone`) using Apple's native hypervisor API. The launcher receives a JSON event stream on stdout and exposes ADB over a vsock bridge.

### Why Cuttlefish

Cuttlefish is Google's official virtual Android device, built for VirtIO hardware. Its device tree maps directly to what `Virtualization.framework` exposes — making it the right image format for this project.

### Why not QEMU

On Apple Silicon, QEMU adds an unnecessary abstraction between Android and the hardware. `Virtualization.framework` is the same hypervisor used by Parallels and UTM. With ARM64 Android on ARM64 hardware through a native hypervisor, there is no instruction translation.

---

## Components

```
nunu-apple/
├── launcher/    Swift CLI (NunuVM) — boots Cuttlefish via Virtualization.framework
└── .github/     CI workflow — builds and publishes NunuVM binary on release tags
```

### launcher/

Swift package (`NunuVM`) that wraps `Virtualization.framework`:

```
VZVirtualMachineConfiguration
├── VZLinuxBootLoader            Android kernel + initrd
├── VZVirtioBlockDevice          Cuttlefish disk images (super, userdata, frp…)
├── VZVirtioNetworkDevice        NAT — ADB over vsock bridge
├── VZVirtioGraphicsDevice       Display → Metal via VZVirtualMachineView
├── VZUSBKeyboardConfiguration   Keyboard passthrough
├── VZUSBScreenCoordinatePointing Absolute touch coordinates
├── VZVirtioSocketDevice         vsock — ADB proxy on configurable port
└── VZVirtioEntropyDevice        /dev/random
```

Snapshot save/restore cuts cold boot (~130s) to ~5s resume.

---

## Build

**Requirements:** macOS 13+, Xcode 15+, Apple Silicon

```bash
git clone https://github.com/wisnuub/nunu-apple
cd nunu-apple/launcher
swift build -c release
# binary: .build/release/NunuVM
```

**Sign with entitlements** (required to run outside Xcode):
```bash
./build.sh --release --sign
```

---

## Usage

nunu installs `NunuVM` to `~/.nunu/engines/nunu-apple/NunuVM` automatically via **Settings → Engine → Install**.

For manual use:
```bash
NunuVM \
  --kernel   /path/to/vmlinuz_full \
  --initrd   /path/to/initramfs.img \
  --disk     /path/to/super.img \
  --disk     /path/to/userdata.img \
  --disk     /path/to/frp.img \
  --memory   8192 \
  --cores    8 \
  --adb-port 5554 \
  --display-width  1920 \
  --display-height 1080 \
  --display-ppi    240 \
  --snapshot /path/to/snapshot.vmsave \
  --cmdline  "console=hvc0 androidboot.hardware=cutf_cvm ..."
```

JSON events are emitted on stdout:
| Event | Meaning |
|---|---|
| `{"event":"started"}` | VM booted |
| `{"event":"adb-ready","address":"127.0.0.1:5554"}` | ADB bridge ready |
| `{"event":"snapshot-saved","path":"..."}` | Snapshot written |
| `{"event":"stopped"}` | VM exited cleanly |
| `{"event":"error","message":"..."}` | Fatal error |

---

## Runtime data

| Path | Purpose |
|---|---|
| `~/.nunu/engines/nunu-apple/NunuVM` | Engine binary |
| `~/.nunu/engines/nunu-apple/version.txt` | Installed version |

Android disk images are managed separately by the nunu launcher.

---

## Releases

Each tagged release (`v*`) on this repo publishes a signed `NunuVM` binary as a GitHub release asset. The nunu launcher fetches from `wisnuub/nunu-apple/releases` to install and update the engine automatically.

---

## Requirements

- macOS 13+ (Ventura) on Apple Silicon (M1 or later)
- `com.apple.security.virtualization` entitlement
- Cuttlefish AOSP disk images (`aosp_cf_arm64_only_phone-userdebug`)
