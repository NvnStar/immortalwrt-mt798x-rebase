# Wi-Fi Roaming (802.11r/k/v) & SQM/CAKE Tuning Guide (Viettel / SDMC NR3053)

This guide covers hardware-verified **SQM/CAKE anti-bufferbloat** and **Wi-Fi roaming (`802.11r/k/v`)** settings for the **Viettel (SDMC) NR3053** running the `nr3053-mt76` (`immortalwrt/openwrt-25.12`) firmware.

---

## 1. Out-of-the-Box Baseline in `nr3053-mt76`

Before running extra package installs or tweaks, note what is already built into the NR3053 CI image:

| Feature / Package | Default State | Notes |
| --- | --- | --- |
| **`wpad-openssl`** | Pre-installed | Full OpenSSL `hostapd`/`wpad` with `802.11r`, `802.11k`, `802.11v`, `WPA3-SAE`, and `802.1X` support (enforced by `verify-nr3053-transparency.sh`). |
| **`luci-app-sqm` + `sqm-scripts`** (`kmod-sched-cake`, `kmod-ifb`, `tc-tiny`) | Pre-installed, **`enabled='0'`** | Pre-seeded on `sqm.wan` with `interface='wan'`, `qdisc='cake'`, `script='piece_of_cake.qos'`, `linklayer='ethernet'`, `overhead='44'`, `download='250000'`, `upload='250000'`. Disabled by default so gigabit WAN lines are never throttled unintentionally. |
| **`irqbalance`** | Pre-installed, **`enabled='1'`** | Enabled on first boot by `99-nr3053-defaults` to balance IRQs across both MT7981B Cortex-A53 cores. |
| **`kmod-tcp-bbr`** | Pre-installed | Kernel BBR congestion control module available in the image. |
| **`bridger` + `mt7915e` WED** | Pre-installed (`wed_enable=Y`) | BPF bridge acceleration (`bridger`) and Filogic Wireless Ethernet Dispatch (WED) hardware offload for L2 LAN/WLAN traffic. |
| **`kmod-nft-fullcone`** | Pre-installed (`fullcone=1`) | ImmortalWrt `firewall4` IPv4 Full-Cone NAT enabled by default (`fullcone6=0`). |

> **Why `luci-app-sqm` is pre-installed**: Custom GitHub Actions and local source builds stamp a build-specific kernel vermagic hash into `kernel`. Attempting `apk add luci-app-sqm` at runtime against rolling `downloads.immortalwrt.org/releases/25.12-SNAPSHOT` would fail on `kmod-sched-cake` and `kmod-ifb` kernel-vermagic dependencies. Pre-installing `luci-app-sqm` with `enabled='0'` costs minimal SquashFS space and **zero CPU or throughput overhead** until you enable it.

---

## 2. SQM / CAKE Anti-Bufferbloat Configuration

### When to Enable vs. Keep Disabled

- **Enable SQM/CAKE (`enabled='1'`)** on WAN connections up to **~300 Mbps**, or whenever consistent Grade A/A+ low latency under heavy upload/download matters more than peak single-stream throughput.
- **Keep SQM disabled (`enabled='0'`)** if:
  - You have a **500–1000 Mbps FTTH plan** and want full gigabit throughput. On the dual-core 1.3 GHz Cortex-A53 **MT7981B**, software `sch_cake` + `ifb` runs in single-core softirq (`sirq`) and tops out around **~250–300 Mbps per direction**.
  - You operate the NR3053 as a **Dumb AP / Mesh node** (no WAN routing).
- **Do NOT enable `flow_offloading_hw='1'`** in `firewall4` while using SQM: hardware flow offloading bypasses Linux `tc`/CAKE queues on routed WAN traffic.
  - Note: `bridger` and `mt7915e` `wed_enable=Y` accelerate **L2 bridged LAN <-> WLAN** traffic; routed WAN packets still traverse CAKE normally as long as `flow_offloading_hw` remains off.

### Choosing the Right NR3053 WAN Interface

The NR3053 uses a MediaTek MT7531 DSA switch exposing `lan1`, `lan2`, `lan3`, and `wan` — **`eth1` does not exist** on this hardware.

- Use **`wan`** if the NR3053 WAN interface gets an IP via DHCP or Static IP behind an ISP ONT.
- Use **`pppoe-wan`** if the NR3053 dials FTTH PPPoE directly (bridged Viettel / VNPT / FPT ONT).

