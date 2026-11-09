#!/usr/bin/env bash
# F12 实测：在这台设备上，「发暂停请求」能不能让内容真的停下来。见 docs/facts/PROBES.md。
#
# 判定只看一个东西：画面左上角 burned-in 的时间码有没有继续走。
# 不看会话状态：实测过 state=Paused 而画面照走的设备（F12 因此把两者分开记）。
#
# 用法：
#   ANDROID_SERIAL=<序列号> tools/f12-adb-probe.sh "<机型>" [stock|third-party] [次数] \
#       [--android=9] [--channel=keyevent|dispatch] [--clip=/sdcard/Download/f12-clock.mp4] \
#       [--launch='am start -n 包/活动 -d file://%s -t video/mp4'] [--stop=包名]
#
# 两道控制，跑不过就不写样本：
#   1 推进控制：起播后时间码必须在走（否则说明没在播，或截屏拿不到画面）。
#   2 静止控制：内容里本就静止的那块区域必须恒定（否则截屏不是干净像素，
#     「画面不变」就不能当作「停了」，整轮判定都不成立）。
set -eu
model=${1:?用法：ANDROID_SERIAL=<序列号> tools/f12-adb-probe.sh "<机型>" [stock|third-party] [次数] [选项]}
player=${2:-stock}
n=${3:-20}
shift 3 2>/dev/null || true
channel=keyevent android= clip=/sdcard/Download/f12-clock.mp4 tap= stop=
launch='am start -a android.intent.action.VIEW -d file://%s -t video/mp4'
# 裁切区域默认按全屏播放算（电视）。手机上有地址栏、视频被顶下去，必须显式给 rect，
# 形式为 WxHxXxY；裁错地方会把判定变成噪声（踩过）。
crop=iw*0.24:ih*0.13:iw*0.01:ih*0.01
static=iw*0.2:ih*0.12:iw*0.5:ih*0.5
for a in "$@"; do
  case "$a" in
    --channel=*) channel=${a#*=} ;;
    --android=*) android=${a#*=} ;;
    --clip=*) clip=${a#*=} ;;
    --launch=*) launch=${a#*=} ;;
    --stop=*) stop=${a#*=} ;;
    --tap=*) tap=${a#*=}; tap=${tap//,/ } ;;   # input tap 要两个参数，不是一个逗号串
    --crop=*) crop=$(printf '%s' "${a#*=}" | tr x :) ;;
    --static=*) static=$(printf '%s' "${a#*=}" | tr x :) ;;
  esac
done
command -v adb >/dev/null || { echo "FAIL 这台机器没有 adb；装 platform-tools 后再跑"; exit 2; }
command -v ffmpeg >/dev/null || { echo "FAIL 需要 ffmpeg 来裁剪截屏区域"; exit 2; }

adbx() { if [ "$channel" = dispatch ]; then adb shell media dispatch "$1" >/dev/null; else adb shell input keyevent "$2" >/dev/null; fi; }
# 换片段前先把承载 App 停掉：播放器已经在前台时，新的 VIEW 意图会被 onNewIntent 吞掉，
# 屏幕上还是上一个片段——控制项会因此假失败（踩过）。
open_clip() {
  [ -n "$stop" ] && adb shell am force-stop "$stop" >/dev/null 2>&1
  sleep 1
  adb shell "$(printf "$launch" "$1")" >/dev/null 2>&1
  sleep 8
}
# 部分 ROM 的 screencap 会把日志混进 stdout，先剥到 PNG 头。
shot() { adb exec-out screencap -p 2>/dev/null | python3 -c 'import sys;d=sys.stdin.buffer.read();sys.stdout.buffer.write(d[d.find(b"\x89PNG"):])'; }
# 只取左上角那块 burned-in 时间码。整屏哈希会被暂停浮层、进度条淡入淡出带偏——
# 曾把一次真暂停测成「没停」，所以不看整屏。
frame() { shot | region "$crop"; }
# 内容里本就静止的那块（背景是纯色）。它动了说明拿到的不是干净像素——浮层、菜单、
# 屏保都会把它拉出好几个级，那本轮的「停了」不可信。取平均亮度而不是逐像素哈希：电视的缩放/编码会偶发抖动，逐像素比会假报「截屏不可信」；
# 但浮层、菜单、屏保会把均值拉出好几个级，照样抓得住。
static_frame() {
  shot | ffmpeg -hide_banner -loglevel error -i - -vf "crop=$static,scale=1x1" \
    -f rawvideo -pix_fmt gray - 2>/dev/null | od -An -tu1 | tr -d ' \n'
}
delta() { a=$1; b=$2; echo $(( a > b ? a - b : b - a )); }
region() { ffmpeg -hide_banner -loglevel error -i - -vf "crop=$1" -f image2pipe -vcodec png - 2>/dev/null | shasum -a 1 | cut -c1-12; }
state() { adb shell dumpsys media_session 2>/dev/null | grep -m1 -oE 'PlaybackState \{state=([A-Z_]*\()?[0-9]+' | grep -oE '[0-9]+' | head -1; }
# 三帧两两不同才算「在推进」。曾经裁偏到只 cut 到时间码的字顶，偶尔变一下，
# 控制项照样「通过」，判定就不可信了 —— 所以这里要按帧率卡死。
advancing() { a=$(frame); sleep 1.2; b=$(frame); sleep 1.2; c=$(frame); [ "$a" != "$b" ] && [ "$b" != "$c" ] && [ "$a" != "$c" ]; }
# 恢复通路一条条试：暂停容易恢复难的播放器是实测里见过的（网页播放器就是这种）。
# 键序之后补一次点按——有些播放器只认中心点击。tap 不给时取屏幕中心。
screen_center() {
  adb shell wm size 2>/dev/null | grep -m1 -oE '[0-9]+x[0-9]+' |
    awk -Fx '{printf "%d %d", $1/2, $2/2}'
}
recover() {
  advancing && return 0
  adb shell input keyevent 126 >/dev/null 2>&1; sleep 1.5
  advancing && return 0
  adb shell input keyevent 85 >/dev/null 2>&1; sleep 1.5
  advancing && return 0
  adb shell input tap ${tap:-$(screen_center)} >/dev/null 2>&1; sleep 1.5
  advancing
}
ensure_playing() { recover; }

