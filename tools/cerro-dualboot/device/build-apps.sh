#!/usr/bin/env bash
# Build only: never adb install, launch, su, flash, or contact a phone.
set -euo pipefail
base=$(cd -- "$(dirname -- "$0")" && pwd)
root=$(cd -- "$base/../../.." && pwd)
app="$root/tools/cerro-dualboot/android/CerroSwitch"
sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}
bt="$sdk/build-tools/${ANDROID_BUILD_TOOLS:-35.0.0}"
jar="$sdk/platforms/${ANDROID_PLATFORM:-android-35}/android.jar"
out="$root/build/system-switch-apps"
mkdir -p "$out/classes" "$out/dex" "$out/assets"
cp "$base/switch-backend.sh" "$out/assets/switch-backend.sh"
"$bt/aapt2" link --manifest "$app/AndroidManifest.xml" -I "$jar" -A "$out/assets" -o "$out/unsigned.apk"
mapfile -t sources < <(find "$app/src" -name '*.java' -type f | sort)
javac -source 11 -target 11 -classpath "$jar" -d "$out/classes" "${sources[@]}"
mapfile -t classes < <(find "$out/classes" -name '*.class' -type f | sort)
"$bt/d8" --lib "$jar" --min-api 29 --output "$out/dex" "${classes[@]}"
(cd "$out/dex" && zip -q "$out/unsigned.apk" classes.dex)
"$bt/zipalign" -f 4 "$out/unsigned.apk" "$out/aligned.apk"
key=${CERRO_SWITCH_KEYSTORE:-$out/local-development.keystore}
if [[ ! -e "$key" ]]; then
 keytool -genkeypair -noprompt -keystore "$key" -storepass android -keypass android \
  -alias switch -dname 'CN=Cerro System Switch Local Development' -keyalg RSA -keysize 2048 -validity 3650
fi
"$bt/apksigner" sign --ks "$key" --ks-key-alias switch --ks-pass pass:android \
 --out "$out/cerro-system-switch-android-v2.apk" "$out/aligned.apk"
"$bt/apksigner" verify --verbose "$out/cerro-system-switch-android-v2.apk" > "$out/signature-verification.txt"
package="$out/cerro-system-switch-linux-v2"
mkdir -p "$package/linux"
cp "$base/switch-backend.sh" "$base/import-host-state.py" "$base/install-linux.sh" "$base/README.md" "$package/"
cp "$base/linux/system-switch.py" "$base/linux/org.cerro.SystemSwitch.desktop" "$base/linux/org.cerro.same-slot-switch.policy" "$package/linux/"
tar -czf "$out/cerro-system-switch-linux-v2.tar.gz" -C "$out" "$(basename "$package")"
(cd "$out" && sha256sum cerro-system-switch-android-v2.apk cerro-system-switch-linux-v2.tar.gz > SHA256SUMS)
cat "$out/SHA256SUMS"
printf '%s\n' 'Built APK and Linux installer archive only. No application or partition test performed.'
