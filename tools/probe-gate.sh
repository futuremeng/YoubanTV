#!/bin/sh
# SPEC: LAYER-07, SENSE-02, SENSE-04
# 实测数据一致性门：样本文件 ↔ 门槛常量 ↔ DEVICES.md 的措辞，三者不得各说各话。
# 反造假：来源不是 adb/manual 的样本一律不得用来抬默认档。
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root" || exit 1

ruby -ryaml -e '
bad = []
rows = []
f12 = YAML.load_file("docs/facts/probes/f12.yaml")
f13 = YAML.load_file("docs/facts/probes/f13.yaml")
dec = File.read("docs/DECISIONS.md")
dev = File.read("docs/facts/DEVICES.md")

# 1. 门槛常量与 DECISIONS「暂定取值」表一致
t12, t13 = f12["threshold"], f13["threshold"]
bad << "F12 响应率门槛与 DECISIONS 不一致（#{t12["responseRate"]}）" unless t12["responseRate"] == 0.95 && dec.include?("≥95%")
bad << "F12 样本量门槛与 DECISIONS 不一致（#{t12["sampleMin"]}）" unless t12["sampleMin"] == 20 && dec.include?("≥20 次")
bad << "F13 自检次数与 DECISIONS 不一致（#{t13["selfTestAttempts"]}）" unless t13["selfTestAttempts"] == 20 && dec.include?("连续 20 次")
bad << "F13 误计率门槛与 DECISIONS 不一致（#{t13["falseCountMax"]}）" unless t13["falseCountMax"] == 0.05 && dec.include?("≤5%")

OK_SOURCE = %w[adb manual]

# 2. F12 逐机型判定
measured12 = false
f12["devices"].to_a.each do |d|
  trials = d["trials"].to_a
  bad << "#{d["model"]}/#{d["player"]} 的 trials 含非 0/1 值" unless trials.all? { |x| [0, 1].include?(x) }
  n = trials.size
  rate = n.zero? ? 0.0 : trials.sum.to_f / n
  src = d["source"].to_s
  bad << "#{d["model"]}/#{d["player"]} 有样本但来源登记为 #{src.inspect}" if n.positive? && !OK_SOURCE.include?(src)
  raise_ok = src != "pending" && OK_SOURCE.include?(src) && n >= t12["sampleMin"] && rate >= t12["responseRate"]
  bad << "#{d["model"]}/#{d["player"]} 用 #{src} 来源的样本抬了默认档" if raise_ok && !OK_SOURCE.include?(src)
  measured12 ||= n.positive? && OK_SOURCE.include?(src)
  rows << format("F12 %-22s %-11s n=%-3s 响应率 %5s%%  %s", d["model"], d["player"], n,
                 (rate * 100).round(1), raise_ok ? "focused 可作默认档" : (n >= t12["sampleMin"] ? "停 ambient" : "样本不足"))
end

# 3. F13 逐项目判定
measured13 = false
f13["projects"].to_a.each do |p|
  st = p["selfTest"] || {}
  n = st["attempts"].to_i
  rate = n.zero? ? 1.0 : st["falseCounts"].to_f / n
  src = p["source"].to_s
  bad << "#{p["name"]}/#{p["device"]} 有自检样本但来源登记为 #{src.inspect}" if n.positive? && !OK_SOURCE.include?(src)
  open_ok = OK_SOURCE.include?(src) && n >= t13["selfTestAttempts"] && rate <= t13["falseCountMax"]
  ref = p["reference"] || {}
  bad << "#{p["name"]} 已标 cameraChannel 可开但自检来源是 #{src}" if open_ok && !OK_SOURCE.include?(src)
  measured13 ||= n.positive? && OK_SOURCE.include?(src)
  rows << format("F13 %-22s %-11s 自检 %-3s 误计 %5s%%  %s%s", p["name"], p["device"], n, (rate * 100).round(1),
                 open_ok ? "摄像头通道可开" : "停加速度计+手动",
                 ref["trials"].to_i >= t13["referenceTrials"] ? "" : "（对照 #{ref["trials"].to_i}/#{t13["referenceTrials"]}）")
end

# 4. DEVICES.md 的措辞必须跟着数据走
f12sec = dev[/^## F12.*?(?=^## )/m].to_s
f13sec = dev[/^## F13.*?(?=^## |\z)/m].to_s
if measured12
  bad << "F12 已有实测样本，但 DEVICES.md 仍写「待实测」" if f12sec.include?("待实测")
else
  bad << "F12 一条样本都没有，DEVICES.md 却去掉了「待实测」" unless f12sec.include?("待实测")
end
if measured13
  bad << "F13 已有自检样本，但 DEVICES.md 仍写「待实测」" if f13sec.include?("待实测")
else
  bad << "F13 一条自检样本都没有，DEVICES.md 却去掉了「待实测」" unless f13sec.include?("待实测")
end

puts rows.empty? ? "F12/F13：尚无样本 —— 默认值按最保守档（focused 不作默认、摄像头通道关）" : rows.join("\n")
bad.each { |b| puts "FAIL #{b}" }
exit(bad.empty? ? 0 : 1)
'
