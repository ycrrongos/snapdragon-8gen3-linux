#!/usr/bin/env bash
# Host compile/sign only; no device contact. Local development signing only.
set -euo pipefail
base=$(cd -- "$(dirname -- "$0")" && pwd)
root=$(cd -- "$base/../../.." && pwd)
sdk=${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}
bt="$sdk/build-tools/35.0.0"
jar="$sdk/platforms/android-35/android.jar"
out="$root/build/waydroid-app-check"
mkdir -p "$out/classes" "$out/dex"
"$bt/aapt2" link --manifest "$base/AndroidManifest.xml" -I "$jar" -o "$out/unsigned.apk"
javac -source 11 -target 11 -classpath "$jar" -d "$out/classes" "$base/MainActivity.java"
mapfile -t classes < <(find "$out/classes" -name '*.class' -type f)
"$bt/d8" --lib "$jar" --min-api 29 --output "$out/dex" "${classes[@]}"
(cd "$out/dex" && zip -q "$out/unsigned.apk" classes.dex)
"$bt/zipalign" -f 4 "$out/unsigned.apk" "$out/aligned.apk"
key="$out/local-development.keystore"
if [[ ! -e "$key" ]]; then
 keytool -genkeypair -noprompt -keystore "$key" -storepass android -keypass android -alias check -dname 'CN=Cerro Local Test Only' -keyalg RSA -keysize 2048 -validity 3650
fi
"$bt/apksigner" sign --ks "$key" --ks-key-alias check --ks-pass pass:android --out "$out/check.apk" "$out/aligned.apk"
"$bt/apksigner" verify "$out/check.apk"
printf '%s\n' "$out/check.apk"
