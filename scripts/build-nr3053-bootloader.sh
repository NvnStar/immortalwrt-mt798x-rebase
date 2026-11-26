#!/usr/bin/env bash
set -euo pipefail

# Deterministic, SHA-pinned open-source bootloader builder for Viettel NR3053
# Source: quytttb/bl-mt798x-dhcpd (U-Boot 2025.07 + TF-A 2026-01 + Web Failsafe)

BOOTLOADER_REPO_URL="https://github.com/quytttb/bl-mt798x-dhcpd.git"
BOOTLOADER_COMMIT="e3df9aa28675993d816c5fea3cffe9635c856fb6"
BOOTLOADER_BOARD="viettel_nr3053"
BOOTLOADER_VERSION="SP2"
BOOTLOADER_VARIANT="default"
MAX_BL2_BYTES=1048576
MAX_FIP_BYTES=2097152

TOPDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTLOADER_DIR="${BOOTLOADER_DIR:-$TOPDIR/tmp/bl-mt798x-dhcpd}"

usage() {
	cat <<'EOF'
Usage: ./scripts/build-nr3053-bootloader.sh [--check-only] [OUTPUT_DIR]

Options:
  --check-only   Fetch/verify pinned bootloader sources, NR3053 brick-safety
                 defconfigs, DS35Q2GBS NAND support, and npm lockfile integrity
                 without running a cross-compile.
  -h, --help     Show this help message.

Environment:
  BOOTLOADER_DIR Override local checkout path (default: $TOPDIR/tmp/bl-mt798x-dhcpd).
EOF
}

CHECK_ONLY=0
OUTPUT_ARG=""

while [ "$#" -gt 0 ]; do
	case "$1" in
	--check-only)
		CHECK_ONLY=1
		shift
		;;
	-h|--help)
		usage
		exit 0
		;;
	-*)
		echo "ERROR: Unknown option: $1" >&2
		usage >&2
		exit 2
		;;
	*)
		if [ -n "$OUTPUT_ARG" ]; then
			echo "ERROR: Unexpected extra argument: $1" >&2
			usage >&2
			exit 2
		fi
		OUTPUT_ARG="$1"
		shift
		;;
	esac
done

