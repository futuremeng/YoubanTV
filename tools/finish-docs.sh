#!/usr/bin/env bash
# 这一步只补文档与忽略项，内容都是实测过的（facts/DEVICES.md#F17、docs/PROVENANCE.md）。
set -eu
cd "$(dirname "$0")"

grep -q '^device/android/out/' .gitignore || printf '# 打出来的包与本地测试密钥，都不入库\ndevice/android/out/\n' >> .gitignore

if ! grep -q '^## F17' docs/facts/DEVICES.md; then
cat >> docs/facts/DEVICES.md <<'MD'

## F17 装上原生壳层之后：遥控器按键真落到设备了，但汉字还是画不对

- 实测（2026-11-10，BOX-B，Konka Android TV 9652 / Android 9）：
  - `adb install` 自签名的 `youban-tv.apk`（0.06 MB）成功；`am start -n com.youban.tv/.MainActivity`
    起来后 `mCurrentFocus` 就是 `com.youban.tv/com.youban.tv.MainActivity`；
    `adb shell input keyevent 23`（确认键）之后设备上出现
    `/sdcard/Android/data/com.youban.tv/files/youban-input.json` = `{"key":"accept","at":…,"monoMs":…}`
    ——**F16 说的「输入通路是空的」从今天起只对免安装的通路成立**。
  - 两个坑：① 应用直接写 `/sdcard/Download` 写不进去（API 28 没声明存储权限），看起来就像按键没被接到；
    换到 `getExternalFilesDir(null)` 就有了，公共目录只作兜底。② 这台电视的屏保
    （`com.smartisanos.screensaver`）会在活动起来之后抢走前台，截图截到的是屏保的钟；
    所以先 `keyevent 82`（必要时再 `220`），确认 `mCurrentFocus` 是我们的组件，才允许截图。
  - **汉字仍不对**：这台设备 `/system/fonts` 里没有汉字字形（拉丁与各非中文字脚本一大堆），随包带的
    OFL 子集字体（170 字 / 60 KB）在角标与脚注那两行正常，主状态句那一行每个字渲染成同一个字形——
    **没修好，不许按「已能显示中文」记账**；下一轮要查子集 cmap 与那一行文本的对应关系。
- 复核：`sh device/android/build-apk.sh && adb -s <电视> install -r device/android/out/youban-tv.apk`
  → `adb -s <电视> shell am start -n com.youban.tv/.MainActivity` → `adb -s <电视> shell input keyevent 23`
  → `adb -s <电视> shell cat /sdcard/Android/data/com.youban.tv/files/youban-input.json`。
MD
fi

if ! grep -q '界面字体与构建取件' docs/PROVENANCE.md; then
cat >> docs/PROVENANCE.md <<'MD'

## 界面字体与构建取件（2026-11-10）

- 界面用字体：Noto Sans SC 的按需子集（`device/android/app/src/main/assets/fonts/youban-subset.otf`，
  170 字 / 60 KB），原字体在 Notofonts `noto-cjk` 的 `Sans/SubsetOTF/SC/` 下，许可 SIL OFL 1.1。
  **今晚没取到 OFL 全文**（`scripts.sil.org` 403、`raw.githubusercontent` 404），包内那张
  `LICENSE-NotoSansSC.txt` 目前只写了出处与许可证名——**随包发布前必须补全文**，这是硬门槛。
- 构建取件走镜像：`mirrors.cloud.tencent.com/AndroidSDK/`（build-tools 34.0.0、platform-33_r01），
  约 1.5 MB/s；同一批文件走 `dl.google.com` 今晚反复超时。**镜像包没有拿到权威校验值**，
  只做了 zip 完整性与内部结构核对（`aapt2`/`d8` 在位、`android.jar` 里有 `TIRAMISU`）。
  将来公开发布时，这些二进制必须换成有校验值的来源，或按 sha256 与官方 `repository2-*.xml` 对账。
MD
fi

grep -q '装上了的原生壳层' docs/ROADMAP.md || python3 - <<'PY'
p = 'docs/ROADMAP.md'
t = open(p, encoding='utf-8').read()
old = """- **写好了但还没编译的东西**：`device/android/`（M3 的壳层：主界面 + 状态入口 + 免 Gradle 的
  `build-apk.sh`）。它补的正是免安装的通路上缺的那一半——遥控器按键有地方接了（`facts/DEVICES.md#F16`）。
  在它能装到设备上跑起来之前，不说「M3 完成」，也不说「输入通路已通」。"""
new = """- **装上了的原生壳层**：`device/android/build-apk.sh`（不用 Gradle：aapt2 → javac → d8 → zip →
  zipalign → apksigner）打出 0.06 MB 的包，`adb install` 到电视上起得来，**遥控器按键已落到设备**
  （`input keyevent 23` → 应用私有目录里的 `youban-input.json`，`facts/DEVICES.md#F17`）。
  还差三件才说得上 M3 完成：① 汉字渲染——这台设备系统字体没汉字，随包的 OFL 子集在主状态句那行
  渲染成同一个字形，**未修好**；② 内核结论的来源接成事件存储，而不是 adb 推的文件；
  ③ 设备测试清单里加「按键落到设备」这一步（现在只有手验，没进清单）。"""
assert old in t, 'ROADMAP M3 那条要改的原文找不到'
open(p, 'w', encoding='utf-8').write(t.replace(old, new, 1))
PY

python3 - <<'PY'
p = 'docs/DECISIONS.md'
t = open(p, encoding='utf-8').read()
if '| D51 |' not in t:
    row = [l for l in t.split('\n') if l.startswith('| D50 |')][0]
    d51 = ("| D51 | 免 Gradle 打出并装上第一个原生壳层 APK（0.06 MB），遥控器按键落到设备"
           "（`input keyevent 23` → 应用私有目录的 `youban-input.json`）——F16 的「输入通路是空的」"
           "从此只对免安装的通路成立。**两条如实记账**：① 这台电视系统字体没有汉字，随包的 OFL 子集字体"
           "在主状态句那行渲染成同一个字形，**没修好**，不许按「已能显示中文」记账（`facts/DEVICES.md#F17`）；"
           "② 我此前判断「本机装不动 Android SDK」是查错了目录——SDK 一直在 `~/android-sdk`"
           "（我找的是 `~/Library/Android/sdk`），那一晚说的「装不动」是错的；镜像解决的是慢，不是装不上"
           "（`docs/PROVENANCE.md`） | `device/android/`、`facts/DEVICES.md#F17`、`docs/PROVENANCE.md`、D50、D48 |")
    open(p, 'w', encoding='utf-8').write(t.replace(row, row + "\n" + d51, 1))
PY
echo "文档补齐：F17=$(/tmp/none 2>/dev/null; grep -c '^## F17' docs/facts/DEVICES.md) PROVENANCE=$(grep -c '界面字体与构建取件' docs/PROVENANCE.md) D51=$(grep -c '^| D51' docs/DECISIONS.md)"