Verify your active Layer-3 WAN device in one command:

```sh
ifstatus wan | jsonfilter -e '@.l3_device'
```

### Bandwidth & Framing Rules

1. Temporarily leave SQM disabled and measure your real unshaped download/upload speeds.
2. Set `download` and `upload` (in **kbit/s**) to **85–90%** of your measured speed (capped around `250000`–`300000` kbit/s on faster lines to avoid `sirq` CPU saturation).
3. Keep `linklayer='ethernet'` and `overhead='44'` (safe framing overhead for GPON, VLAN tags, and PPPoE).

### Option A: LuCI Setup

1. Open **Network -> SQM QoS**.
2. Edit the pre-configured **`wan`** queue instance:
   - **Basic Settings**: check **Enable this SQM instance**, select **`wan`** (or **`pppoe-wan`** if using PPPoE) for **Interface name**, and set **Download speed** / **Upload speed** (kbit/s) to 85–90% of measured speed.
   - **Queue Discipline**: verify `cake` and `piece_of_cake.qos`.
   - **Link Layer Adaptation**: verify `Ethernet with overhead` and **Per Packet Overhead (byte)** = `44`.
3. Click **Save & Apply**.

### Option B: SSH UCI Setup

```sh
# 1. Detect active L3 WAN interface ('wan' for DHCP/Static, 'pppoe-wan' for PPPoE)
WAN_L3_DEV="$(ifstatus wan | jsonfilter -e '@.l3_device')"
echo "Detected L3 WAN device: ${WAN_L3_DEV:-wan}"

# 2. Configure and enable SQM on the pre-created sqm.wan queue (example: 250 Mbps line -> ~220 Mbps)
uci set sqm.wan.interface="${WAN_L3_DEV:-wan}"
uci set sqm.wan.download='220000'
uci set sqm.wan.upload='220000'
uci set sqm.wan.qdisc='cake'
uci set sqm.wan.script='piece_of_cake.qos'
uci set sqm.wan.linklayer='ethernet'
uci set sqm.wan.overhead='44'
uci set sqm.wan.enabled='1'
uci commit sqm

/etc/init.d/sqm enable
/etc/init.d/sqm restart
```

### Verification

