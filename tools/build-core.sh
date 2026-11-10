#!/bin/sh
# 编译 Kotlin 内核（M2）。不用 Gradle：直接 kotlinc。
# kotlinc 从 GitHub releases 的 kotlin-compiler-1.9.24.zip 解出来用（Maven 上那个裸
# kotlin-compiler.jar 缺 intellij 依赖，跑不起来——踩过）。可用 KOTLINC= 指定。
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$root/core/build/classes"
kotlinc=${KOTLINC:-$(command -v kotlinc || echo /tmp/kotlinc/bin/kotlinc)}
[ -x "$kotlinc" ] || { echo "找不到 kotlinc：解压 kotlin-compiler-1.9.24.zip 后 KOTLINC=/path/to/kotlinc 再跑"; exit 1; }
mkdir -p "$out"
# -jvm-target 1.8：这份字节码要能被 d8 打进 APK，在 Android 9 上跑。
"$kotlinc" -nowarn -jvm-target 1.8 -d "$out" "$root/core/src/main/kotlin"
n=$(find "$out" -name '*.class' | wc -l | tr -d ' ')
echo "Kotlin 内核编译完成：$n 个 class → core/build/classes"
