#!/usr/bin/env bash
set -euo pipefail

# Automated transparency, provenance, and brick-safety gate for Viettel NR3053

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BASE_IMMORTALWRT_COMMIT="b1088b5661bf257b3e89f8537df906a67b8e7289"
EXPECTED_BOOTLOADER_COMMIT="e3df9aa28675993d816c5fea3cffe9635c856fb6"

usage() {
	cat <<'EOF'
Usage:
  ./scripts/verify-nr3053-transparency.sh [--root <repo_root>] --pre-build
  ./scripts/verify-nr3053-transparency.sh [--root <repo_root>] --check-config <config_file>
  ./scripts/verify-nr3053-transparency.sh [--root <repo_root>] --post-build <dist_dir>

Options:
  --root <repo_root>           Override repository root (default: parent of scripts/)
  --pre-build                  Run static source, pinning, checksum, and brick-safety checks
  --check-config <config_file> Validate resolved OpenWrt/ImmortalWrt .config file
  --post-build <dist_dir>      Validate built firmware artifacts, manifest, fwtool metadata, and sums
  -h, --help                   Show this help message
EOF
}

ROOT_DIR="$DEFAULT_ROOT"
MODE=""
MODE_ARG=""

while [ "$#" -gt 0 ]; do
	case "$1" in
	--root)
		[ "$#" -ge 2 ] || { echo "ERROR: --root requires an argument" >&2; exit 2; }
		ROOT_DIR="$2"
		shift 2
		;;
	--pre-build)
		[ -z "$MODE" ] || { echo "ERROR: Multiple modes specified" >&2; exit 2; }
		MODE="pre-build"
		shift
		;;
	--check-config)
		[ -z "$MODE" ] || { echo "ERROR: Multiple modes specified" >&2; exit 2; }
		[ "$#" -ge 2 ] || { echo "ERROR: --check-config requires a file argument" >&2; exit 2; }
		MODE="check-config"
		MODE_ARG="$2"
		shift 2
		;;
	--post-build)
		[ -z "$MODE" ] || { echo "ERROR: Multiple modes specified" >&2; exit 2; }
		[ "$#" -ge 2 ] || { echo "ERROR: --post-build requires a directory argument" >&2; exit 2; }
		MODE="post-build"
		MODE_ARG="$2"
		shift 2
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		echo "ERROR: Unknown argument: $1" >&2
		usage >&2
		exit 2
		;;
	esac
done

[ -n "$MODE" ] || { echo "ERROR: Must specify one of --pre-build, --check-config, or --post-build" >&2; usage >&2; exit 2; }
[ -d "$ROOT_DIR" ] || { echo "ERROR: Repository root not found: $ROOT_DIR" >&2; exit 1; }
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"

die() {
	echo "ERROR: $*" >&2
	exit 1
}

