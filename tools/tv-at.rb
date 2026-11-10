#!/usr/bin/env ruby
# 电视端的 adb 调试与设备测试入口：一条命令把 fixtures/tv-device.yaml 那批用例在真机上跑一遍。
#
# 每步两道，缺一不可：
#   内核侧  跑那一条夹具（ruby tools/run-fixtures.rb <ID>），要求 0 失败、0 未支持；
#   设备侧  把同一份结论显示到设备上（tools/tv-present.rb），由它自己验前台窗口、画面不白、
#           与本地卡的灰度比对——不看人眼点头，也不拿截图假装（facts/DEVICES.md#F14、#F15）。
# 这条通路是**呈现通路演练**，不是 M3 的设备端界面：这台设备上目前没有我们的 APK，
# 遥控器按键也没有能接收它的界面（见下 --facts 里的「输入通路」）。
#
# 用法：
#   ruby tools/tv-at.rb --serial=192.168.1.44:5555              # 跑清单
#   ruby tools/tv-at.rb --serial=… --only=LAYER-07              # 只跑一步
#   ruby tools/tv-at.rb --serial=… --facts                      # 只读设备一手事实，看它们怎么进内核
#   ruby tools/tv-at.rb --serial=… --cycle=3                    # 调试：连播三轮（遥控器坏了也能换页）
#   ruby tools/tv-at.rb --serial=… --keep-facts                 # 顺手把读到的事实写进 facts 那份样本
require 'json'
require 'yaml'
require 'fileutils'
require 'shellwords'

ROOT = File.expand_path('..', __dir__)
LIST = File.join(ROOT, 'tools/tv-device.yaml') # 清单在 tools/ 不在 fixtures/：它是测试清单，不是夹具（判定期望仍只在夹具里）
SHOT_DIR = '/tmp/youban-tv-at'
FACTS_CACHE = File.join(ROOT, 'tmp', 'device-facts.json')

def parse_args(argv)
  o = { serial: nil, only: nil, cycle: 1, facts: false, keep_facts: false }
  argv.each do |a|
    case a
    when /\A--serial=(.*)/ then o[:serial] = Regexp.last_match(1)
    when /\A--only=(.*)/ then o[:only] = Regexp.last_match(1).split(',')
    when /\A--cycle=(\d+)/ then o[:cycle] = Regexp.last_match(1).to_i
    when '--facts' then o[:facts] = true
    when '--keep-facts' then o[:keep_facts] = true
    end
  end
  o
end

def adb(args, *cmd)
  full = (['adb'] + (args[:serial] ? ['-s', args[:serial]] : []) + cmd).shelljoin
  [`#{full} 2>&1`, $?.success?]
end

def online?(args)
  out, = adb(args, 'get-state')
  out.strip == 'device'
end

