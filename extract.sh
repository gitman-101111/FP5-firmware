#!/usr/bin/env nix-shell
#!nix-shell -i bash -p unzip mtools e2fsprogs android-tools
#
# Extract the Fairphone 5 firmware blobs out of a stock factory image zip.
#
# Everything here runs in userspace: nothing is mounted, no loop device is
# claimed, no device-mapper table is created, and sudo is never invoked. That
# is a deliberate departure from how this used to work. The old approach needed
# root for mount/losetup/dmsetup and leaned on `parse-android-dynparts`, which
# is not packaged in nixpkgs, so the script could not run to completion on this
# machine at all. The replacements:
#
#   FAT images   (NON-HLOS.bin, BTFM.bin)  -> mtools
#   ext4 images  (dspso.bin, vendor_a)     -> debugfs, from e2fsprogs
#   super.img    (dynamic partitions)      -> simg2img + lpunpack, android-tools
#
# The nix-shell shebang above pins those four tools, so the script brings its
# own dependencies rather than assuming the host has them.
#
# Needs roughly 15GB of scratch space: super.img and its desparsified copy are
# ~6GB each. Scratch goes wherever mktemp points, so set TMPDIR if /tmp is
# small or on tmpfs.
#
# Usage: ./extract.sh <path-to-factory-image.zip>
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <path-to-factory-image.zip>" >&2
    exit 1
fi

zip=$(realpath "$1")
[ -r "$zip" ] || { echo "Cannot read '$zip'." >&2; exit 1; }

out=$(pwd)
tmpdir=$(mktemp -d)

# Only our own scratch directory needs cleaning up now. The previous version
# unmounted, removed dm tables and detached a loop device here, all under sudo,
# all of which failed noisily when the script died before setting them up.
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# These images declare 4096 byte sectors, which does not match what mtools
# considers a plausible disk geometry; without this it refuses to read them.
export MTOOLS_SKIP_CHECK=1

# <image> <source glob inside image> <destination directory>
fat_copy() {
    mcopy -i "$1" -s -n "$2" "$3"
}

# <image> <path inside image> <destination directory>
ext_rdump() {
    debugfs -R "rdump \"$2\" \"$3\"" "$1" 2>/dev/null
}

# <description> <path that must exist>
require() {
    if [ ! -e "$2" ]; then
        echo "ERROR: expected $1 at '$2', which is missing." >&2
        echo "       The factory image layout may have changed." >&2
        exit 1
    fi
}

echo "==> unpacking images from $(basename "$zip")"
unzip -o -j -d "$tmpdir" "$zip" \
    '*/images/BTFM.bin' \
    '*/images/dspso.bin' \
    '*/images/NON-HLOS.bin' \
    '*/images/super.img'

for img in BTFM.bin dspso.bin NON-HLOS.bin super.img; do
    require "$img" "$tmpdir/$img"
done

# mkdir -p, not mkdir: this script is expected to be re-run over an existing
# checkout to refresh the blobs, and plain mkdir aborted the whole run under
# `set -e` the moment hexagonfs/ already existed.
mkdir -p "$out"/hexagonfs/dsp "$out"/hexagonfs/sensors

### NON-HLOS.bin ###
echo "==> NON-HLOS.bin (modem, adsp, cdsp, wpss)"
fat_copy "$tmpdir/NON-HLOS.bin" '::/image/adsp*'       "$out"
fat_copy "$tmpdir/NON-HLOS.bin" '::/image/battmgr.jsn' "$out"
fat_copy "$tmpdir/NON-HLOS.bin" '::/image/cdsp*'       "$out"
fat_copy "$tmpdir/NON-HLOS.bin" '::/image/modem*'      "$out"
fat_copy "$tmpdir/NON-HLOS.bin" '::/image/wpss*'       "$out"

### BTFM.bin ###
echo "==> BTFM.bin (bluetooth)"
fat_copy "$tmpdir/BTFM.bin" '::/image/msbtfw11.mbn' "$out"
fat_copy "$tmpdir/BTFM.bin" '::/image/msnv11.bin'   "$out"

### dspso.bin ###
echo "==> dspso.bin (hexagonfs dsp)"
ext_rdump "$tmpdir/dspso.bin" /adsp "$out/hexagonfs/dsp"
ext_rdump "$tmpdir/dspso.bin" /cdsp "$out/hexagonfs/dsp"
require "hexagonfs dsp payload" "$out/hexagonfs/dsp/adsp"

### super.img ###
echo "==> super.img: sparse -> raw"
simg2img "$tmpdir/super.img" "$tmpdir/super.raw.img"
rm -f "$tmpdir/super.img"

echo "==> super.img: unpacking vendor_a"
# Replaces parse-android-dynparts + dmsetup: lpunpack understands the dynamic
# partition metadata directly and writes the logical partition out as a file.
lpunpack --partition=vendor_a "$tmpdir/super.raw.img" "$tmpdir"
rm -f "$tmpdir/super.raw.img"

vendor="$tmpdir/vendor_a.img"
require "unpacked vendor_a" "$vendor"

echo "==> vendor_a: firmware blobs"
# debugfs cannot glob, so pull /firmware wholesale and pick from it with the
# shell afterwards.
mkdir -p "$tmpdir/vendor-firmware"
ext_rdump "$vendor" /firmware "$tmpdir/vendor-firmware"
fw="$tmpdir/vendor-firmware/firmware"
require "vendor firmware directory" "$fw"

cp -t "$out" \
    "$fw"/a660_zap.b* \
    "$fw"/a660_zap.mdt \
    "$fw"/aw882xx_acf.bin \
    "$fw"/yupik_ipa_fws.* \
    "$fw"/vpu20_1v.mbn

echo "==> vendor_a: hexagonfs acdb and sensor config"
mkdir -p "$tmpdir/vendor-etc"
ext_rdump "$vendor" /etc/acdbdata "$tmpdir/vendor-etc"
require "acdbdata" "$tmpdir/vendor-etc/acdbdata"
rm -rf "$out/hexagonfs/acdb"
mv "$tmpdir/vendor-etc/acdbdata" "$out/hexagonfs/acdb"

ext_rdump "$vendor" /etc/sensors "$tmpdir/vendor-etc"
require "sensor config" "$tmpdir/vendor-etc/sensors/config"
rm -rf "$out/hexagonfs/sensors/config"
mv "$tmpdir/vendor-etc/sensors/config" "$out/hexagonfs/sensors/config"
cp "$tmpdir/vendor-etc/sensors/sns_reg_config" "$out/hexagonfs/sensors/sns_reg.conf"

# Sensor registry for hexagonfs is extracted from persist partition which is
# not shipped with the factory image.
# cp -r /mnt/persist/sensors/registry/registry hexagonfs/sensors/registry

# Socinfo files are extracted from the running device with stock Android.
# for i in hw_platform platform_subtype platform_subtype_id platform_version revision soc_id; do adb shell cat /sys/devices/soc0/$i > hexagonfs/socinfo/$i; done

echo ""
echo "==> done."
echo "    hexagonfs/sensors/registry and hexagonfs/socinfo are NOT refreshed by"
echo "    this script; they come off a running device (see the notes above)."

# cleanup happens on exit with the signal handler at the top
