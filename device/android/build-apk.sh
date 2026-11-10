#!/bin/sh
# 不用 Gradle 打这个 APK：aapt2 编译链接 → javac → d8 → 打包 → 签名。
# 为什么要这条路径：本机当时装不动 Gradle（也没有 Android Studio），而 M3 需要一个能装的界面
# 才谈得上遥控器按键与焦点（facts/DEVICES.md#F16）。产物 device/out/youban-tv.apk。
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sdk=${ANDROID_HOME:-$HOME/android-sdk}
out="$root/out"
work="$out/work"
# 版本按「装了哪个用哪个」挑最高的，并且把选到的打出来：这台机器上 SDK 装在 ~/android-sdk
# （不是 ~/Library/Android/sdk——之前在那儿找了半天没找到，白说了一晚「装不动 SDK」）。
build_tools=$(ls -1 "$sdk"/build-tools 2>/dev/null | sort -V | tail -1)
platform=$(ls -1 "$sdk"/platforms 2>/dev/null | sort -V | tail -1)
[ -n "$build_tools" ] || { echo "缺 build-tools：sdkmanager --install 'build-tools;34.0.0'"; exit 1; }
[ -n "$platform" ] || { echo "缺平台 android.jar：sdkmanager --install 'platforms;android-34'"; exit 1; }
[ -f "$sdk/build-tools/$build_tools/aapt2" ] || { echo "build-tools/$build_tools 里没有 aapt2，换一个"; exit 1; }
bt="$sdk/build-tools/$build_tools"
jar="$sdk/platforms/$platform/android.jar"
echo "SDK：build-tools $build_tools · $platform"

rm -rf "$work" && mkdir -p "$work/obj" "$work/res" "$work/apk" "$work/gen" "$root/app/src/main/assets"
# 契约每次打包重新拷一份：留着手拷的那份会在改了契约之后悄悄带着旧表上设备，
# 于是设备与 Mac 两边用两份契约——align 绿、设备红，最难查的那种（F19）。
cp "$root/../../contract/contract.json" "$root/app/src/main/assets/contract.json"
"$bt/aapt2" compile --dir "$root/app/src/main/res" -o "$work/res.zip"
# --java 这一步不能省：R.java 由 aapt2 生成，javac 才有 R.layout.status 这些符号可引。
# aapt2 link 没有 --assets 这个选项（试过了：它只吃 --manifest/--java/--auto-add-overlay 这些），
# Gradle 会自己把 assets 塞进去，我们不用 Gradle，就得自己压——漏了它这台电视上就是方块（F17）。
"$bt/aapt2" link -o "$work/base.apk" -I "$jar" --manifest "$root/app/src/main/AndroidManifest.xml" \
  --java "$work/gen" --auto-add-overlay "$work/res.zip"
# -encoding UTF-8 不能省：不写就按平台默认编码读源文件，中文常量全变成同一个替换字符——
# 屏幕上就是一排排一模一样的字，看着像「设备画不出中文」，其实是编译期就毁了（F17）。
core="$root/../../core/build/classes"
stdlib=${KOTLIN_STDLIB:-}
if [ -z "$stdlib" ]; then
  for c in /tmp/kotlinc/lib/kotlin-stdlib.jar "$HOME/.cache/youban-kotlin/kotlin-stdlib.jar"; do
    [ -f "$c" ] && stdlib=$c && break
  done
fi
sh "$root/../../tools/build-core.sh"
[ -f "$stdlib" ] || { echo "缺 kotlin-stdlib.jar：KOTLIN_STDLIB= 指一下（解压 kotlin-compiler-1.9.24.zip 就有）"; exit 1; }
# javac 要能看见 Kotlin 内核的类（界面直接调 Kernel.state），所以 -cp 里带上内核与 stdlib。
javac -source 8 -target 8 -encoding UTF-8 -bootclasspath "$jar" -cp "$core:$stdlib" -d "$work/obj" -proc:none \
  $(find "$root/app/src/main/java" "$work/gen" -name '*.java')
# 内核带着走：屏幕上那句结论要设备自己算出来，不是别人算好推上来的文件（M3 最后一件）。
# 所以 Kotlin 内核和 kotlin-stdlib 要跟界面同一份 dex 里——kotlinc 编内核，d8 一起 dex。
[ -d "$core" ] || sh "$root/../../tools/build-core.sh"
[ -f "$stdlib" ] || { echo "缺 kotlin-stdlib.jar：KOTLIN_STDLIB= 指一下（解压 kotlin-compiler-1.9.24.zip 就有）"; exit 1; }
"$bt/d8" --lib "$jar" --min-api 19 --release --output "$work/apk" "$stdlib" \
  $(find "$work/obj" "$core" -name '*.class')
# build-tools 里没有 zip 这个可执行文件（别把 $bt/zip 当工具用），用系统的。
cp "$work/base.apk" "$work/app.apk"
(cd "$work/apk" && zip -q -j "$work/app.apk" *.dex)
# assets 只在需要随包带字体时才压进来。这台电视自带中文字形（F17），所以现在不带；
# 真要带的时候必须带路径前缀，并且**在设备上验**，本地 ImageMagick 出图不算数（F18）。
if [ -d "$root/app/src/main/assets" ]; then
  (cd "$root/app/src/main" && zip -q -r "$work/app.apk" assets)
fi
# 自签名：这台设备装的是自己造的包，测试用的 debug keystore 就地生成，不入库。
ks="$out/youban-debug.keystore"
[ -f "$ks" ] || keytool -genkeypair -keystore "$ks" -alias youban -storepass youban -keypass youban \
  -keyalg RSA -keysize 2048 -validity 3650 -dname "CN=youban-test" >/dev/null 2>&1
"$bt/zipalign" -f 4 "$work/app.apk" "$work/aligned.apk"
"$bt/apksigner" sign --ks "$ks" --ks-pass pass:youban --key-pass pass:youban --out "$out/youban-tv.apk" "$work/aligned.apk"
"$bt/apksigner" verify --print-certs "$out/youban-tv.apk" | head -2
ls -la "$out/youban-tv.apk" | awk '{printf "APK %.2f MB\n", $5/1048576}'
