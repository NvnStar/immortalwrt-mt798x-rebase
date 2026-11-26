# Transparency & Supply-Chain Provenance (`nr3053-mt76`)

This document is for users and auditors who want to know **exactly** what code, feeds, binary blobs, build mirrors, bootloader sources, runtime endpoints, and flash brick-safety invariants go into the Viettel NR3053 (`nr3053-mt76`) firmware and bootloader built from this branch.

---

## 1. Branch Scope & Exact Delta vs. Upstream

- **Base tree**: Official [`immortalwrt/immortalwrt`](https://github.com/immortalwrt/immortalwrt) branch `openwrt-25.12` at commit `b1088b5661` (`b1088b5661bf257b3e89f8537df906a67b8e7289`).
- **No proprietary MediaTek SDK (`package/mtk/`)**: Unlike the `main` branch in this repository (which ships the third-party `mt_wifi` / `warp` / `conninfra` SDK fork and 75 committed binaries), `nr3053-mt76` uses the open-source upstream **`mt76`** Wi-Fi driver (`kmod-mt7915e`).
- **Zero binary files added** by this branch.

Every change on top of official `immortalwrt/openwrt-25.12` (`b1088b5661`) lives in these allowlisted text files:

| File | Purpose |
| --- | --- |
| `target/linux/mediatek/dts/mt7981b-viettel-nr3053.dts` | Board device tree (`GPL-2.0-only OR MIT`) |
| `target/linux/mediatek/image/filogic.mk` | `Device/viettel_nr3053` FIT image profile (`-default-settings -default-settings-chn`) |
| `target/linux/mediatek/filogic/base-files/etc/board.d/02_network` | LAN/WAN switch port mapping & Factory MAC offset |
| `target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh` | `viettel,nr3053` UBI `fit_do_upgrade` / `fit_check_image` hooks |
| `package/boot/uboot-tools/uboot-envtools/files/mediatek_filogic` | U-Boot env volumes (`ubootenv` / `ubootenv2`) |
| `feeds.conf.default` | Exact 40-char commit-SHA pinning for all 5 upstream feeds |
| `.github/workflows/build-nr3053-mt76.yml` | Transparent, SHA-pinned GitHub Actions firmware & isolated bootloader CI |
| `scripts/verify-nr3053-transparency.sh` | Automated pre-build, config, and post-build transparency & brick-safety gate |
| `scripts/build-nr3053-bootloader.sh` | Reproducible, SHA-pinned open-source U-Boot/TF-A (`SP2`) builder |
| `docs/TRANSPARENCY.md`, `README.md` | Documentation only (does not affect built images) |

### 1.1 Inherited ImmortalWrt Delta vs. Official `openwrt/openwrt` (`c8a7c4c065..b1088b5661`)

Because this branch is based on `immortalwrt/openwrt-25.12` (`b1088b5661`, whose second parent is official `openwrt/openwrt` commit `c8a7c4c065f8f649e8821b490c97fc3c9ae26fab`), the compiled NR3053 image includes the following ImmortalWrt-specific in-tree components and defaults beyond vanilla OpenWrt:

| Component | Exact Location / Source | Effect in NR3053 Image |
| --- | --- | --- |
| **`kmod-nft-fullcone`** | `package/network/utils/fullconenat-nft` (`https://github.com/fullcone-nat-nftables/nft-fullcone.git` @ `07d93b626ce5ea885cd16f9ab07fac3213c355d9`, `PKG_MIRROR_HASH:=84d54b5e...`), `target/linux/generic/hack-6.12/952-net-conntrack-events-support-multiple-registrant.patch`, `package/network/config/firewall4/patches/001-firewall4-add-support-for-fullcone-nat.patch` | Adds `CONFIG_NF_CONNTRACK_CHAIN_EVENTS` kernel notifier support and enables `option fullcone 1` by default in `firewall4` (with `option fullcone6 0`). |
| **`bridger` + WED offload** | `package/network/services/bridger` (`https://github.com/nbd168/bridger` @ `9fc2bc3e3d4d3ffa63ee202ce8097620ce300e4f`), `target/linux/mediatek/filogic/target.mk`, `package/kernel/mt76/Makefile` (`MODPARAMS.mt7915e:=wed_enable=Y`) | Enables BPF bridge acceleration (`bridger`) and Filogic hardware Wireless Ethernet Dispatch (WED) offload by default for `mt7915e`. |
| **`autocore`** | `package/emortal/autocore` | Installs `/sbin/cpuinfo`, `/sbin/tempinfo`, and `rpcd` ACL `luci-mod-status-autocore.json` consumed by `immortalwrt/luci`. |
| **`shellsync`** | `package/network/services/shellsync` | Installs POSIX semaphore sync helper (`shellsync.c`) linked into `ppp`. |
| **OpenSSL crypto defaults** | `include/default-packages.mk` (`apk-openssl`), `include/target.mk` (`libustream-openssl`), `target/linux/mediatek/filogic/target.mk` (`wpad-openssl`) | Selects OpenSSL variants for APK, `uhttpd`/`ustream`, and `hostapd`/`wpad` instead of `mbedtls`. |
| **SPI-NAND vendor patches** | `target/linux/mediatek/patches-6.12/341-mtd-spinand-Support-dosilicon.patch` (`DS35Q2GBS`), `343-mtd-spinand-gsto-Add-code.patch`, `target/linux/generic/hack-6.12/400-mtd-spinand-Support-fmsh.patch` | Adds Linux 6.12 SPI-NAND flash IDs including Dosilicon `DS35Q2GBS` (`0xe5, 0xb2`) physically present on the NR3053. |
| **`default-settings` & `default-settings-chn` disabled** | `target/linux/mediatek/image/filogic.mk` (`-default-settings -default-settings-chn`), `.github/workflows/build-nr3053-mt76.yml` | **Both** `package/emortal/default-settings` and `default-settings-chn` are excluded on this branch so neither `mirrors.vsean.net` / `Asia/Shanghai` (`99-default-settings-chinese`) nor `dnsmasq` `log-facility=/dev/null` silencing (`99-default-settings`) is injected into the rootfs. |

### Verify the diff yourself

```bash
git remote add immortalwrt https://github.com/immortalwrt/immortalwrt.git
git fetch immortalwrt openwrt-25.12
git diff --stat b1088b5661..HEAD
git diff b1088b5661..HEAD -- target/ package/ feeds.conf.default scripts/ .github/
```

---

## 2. Source & Download Provenance

### Pinned Package Feeds (`feeds.conf.default`)

All five feeds are pinned to immutable 40-character commit SHAs from the official `immortalwrt` and `openwrt` GitHub organizations (snapshotted from `openwrt-25.12` on `2026-11-26`):

| Feed | Repository | Pinned Commit |
| --- | --- | --- |
| `packages` | `https://github.com/immortalwrt/packages.git` | `3f37537ae8f410bd300852330a0e540d71c70a95` |
| `luci` | `https://github.com/immortalwrt/luci.git` | `289da3f6a822befafe96cf2142215219db9f42ae` |
| `routing` | `https://github.com/openwrt/routing.git` | `bfe1c696846e6c5bf69df97d155f639879cf9729` |
| `telephony` | `https://github.com/openwrt/telephony.git` | `c58ec5a6703966dcccb53d0919698c8aba3a9ef5` |
| `video` | `https://github.com/openwrt/video.git` | `094bf58da6682f895255a35a84349a79dab4bf95` |

> **Feed Rebase Lockstep Rule**: When rebasing `nr3053-mt76` onto a newer `immortalwrt/openwrt-25.12` commit, update **all five** feed SHAs in `feeds.conf.default` together to prevent core/feed ABI or kernel-symbol drift. Also note that if a local `feeds.conf` file exists in the repository root, `./scripts/feeds` uses `feeds.conf` instead of `feeds.conf.default`.

### Core Components & Hash Verification

- **Linux kernel**: `6.12.118` (`target/linux/generic/kernel-6.12`) with SHA-256 hash `08308460320e852ac0745b2be3c7ae1cd81bdad713506ed7d817ba1ec9e1a5a5`.
- **Wi-Fi driver (`mt76`)**: `https://github.com/openwrt/mt76` pinned to commit `39c960c3ada558b4c2e7915772483d3731573d09` (`BSD-3-Clause-Clear`) with `PKG_MIRROR_HASH`.
- **Integrity enforcement**: `scripts/download.pl` requires a valid checksum (SHA-256/MD5) for every downloaded archive unless `skip` is explicitly set. `scripts/verify-nr3053-transparency.sh --pre-build` scans `package/`, `tools/`, and `toolchain/` Makefiles to enforce zero `PKG_HASH:=skip` or `PKG_MIRROR_HASH:=skip` entries.

### Build-Time Mirrors (ImmortalWrt Upstream Disclosure)

Because this branch keeps ImmortalWrt's upstream build scripts unmodified to minimize rebase drift, two upstream ImmortalWrt behaviors exist **during build time**:

1. `scripts/projectsmirrors.json` lists Chinese academic/cloud mirrors (`mirrors.tencent.com`, `mirrors.aliyun.com`, `mirrors.tuna.tsinghua.edu.cn`, `mirrors.ustc.edu.cn`, `mirror.iscas.ac.cn`, `mirror.nju.edu.cn`) ahead of `cdn.kernel.org`, `ftpmirror.gnu.org`, `ftp.debian.org`, `dlcdn.apache.org`, and `download.gnome.org` (and `tools/libressl/Makefile` lists `mirrors.tencent.com` first).
2. `scripts/download.pl` pushes `https://fastly.jsdelivr.net/gh/...` and `https://raw.gitmirror.com/...` onto the mirror list ahead of `@GITHUB` fallback mirrors.

**Security impact & `DOWNLOAD_MIRROR` behavior**: Every archive fetched from any mirror is verified by SHA-256 against the hash committed in the package Makefile before extraction; a tampered file fails the build immediately. Note that `DOWNLOAD_MIRROR` / `CONFIG_LOCALMIRROR` in `scripts/download.pl` only **prepends** your mirror to the candidate URL list — if a tarball is missing from `DOWNLOAD_MIRROR`, `scripts/download.pl` still falls back to `fastly.jsdelivr.net`, `raw.gitmirror.com`, and `scripts/projectsmirrors.json` (still SHA-256 verified).

---

## 3. Binary Blobs & Open-Source Bootloader Provenance

### Firmware Microcontroller Blobs (SHA-256 Verified)

Even with the open-source `mt76` driver, MediaTek MT7981B silicon requires redistributable closed-source microcontroller firmware binaries. Every blob included in the NR3053 image comes from official OpenWrt or Linux kernel upstream and is SHA-256 verified at build time:

| Package | Files Installed | Upstream Source | License |
| --- | --- | --- | --- |
| `kmod-mt7981-firmware` | `mt7981_wa.bin`, `mt7981_wm.bin`, `mt7981_rom_patch.bin`, `mt7981_eeprom_mt7976_dbdc.bin` | `https://github.com/openwrt/mt76` (pinned commit + `PKG_MIRROR_HASH`) | MediaTek redistributable |
| `mt7981-wo-firmware` | `/lib/firmware/mediatek/mt7981_wo.bin` (WED offload) | `linux-firmware-20261019.tar.xz` from `@KERNEL/linux/kernel/firmware` (`PKG_HASH`) | `LICENCE.mediatek` |
| `eip197-mini-firmware` | Inside Secure SafeXcel EIP197 crypto engine firmware | `linux-firmware-20261019.tar.xz` from `@KERNEL/linux/kernel/firmware` (`PKG_HASH`) | Upstream `linux-firmware` |

### Open-Source Bootloader (`quytttb/bl-mt798x-dhcpd`, Isolated Build)

- **Firmware artifact isolation**: The firmware build (`jobs.build` -> `immortalwrt-nr3053-mt76-<sha>`) packages **only** `initramfs-recovery.itb`, `squashfs-sysupgrade.itb`, `*.manifest`, `kmods-packages.tar.gz`, `config.buildinfo`, and `sha256sums`. Zero `.fip` or `preloader.bin` files are included in firmware artifacts (`scripts/verify-nr3053-transparency.sh --post-build` enforces this).
- **Isolated bootloader build**: A separate CI job (`jobs.build-bootloader` -> `immortalwrt-nr3053-bootloader-sp2-<sha>`) and local script (`./scripts/build-nr3053-bootloader.sh`) compile the NR3053 bootloader from [`quytttb/bl-mt798x-dhcpd`](https://github.com/quytttb/bl-mt798x-dhcpd.git) pinned to commit `e3df9aa28675993d816c5fea3cffe9635c856fb6` (`VERSION=SP2`):
  - **U-Boot + Web Failsafe + DHCPD**: Open-source `uboot-mtk-20250711` with HTTP `192.168.1.1` Web Failsafe and DHCPD; embedded Web UI assets are minified using `npm ci --ignore-scripts` validated against `package-lock.json` (`https://registry.npmjs.org/` + `sha512-` integrity).
  - **TF-A (`atf-20260123`)**: Open-source ARM Trusted Firmware configured with `OVERRIDE_FIP_BASE=0x400000`, `OVERRIDE_FIP_SIZE=0x200000`, `CONFIG_ENABLE_NAND_NMBM=y`, and Dosilicon `DS35Q2GBS` (`0xe5, 0xb2`) SPI-NAND support. Like OpenWrt's in-tree `arm-trusted-firmware-mediatek`, `atf-20260123` links MediaTek's redistributable silicon archives (`dram.a`, `efuse_cmd.a`, `mtk_plat_key.a`).
  - **Output files**:
    - `immortalwrt-mediatek-filogic-viettel_nr3053-preloader.bin` (SPI-NAND BL2 @ `0x0`, max `1 MiB`)
    - `immortalwrt-mediatek-filogic-viettel_nr3053-bl31-uboot.fip` (BL31 + U-Boot FIP @ `0x400000`, max `2 MiB`)
    - `bl2-mt7981-ddr3-bga-ram-SP2-uartboot.bin` (RAM-only BL2 for `mtk_uartboot` serial unbricking — **never flash to NAND**)

Reproduce locally (or run `--check-only` without a cross-compiler):

```bash
./scripts/build-nr3053-bootloader.sh --check-only
./scripts/build-nr3053-bootloader.sh tmp/dist-bootloader
```

---

## 4. On-Router Runtime Network Endpoints, Trust Roots & Sysupgrade Persistence

Once flashed onto the NR3053, these are the external endpoints and trust anchors configured by default:

- **APK package repositories**: `https://downloads.immortalwrt.org/releases/25.12-SNAPSHOT`
  - Upstream ImmortalWrt enables `default-settings-chn` (rewriting `/etc/apk/repositories.d/distfeeds.list` to `https://mirrors.vsean.net/openwrt` and setting timezone to `Asia/Shanghai`) and `default-settings` (appending `log-facility=/dev/null` to `/etc/dnsmasq.conf`).
  - **Both disabled here**: `Device/viettel_nr3053` excludes `-default-settings -default-settings-chn`, and CI + `verify-nr3053-transparency.sh` assert neither package is present in `.config` or `*.manifest`.
- **Trusted APK signing keys (`/etc/apk/keys/`)**: Every built NR3053 rootfs contains **three** public keys in `/etc/apk/keys/`:
  1. `openwrt-25.12.pem` (from `package/system/openwrt-keyring` / `https://github.com/immortalwrt/keyring.git` @ `14e1f88b521f6466dfcc06b055646cfa25e8e02f`, SHA-256 verified)
  2. `immortalwrt-25.12.pem` (from `openwrt-keyring`)
  3. `public-key.pem` (an **ephemeral per-build signing key** generated during that specific build run to sign its local `kmods-packages.tar.gz` feed; `kmods-packages.tar.gz` matches only the `public-key.pem` embedded in the exact `.itb` from the same build, whereas runtime `apk` installs rolling `25.12-SNAPSHOT` userspace packages signed by `openwrt-25.12.pem` / `immortalwrt-25.12.pem`).
- **`sysupgrade` persistence**:
  - `/etc/apk/repositories.d/distfeeds.list` is **overwritten** during `sysupgrade`, so upgrading to a build from this branch clears any legacy `mirrors.vsean.net` feed entry automatically.
  - `/etc/config/system` is **preserved** when upgrading without `-n` (`sysupgrade -n` resets config), meaning an `Asia/Shanghai` timezone saved by an older ImmortalWrt build will remain until updated or reset.
- **NTP servers** (set on first boot by `files/etc/uci-defaults/99-nr3053-defaults` in CI):
  - `162.159.200.1` (Cloudflare IP literal — allows clock sync before DNS/DNSSEC)
  - `216.239.35.0` (Google IP literal)
  - `time.cloudflare.com`, `time1.google.com`, `0.openwrt.pool.ntp.org`

---

## 5. Automated Verification, CI Transparency & Local Reproduction

### Automated Gate (`scripts/verify-nr3053-transparency.sh`)

- `--pre-build`: Enforces the `b1088b5661` branch allowlist, zero binary diffs in core directories, 40-char SHA pins in `feeds.conf.default` / workflow `uses:` / `build-nr3053-bootloader.sh`, zero `PKG_HASH:=skip` / `PKG_MIRROR_HASH:=skip`, and the full NR3053 DTS/NAND/`platform.sh`/`filogic.mk` brick-safety matrix.
- `--check-config <config_file>`: Verifies `fitblk=y`, `mt76` + MT7981 firmware, and absence of `default-settings`, `default-settings-chn`, `LUCI_LANG_zh_Hans`, and `mt_wifi`.
- `--post-build <dist_dir>`: Verifies `config.buildinfo`, `sha256sums`, strict non-empty `*.manifest` (with `fitblk`/`kmod-mt7915e`/`mt7981-wo-firmware` and without `default-settings*`), zero `.fip`/`preloader.bin` leaks, `IMAGE_SIZE` bounds, `supported_devices` (`viettel,nr3053` and `sdmc,nr3053`), and non-shallow fwtool `version.revision` (`r<count>-<sha>`, rejecting `r0-<sha>`).

### GitHub Actions Workflow (`.github/workflows/build-nr3053-mt76.yml`)

- **Least privilege**: `permissions: contents: read`.
- **Triggers**: `push` to `nr3053-mt76` (including `scripts/**`, `config/**`, `tools/**`, `toolchain/**`) and manual `workflow_dispatch` only.
- **Full git history**: `fetch-depth: 0` + branch tracking so `scripts/getver.sh` emits real `r<count>-<sha>` revisions instead of `r0-<sha>`.
- **Cache hygiene**: Toolchain cache keys exclude `feeds.conf.default` and omit `restore-keys`; caches save only on `if: success()`.
- **Strict artifact collection**: `cp bin/targets/mediatek/filogic/*.manifest dist/` fails immediately if the manifest is missing, and firmware vs. bootloader artifacts upload from separate jobs.

### Build Locally From Source

```bash
git clone -b nr3053-mt76 https://github.com/NvnStar/immortalwrt-mt798x-rebase.git
cd immortalwrt-mt798x-rebase

./scripts/verify-nr3053-transparency.sh --pre-build
./scripts/feeds update -a
./scripts/feeds install -a

cat > .config <<'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_viettel_nr3053=y
CONFIG_TARGET_ROOTFS_INITRAMFS=y
CONFIG_PACKAGE_luci-ssl=y
CONFIG_PACKAGE_irqbalance=y
CONFIG_PACKAGE_kmod-tcp-bbr=y
# CONFIG_PACKAGE_default-settings is not set
# CONFIG_PACKAGE_default-settings-chn is not set
# CONFIG_LUCI_LANG_zh_Hans is not set
# CONFIG_PACKAGE_luci-i18n-base-zh-cn is not set
# CONFIG_PACKAGE_luci-i18n-firewall-zh-cn is not set
# CONFIG_PACKAGE_luci-i18n-package-manager-zh-cn is not set
EOF

make defconfig
./scripts/verify-nr3053-transparency.sh --check-config .config
make download -j8
make -j"$(nproc)"
```

Verify on a running router after flashing that neither the third-party mirror nor `dnsmasq` log silencing was injected:

```sh
cat /etc/apk/repositories.d/distfeeds.list
# Expect https://downloads.immortalwrt.org/... (NOT mirrors.vsean.net)
grep log-facility /etc/dnsmasq.conf || echo "OK: dnsmasq logging not silenced"
```

---

## 6. NR3053 Brick-Safety & Safe-Modification Matrix

| Hazard / Invariant | Requirement on NR3053 | Consequence if Violated |
| --- | --- | --- |
| **Bootloader, env & calibration write-protection** | `partition@0` (`BL2` `0x0..0x100000`), `partition@100000` (`u-boot-env` `0x100000..0x200000`), `partition@200000` (`Factory` `0x200000..0x400000`), and `partition@400000` (`FIP` `0x400000..0x600000`) MUST retain `read-only;` in `mt7981b-viettel-nr3053.dts`. | Accidental Linux MTD writes overwrite BL2, U-Boot FIP, or factory Wi-Fi EEPROM/MAC calibration (`mtd2`). |
| **NMBM bad-block pool boundary** | `partition@600000` (`ubi`) has `reg = <0x600000 0xea00000>` (`0x600000 + 0xea00000 = 0xf000000`, 240 MiB ceiling) and `IMAGE_SIZE := 229376k` (<= `0xea00000`). | Extending `ubi` into `0xf000000..0x10000000` corrupts the top-16 MiB NMBM bad-block pool used by `quytttb` U-Boot (`CONFIG_ENABLE_NAND_NMBM=y`). |
| **Dosilicon `DS35Q2GBS` SPI-NAND driver** | `target/linux/mediatek/patches-6.12/341-mtd-spinand-Support-dosilicon.patch` (`SPINAND_INFO("DS35Q2GBS"`, `0xe5, 0xb2`) is mandatory before any rebase/port to vanilla `openwrt/openwrt`. | Kernel fails to probe the 256 MiB SPI-NAND flash (`ubi` fails to attach; boot fails). |
| **FIT rootfs mounting & sysupgrade hooks** | `chosen.rootdisk = <&ubi_fit_volume>;`, `CONFIG_PACKAGE_fitblk=y`, and `viettel,nr3053` in both `platform_do_upgrade` (`fit_do_upgrade`) and `platform_check_image` (`fit_check_image`) in `platform.sh`. | Missing `fitblk` or `rootdisk` causes immediate SquashFS root mount bootloop; broken `platform.sh` cases break or corrupt `sysupgrade`. |
| **FIP offset mismatch vs. upstream `uboot-mediatek`** | Never flash in-tree OpenWrt `uboot-mediatek` BL2 (`0x380000` default FIP offset) onto NR3053; use only `scripts/build-nr3053-bootloader.sh` (`OVERRIDE_FIP_BASE=0x400000`). | BL2 looks for FIP at `0x380000` instead of `0x400000` and fails to boot U-Boot (requires `mtk_uartboot` recovery with `bl2-mt7981-ddr3-bga-ram-SP2-uartboot.bin`). |
| **Mandatory RAM test before flashing** | Always boot `*initramfs-recovery.itb` in RAM first (`bootm` / TFTP / Web Failsafe) and verify Wi-Fi, Ethernet, and NAND before running `sysupgrade` with `*squashfs-sysupgrade.itb`. | Prevents persistent bricking if a custom kernel/DTS build fails to initialize flash or networking. |