run_check_config() {
	local cfg="$1"
	[ -f "$cfg" ] || die "Config file not found: $cfg"

	python3 - "$cfg" <<'PY'
import re
import sys

cfg_path = sys.argv[1]
with open(cfg_path, "r", encoding="utf-8", errors="replace") as fh:
    lines = [line.rstrip("\r\n") for line in fh]

required_patterns = [
    (r"^CONFIG_TARGET_mediatek=y$", "CONFIG_TARGET_mediatek=y"),
    (r"^CONFIG_TARGET_mediatek_filogic=y$", "CONFIG_TARGET_mediatek_filogic=y"),
    (
        r"^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_viettel_nr3053=y$",
        "CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_viettel_nr3053=y",
    ),
    (r"^CONFIG_PACKAGE_fitblk=y$", "CONFIG_PACKAGE_fitblk=y"),
    (r"^CONFIG_PACKAGE_kmod-mt7915e=(y|m)$", "CONFIG_PACKAGE_kmod-mt7915e=y|m"),
    (r"^CONFIG_PACKAGE_kmod-mt7981-firmware=(y|m)$", "CONFIG_PACKAGE_kmod-mt7981-firmware=y|m"),
    (r"^CONFIG_PACKAGE_mt7981-wo-firmware=(y|m)$", "CONFIG_PACKAGE_mt7981-wo-firmware=y|m"),
    (r"^CONFIG_PACKAGE_wpad-openssl=(y|m)$", "CONFIG_PACKAGE_wpad-openssl=y|m"),
]

forbidden_patterns = [
    (r"^CONFIG_PACKAGE_default-settings=", "CONFIG_PACKAGE_default-settings="),
    (r"^CONFIG_PACKAGE_default-settings-chn=", "CONFIG_PACKAGE_default-settings-chn="),
    (r"^CONFIG_LUCI_LANG_zh_Hans=y$", "CONFIG_LUCI_LANG_zh_Hans=y"),
    (r"^CONFIG_PACKAGE_mt_wifi=", "CONFIG_PACKAGE_mt_wifi="),
    (r"^CONFIG_PACKAGE_kmod-mt_wifi=", "CONFIG_PACKAGE_kmod-mt_wifi="),
    (r"^CONFIG_PACKAGE_wpad-(basic|mini)(-.*)?=y$", "CONFIG_PACKAGE_wpad-basic/mini=y"),
]

errors = []
for pat, label in required_patterns:
    rx = re.compile(pat)
    if not any(rx.match(line) for line in lines):
        errors.append(f"Missing required config option: {label}")

for pat, label in forbidden_patterns:
    rx = re.compile(pat)
    matches = [line for line in lines if rx.match(line)]
    if matches:
        errors.append(f"Forbidden config option present ({label}): {matches[0]}")

if errors:
    for err in errors:
        print(f"FAIL: {err}", file=sys.stderr)
    sys.exit(1)

print(f"PASS: Config checks passed for {cfg_path}")
PY
}