echo "控制 1/2：推进。$clip"
open_clip "$clip"
if ! ensure_playing; then
  echo "FAIL 时间码没在走：内容没在播，或截屏拿不到画面（DRM 会黑屏）。"
  echo "     拿不到画面就不算测过，不要用估计值填。"
  exit 2
fi
echo "  通过：时间码在走。"

# 控制 2：静止区域必须恒定。时间码区跟着解码帧走 + 静止区恒定，两者成立才说明
# 「画面在变」等价于「解码在推进」，反过来「画面不变」才等价于「真的停了」。
echo "控制 2/2：静止区域恒定。"
s1=$(static_frame); sleep 1.2; s2=$(static_frame)
if [ "$(delta "$s1" "$s2")" -gt 2 ]; then
  echo "FAIL 内容里本就静止的那块均值动了（${s1}→${s2}）—— 拿到的不是干净像素（浮层、菜单或屏保），"
  echo "     「画面不变」就不能当作「停了」。本次不写样本。"
  exit 2
fi
echo "  通过：静止区域恒定。"

trials=; ok=0; sessionpaused=0
open_clip "$clip"
ensure_playing || { echo "FAIL 主片段没能起播"; exit 2; }
echo "开始 $n 轮（通路 ${channel}）；画面为判据，会话状态只当旁证："
for i in $(seq 1 "$n"); do
  before=$(state)
  adbx pause 127
  sleep 1.2
  # 观察窗 2.4s：见过暂停在 1.2s 之后才落地的播放器，迟到的暂停也是真停了，
  # 但窗口记进样本，别把它当成 1.5s 内的响应。
  a=$(frame); s1=$(static_frame); sleep 1.2; b=$(frame); c=""; s2=$(static_frame)
  if [ "$a" != "$b" ]; then sleep 1.2; c=$(frame); s2=$(static_frame); fi
  if [ "$(delta "$s1" "$s2")" -gt 2 ]; then
    echo "FAIL 第 $i 轮静止区均值动了（${s1}→${s2}），截屏不可信，已中止（本轮不写入）。"
    exit 2
  fi
  after=$(state)
  # 会话报不报「已暂停」单独数一笔：实测见过报 state=2 而画面照走的设备，
  # 两个数不一致本身就是 F12 要的事实（D44）。
  [ "${after:-}" = "2" ] && sessionpaused=$((sessionpaused+1))
  if [ "$a" = "$b" ] || [ "$b" = "${c:-$a}" ]; then t=1; ok=$((ok+1)); else t=0; fi
  trials="${trials}${trials:+,}$t"
  printf '  %2d/%s 时间码 %s=%s%s 会话 %s→%s → %s\n' "$i" "$n" "${a:0:6}" "${b:0:6}" \
    "${c:+,${c:0:6}}" "${before:-无}" "${after:-无}" "$([ "$t" = 1 ] && echo 停了 || echo 没停)"
  # 有效性控制：恢复后必须重新推进。否则后面每一轮都会「一直停着」，全部作废。
  if ! recover; then
    echo "FAIL 第 $i 轮后没能恢复播放，样本不可信，已中止（本轮不写入）。"
    exit 2
  fi
done
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
echo "画面判定响应 $ok/${n}；会话自称已暂停 $sessionpaused/${n}（两者不一致就是 D44 说的坑）。"
exec ruby "$root/tools/probe-record.rb" --fact=f12 --device="$model" --player="$player" \
  --source=adb --channel="$channel" --method=clockCrop --trials="$trials" \
  --session-paused="$sessionpaused" ${android:+--android=$android}
