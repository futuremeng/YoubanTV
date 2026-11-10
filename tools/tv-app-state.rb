#!/usr/bin/env ruby
# 设备侧那一道：把某个夹具 case 的事实送进设备，让设备上的内核自己算，再自证画出来了。
#
# 为什么不用那条「Mac 画一张卡推到相册」的老路（tools/tv-present.rb）：那条是呈现通路演练，
# 在旧设备上时通时不通（同一台机器上八步里四步开不出屏），而且它验的是 Mac 画的图，
# 不是设备算的结论。这里改成：事实进账 → 设备算 → 读回结论逐字段比 → 屏幕自证。
#
# 用法：ruby tools/tv-app-state.rb fixtures/layer.yaml LAYER-07 --serial=<设备> [--shot=路径]
require 'json'
require 'tmpdir'
require 'yaml'
require_relative 'run-fixtures'

ROOT = File.expand_path('..', __dir__)
PKG = 'com.youban.tv'
FILES = "/sdcard/Android/data/#{PKG}/files"
DIFF_MAX = 12.0 # 与 tv-present 同一条：光「画暗了」不够，载入画面也是暗的（F15）

def abort_with(msg)
  warn "FAIL #{msg}"
  exit 1
end

def adb(serial, *cmd)
  IO.popen(['adb', '-s', serial.to_s, *cmd.map(&:to_s)], err: %i[child out], &:read)
end

def screen(serial, path)
  shot = File.join(Dir.tmpdir, "youban-app-#{Process.pid}.png")
  adb(serial, 'shell', 'screencap', '-p', '/sdcard/Download/yb-check.png')
  pull = adb(serial, 'pull', '/sdcard/Download/yb-check.png', shot)
  abort_with("截屏没取回来：#{pull.lines.last.to_s.strip}") unless File.exist?(shot) && File.size(shot) > 1000

  raw = IO.popen(['magick', shot, '-colorspace', 'Gray', '-depth', '8', 'rgb:-'], &:read)
  FileUtils.mkdir_p(File.dirname(path)) if path && !path.empty?
  FileUtils.cp(shot, path) if path && !path.empty?
  [raw.each_byte.sum.to_f / raw.bytesize, shot]
end

serial = (ARGV.find { |a| a =~ /^--serial=/ } || '').sub('--serial=', '')
shot_path = (ARGV.find { |a| a =~ /^--shot=/ } || '').sub('--shot=', '')
file, id = ARGV.reject { |a| a.start_with?('--') }
abort_with('用法：ruby tools/tv-app-state.rb <夹具> <ID> --serial=<设备>') if file.nil? || id.nil?
abort_with("设备不通：#{serial}") if serial.empty? || !adb(serial, 'get-state').include?('device')

body = YAML.load_file(File.join(ROOT, file))[id.split('.').first]
c = body['cases'].find { |x| x['id'] == id } || body['cases'][(id.split('.').last.to_i - 1)]
abort_with "#{file} 里找不到 #{id}" if c.nil?

given = (body['given'] || {}).merge(c['given'] || {})
world = World.new(given)
begin
  world.apply(c['when'] || {})
rescue Unsupported => e
  abort_with "这一步夹具自己就未支持：#{e.message}"
end
mine = world.commit_state
abort_with '这个 case 没有可比的 CommitState' unless mine.is_a?(Hash)

FIELDS = JSON.parse(File.read(File.join(ROOT, 'contract/contract.json')))['commitState']['fields']

# 先清账再灌事件：留着上一轮的账，设备算的就是另一件事了。
adb serial, 'shell', 'am', 'force-stop', PKG
adb serial, 'shell', "rm -f #{FILES}/youban-events.jsonl"
File.open(File.join(Dir.tmpdir, 'youban-plan.json'), 'w') do |f|
  f.write(JSON.generate(world.plan))
  @plan_path = f.path
end
adb serial, 'push', @plan_path, "#{FILES}/youban-plan.json"
adb serial, 'shell', "echo #{world.profile} > #{FILES}/youban-profile.txt"
adb serial, 'shell', "echo #{world.strength} > #{FILES}/youban-strength.txt"

