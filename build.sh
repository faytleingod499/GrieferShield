#!/bin/bash
# Makes the two zips from package/ (rebuild package/GrieferShield/GrieferShield.pck first with pack.gd, see the README):
#   out/GrieferShield-mod.zip         the GrieferShield folder to drop into GDWeave/mods
#   out/GrieferShield-<version>.zip   the Thunderstore upload
set -e
cd "$(dirname "$0")"
mkdir -p out
V=$(python3 -c "import json;print(json.load(open('thunderstore/manifest.json'))['version_number'])")
rm -f out/GrieferShield-mod.zip out/GrieferShield-$V.zip
(cd package && zip -qr ../out/GrieferShield-mod.zip GrieferShield)
T=$(mktemp -d)
cp thunderstore/manifest.json thunderstore/README.md thunderstore/CHANGELOG.md thunderstore/icon.png $T/
cp LICENSE $T/
mkdir -p $T/GDWeave/mods/GrieferShield
cp package/GrieferShield/manifest.json package/GrieferShield/GrieferShield.pck $T/GDWeave/mods/GrieferShield/
(cd $T && zip -qr - .) > out/GrieferShield-$V.zip
rm -rf $T
echo "out/GrieferShield-mod.zip"
echo "out/GrieferShield-$V.zip"
