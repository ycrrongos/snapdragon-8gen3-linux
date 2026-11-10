#!/bin/bash
set -euo pipefail
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$base/../.." && pwd)
sdk=/home/rong/Android/Sdk
bt=$sdk/build-tools/35.0.0
out=$root/build/camera-20261110/android-reference-apk
mkdir -p "$out/classes" "$out/dex"
"$bt/aapt2" link --manifest "$base/AndroidManifest.xml" -I "$sdk/platforms/android-35/android.jar" -o "$out/reference-unsigned.apk"
javac -source 11 -target 11 -classpath "$sdk/platforms/android-35/android.jar" -d "$out/classes" "$base/src/org/cerro/cameraref/MainActivity.java"
mapfile -t classes < <(rg --files "$out/classes" -g '*.class')
"$bt/d8" --lib "$sdk/platforms/android-35/android.jar" --min-api 28 --output "$out/dex" "${classes[@]}"
(cd "$out/dex" && zip -q "$out/reference-unsigned.apk" classes.dex)
"$bt/zipalign" -f 4 "$out/reference-unsigned.apk" "$out/reference-aligned.apk"
if [[ ! -e $out/debug.keystore ]]; then
 keytool -genkeypair -noprompt -keystore "$out/debug.keystore" -storepass android -keypass android -alias debug -dname 'CN=Cerro Camera Reference' -keyalg RSA -keysize 2048 -validity 3650
fi
"$bt/apksigner" sign --ks "$out/debug.keystore" --ks-key-alias debug --ks-pass pass:android --out "$out/cerro-camera-reference.apk" "$out/reference-aligned.apk"
"$bt/apksigner" verify "$out/cerro-camera-reference.apk"
sha256sum "$out/cerro-camera-reference.apk"