run_pre_build() {
	# 1. Branch delta & zero-binary gate (when git repo + base commit exist)
	if [ -e "$ROOT_DIR/.git" ] && git -C "$ROOT_DIR" cat-file -e "${BASE_IMMORTALWRT_COMMIT}^{commit}" 2>/dev/null; then
		local tracked_diff untracked_files binary_diff
		tracked_diff="$(git -C "$ROOT_DIR" diff --name-only "$BASE_IMMORTALWRT_COMMIT")"
		untracked_files="$(git -C "$ROOT_DIR" ls-files --others --exclude-standard)"

		python3 - "$tracked_diff" "$untracked_files" <<'PY'
import sys

tracked = [x.strip() for x in sys.argv[1].splitlines() if x.strip()]
untracked = [x.strip() for x in sys.argv[2].splitlines() if x.strip()]
all_paths = sorted(set(tracked + untracked))

allowlist = {
    "target/linux/mediatek/dts/mt7981b-viettel-nr3053.dts",
    "target/linux/mediatek/image/filogic.mk",
    "target/linux/mediatek/filogic/base-files/etc/board.d/02_network",
    "target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh",
    "package/boot/uboot-tools/uboot-envtools/files/mediatek_filogic",
    "feeds.conf.default",
    ".github/workflows/build-nr3053-mt76.yml",
    "scripts/verify-nr3053-transparency.sh",
    "scripts/build-nr3053-bootloader.sh",
    "docs/TRANSPARENCY.md",
    "docs/TUNING.md",
    "README.md",
}

def is_local_ignored(p):
    return (
        p == ".agent"
        or p.startswith(".agent/")
        or p == ".kilo"
        or p.startswith(".kilo/")
        or p.startswith("immortalwrt-nr3053-mt76-")
        or p == "dist"
        or p.startswith("dist/")
        or p == "files"
        or p.startswith("files/")
    )

disallowed = [p for p in all_paths if not is_local_ignored(p) and p not in allowlist]
if disallowed:
    for p in disallowed:
        print(f"FAIL: Unallowlisted modified/untracked file vs base: {p}", file=sys.stderr)
    sys.exit(1)
PY

		binary_diff="$(git -C "$ROOT_DIR" diff --numstat "$BASE_IMMORTALWRT_COMMIT" -- target/ package/ include/ scripts/ tools/ toolchain/ config/ | awk -F'\t' '$1 == "-" && $2 == "-" { print }')"
		if [ -n "$binary_diff" ]; then
			die "Binary file changes detected in core directories vs $BASE_IMMORTALWRT_COMMIT: $binary_diff"
		fi
		echo "PASS: Git delta allowlist and zero-binary check passed"
	else
		echo "INFO: Skipping git base-commit delta gate (.git or $BASE_IMMORTALWRT_COMMIT unavailable)"
	fi

	# 2. Immutable pinning & checksum enforcement gate
	local feeds_file="$ROOT_DIR/feeds.conf.default"
	local workflow_file="$ROOT_DIR/.github/workflows/build-nr3053-mt76.yml"
	local bootloader_script="$ROOT_DIR/scripts/build-nr3053-bootloader.sh"

	[ -f "$feeds_file" ] || die "Missing $feeds_file"
	[ -f "$workflow_file" ] || die "Missing $workflow_file"
	[ -f "$bootloader_script" ] || die "Missing $bootloader_script"

	python3 - "$feeds_file" "$workflow_file" "$bootloader_script" "$EXPECTED_BOOTLOADER_COMMIT" <<'PY'
import re
import sys

feeds_path, wf_path, bl_path, expected_bl_commit = sys.argv[1:5]

# Validate feeds.conf.default
feed_rx = re.compile(
    r"^src-git [a-z0-9_-]+ https://github\.com/(immortalwrt|openwrt)/[a-z0-9._-]+\.git\^[0-9a-f]{40}$"
)
feed_count = 0
with open(feeds_path, "r", encoding="utf-8") as fh:
    for lineno, raw in enumerate(fh, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if not feed_rx.match(line):
            raise SystemExit(
                f"FAIL: Unpinned or disallowed feed entry at {feeds_path}:{lineno}: {line}"
            )
        feed_count += 1
if feed_count == 0:
    raise SystemExit(f"FAIL: No feed entries found in {feeds_path}")

# Validate workflow uses: lines
uses_line_rx = re.compile(r"^\s*(?:-\s*)?uses:\s*(.+?)\s*$")
uses_val_rx = re.compile(r"^actions/[a-z0-9_/-]+@[0-9a-f]{40}(\s+#.*)?$")
uses_count = 0
with open(wf_path, "r", encoding="utf-8") as fh:
    for lineno, raw in enumerate(fh, 1):
        stripped = raw.lstrip()
        if stripped.startswith("#"):
            continue
        m = uses_line_rx.match(raw.rstrip("\r\n"))
        if m:
            val = m.group(1)
            if not uses_val_rx.match(val):
                raise SystemExit(
                    f"FAIL: Unpinned or non-official action at {wf_path}:{lineno}: uses: {val}"
                )
            uses_count += 1
if uses_count == 0:
    raise SystemExit(f"FAIL: No 'uses:' steps found in {wf_path}")

# Validate build-nr3053-bootloader.sh
with open(bl_path, "r", encoding="utf-8") as fh:
    bl_text = fh.read()
commit_m = re.search(r'^BOOTLOADER_COMMIT="([0-9a-f]{40})"$', bl_text, re.MULTILINE)
if not commit_m or commit_m.group(1) != expected_bl_commit:
    raise SystemExit(
        f"FAIL: {bl_path} must define BOOTLOADER_COMMIT=\"{expected_bl_commit}\""
    )
if "npm ci --ignore-scripts" not in bl_text:
    raise SystemExit(f"FAIL: {bl_path} must use 'npm ci --ignore-scripts'")
PY

	local scan_dirs=()
	local d
	for d in package tools toolchain; do
		if [ -d "$ROOT_DIR/$d" ]; then
			scan_dirs+=("$ROOT_DIR/$d")
		fi
	done
	if [ "${#scan_dirs[@]}" -gt 0 ]; then
		local skip_hits
		skip_hits="$(find "${scan_dirs[@]}" -path "$ROOT_DIR/package/feeds" -prune -o -type f -name 'Makefile' -print0 | xargs -0 grep -nE 'PKG_(MIRROR_)?HASH:=skip' 2>/dev/null || true)"
		if [ -n "$skip_hits" ]; then
			die "Disallowed skipped package hash(es) detected:\n$skip_hits"
		fi
	fi
	echo "PASS: Immutable SHA pinning and zero-skip-hash checks passed"

	# 3. NR3053 hardware brick-safety static gate
	local dts_file="$ROOT_DIR/target/linux/mediatek/dts/mt7981b-viettel-nr3053.dts"
	local patch_file="$ROOT_DIR/target/linux/mediatek/patches-6.12/341-mtd-spinand-Support-dosilicon.patch"
	local platform_file="$ROOT_DIR/target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh"
	local mk_file="$ROOT_DIR/target/linux/mediatek/image/filogic.mk"

	[ -f "$dts_file" ] || die "Missing DTS file: $dts_file"
	[ -f "$patch_file" ] || die "Missing Dosilicon SPI-NAND patch: $patch_file"
	[ -f "$platform_file" ] || die "Missing platform upgrade script: $platform_file"
	[ -f "$mk_file" ] || die "Missing image Makefile: $mk_file"

	grep -Fq 'SPINAND_INFO("DS35Q2GBS"' "$patch_file" || \
		die "DS35Q2GBS entry missing from $patch_file"

	python3 - "$dts_file" "$platform_file" "$mk_file" <<'PY'
import re
import sys

dts_path, platform_path, mk_path = sys.argv[1:4]

# --- DTS block parser ---
with open(dts_path, "r", encoding="utf-8") as fh:
    dts_raw = fh.read()

# Strip C/DTS comments and preprocessor directives (#include, etc.)
dts_clean = re.sub(r"/\*.*?\*/", "", dts_raw, flags=re.S)
dts_clean = re.sub(r"//.*", "", dts_clean)
dts_clean = re.sub(r"^\s*#.*$", "", dts_clean, flags=re.M)

def parse_dts_nodes(text):
    # Recursive descent parser for DTS blocks: returns list of (header, body, children)
    idx = 0
    n = len(text)

    def parse_block():
        nonlocal idx
        stmts = []
        children = []
        buf = []
        while idx < n:
            ch = text[idx]
            if ch == "{":
                header = "".join(buf).strip()
                buf = []
                idx += 1
                sub_stmts, sub_children = parse_block()
                children.append((header, sub_stmts, sub_children))
                # consume optional trailing semicolon after '}'
                while idx < n and text[idx].isspace():
                    idx += 1
                if idx < n and text[idx] == ";":
                    idx += 1
            elif ch == "}":
                tail = "".join(buf).strip()
                if tail:
                    stmts.append(tail)
                idx += 1
                return stmts, children
            elif ch == ";":
                stmt = "".join(buf).strip()
                if stmt:
                    stmts.append(stmt)
                buf = []
                idx += 1
            else:
                buf.append(ch)
                idx += 1
        return stmts, children

    return parse_block()

_, root_children = parse_dts_nodes(dts_clean)

def find_nodes(children, pattern):
    rx = re.compile(pattern)
    found = []
    for hdr, stmts, sub in children:
        if rx.search(hdr):
            found.append((hdr, stmts, sub))
        found.extend(find_nodes(sub, pattern))
    return found

def has_stmt(stmts, pattern):
    rx = re.compile(pattern)
    return any(rx.search(s) for s in stmts)

# 1. compatible includes "viettel,nr3053"
root_nodes = [n for n in root_children if n[0] == "/"]
if not root_nodes:
    raise SystemExit("FAIL: DTS root '/' node not found")
if not has_stmt(root_nodes[0][1], r'^compatible\s*=.*"viettel,nr3053"'):
    raise SystemExit('FAIL: DTS root compatible does not include "viettel,nr3053"')

# 2. chosen contains rootdisk = <&ubi_fit_volume>
chosen_nodes = find_nodes(root_children, r'^chosen$')
if not chosen_nodes or not has_stmt(chosen_nodes[0][1], r'^rootdisk\s*=\s*<&ubi_fit_volume>$'):
    raise SystemExit("FAIL: DTS chosen node missing 'rootdisk = <&ubi_fit_volume>;'")

# 3. partitions layout
partitions_nodes = find_nodes(root_children, r'^partitions$')
if not partitions_nodes:
    raise SystemExit("FAIL: DTS partitions node not found")
part_children = partitions_nodes[0][2]

def get_part(name):
    for hdr, stmts, sub in part_children:
        if hdr == name or hdr.endswith(f" {name}"):
            return stmts, sub
    raise SystemExit(f"FAIL: DTS missing {name}")

expected_ro = [
    ("partition@0", "BL2", 0x0, 0x100000),
    ("partition@100000", "u-boot-env", 0x100000, 0x100000),
    ("partition@200000", "Factory", 0x200000, 0x200000),
    ("partition@400000", "FIP", 0x400000, 0x200000),
]

def parse_reg(stmts):
    for s in stmts:
        m = re.match(r'^reg\s*=\s*<\s*(0x[0-9a-fA-F]+|[0-9]+)\s+(0x[0-9a-fA-F]+|[0-9]+)\s*>$', s)
        if m:
            return int(m.group(1), 0), int(m.group(2), 0)
    return None

for node_name, label, exp_off, exp_size in expected_ro:
    stmts, sub = get_part(node_name)
    if not has_stmt(stmts, rf'^label\s*=\s*"{re.escape(label)}"$'):
        raise SystemExit(f'FAIL: {node_name} missing label = "{label}"')
    reg = parse_reg(stmts)
    if reg != (exp_off, exp_size):
        raise SystemExit(f"FAIL: {node_name} reg={reg}, expected {(hex(exp_off), hex(exp_size))}")
    if not has_stmt(stmts, r'^read-only$'):
        raise SystemExit(f"FAIL: {node_name} ({label}) MUST have 'read-only;'")

    if node_name == "partition@200000":
        for nv_name, nv_reg in [
            ("eeprom@0", (0x0, 0x5000)),
            ("macaddr@4", (0x4, 0x6)),
            ("macaddr@a", (0xA, 0x6)),
        ]:
            matches = find_nodes(sub, rf'(?:^|:\s*){re.escape(nv_name)}$')
            if not matches or parse_reg(matches[0][1]) != nv_reg:
                raise SystemExit(f"FAIL: Factory missing {nv_name} with reg <{hex(nv_reg[0])} {hex(nv_reg[1])}>")

ubi_stmts, ubi_sub = get_part("partition@600000")
if not has_stmt(ubi_stmts, r'^label\s*=\s*"ubi"$'):
    raise SystemExit('FAIL: partition@600000 missing label = "ubi"')
ubi_reg = parse_reg(ubi_stmts)
if ubi_reg != (0x600000, 0xEA00000):
    raise SystemExit(f"FAIL: partition@600000 reg={ubi_reg}, expected (0x600000, 0xea00000)")
if ubi_reg[0] + ubi_reg[1] != 0xF000000:
    raise SystemExit("FAIL: UBI partition exceeds 0xf000000 NMBM boundary")
if has_stmt(ubi_stmts, r'^read-only$'):
    raise SystemExit("FAIL: partition@600000 (ubi) must NOT have 'read-only;'")

fit_vols = find_nodes(ubi_sub, r'\bubi_fit_volume\b')
if not fit_vols or not has_stmt(fit_vols[0][1], r'^volname\s*=\s*"fit"$'):
    raise SystemExit('FAIL: DTS missing ubi_fit_volume with volname = "fit";')

# --- platform.sh parser ---
with open(platform_path, "r", encoding="utf-8") as fh:
    plat_text = fh.read()

def extract_shell_fn(text, fn_name):
    m = re.search(rf'^{fn_name}\s*\(\)\s*\{{(.*?)^\}}', text, flags=re.M | re.S)
    if not m:
        raise SystemExit(f"FAIL: Function {fn_name}() not found in {platform_path}")
    return m.group(1)

def check_board_arm(fn_body, fn_name, expected_call):
    # Find case arm containing viettel,nr3053 and check it executes expected_call
    arm_rx = re.compile(r'([^\n]*viettel,nr3053[^\n]*\).*?;;)', flags=re.S)
    # Search across multi-line case patterns ending in ')' up to ';;'
    arms = re.findall(r'(?:^|\n)([ \t]*[a-zA-Z0-9_,|\\\n\t*-]+\)\s*.*?;;)', fn_body, flags=re.S)
    for arm in arms:
        if "viettel,nr3053" in arm:
            if expected_call in arm:
                return
            raise SystemExit(f"FAIL: {fn_name}() viettel,nr3053 arm missing {expected_call}")
    raise SystemExit(f"FAIL: viettel,nr3053 not handled in {fn_name}()")

check_board_arm(extract_shell_fn(plat_text, "platform_do_upgrade"), "platform_do_upgrade", "fit_do_upgrade")
check_board_arm(extract_shell_fn(plat_text, "platform_check_image"), "platform_check_image", "fit_check_image")

# --- filogic.mk Device/viettel_nr3053 parser ---
with open(mk_path, "r", encoding="utf-8") as fh:
    mk_text = fh.read()

dev_m = re.search(r'^define Device/viettel_nr3053\n(.*?)^endef', mk_text, flags=re.M | re.S)
if not dev_m:
    raise SystemExit(f"FAIL: define Device/viettel_nr3053 not found in {mk_path}")
dev_block = dev_m.group(1)

img_m = re.search(r'^\s*IMAGE_SIZE\s*:=\s*([0-9]+)k\s*$', dev_block, flags=re.M)
if not img_m or int(img_m.group(1)) != 229376:
    raise SystemExit("FAIL: Device/viettel_nr3053 must set IMAGE_SIZE := 229376k")
if int(img_m.group(1)) * 1024 > 0xEA00000:
    raise SystemExit("FAIL: IMAGE_SIZE exceeds UBI partition ceiling 0xea00000")

if not re.search(r'^\s*KERNEL_IN_UBI\s*:=\s*1\s*$', dev_block, flags=re.M):
    raise SystemExit("FAIL: Device/viettel_nr3053 missing KERNEL_IN_UBI := 1")
if not re.search(r'^\s*IMAGES\s*:=\s*sysupgrade\.itb\s*$', dev_block, flags=re.M):
    raise SystemExit("FAIL: Device/viettel_nr3053 missing IMAGES := sysupgrade.itb")

for line in dev_block.splitlines():
    if re.match(r'^\s*ARTIFACTS\s*[:+?]?=', line):
        if "preloader.bin" in line or "bl31-uboot.fip" in line:
            raise SystemExit(f"FAIL: Device/viettel_nr3053 must not package bootloader in ARTIFACTS: {line}")

pkg_m = re.search(r'^\s*DEVICE_PACKAGES\s*:=\s*(.+)$', dev_block, flags=re.M)
if not pkg_m:
    raise SystemExit("FAIL: Device/viettel_nr3053 missing DEVICE_PACKAGES")
pkgs = pkg_m.group(1).split()
for req_pkg in [
    "kmod-mt7915e",
    "kmod-mt7981-firmware",
    "mt7981-wo-firmware",
    "-default-settings",
    "-default-settings-chn",
]:
    if req_pkg not in pkgs:
        raise SystemExit(f"FAIL: Device/viettel_nr3053 DEVICE_PACKAGES missing '{req_pkg}'")
PY

	echo "PASS: NR3053 hardware brick-safety static gate passed"
}

run_post_build() {
	local dist_dir="$1"
	[ -d "$dist_dir" ] || die "Distribution directory not found: $dist_dir"
	dist_dir="$(cd "$dist_dir" && pwd)"

	# Zero bootloader binaries inside firmware dist_dir
	local bl_leaks
	bl_leaks="$(find "$dist_dir" -type f \( -name '*.fip' -o -name '*preloader.bin' \))"
	if [ -n "$bl_leaks" ]; then
		die "Bootloader binary leaked into firmware artifact directory:\n$bl_leaks"
	fi

	# Config check
	[ -f "$dist_dir/config.buildinfo" ] || die "Missing $dist_dir/config.buildinfo"
	run_check_config "$dist_dir/config.buildinfo"

	# Checksum check
	[ -f "$dist_dir/sha256sums" ] || die "Missing $dist_dir/sha256sums"
	(cd "$dist_dir" && sha256sum -c sha256sums) || die "sha256sums verification failed in $dist_dir"

	python3 - "$dist_dir" <<'PY'
import glob
import json
import os
import re
import sys

dist_dir = sys.argv[1]

rec_files = sorted(glob.glob(os.path.join(dist_dir, "*viettel_nr3053*initramfs-recovery.itb")))
sys_files = sorted(glob.glob(os.path.join(dist_dir, "*viettel_nr3053*squashfs-sysupgrade.itb")))
manifest_files = sorted(glob.glob(os.path.join(dist_dir, "*.manifest")))

if len(rec_files) != 1:
    raise SystemExit(f"FAIL: Expected 1 initramfs-recovery.itb, found {len(rec_files)}")
if len(sys_files) != 1:
    raise SystemExit(f"FAIL: Expected 1 squashfs-sysupgrade.itb, found {len(sys_files)}")
if len(manifest_files) < 1:
    raise SystemExit("FAIL: Expected at least one *.manifest file in dist_dir")

rec_size = os.path.getsize(rec_files[0])
sys_size = os.path.getsize(sys_files[0])

if not (4194304 < rec_size < 67108864):
    raise SystemExit(f"FAIL: initramfs-recovery.itb size out of bounds: {rec_size}")
if not (4194304 < sys_size <= 229376 * 1024):
    raise SystemExit(f"FAIL: squashfs-sysupgrade.itb size out of bounds: {sys_size}")

# Check manifest files
valid_manifest = False
for mf in manifest_files:
    with open(mf, "r", encoding="utf-8", errors="replace") as fh:
        lines = [line.rstrip("\r\n") for line in fh]
    if len(lines) < 50:
        raise SystemExit(f"FAIL: Manifest {mf} has too few entries ({len(lines)} < 50)")
    pkg_names = {line.split()[0] for line in lines if line.strip()}
    for req in ("fitblk", "kmod-mt7915e", "mt7981-wo-firmware", "wpad-openssl"):
        if req not in pkg_names:
            raise SystemExit(f"FAIL: Manifest {mf} missing required package '{req}'")
    for bad in ("default-settings", "default-settings-chn"):
        if bad in pkg_names:
            raise SystemExit(f"FAIL: Manifest {mf} contains forbidden package '{bad}'")
    valid_manifest = True

if not valid_manifest:
    raise SystemExit("FAIL: No valid manifest verified")

# Inspect trailing fwtool JSON metadata of squashfs-sysupgrade.itb
with open(sys_files[0], "rb") as fh:
    fh.seek(0, os.SEEK_END)
    fsize = fh.tell()
    fh.seek(max(0, fsize - 4096), os.SEEK_SET)
    tail = fh.read()

tail_text = tail.decode("utf-8", errors="ignore")
decoder = json.JSONDecoder()
meta = None
for m in re.finditer(r"\{", tail_text):
    try:
        obj, _ = decoder.raw_decode(tail_text, m.start())
    except json.JSONDecodeError:
        continue
    if isinstance(obj, dict) and "metadata_version" in obj:
        meta = obj

if meta is None:
    raise SystemExit(f"FAIL: Could not find fwtool JSON metadata in {sys_files[0]}")

supported = meta.get("supported_devices") or []
for dev in ("viettel,nr3053", "sdmc,nr3053"):
    if dev not in supported:
        raise SystemExit(
            f"FAIL: fwtool supported_devices missing '{dev}': {supported!r}"
        )

revision = ((meta.get("version") or {}).get("revision")) or ""
if re.match(r"^r0-[0-9a-f]+$", revision):
    raise SystemExit(f"FAIL: Shallow-clone revision rejected: {revision!r}")
if not re.match(r"^r([1-9][0-9]*|0\+[1-9][0-9]*)-[0-9a-f]{7,40}$", revision):
    raise SystemExit(f"FAIL: Invalid version.revision format: {revision!r}")

print(
    f"PASS: Post-build verification passed ({os.path.basename(sys_files[0])}, revision={revision})"
)
PY
}

case "$MODE" in
pre-build)
	run_pre_build
	;;
check-config)
	run_check_config "$MODE_ARG"
	;;
post-build)
	run_post_build "$MODE_ARG"
	;;
esac