# 先把界面起来再灌事件：被 force-stop 掉的应用收不到广播（Android 7 起就是这个规矩），
# 在那台旧设备上表现为账是空的、屏幕上是一句「还没到期」——看着像判定错了，其实是没进去。
adb serial, 'shell', 'input', 'keyevent', '82' # 屏睡了先戳醒：屏保也是深色画面（F15）
adb serial, 'shell', 'am', 'start', '-n', "#{PKG}/.MainActivity"
sleep 3

world.ledger.events.each do |e|
  f = e.fields
  args = ['--es', 'kind', e.kind.to_s, '--es', 'profile', e.profile.to_s,
          '--el', 'ms', (f[:ms] || 0).to_i.to_s, '--el', 'pauseMs', (f[:pauseMs] || 0).to_i.to_s]
  # 动议是哪一种也要送过去：受理了的「延一延」不是暂停，只看有没有 MOTION_SETTLED 会判错。
  # 但空值不能带——`--es fieldKind ""` 在 adb shell 里直接报 IllegalArgumentException，
  # 整条广播就没了：那一晚八条只落了两条，查出来是这个。
  args.push('--es', 'fieldKind', f[:kind].to_s) unless f[:kind].to_s.empty?
  adb serial, 'shell', 'am', 'broadcast', '-n', "#{PKG}/.StateReceiver", '-a', 'com.youban.STATE', *args
end
sleep 2

windows = adb(serial, 'shell', 'dumpsys', 'window').to_s
front = windows[/mCurrentFocus=(.+)/, 1].to_s + windows[/mFocusedApp=(.+)/, 1].to_s
abort_with("前台不是我们的应用：#{front[0, 90]}") unless front.include?(PKG)

got = (adb(serial, 'shell', "cat #{FILES}/youban-state-out.json").gsub(/[\r\n]+/, ''))[/\{.*\}/]
abort_with('设备没写出它自己算的那份结论（装的是带内核的 APK 吗？）') unless got
theirs = JSON.parse(got)
diff = FIELDS.reject { |k| JSON.parse(JSON.generate(mine[k] || mine[k.to_sym])) == theirs[k] }
abort_with("#{diff.size} 个字段与规范模型不同：#{diff.join(', ')}\n  设备 #{theirs.inspect[0, 220]}\n  Mac  #{mine.inspect[0, 220]}\n  账 #{world.ledger.events.map { |e| [e.kind, e.fields] }.inspect[0, 200]}\n  案 #{c["id"]} 计划 #{world.plan.inspect[0, 160]}") unless diff.empty?

mean, shot = screen(serial, shot_path)
if mean > 235
  # 白屏多半是还停在桌面：再戳一次醒、再拉一次界面；第二次还是白才算不过。
  # 旧设备上 mCurrentFocus 会写着「android」而真正在前面的那个在 mFocusedApp，那一行不能只信一半。
  adb serial, 'shell', 'input', 'keyevent', '82'
  adb serial, 'shell', 'am', 'start', '-n', "#{PKG}/.MainActivity"
  sleep 3
  mean, shot = screen(serial, shot_path)
end
abort_with("画面平均亮度 #{mean.round(1)}，接近纯白：等于没画东西") if mean > 235

# 与设备上一屏比一眼：同一个应用连开两次，画面应当几乎一样；差太多说明这一屏根本没刷新。
prev = File.join(Dir.tmpdir, "youban-app-#{serial}-prev.png")
if File.exist?(prev) && File.exist?(shot)
  d = IO.popen(['magick', shot, prev, '-metric', 'AE', 'null:'], err: %i[child out], &:read)
  # AE 是差异像素数，屏幕百万级像素，这里只当「有没有整屏变化」的粗信号，不卡阈值。
  puts "与上一屏的差异像素 #{d[/[\d.]+/].to_i}"
end
FileUtils.cp(shot, prev) if File.exist?(shot)

puts "已在 #{serial} 显示并自证：#{FIELDS.size} 个字段与规范模型逐位相同（#{theirs['status']} · #{theirs['tier']} · #{theirs['text']}）"
