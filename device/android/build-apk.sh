#!/bin/sh
# 不用 Gradle 打这个 APK：aapt2 编译链接 → javac → d8 → 打包 → 签名。
# 为什么要这条路径：本机当时装不动 Gradle（也没有 Android Studio），而 M3 需要一个能装的界面
# 才谈得上遥控器按键与焦点（facts/DEVICES.md#F16）。产物 device/out/youban-tv.apk。
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sdk=${ANDROID_HOME:-$HOME/android-sdk}
out="$root/out"
work="$out/work"
build_tools=$(ls -1 "$sdk"/build-tools 2>/dev/null | sort | tail -1)
platform=$(ls -1 "$sdk"/platforms 2>/dev/null | sort | tail -1)
[ -n "$build_tools" ] || { echo "缺 build-tools：sdkmanager --install 'build-tools;34.0.0'"; exit 1; }
[ -n "$platform" ] || { echo "缺平台 android.jar：sdkmanager --install 'platforms;android-34'"; exit 1; }
bt="$sdk/build-tools/$build_tools"
jar="$sdk/platforms/$platform/android.jar"
echo "SDK：build-tools $build_tools · $platform"

rm -rf "$work" && mkdir -p "$work/obj" "$work/res" "$work/apk"
"$bt/aapt2" compile --dir "$root/app/src/main/res" -o "$work/res.zip"
"$bt/aapt2" link -o "$work/base.apk" -I "$jar" --manifest "$root/app/src/main/AndroidManifest.xml" "$work/res.zip" \
  --auto-add-overlay
javac -source 8 -target 8 -bootclasspath "$jar" -d "$work/obj" \
  -proc:none $(find "$root/app/src/main/java" -name '*.java') 2>/dev/null
"$bt/d8" --lib "$jar" --min-api 19 --output "$work/apk" $(find "$work/obj" -name '*.class')
cd "$work/apk" && "$bt/zip" -q -j "$work/with-dex.apk" classes.dex
cp "$work/base.apk" "$work/app.apk"
cd "$work" && "$bt/zip" -q -j app.apk apk/classes.dex
# 自签名：这台设备装的是自己造的包，测试用的 debug keystore 就地生成，不入库。
ks="$out/youban-debug.keystore"
[ -f "$ks" ] || keytool -genkeypair -keystore "$ks" -alias youban -storepass youban -keypass youban \
  -keyalg RSA -keysize 2048 -validity 3650 -dname "CN=youban-test" >/dev/null 2>&1
"$bt/zipalign" -f 4 app.apk aligned.apk
"$bt/apksigner" sign --ks "$ks" --ks-pass pass:youban --key-pass pass:youban --out "$out/youban-tv.apk" aligned.apk
"$bt/apksigner" verify --print-certs "$out/youban-tv.apk" | head -2
ls -la "$out/youban-tv.apk" | awk '{printf "APK %.2f MB\n", $5/1048576}'
