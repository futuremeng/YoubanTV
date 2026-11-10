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
require 'digest'
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

# 广播用参数数组送，不拼成一整条字符串：拼字符串会被两道 shell 吃掉 `{},"`（F20 那一坑）。
def broadcast(args, extra)
  IO.popen(['adb', '-s', args[:serial].to_s, 'shell', 'am', 'broadcast', '-n', "#{APK_PACKAGE}/.StateReceiver",
            '-a', 'com.youban.STATE', *extra], err: %i[child out], &:read).to_s
end

# 设备上按身份各存一份方案；没存过的那一档退到公共那一份（AGREE-13）——Mac 这边要喂同样的输入。
def device_plans(args)
  legacy_raw = shell(args, "cat #{APK_FILES}/youban-plan.json").gsub(/\r\n?/, '')[/\{.*\}/]
  legacy = legacy_raw ? JSON.parse(legacy_raw) : nil
  who = shell(args, "cat #{APK_FILES}/youban-profile.txt").to_s[/member:\S+/].to_s.strip
  plans = {}
  listing = shell(args, "ls #{APK_FILES}").to_s
  listing.each_line do |name|
    next unless name =~ /youban-plan-member_(\w+)\.json/

    raw = shell(args, "cat #{APK_FILES}/#{name.strip}").gsub(/\r\n?/, '')[/\{.*\}/]
    plans["member:#{$1}"] = JSON.parse(raw) if raw
  end
  roster = plans.keys + [who.empty? ? nil : who].compact
  roster.each { |k| plans[k] ||= legacy } if legacy
  plans
rescue JSON::ParserError
  {}
end

def device_state(args)
  raw = shell(args, "cat #{APK_FILES}/youban-state-out.json").gsub(/\r\n?/, '')[/\{.*\}/]
  raw && JSON.parse(raw)
rescue JSON::ParserError
  nil
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
  facts = device_facts_body(args)
  # 设备上「上一次到前台」的时间也在事实里：证据不过期那一条靠它，不靠开机广播（ONBOARD-07、F25）。
  raw = shell(args, "cat #{APK_FILES}/youban-probe.json").gsub(/\r/, '')[/\{.*\}/]
  facts['deviceProbedAt'] = raw ? JSON.parse(raw)['at'] : nil
  facts['deviceProbeAgeS'] = raw ? ((Time.now.to_f * 1000 - JSON.parse(raw)['at'].to_f) / 1000).round : nil
  facts
end

