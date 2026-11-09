#!/bin/sh
# SPEC: LAYER-07
# F12 现场跑：在连着 adb 的设备上循环「请求暂停 → 读播放器状态」，结果直接进样本文件。
# 前提：这台机器有 adb；设备已授权；内容正在播放（先在电视/手机上放一片）。
# 用法：tools/f12-adb-probe.sh "<机型名>" [stock|third-party] [次数=20] ["--android=14"]
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

model=${1:?用法：f12-adb-probe.sh "<机型名>" [stock|third-party] [次数=20] [--android=14]}
player=${2:-stock}
n=${3:-20}
extra=${4:-}

command -v adb >/dev/null || { echo "FAIL 这台机器没有 adb；装 platform-tools 后再跑"; exit 2; }
state() { adb shell dumpsys media_session 2>/dev/null | grep -m1 -oE 'state=PlaybackState \{state=[0-9]+' | cut -d= -f3; }

before=$(state)
if [ "${before:-}" != "3" ]; then
  echo "FAIL 当前不是播放态（state=${before:-读不到}）。先让内容播起来再跑。"
  exit 2
fi

trials=
i=0
while [ "$i" -lt "$n" ]; do
  i=$((i + 1))
  adb shell input keyevent 121 >/dev/null 2>&1 || adb shell media dispatch pause >/dev/null
  sleep 1.5
  after=$(state)
  if [ "${after:-}" = "2" ]; then t=1; else t=0; fi
  trials="${trials}${trials:+,}$t"
  printf '  %2d/%s 暂停后 state=%s → %s\n' "$i" "$n" "${after:-无}" "$([ "$t" = 1 ] && echo 停了 || echo 没停)"
  adb shell input keyevent 126 >/dev/null 2>&1 || adb shell media dispatch play >/dev/null
  sleep 1.5
done

exec ruby "$root/tools/probe-record.rb" --fact=f12 --device="$model" --player="$player" \
  --source=adb --trials="$trials" $extra
