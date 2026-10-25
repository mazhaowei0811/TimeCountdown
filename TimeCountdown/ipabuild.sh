#!/bin/bash
set -e

WORKING_LOCATION="$(pwd)"
APP_BUILD_FILES="$WORKING_LOCATION/layout/Applications/TimeCountdown.app"
BUILD_LOCATION="$WORKING_LOCATION/.theos/obj/TimeCountdown.app"

if [[ $* == *--clean* ]]; then
    echo "[*] Cleaning..."
    rm -rf build
    make clean || true
fi

mkdir -p build
rm -rf build/TimeCountdown.tipa build/Payload

if ! type "gmake" >/dev/null; then
    echo "[!] gmake not found, using bundled make"
    make clean || true
    make FINALPACKAGE=1
else
    gmake clean || true
    gmake -j"$(sysctl -n machdep.cpu.thread_count)" FINALPACKAGE=1
fi

if [ ! -d "$BUILD_LOCATION" ]; then
    echo "[!] 构建产物不存在: $BUILD_LOCATION"
    exit 1
fi

echo "Adding application files"
cp -f "$APP_BUILD_FILES/Info.plist" "$BUILD_LOCATION/Info.plist"
if [ -f "$APP_BUILD_FILES/icon.png" ]; then
    cp -f "$APP_BUILD_FILES/icon.png" "$BUILD_LOCATION/icon.png"
fi

echo "Creating payload"
cd build
mkdir -p Payload
cp -r "$BUILD_LOCATION" Payload/TimeCountdown.app

echo "Archiving"
zip -qr TimeCountdown.tipa Payload
rm -rf Payload

echo "== tipa contents =="
unzip -l TimeCountdown.tipa