if [ -n "$OUTPUT_ARG" ]; then
	case "$OUTPUT_ARG" in
	/*) OUTPUT_DIR="$OUTPUT_ARG" ;;
	*) OUTPUT_DIR="$PWD/$OUTPUT_ARG" ;;
	esac
else
	OUTPUT_DIR="$TOPDIR/tmp/dist-bootloader"
fi

die() {
	echo "ERROR: $*" >&2
	exit 1
}

require_line() {
	local file="$1"
	local line="$2"
	[ -f "$file" ] || die "Missing expected file: $file"
	if ! grep -Fxq -- "$line" "$file"; then
		die "Expected exact line '$line' missing in $file"
	fi
}

require_single_match() {
	local desc="$1"
	shift
	local matches=("$@")
	local existing=()
	local p
	for p in "${matches[@]}"; do
		if [ -f "$p" ]; then
			existing+=("$p")
		fi
	done
	if [ "${#existing[@]}" -ne 1 ]; then
		die "Expected exactly 1 $desc file, found ${#existing[@]} (${existing[*]:-none})"
	fi
	printf '%s\n' "${existing[0]}"
}

ensure_bootloader_checkout() {
	if [ ! -d "$BOOTLOADER_DIR/.git" ]; then
		if [ -e "$BOOTLOADER_DIR" ]; then
			die "BOOTLOADER_DIR exists without .git: $BOOTLOADER_DIR"
		fi
		mkdir -p "$(dirname "$BOOTLOADER_DIR")"
		git clone --quiet --no-checkout "$BOOTLOADER_REPO_URL" "$BOOTLOADER_DIR"
	fi

	if ! git -C "$BOOTLOADER_DIR" cat-file -e "${BOOTLOADER_COMMIT}^{commit}" 2>/dev/null; then
		git -C "$BOOTLOADER_DIR" fetch --quiet --depth 1 origin "$BOOTLOADER_COMMIT"
	fi

	git -C "$BOOTLOADER_DIR" checkout --quiet --detach "$BOOTLOADER_COMMIT"

	local head_sha
	head_sha="$(git -C "$BOOTLOADER_DIR" rev-parse HEAD)"
	[ "$head_sha" = "$BOOTLOADER_COMMIT" ] || die "HEAD mismatch: expected $BOOTLOADER_COMMIT, got $head_sha"
}

verify_bootloader_sources() {
	local atf_defconfig="$BOOTLOADER_DIR/atf-20260123/configs/mt7981_viettel_nr3053_defconfig"
	local atf_nand="$BOOTLOADER_DIR/atf-20260123/plat/mediatek/apsoc_common/drivers/spi_nand/mtk_spi_nand.c"
	local uboot_defconfig="$BOOTLOADER_DIR/uboot-mtk-20250711/configs/mt7981_viettel_nr3053_defconfig"
	local npm_lock="$BOOTLOADER_DIR/uboot-mtk-20250711/failsafe/embedded/package-lock.json"

	require_line "$atf_defconfig" "_PLAT_MT7981=y"
	require_line "$atf_defconfig" "_MT7981_BOARD_BGA=y"
	require_line "$atf_defconfig" "_ENABLE_OVERRIDE_FIP_BASE=y"
	require_line "$atf_defconfig" "OVERRIDE_FIP_BASE=0x400000"
	require_line "$atf_defconfig" "_ENABLE_OVERRIDE_FIP_SIZE=y"
	require_line "$atf_defconfig" "OVERRIDE_FIP_SIZE=0x200000"

	[ -f "$atf_nand" ] || die "Missing ATF SPI-NAND driver: $atf_nand"
	grep -Fq '"DS35Q2GBS"' "$atf_nand" || die "DS35Q2GBS missing in $atf_nand"
	grep -Fq '0xe5, 0xb2' "$atf_nand" || die "Dosilicon ID (0xe5, 0xb2) missing in $atf_nand"

	require_line "$uboot_defconfig" 'CONFIG_MTDPARTS_DEFAULT="nmbm0:1024k(bl2),1024k(u-boot-env),2048k(Factory),2048k(fip),-(ubi)"'
	require_line "$uboot_defconfig" 'CONFIG_ENV_IS_IN_MTD=y'

	[ -f "$npm_lock" ] || die "Missing npm lockfile: $npm_lock"
	python3 - "$npm_lock" <<'PY'
import json
import sys

lock_path = sys.argv[1]
with open(lock_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

checked = 0

def validate_entry(ctx, entry):
    global checked
    if not isinstance(entry, dict):
        return
    resolved = entry.get("resolved")
    if resolved is not None:
        if not isinstance(resolved, str) or not resolved.startswith("https://registry.npmjs.org/"):
            raise SystemExit(f"ERROR: Disallowed resolved URL in {ctx}: {resolved!r}")
        integrity = entry.get("integrity", "")
        if not isinstance(integrity, str) or not integrity.startswith("sha512-") or len(integrity) <= len("sha512-"):
            raise SystemExit(f"ERROR: Missing sha512 integrity in {ctx}: {integrity!r}")
        checked += 1
    deps = entry.get("dependencies")
    if isinstance(deps, dict):
        for name, sub in deps.items():
            validate_entry(f"{ctx}.dependencies.{name}", sub)

packages = data.get("packages")
if isinstance(packages, dict):
    for pkg_path, pkg_meta in packages.items():
        if pkg_path == "":
            continue
        validate_entry(f"packages[{pkg_path}]", pkg_meta)

dependencies = data.get("dependencies")
if isinstance(dependencies, dict):
    for name, dep_meta in dependencies.items():
        validate_entry(f"dependencies.{name}", dep_meta)

if checked == 0:
    raise SystemExit("ERROR: No resolved packages found in package-lock.json")
PY
}

ensure_bootloader_checkout
verify_bootloader_sources

if [ "$CHECK_ONLY" -eq 1 ]; then
	echo "PASS: Verified bootloader commit $BOOTLOADER_COMMIT ($BOOTLOADER_BOARD $BOOTLOADER_VERSION)"
	echo "PASS: Verified ATF OVERRIDE_FIP_BASE=0x400000, OVERRIDE_FIP_SIZE=0x200000, DS35Q2GBS NAND (0xe5, 0xb2)"
	echo "PASS: Verified U-Boot mtdparts (nmbm0) and npm lockfile sha512 integrity"
	exit 0
fi

missing_cmds=()
for cmd in aarch64-linux-gnu-gcc make dtc node npm python3; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		missing_cmds+=("$cmd")
	fi
done
if [ "${#missing_cmds[@]}" -gt 0 ]; then
	echo "ERROR: Missing required host build tool(s): ${missing_cmds[*]}" >&2
	echo "Install on Debian/Ubuntu with:" >&2
	echo "  sudo apt-get install -y gcc-aarch64-linux-gnu device-tree-compiler nodejs npm" >&2
	exit 1
fi

SOURCE_DATE_EPOCH="$(git -C "$BOOTLOADER_DIR" show -s --format=%ct HEAD)"
export SOURCE_DATE_EPOCH
export TZ=UTC

(
	cd "$BOOTLOADER_DIR/uboot-mtk-20250711/failsafe/embedded"
	npm ci --ignore-scripts --no-audit --no-fund
	touch .npm-install-done
)

rm -f "$BOOTLOADER_DIR/output/"*viettel_nr3053* "$BOOTLOADER_DIR/output/build-${BOOTLOADER_BOARD}-${BOOTLOADER_VERSION}-${BOOTLOADER_VARIANT}.log" 2>/dev/null || true
rm -f "$BOOTLOADER_DIR/output_bl2/bl2-mt7981-ddr3-bga-ram-${BOOTLOADER_VERSION}"* 2>/dev/null || true

make -C "$BOOTLOADER_DIR" \
	BOARD="$BOOTLOADER_BOARD" \
	VERSION="$BOOTLOADER_VERSION" \
	VARIANT="$BOOTLOADER_VARIANT" \
	BUILD_LOG=y

(
	cd "$BOOTLOADER_DIR"
	VERSION="$BOOTLOADER_VERSION" ./compile_atf.sh mt7981-ddr3-bga-ram
)

shopt -s nullglob
fip_candidates=("$BOOTLOADER_DIR/output/fip-mt7981-${BOOTLOADER_BOARD}-${BOOTLOADER_VERSION}"*.bin)
bl2_candidates=("$BOOTLOADER_DIR/output/bl2-mt7981_${BOOTLOADER_BOARD}_${BOOTLOADER_VERSION}"*.img)
ram_bl2_candidates=("$BOOTLOADER_DIR/output_bl2/bl2-mt7981-ddr3-bga-ram-${BOOTLOADER_VERSION}"*)
shopt -u nullglob

fip_file="$(require_single_match "FIP" "${fip_candidates[@]}")"
bl2_file="$(require_single_match "SPI-NAND BL2" "${bl2_candidates[@]}")"
ram_bl2_file="$(require_single_match "UART RAM BL2" "${ram_bl2_candidates[@]}")"

bl2_size="$(stat -c '%s' "$bl2_file")"
fip_size="$(stat -c '%s' "$fip_file")"
ram_bl2_size="$(stat -c '%s' "$ram_bl2_file")"

[ "$bl2_size" -gt 0 ] && [ "$bl2_size" -le "$MAX_BL2_BYTES" ] || \
	die "SPI-NAND BL2 size out of bounds: $bl2_size bytes (max $MAX_BL2_BYTES)"
[ "$fip_size" -gt 0 ] && [ "$fip_size" -le "$MAX_FIP_BYTES" ] || \
	die "FIP size out of bounds: $fip_size bytes (max $MAX_FIP_BYTES)"
[ "$ram_bl2_size" -gt 0 ] || \
	die "UART RAM BL2 is empty: $ram_bl2_file"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

cp "$fip_file" "$OUTPUT_DIR/immortalwrt-mediatek-filogic-viettel_nr3053-bl31-uboot.fip"
cp "$bl2_file" "$OUTPUT_DIR/immortalwrt-mediatek-filogic-viettel_nr3053-preloader.bin"
cp "$ram_bl2_file" "$OUTPUT_DIR/bl2-mt7981-ddr3-bga-ram-SP2-uartboot.bin"

build_log="$BOOTLOADER_DIR/output/build-${BOOTLOADER_BOARD}-${BOOTLOADER_VERSION}-${BOOTLOADER_VARIANT}.log"
if [ -f "$build_log" ]; then
	cp "$build_log" "$OUTPUT_DIR/build-viettel_nr3053-SP2-default.log"
fi

cat > "$OUTPUT_DIR/BOOTLOADER-PROVENANCE-AND-WARNING.txt" <<EOF
Viettel NR3053 Open-Source Bootloader Provenance & Flashing Warning
====================================================================

Source Repository : $BOOTLOADER_REPO_URL
Pinned Commit SHA : $BOOTLOADER_COMMIT
Board / Version   : $BOOTLOADER_BOARD / $BOOTLOADER_VERSION ($BOOTLOADER_VARIANT)
SOURCE_DATE_EPOCH : $SOURCE_DATE_EPOCH (TZ=UTC)
Partition Offsets : BL2 @ 0x0 (max 1 MiB / $MAX_BL2_BYTES bytes)
                    FIP @ 0x400000 (max 2 MiB / $MAX_FIP_BYTES bytes)

Output Sizes (bytes):
- immortalwrt-mediatek-filogic-viettel_nr3053-preloader.bin : $bl2_size
- immortalwrt-mediatek-filogic-viettel_nr3053-bl31-uboot.fip : $fip_size
- bl2-mt7981-ddr3-bga-ram-SP2-uartboot.bin                  : $ram_bl2_size

CRITICAL BRICK-SAFETY WARNING:
1. Normal OpenWrt/ImmortalWrt firmware upgrades use ONLY:
     immortalwrt-mediatek-filogic-viettel_nr3053-squashfs-sysupgrade.itb
   DO NOT flash preloader.bin or bl31-uboot.fip during normal upgrades.
2. Only flash preloader.bin (mtd0 BL2 @ 0x0) or bl31-uboot.fip (mtd3 FIP @ 0x400000)
   if you intentionally want to install/replace the bootloader AND have already
   backed up mtd0 (BL2), mtd1 (u-boot-env), mtd2 (Factory), and mtd3 (FIP).
3. bl2-mt7981-ddr3-bga-ram-SP2-uartboot.bin is a RAM-only recovery image for
   mtk_uartboot serial recovery. NEVER flash it to SPI-NAND!
EOF

(
	cd "$OUTPUT_DIR"
	sha256sum * > sha256sums
	sha256sum -c sha256sums
)

echo "PASS: Bootloader artifacts written to $OUTPUT_DIR"