# 设备一手事实：DAY-07 要的那三项（探测时刻、墙钟差、单调钟差）只能从设备上读，模型不自己造。
# 这里在 Mac 侧存一份「上次见到的最大墙上时间」只为调试对比；真机上这件事由设备端自己持久化。
def device_facts(args)
  unless online?(args)
    puts "设备不通：#{args[:serial] || '默认设备'} 不在线（adb devices 里有它吗？电视是否睡了？）"
    return nil
  end
  wall_s, = adb(args, 'shell', 'date', '+%s')
  mono_s, = adb(args, 'shell', 'cat', '/proc/uptime')
  tz, = adb(args, 'shell', 'getprop', 'persist.sys.timezone')
  sdk, = adb(args, 'shell', 'getprop', 'ro.build.version.sdk')
  model, = adb(args, 'shell', 'getprop', 'ro.product.model')
  disp, = adb(args, 'shell', 'wm', 'size')
  wake, = adb(args, 'shell', 'dumpsys', 'power')
  wall = wall_s.strip.to_i
  facts = {
    'probedAt' => Time.at(wall).utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
    'model' => model.strip, 'android' => sdk.strip, 'timezone' => tz.strip,
    'display' => disp[/\d+x\d+/, 0].to_s, 'monotonicUpS' => mono_s.split.first.to_i,
    'awake' => !!(wake =~ /mWakefulness=Awake/i)
  }
  prev = File.exist?(FACTS_CACHE) ? JSON.parse(File.read(FACTS_CACHE)) : {}
  facts['wallClockDeltaMs'] = prev['wallMs'] ? (wall - prev['wallMs'].to_i) * 1000 : 0
  facts['monotonicDeltaMs'] = prev['monotonicUpS'] ? (facts['monotonicUpS'] - prev['monotonicUpS']) * 1000 : 0
  facts['wallMs'] = [wall, prev['wallMs'].to_i].max # 「见过的最大墙上时间」：回跳就靠它判（DAY-07）
  # 输入通路：这台设备上没有任何组件认领我们的状态更新，遥控器按键也就没人接。
  rcv, = adb(args, 'shell', 'cmd', 'package', 'query-receivers',
             '-a', 'com.youban.STATE')
  facts['inputChannel'] = rcv =~ /Receiver List is empty/ || !rcv.include?('com.youban') ? 'none（需要 device/ 的原生 APK）' : 'apk'
  puts JSON.pretty_generate(facts.reject { |k,| k == 'wallMs' })
  puts "输入通路：#{facts['inputChannel']}——遥控器按键现在没人接，这一轮的换页只能从 Mac 侧走 adb。"
  FileUtils.mkdir_p(File.dirname(FACTS_CACHE)) if args[:keep_facts]
  File.write(FACTS_CACHE, JSON.pretty_generate(facts)) if args[:keep_facts]
  facts
end

def kernel_step(args, id)
  out = IO.popen(['ruby', File.join(ROOT, 'tools/run-fixtures.rb'), id], err: [:child, :out], &:read)
  line = out[/合计：.*/].to_s
  # 跑不出「合计」这一行就是命令自己炸了（契约表读不到、模型抛错…），把那行错误带出来，别留空白。
  [line.include?('失败 0') && $?.success?, line.empty? ? out.lines.last.to_s.strip : line.strip]
end

def device_step(args, file, id)
  FileUtils.mkdir_p(SHOT_DIR)
  shot = File.join(SHOT_DIR, "#{id.tr('.', '-')}.png")
  out = IO.popen(['ruby', File.join(ROOT, 'tools/tv-present.rb'), file, id,
                  "--serial=#{args[:serial]}", "--shot=#{shot}"], err: %i[child out], &:read)
  [out.lines.grep(/已在/).any? && $?.success?, out.lines.last.to_s.strip, shot]
end

# 两道设备自检：验的不是「判定」而是「设备能力本身」——这两件事没有对应的判定夹具。
# 它们只能证明东西落到了设备、码位是对的；字形画得对不对仍由上面那八步的像素比对管（F17）。
APK_PACKAGE = 'com.youban.tv'
APK_FILES = "/sdcard/Android/data/#{APK_PACKAGE}/files".freeze

def shell(args, cmd)
  IO.popen(['adb', '-s', args[:serial].to_s, 'shell', cmd], err: %i[child out], &:read).to_s
end

def probe_input(args)
  return [false, '没装 com.youban.tv：先 sh device/android/build-apk.sh && adb install -r'] if
    shell(args, "pm list packages #{APK_PACKAGE}").strip.empty?

  shell(args, "am force-stop #{APK_PACKAGE}")
  shell(args, "am start -n #{APK_PACKAGE}/.MainActivity")
  sleep 3
  shell(args, "rm -f #{APK_FILES}/youban-input.json")
  shell(args, 'input keyevent 23') # 确认键：遥控器上那一下
  sleep 1
  got = shell(args, "cat #{APK_FILES}/youban-input.json")
  ok = got.include?('"key":"accept"') && got.include?('monoMs')
  return [true, "确认键落到设备：#{got.lines.first.to_s.strip}"] if ok

  [false, "按了确认键但设备没落账：#{got.lines.first.to_s.strip.empty? ? '文件不存在' : got.lines.first.strip}"]