Check that CAKE is attached to your active WAN interface (replace `wan` with `pppoe-wan` if using PPPoE) and test loaded latency with the [Waveform Bufferbloat Test](https://www.waveform.com/tools/bufferbloat):

```sh
tc -s qdisc show dev wan
# Or for PPPoE:
# tc -s qdisc show dev pppoe-wan
```

> **`sysupgrade` note**: `/etc/config/sqm` is preserved across `sysupgrade` (without `-n`). `99-nr3053-defaults` only migrates an untouched stock `sqm.eth1` template (`enabled='0'`, `interface='eth1'`) and never overwrites user-customized SQM settings.

---

## 3. Wi-Fi Security & Roaming (`802.11r / 802.11k / 802.11v`)

On first boot, ImmortalWrt creates `default_radio0` (2.4 GHz `he20`) and `default_radio1` (5 GHz `he80`) with `ssid='ImmortalWrt'` and `encryption='none'`.

- **`802.11r` requires WPA2 or WPA3 (`wpa >= 2`)**: OpenWrt's `wifi-scripts` (`ap.uc`) ignores `ieee80211r` on unencrypted (`encryption='none'`) networks.
- **Auto-derived roaming keys in OpenWrt 25.12**: When `ssid`, `key`, and `encryption` match across radios/APs, `ap.uc` automatically derives a deterministic 4-hex `mobility_domain` from the SSID, sets `ft_psk_generate_local='1'` for WPA2-PSK (`psk2+ccmp`), and derives deterministic `r0kh`/`r1kh` keys for WPA2/WPA3 mixed mode (`psk-sae`).

### Option A: LuCI Setup

1. Open **Network -> Wireless** and click **Edit** on each radio interface (`2.4 GHz` and `5 GHz`).
2. Set the same **ESSID** on both interfaces.
3. Under **Interface Configuration -> Wireless Security**:
   - Choose **WPA2-PSK (`psk2+ccmp`)** for maximum IoT + legacy client compatibility, or **WPA2-PSK/WPA3-SAE Mixed Mode (`psk-sae`)** for modern clients.
   - Set a **Key** of at least 8 characters.
4. Under **Interface Configuration -> WLAN Roaming**:
   - Enable **802.11r Fast Transition** (`ieee80211r='1'`, leave **FT protocol** on *FT over the Air* / `ft_over_ds='0'`).
   - Enable **802.11k Radio Resource Measurement** (`ieee80211k='1'`).
   - Enable **802.11v BSS Transition** (`bss_transition='1'`).
5. Click **Save & Apply** and repeat for the second radio.

### Option B: SSH UCI Setup

Replace `'YourWiFiName'` and `'YourStrongPassword'` before running:

```sh
for iface in default_radio0 default_radio1; do
  uci set wireless.${iface}.ssid='YourWiFiName'
  uci set wireless.${iface}.encryption='psk2+ccmp'
  uci set wireless.${iface}.key='YourStrongPassword'
  uci set wireless.${iface}.ieee80211r='1'
  uci set wireless.${iface}.ft_over_ds='0'
  uci set wireless.${iface}.ieee80211k='1'
  uci set wireless.${iface}.bss_transition='1'
done
uci commit wireless
wifi reload
```

> Use `encryption='psk-sae'` instead of `'psk2+ccmp'` if all your clients support WPA3-SAE / MFP cleanly.

### Two Critical Real-World Caveats

1. **2.4 GHz IoT Compatibility (`802.11r` / `FT-SAE`)**:
   Older 2.4 GHz IoT devices (ESP8266, Tuya smart plugs, IP cameras, older printers) frequently fail to associate when `ieee80211r='1'` or `psk-sae` is enabled on 2.4 GHz. If IoT devices drop or refuse to connect, keep `802.11r/k/v` on 5 GHz (`default_radio1`) and disable `802.11r` on 2.4 GHz (`default_radio0`) — or create a dedicated 2.4 GHz `psk2+ccmp` IoT SSID without `802.11r`:

   ```sh
   uci set wireless.default_radio0.ieee80211r='0'
   uci set wireless.default_radio0.encryption='psk2+ccmp'
   uci commit wireless
   wifi reload
   ```

2. **Single-AP vs. Multi-AP Steering (`hostapd` vs. `usteer`)**:
   In standalone `hostapd`, `ieee80211k='1'` and `bss_transition='1'` enable **passive** RRM/WNM capabilities for client-initiated roaming — `hostapd` does **not** automatically populate cross-band (`2.4G <-> 5G`) Neighbor Reports or actively send `802.11v` BSS Transition steering kicks on its own. For multi-AP NR3053 setups (or active AP-assisted band steering), install `luci-app-usteer` (a pure userspace package with no kernel vermagic restriction):

   ```sh
   apk update && apk add luci-app-usteer
   ```

---

## 4. Summary of Corrections vs. `hashcott` Gist (`68e337ac52f3410e6d19a177fb5bc1bf`)

| Topic | Community Gist | `nr3053-mt76` Verified Behavior |
| --- | --- | --- |
| **SQM package install & default state** | Runs `apk add luci-app-sqm` at runtime and forces `enabled='1'` at `250000` kbit/s | `luci-app-sqm` + `sqm-scripts` (`kmod-sched-cake`, `kmod-ifb`) are **pre-installed** (avoiding custom kernel vermagic mismatch) and **`enabled='0'` by default** so gigabit lines are not throttled. |
| **WAN interface name** | Hardcodes `interface='eth1'` | NR3053 uses MT7531 DSA (`lan1`/`lan2`/`lan3`/`wan`) — **`eth1` does not exist**. Use **`wan`** (DHCP/Static) or **`pppoe-wan`** (PPPoE). |
| **Invalid roaming UCI option** | Sets `ft_roam_wakeup='1'` | **Removed**: `ft_roam_wakeup` does not exist in OpenWrt `wifi-scripts` schema, `ap.uc`, `hostapd.sh`, or `hostapd`. |
| **Wi-Fi reload & upgrade safety** | Uses legacy reload pattern / overwrites defaults | Uses `wifi reload`, keeps `802.11r/k/v` opt-in after setting WPA2/WPA3 credentials, and preserves user `/etc/config/sqm` across `sysupgrade`. |