def device_facts_body(args)
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
  # 输入通路看装没装：装了 APK 才有接按键的组件；没装就是免安装那条路，按键没人接（F16→F17）。
  facts['inputChannel'] = shell(args, "pm list packages #{APK_PACKAGE}").include?(APK_PACKAGE) ? 'apk' : 'none'
  puts JSON.pretty_generate(facts.reject { |k,| k == 'wallMs' })
  if facts['inputChannel'] == 'apk'
    puts '输入通路：apk——遥控器按键由装着的这层接；按键→事件→内核重算由 input/key/setup/switch 四道自检各验一条。'
  else
    puts "输入通路：#{facts['inputChannel']}——这台设备上没装那层壳，遥控器按键没人接，换页只能从 Mac 侧走 adb（F16）。"
  end
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
  # 设备侧走装了 APK 的那条：事实进账 → 设备自己算 → 读回逐字段比 → 屏幕自证。
  # 老那条「Mac 画卡推相册」（tools/tv-present.rb）留作呈现通路演练，不再当设备测试的依据：
  # 在旧设备上它八步里能开四步屏，而且验的是 Mac 画的图，不是设备算的结论。
  out = IO.popen(['ruby', File.join(ROOT, 'tools/tv-app-state.rb'), file, id,
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

  # 只拦两类：U+FFFD（替换字符——文本在途中坏了）和控制字符。中文标点（？、。（））都算合法，
  # 之前把它们当非法，一句带问号的状态句就误报过一次。
  bad = cps.select { |c| c == 0xFFFD || (c < 0x20 && ![0x0A, 0x0D, 0x09].include?(c)) }
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
# 先把账清成一条已知的事件流再比：留着前面八步的账，比的就是「两份不同的账」而不是同一个内核。
# 而且「这一轮请求了 focused」「已受理的暂停」这类状态不在事件里，靠攒下来的账比必然对不上。
SEED_EVENTS = [['WATCHED', 3_600_000]].freeze

def probe_state(args)
  shell(args, "am force-stop #{APK_PACKAGE}")
  shell(args, "rm -f #{APK_FILES}/#{EVENTS_FILE}")
  # 这一道自己声明输入：账清空了就把「现在是哪一档」也摆回去——前一道自检（换这一档）会把它留在别人身上。
  shell(args, "echo member:kid > #{APK_FILES}/youban-profile.txt")
  shell(args, "am start -n #{APK_PACKAGE}/.MainActivity")
  sleep 2
  SEED_EVENTS.each do |kind, ms|
    shell(args, "am broadcast -n #{APK_PACKAGE}/.StateReceiver -a com.youban.STATE " \
                 "--es kind #{kind} --es profile member:kid --el ms #{ms} --el pauseMs 0")
  end
  sleep 2
  events = shell(args, "cat #{APK_FILES}/#{EVENTS_FILE}").gsub(/\r/, '')
  return [false, '设备上没有事件账，算不出结论'] if events.strip.empty?

  mine = KernelFromEvents.call(events, device_plans(args))
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

# 装到设备上的包不许比仓库里编译出来的那份旧：装错了版本会伪装成「判定错了」（F20 那一类坑，
# 这次是手机装了旧包，8 步全红，看着像内核少实现了一条）。
def probe_apk(args)
  local = File.join(ROOT, 'device/android/out/youban-tv.apk')
  return [false, "本地没有编译产物 #{local}（先跑 device/android/build-apk.sh）"] unless File.exist?(local)

  path = (shell(args, 'dumpsys package com.youban.tv').gsub(/
/, ''))[/codePath=(\S+)/, 1]
  return [false, '读不到设备上这个包装在哪（装了吗？）'] unless path

  remote = (shell(args, "md5sum #{path}/base.apk")[/\h{32}/])
  if remote
    mine = Digest::MD5.file(local).hexdigest
    return [false, "设备上装的不是这份编译产物（md5 不同），先 install -r 再测"] unless remote == mine
    [true, "装的就是这份编译产物（md5 一致）"]
  else
    size = (shell(args, "stat -c %s #{path}/base.apk")[/\d+/]).to_i
    return [false, '设备上算不了 md5，也比不出大小'] if size.zero?
    mine = File.size(local)
    return [false, "设备上装的包大小 #{size}，与这份编译产物 #{mine} 不同，先 install -r 再测"] unless size == mine
    [true, "md5 这条设备不认，退而比大小：#{mine} 字节一致"]
  end
end

# 按键 → 事件 → 设备上的内核重算：这条是 M3 里「按键进了账」那半边的验收。
# 只看账里多了一行不够——得看结论跟着变了，而且变得跟规范模型一样（D50）。
def probe_key(args)
  # 广播之间留一点间隔：这几条是并发的，账是追加式的，挤在一起会丢（F20）。
  return [false, '没装 com.youban.tv：先 sh device/android/build-apk.sh && adb install -r'] if
    shell(args, "pm list packages #{APK_PACKAGE}").strip.empty?

  profile = 'member:kid'
  shell(args, "am force-stop #{APK_PACKAGE}")
  shell(args, "rm -f #{APK_FILES}/#{EVENTS_FILE}")
  # 先起应用再广播：被 force-stop 的应用处在 stopped 状态，广播会被直接丢掉（F20 那一坑）。
  # 用 WAKEUP(224) 不用 POWER(82)：82 是「切换」，屏本来就醒着时它把手机屏按熄了——
  # 应用进了 onPause，后面的按键就没人接（真机上踩过，见 F22）。
  shell(args, 'input keyevent 224')
  shell(args, "am start -n #{APK_PACKAGE}/.MainActivity")
  sleep 2
  broadcast(args, %w[--es kind WATCHED --es profile] + [profile] + %w[--el ms 1800000])
  broadcast(args, %w[--es kind MOTION --es profile] + [profile] + %w[--es fieldKind pause --el pauseMs 900000])
  broadcast(args, %w[--es kind MOTION_UNANSWERED --es profile] + [profile] + %w[--es fieldKind pause])
  sleep 3
  before = device_state(args)
  return [false, '按键前设备没出结论'] unless before
  return [false, "按键前不该是空的：pendingMotion=#{before['pendingMotion'].inspect}"] unless
    before.dig('pendingMotion', 'kind').to_s == 'pause'

  shell(args, 'input keyevent 23') # 确认键：这一步要落进账，不是落一条回执
  sleep 2
  after = device_state(args)
  return [false, '按键后设备没重算出结论'] unless after

  ledger = shell(args, "cat #{APK_FILES}/#{EVENTS_FILE}")
  unless ledger.include?('"kind":"MOTION_SETTLED"')
    top = shell(args, 'dumpsys window windows').gsub(/\r/, '')[/mCurrentFocus=\S+/].to_s
    got = shell(args, "cat #{APK_FILES}/youban-input.json").lines.last.to_s.strip
    return [false, "确认键没落进事件账——按键不许只落回执｜这一会儿前台是 #{top.empty? ? '读不到' : top.split('=').last}，"                     "按键本身到了吗：#{got.empty? ? '没落 input.json' : got}"]
  end
  if after['pendingMotion']
    return [false, "受理之后还挂着一条要受理的动议：#{after['pendingMotion'].inspect}"]
  end
  unless after['status'].to_s == 'honored' && after['tier'].to_s == 'L1.5'
    return [false, "受理后结论没跟着变：#{after['status']} · #{after['tier']}"]
  end

  mine = KernelFromEvents.call(ledger, device_plans(args))
  return [false, "Mac 这边的规范模型没出结论：%s" % mine] unless mine.is_a?(Hash)
  fields = JSON.parse(File.read(File.join(ROOT, 'contract/contract.json')))['commitState']['fields']
  diff = fields.reject { |k| JSON.parse(JSON.generate(mine[k] || mine[k.to_sym])) == after[k] }
  return [false, "按键之后的结论与规范模型不同：#{diff.join(', ')}"] unless diff.empty?

  [true, "确认键落账→内核重算：受理前挂着 pause，受理后 #{after['status']} · #{after['tier']}，"         "#{fields.size} 个字段与规范模型逐位相同"]
end

# 首启那六步在真机上走完：确认键进流程 → 一路确认到底 → PLAN_SIGNED 落账 → 「未签」那一栏消失。
# 这一条不许用 Mac 画好的卡代替：问什么、有哪些可选，都得是设备上的内核从契约里给的（AGREE-05）。
def probe_setup(args)
  return [false, '没装 com.youban.tv：先 sh device/android/build-apk.sh && adb install -r'] if
    shell(args, "pm list packages #{APK_PACKAGE}").strip.empty?

  shell(args, "am force-stop #{APK_PACKAGE}")
  shell(args, "rm -f #{APK_FILES}/#{EVENTS_FILE} #{APK_FILES}/youban-plan.json")
  shell(args, 'input keyevent 224') # 用 WAKEUP，不用 POWER：见 F22
  shell(args, "am start -n #{APK_PACKAGE}/.MainActivity")
  sleep 4
  before = device_state(args)
  return [false, '起屏没出结论'] unless before
  unless before['nextAction'].to_s == 'agreement'
    return [false, "什么约定都没有时起屏该指向立约定：#{before['nextAction'].inspect}"]
  end

  pressed = 0
  until shell(args, "grep -c PLAN_SIGNED #{APK_FILES}/#{EVENTS_FILE}").to_i.positive?
    break if pressed >= 12

    shell(args, 'input keyevent 23')
    pressed += 1
    sleep 1
  end
  ledger = shell(args, "cat #{APK_FILES}/#{EVENTS_FILE}")
  return [false, "按了 #{pressed} 次确认键，账里还是没有 PLAN_SIGNED"] unless ledger.include?('PLAN_SIGNED')

  after = device_state(args)
  return [false, '签完之后设备没重算出结论'] unless after
  if after['nextAction'].to_s == 'agreement'
    return [false, '签过了却还指着立约定那一步']
  end
  if Array(after['panels']).any? { |x| x.to_s.include?('未签') }
    return [false, "签过了那一栏还在：#{after['panels'].inspect}"]
  end

  mine = KernelFromEvents.call(ledger, device_plans(args))
  return [false, "Mac 这边的规范模型没出结论：%s" % mine] unless mine.is_a?(Hash)
  fields = JSON.parse(File.read(File.join(ROOT, 'contract/contract.json')))['commitState']['fields']
  diff = fields.reject { |k| JSON.parse(JSON.generate(mine[k] || mine[k.to_sym])) == after[k] }
  return [false, "签完之后与规范模型不同：#{diff.join(', ')}"] unless diff.empty?

  [true, "六步走完写了 PLAN_SIGNED(v1)（#{pressed} 下确认键），"         "签过之后 #{fields.size} 个字段与规范模型逐位相同，那一栏消失了"]
end

# 换这一档在真机上是一条事件加一组约定的加载：另一档没签过，下一步又回到立约定（AGREE-08、AGREE-09）。
def probe_switch(args)
  return [false, '没装 com.youban.tv：先 sh device/android/build-apk.sh && adb install -r'] if
    shell(args, "pm list packages #{APK_PACKAGE}").strip.empty?

  shell(args, "am force-stop #{APK_PACKAGE}")
  shell(args, "rm -f #{APK_FILES}/#{EVENTS_FILE} #{APK_FILES}/youban-plan*.json #{APK_FILES}/youban-profile.txt")
  shell(args, 'input keyevent 224')
  shell(args, "am start -n #{APK_PACKAGE}/.MainActivity")
  sleep 3
  [['WATCHED', 'member:kid', '--el ms 1800000'],
   ['PLAN_SIGNED', 'member:kid', '--el version 3'],
   ['WATCHED', 'member:dad', '--el ms 600000']].each do |kind, who, extra|
    broadcast(args, ['--es', 'kind', kind, '--es', 'profile', who] + extra.split(' '))
    sleep 1
  end
  before = device_state(args)
  return [false, '起屏没出结论'] unless before
  return [false, "起屏该在 #{before['activeProfile']}"] unless before['activeProfile'].to_s.end_with?('kid')

  # INFO 打开那一屏 → INFO 挪到另一档 → INFO 切过去（壳层上确认键只管选与签）。
  3.times do
    shell(args, 'input keyevent 165') # INFO：开那一屏 → 挪到另一档 → 切过去
    sleep 1
  end
  ledger = shell(args, "cat #{APK_FILES}/#{EVENTS_FILE}")
  return [false, '换这一档没落 PROFILE_SWITCH'] unless ledger.include?('PROFILE_SWITCH')
  unless ledger.include?('"to":"member:dad"')
    return [false, "PROFILE_SWITCH 没写到另一档：#{ledger.lines.last.to_s.strip}"]
  end

  after = device_state(args)
  return [false, '切过去之后设备没重算出结论'] unless after
  unless after['activeProfile'].to_s.end_with?('dad')
    return [false, "切了但这一屏还是 #{after['activeProfile'].inspect}"]
  end
  unless after['nextAction'].to_s == 'agreement'
    return [false, "另一档没签过，下一步该指回立约定：#{after['nextAction'].inspect}"]
  end
  unless Array(after['panels']).any? { |x| x.to_s.include?('未签') }
    return [false, "另一档没签过却没有那一栏：#{after['panels'].inspect}"]
  end

  mine = KernelFromEvents.call(ledger, device_plans(args))
  return [false, "Mac 这边的规范模型没出结论：%s" % mine] unless mine.is_a?(Hash)
  fields = JSON.parse(File.read(File.join(ROOT, 'contract/contract.json')))['commitState']['fields']
  diff = fields.reject { |k| JSON.parse(JSON.generate(mine[k] || mine[k.to_sym])) == after[k] }
  return [false, "切过去之后与规范模型不同：#{diff.join(', ')}"] unless diff.empty?

  [true, "PROFILE_SWITCH 落账→加载那一组：kid 签过的不算 dad 签的，下一步回到立约定，" \
        "#{fields.size} 个字段与规范模型逐位相同"]
end

PROBES = { 'input' => method(:probe_input), 'text' => method(:probe_text),
           'glyphs' => method(:probe_glyphs), 'state' => method(:probe_state),
           'apk' => method(:probe_apk), 'key' => method(:probe_key),
           'setup' => method(:probe_setup), 'switch' => method(:probe_switch) }.freeze

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
  puts '这验的是「事实 → 设备上的内核 → 落层 → 措辞 → 屏上自证」这条链在真机上对；' \
       '设备侧走的是装了 APK 的那条，不再是 Mac 画卡推相册（那是呈现通路演练，见 F15）。'
else
  puts "电视端设备测试：#{fails.size} 步没过——#{fails.join(', ')}"
end
exit(fails.empty? ? 0 : 1)