end

# 这一屏句子到 TextView 时的码位（应用自己写到 youban-diag.json，见 F17）。
# 只看码位：它们必须是真汉字、不能是 U+FFFD——那意味着文本在编译或传递途中就坏了。
PROBE_TEXT_CASE = ['fixtures/layer.yaml', 'LAYER-07'].freeze

def probe_text(args)
  raw = IO.popen(['ruby', File.join(ROOT, 'tools/tv-status.rb'), *PROBE_TEXT_CASE, '--raw'],
                 err: %i[child out], &:read)
  return [false, "内核这边就没出结论：#{raw.lines.last.to_s.strip}"] unless raw.include?('"status"')

  shell(args, "am broadcast -n #{APK_PACKAGE}/.StateReceiver -a com.youban.STATE --es state #{raw.strip.gsub("'", "'\\''")}")
  sleep 2
  got = shell(args, "cat #{APK_FILES}/youban-diag.json")
  json = (got.scan(/[\s\S]+/).join).gsub(/[\r\n]+/, '')[/{"len.*?\}/]
  return [false, "设备没回写码位（装了 APK 并推过状态吗？）：#{got.lines.first.to_s.strip}"] unless json

  # 不依 JSON 解析：这台机器的 screencap/cat 习惯在 stdout 里夹带警告，整份解析一炸就没法往下走。
  cps = json.to_s.scan(/\b[0-9a-f]{4}\b/).map { |h| h.to_i(16) }
  return [false, '码位是空的'] if cps.empty?

  bad = cps.reject { |c| (0x4E00..0x9FFF).cover?(c) || [0x3002, 0xFF0C, 0x3001].include?(c) || (0x20..0x7E).cover?(c) }
  return [false, "码位里有不该出现的字符：#{bad.map { |c| format('%X', c) }.join(',')}（文本在途中坏了）"] unless bad.empty?

  han = cps.count { |c| (0x4E00..0x9FFF).cover?(c) }
  return [false, "这一屏句子里一个汉字都没有：#{json}"] if han.zero?

  [true, "#{cps.size} 个码位全是真字（#{han} 个汉字），没有 U+FFFD"]
end

# 字形这条只由画来答：应用把句子里每个字单独画进小图、比字节，写回 youban-glyphs.json。
# distinct=1 就是真的塌成同一个字；blank 里列出画出来是空白的码位。这条判据不看分辨率、不看字体名、
# 也不看谁的肉眼——之前「每个字同一个字形」那句就是我读低分辨率截屏读出来的（F17）。
GLYPHS_DISTINCT_MIN = 8 # 那句状态句有 14 个 CJK/标点，塌了会是 1；这里只要求明显大于 1。

def probe_glyphs(args)
  got = (shell(args, "cat #{APK_FILES}/youban-glyphs.json").gsub(/[\r\n]+/, ''))[/\{.*?\}/]
  return [false, '设备没回写字形自检（装了 APK 并起过界面吗？）'] unless got

  distinct = got[/"distinct":(\d+)/, 1].to_i
  blank = got[/"blank":"(.*?)"/, 1].to_s
  return [false, "有字画出来是空白：#{blank}"] unless blank.empty?
  return [false, "#{distinct} 种——字都画成同一个了"] if distinct < GLYPHS_DISTINCT_MIN

  [true, "每个字各画各的：#{distinct} 种不同字形，没有空白"]
end

# 两端同源：把设备上的事件账读回 Mac，喂给 Ruby 那份规范模型，再与设备自己算的那份逐字段比。
# 这是 M3 最硬的一道：设备不是在念别人算好的结论，而是在跑同一个内核——这一道红了就是不同源。
def probe_state(args)
  events = shell(args, "cat #{APK_FILES}/#{EVENTS_FILE}").gsub(/\r/, '')
  return [false, '设备上没有事件账，算不出结论'] if events.strip.empty?

  mine = KernelFromEvents.call(events)
  return [false, "Mac 这边的规范模型没出结论：#{mine}"] unless mine.is_a?(Hash)

  theirs_raw = (shell(args, "cat #{APK_FILES}/youban-state-out.json").gsub(/\r\n?/, ''))[/\{.*\}/]
  return [false, '设备没写出它自己算的那份结论'] unless theirs_raw

  theirs = JSON.parse(theirs_raw)
  fields = JSON.parse(File.read(File.join(ROOT, 'contract/contract.json')))['commitState']['fields']
  diff = fields.reject { |k| JSON.parse(JSON.generate(mine[k] || mine[k.to_sym])) == theirs[k] }
  return [false, "#{diff.size} 个字段与规范模型不同：#{diff.join(', ')}"] unless diff.empty?

  [true, "#{fields.size} 个字段与 Mac 上的规范模型逐位相同（#{mine['status'] || mine[:status]} · #{mine['tier'] || mine[:tier]}）"]
end

EVENTS_FILE = 'youban-events.jsonl'
require_relative 'kernel-from-events'
KernelFromEvents = method(:kernel_from_events)

PROBES = { 'input' => method(:probe_input), 'text' => method(:probe_text),
           'glyphs' => method(:probe_glyphs), 'state' => method(:probe_state) }.freeze

args = parse_args(ARGV)
if args[:facts]
  device_facts(args)
  exit 0
end

probes = Array(YAML.load_file(LIST)['probes'])
scenarios = YAML.load_file(LIST)['scenarios']
scenarios = scenarios.select { |s| Array(args[:only]).any? { |p| s['case'].split('#').last.start_with?(p) } } if args[:only]
abort "#{LIST} 里没有要跑的用例" if scenarios.empty?
abort "设备不通：#{args[:serial] || '默认设备'} 不在线（adb devices 里有它吗？）" unless online?(args)

facts = device_facts(args)
puts "\n设备：#{facts['model']} · Android #{facts['android']} · #{facts['display']} · 醒着=#{facts['awake']}#{' 在' if facts['awake']}（屏睡了先戳醒，屏保也是深色画面，见 F15）"
puts "清单：#{scenarios.size} 步 · 每步两道（内核侧夹具 + 设备侧显示自证）\n"

fails = []
args[:cycle].times do |round|
  scenarios.each do |s|
    file, id = s['case'].split('#')
    label = round.zero? ? id : "#{id}#{'/轮2' if round == 1}#{'/轮3' if round == 2}"
    kok, klin = kernel_step(args, id)
    dok, dlast, shot = device_step(args, file, id)
    ok = kok && dok
    fails << id unless ok
    printf("%-14s %s 内核侧 %s ｜ 设备侧 %s\n", label, ok ? 'PASS' : 'FAIL',
           kok ? '绿' : "红（#{klin.strip}）", dok ? '已显示并自证' : "没显示：#{dlast}")
    puts "               #{s['why']}；截图 #{shot}" if ok
  end
  puts
end

if fails.empty?
  probes.each do |p|
    fn = PROBES[p['probe'].to_s]
    ok, detail = fn.call(args)
    fails << "probe:#{p['probe']}" unless ok
    printf("%-14s %s %s\n", p['probe'], ok ? 'PASS' : 'FAIL', detail)
    puts "               #{p['why']}"
  end
  puts
end

if fails.empty?
  puts "电视端设备测试：#{scenarios.size} 步全部通过（内核判定 + 真机显示各一道）"
  puts '这验的是「判定 → 落层 → 措辞 → 呈现」这条链在真机上对；界面本身仍要 device/ 的原生 APK（M3）。'
else
  puts "电视端设备测试：#{fails.size} 步没过——#{fails.join(', ')}"
end
exit(fails.empty? ? 0 : 1)
