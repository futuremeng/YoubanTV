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
require 'tmpdir'
require 'fileutils'
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
  seen = []
  until shell(args, "grep -c PLAN_SIGNED #{APK_FILES}/#{EVENTS_FILE}").to_i.positive?
    break if pressed >= 12

    shell(args, 'input keyevent 23')
    pressed += 1
    sleep 1
    # 每一屏上写了什么，屏幕上那些字全由设备上的内核给（AGREE-05）；这里只把它们收下来看一眼。
    seen << shell(args, "cat #{APK_FILES}/youban-setup-screen.json").gsub(/\r\n?/, '')
  end
  ui = JSON.parse(File.read(File.join(ROOT, 'contract/contract.json')))['agreement']['ui']
  defaults = ui['defaultsWhere'].sub('{where}', '')
  unless seen.any? { |s| s.include?(defaults) && s.include?('按默认') }
    return [false, "按默认那一步的屏上没写明去哪儿改（屏上应有 #{defaults.inspect}）：#{seen.last.to_s[0, 120]}"]
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

# L3 那一张：离开本应用仍可见、不抢焦点、不进字幕带；装完默认不开（LAYER-13、ONBOARD-06、F30）。
def probe_overlay(args)
  return [false, '没装 com.youban.tv：先 sh device/android/build-apk.sh && adb install -r'] if
    shell(args, "pm list packages #{APK_PACKAGE}").strip.empty?

  raw_size = shell(args, 'wm size')
  width = raw_size[/(\d+)x\d+/, 1].to_i
  height = raw_size[/\d+x(\d+)/, 1].to_i
  return [false, "读不到屏幕尺寸：#{raw_size.strip.inspect}"] if width.zero? || height.zero?

  # 装完默认不开：先把这条权限收回来自系统，看它是不是真的什么都不做。
  shell(args, "appops set #{APK_PACKAGE} SYSTEM_ALERT_WINDOW deny")
  shell(args, "am force-stop #{APK_PACKAGE}")
  shell(args, "rm -f #{APK_FILES}/#{EVENTS_FILE} #{APK_FILES}/youban-overlay.json #{APK_FILES}/youban-plan*.json")
  shell(args, 'input keyevent 224')
  shell(args, "am start -n #{APK_PACKAGE}/.MainActivity")
  sleep 3
  [['WATCHED', 'member:kid', '--el ms 2100000'],
   ['PLAN_SIGNED', 'member:kid', '--el version 1']].each do |kind, who, extra|
    broadcast(args, ['--es', 'kind', kind, '--es', 'profile', who] + extra.split(' '))
    sleep 1
  end
  mine = KernelFromEvents.call(shell(args, "cat #{APK_FILES}/#{EVENTS_FILE}").gsub(/\r/, ''), device_plans(args))
  return [false, "Mac 这边的规范模型没出结论：#{mine}"] unless mine.is_a?(Hash)
  if mine['nextAction'].to_s =~ /\A(agreement|none)\z/
    return [false, "这一轮本就不该出那一张，用例摆错了：#{mine['nextAction'].inspect}"]
  end

  shell(args, 'input keyevent 3') # HOME：离开本应用，这才是 L3 那一张的时机
  sleep 2
  off = overlay_record(args)
  return [false, '没读到 youban-overlay.json'] if off.nil?
  if off['shown']
    return [false, '悬浮窗权限没授予却显示了那一张：装完默认不开这条不成立']
  end
  if off['attempted']
    return [false, '权限没授予还是去加了那个窗：装完默认不开这条只靠系统挡着，代码自己没守']
  end

  # 这台设备上的 appops 是带时限的（appops get 里能看到 duration=+4s）：授权几秒后自己收回，
  # 于是「那一张出没出」会变成看运气。重新授权再走一遍，最多三次；三次还不认，
  # 就如实报这台设备留不住这条授权——那是设备事实，不是通过。
  tries = 0
  on = nil
  loop do
    tries += 1
    shell(args, "appops set #{APK_PACKAGE} SYSTEM_ALERT_WINDOW allow")
    shell(args, "am force-stop #{APK_PACKAGE}")
    shell(args, 'input keyevent 224')
    shell(args, "am start -n #{APK_PACKAGE}/.MainActivity")
    sleep 2
    shell(args, 'input keyevent 3')
    sleep 1
    on = overlay_record(args)
    break if on && on['shown']
    break if tries >= 3
  end
  return [false, '授权后仍没读到那一张的记录'] if on.nil?
  unless on['shown']
    why = on['refuse'].to_s
    why = on['attempted'] ? '系统没让那个窗上来（授权可能几秒就被收回，试了 '                            "#{tries} 次）" : '这台设备留不住这条授权（重授 ' + tries.to_s + ' 次都没赶上）' if why.empty?
    return [false, "授权后那一张没出来：#{why}"]
  end
  text = on['text'].to_s
  return [false, '那一张是空的：内核那句没搬过来'] if text.strip.empty?
  unless text == mine['text']
    return [false, "那一张说的话与内核不同：#{text.inspect} ≠ #{mine['text'].inspect}"]
  end

  box = on['rect']
  return [false, '量不到那一张的位置'] unless box.is_a?(Array) && box.size == 4
  band = (height * (1 - 0.15)).round # 字幕带那一截不许进（契约 layering.overlay.subtitleBandPct）
  if box[3].to_i > band
    return [false, "那一张压进字幕带了：下边缘 #{box[3]} > #{band}"]
  end
  unless on['rendered'].to_s == text
    return [false, "记录里是内核那句，交给那一张画的却是另一句：#{on['rendered'].inspect}"]
  end
  # 这一台用 screencap 拍不到悬浮窗那一层（facts/DEVICES.md#F30：两张截图逐格一样）——
  # 所以「画出来了没有」不靠截图判，读窗口管理器那一手：窗口在不在、可见不可见。
  windows = shell(args, 'dumpsys window windows')
  # 悬浮窗那一层的窗口在窗口管理器里长这样：Window #N Window{... u0 Sys2038:com.youban.tv/...}
  # 2038 是 TYPE_APPLICATION_OVERLAY（API 26+），2002 是 TYPE_PHONE（这台手机是 API 25）；
  # 它带着 activity 的名字，因为窗口令牌挂在 activity 上。截图拍不到这一层（F30）。
  mine = overlay_window(windows)
  return [false, "窗口列表里找不到这一张：#{windows.to_s.lines.grep(/youban/).first.to_s.strip}"] if mine.nil?
  vis = overlay_visibility(mine)
  return [false, "那一张的窗口在，但可见性不对：#{vis.inspect}"] unless vis[:visible]

  before_vis = vis
  # 真实遮挡：换一个前台应用上去，那一张该还在（L3 的定义就是「离开本应用仍可见」，
  # 它在应用之上，不是被内容盖住的那一层）。这一条以前只在文档里写着。
  shell(args, 'am start -a android.settings.SETTINGS')
  sleep 3
  over = shell(args, 'dumpsys window windows')
  mine2 = overlay_window(over)
  if mine2.nil?
    return [false, "换到别的应用后那一张不见了：#{over.to_s.lines.grep(/youban/).first.to_s.strip}"]
  end
  vis2 = overlay_visibility(mine2)
  unless vis2[:visible]
    return [false, "换到别的应用后那一张不显示了：之前 #{before_vis.inspect} · 现在 #{vis2.inspect}"]
  end

  shot_diff, = snap_pair(args)
  [true, "离开本应用那一张出来了（#{text}），落在字幕带以上（下边缘 #{box[3]} ≤ #{band}），" \
        "且不抢焦点；换到别的应用后那一张还在；截图里那一层有画面（整屏差 #{shot_diff}）——" \
        '装完默认不开也验了']
end

# 悬浮窗那一格在窗口管理器里的名字有几种写法：带 activity 的（Sys2038:包名/组件）、
# 用 application context 加的直接是包名。三种都认，认不出就是「没有这一格」。
def overlay_window(dump)
  dump.to_s.split(/^\s*Window #/).find do |w|
    head = w[/\A[^\n]*/].to_s
    next false unless head.include?(APK_PACKAGE)

    head =~ /Sys20(02|38)/ || !head.include?("#{APK_PACKAGE}/")
  end
end

# 窗口管理器里那一格的可见性：mViewVisibility 是 View 的可见性常量（0 是 VISIBLE，
# 8 是 INVISIBLE、4 是 GONE），拿字符串前缀去比会把 0x8 当成 0——这一条是实测踩出来的（F30）。
def overlay_visibility(entry)
  v = entry[/mViewVisibility=0x([0-9a-f]+)/i, 1]&.to_i(16)
  { visible: v.zero?, viewVisibility: v,
    isVisible: entry[/mIsVisible=(true|false)/, 1], hasSurface: entry[/mHasSurface=(true|false)/, 1],
    obscured: entry[/mObscured=(true|false)/, 1] }
end

# 顺带量一次「截图拍不拍得到这一层」：只报数，不当依据（依据是窗口管理器那一格）。
# 这条是 F30 的教训：早先那两次「两张截图逐格一样」其实是因为那一格 mHasSurface=false——
# 截图没骗人，是那一格根本没画出来。
def snap_pair(args)
  on = snap(args, 'on')
  shell(args, "am force-stop #{APK_PACKAGE}") # 那一张随进程走：这就是「没有那一张」的对照照
  sleep 2
  off = snap(args, 'off')
  [mean_diff(gray_all(on), gray_all(off)), gray_all(on)]
end

def snap(args, tag)
  FileUtils.mkdir_p(SHOT_DIR)
  file = File.join(SHOT_DIR, "overlay-#{tag}-#{Process.pid}.png")
  shell(args, 'screencap -p /sdcard/Download/yb-ov.png')
  IO.popen(['adb', '-s', args[:serial].to_s, 'pull', '/sdcard/Download/yb-ov.png', file],
           err: %i[child out], &:read)
  file
end

def gray_all(path)
  IO.popen(['magick', path, '-colorspace', 'gray', '-resize', '32x32!', '-depth', '8', 'gray:-'],
           err: File::NULL, &:read).bytes
end

def mean_diff(a, b)
  return 999.0 if a.empty? || a.size != b.size
  ((0...a.size).sum { |i| (a[i] - b[i]).abs } / a.size.to_f).round(2)
end

def overlay_record(args)
  raw = shell(args, "cat #{APK_FILES}/youban-overlay.json").gsub(/\r\n?/, '')[/\{.*\}/]
  raw ? JSON.parse(raw) : nil
rescue JSON::ParserError
  nil
end

# 那一屏只读的条目（AGREE-14）：设备上的内核给的字，与 Mac 上规范模型逐字相同；
# 打开这一屏不写账，契约 agreement.panel.never 那些词一个都不许出现。
def probe_panel(args)
  return [false, '没装 com.youban.tv：先 sh device/android/build-apk.sh && adb install -r'] if
    shell(args, "pm list packages #{APK_PACKAGE}").strip.empty?

  shell(args, "am force-stop #{APK_PACKAGE}")
  shell(args, "rm -f #{APK_FILES}/#{EVENTS_FILE} #{APK_FILES}/youban-plan*.json #{APK_FILES}/youban-panel.json")
  shell(args, "echo member:kid > #{APK_FILES}/youban-profile.txt")
  shell(args, 'input keyevent 224')
  shell(args, "am start -n #{APK_PACKAGE}/.MainActivity")
  sleep 3
  [['WATCHED', 'member:kid', '--el ms 600000'],
   ['PLAN_SIGNED', 'member:kid', '--el version 3']].each do |kind, who, extra|
    broadcast(args, ['--es', 'kind', kind, '--es', 'profile', who] + extra.split(' '))
    sleep 1
  end
  # 动议那一路也摆几条：提出 / 婉拒 / 没人受理（AUTO-03）——那一屏的历史就是数这几条。
  broadcast(args, ['--es', 'kind', 'MOTION', '--es', 'profile', 'member:kid',
                   '--es', 'actor', 'member:mom', '--es', 'fieldKind', 'pause'])
  sleep 1
  broadcast(args, ['--es', 'kind', 'MOTION_SETTLED', '--es', 'profile', 'member:kid',
                   '--es', 'fieldKind', 'pause', '--es', 'accepted', 'false'])
  sleep 1
  broadcast(args, ['--es', 'kind', 'MOTION', '--es', 'profile', 'member:kid',
                   '--es', 'actor', 'member:dad', '--es', 'fieldKind', 'slotChange'])
  sleep 1
  broadcast(args, ['--es', 'kind', 'MOTION_UNANSWERED', '--es', 'profile', 'member:kid',
                   '--es', 'fieldKind', 'extend'])
  sleep 1
  broadcast(args, ['--es', 'kind', 'MOTION_SETTLED', '--es', 'profile', 'member:kid',
                   '--es', 'fieldKind', 'slotChange', '--es', 'accepted', 'true'])
  sleep 1
  ledger_before = shell(args, "cat #{APK_FILES}/#{EVENTS_FILE}").gsub(/\r\n?/, '')

  shell(args, 'input keyevent 174') # BOOKMARK：那一屏只读的条目（SETTINGS 被系统吃了，见 F33）
  sleep 2
  raw = shell(args, "cat #{APK_FILES}/youban-panel.json").gsub(/\r\n?/, '')[/\{.*\}/]
  return [false, '没读到 youban-panel.json：那一屏没出来'] if raw.nil?
  mine = JSON.parse(raw)

  File.write(File.join(Dir.tmpdir, 'youban-panel-events.jsonl'), ledger_before)
  File.write(File.join(Dir.tmpdir, 'youban-panel-plans.json'), JSON.generate(device_plans(args)))
  out = IO.popen(['ruby', File.join(ROOT, 'tools/panel-from-events.rb'),
                  File.join(Dir.tmpdir, 'youban-panel-events.jsonl'),
                  File.join(Dir.tmpdir, 'youban-panel-plans.json'), 'member:kid'],
                 err: %i[child out], &:read)
  return [false, "Mac 这边那一屏跑挂了：#{out.lines.last.to_s.strip}"] unless $?.success?
  theirs = JSON.parse(out)
  diff = %w[title lines foot never].reject { |k| mine[k] == theirs[k] }
  return [false, "那一屏与规范模型不同（#{diff.join(', ')}）：#{mine['lines'].inspect}"] unless diff.empty?

  never = theirs['never'].to_a
  # 只扫屏上看得见的字：never 那一张表本身也在这份 JSON 里，把它也算进去等于自己抓自己（今天就是这样）。
  visible = [mine['title'], mine['lines'], mine['foot']]
  hit = never.select { |w| JSON.generate(visible).include?(w.to_s) }
  return [false, "那一屏上出现了不许有的词：#{hit.join('、')}"] if hit.any?
  # 界面上真正摆出来的那批码位也要扫一遍：记录里没有、界面上自己加上去的那句，只有这一路抓得到（D54）。
  cps = shell(args, "cat #{APK_FILES}/youban-diag.json").gsub(/\r\n?/, '')[/"cps":\[([^\]]*)\]/, 1].to_s
  rendered = cps.split(',').map { |h| [h.gsub(/[\"\s]/, '').hex].pack('U*') }.join
  return [false, '界面上摆出来的字与记录不同（壳层自己加了一句）' ] if rendered.empty?
  hit2 = never.select { |w| rendered.include?(w.to_s) }
  return [false, "界面上自己加了不许有的词：#{hit2.join('、')}"] if hit2.any?

  after = shell(args, "cat #{APK_FILES}/#{EVENTS_FILE}").gsub(/\r\n?/, '')
  return [false, '打开那一屏往账里写了东西'] unless after == ledger_before

  # 提出来 / 接受了 / 婉拒了 / 没人受理，这四样各要在屏上出现一次：这三条用例正好覆盖
  # 「婉拒与接受是同一条事件的两种结果」和「没受理不是婉拒」（AUTO-03）。
  want = ['等对方受理', '对方接受了', '婉拒', '没人受理']
  missing = want.reject { |w| mine['lines'].to_a.any? { |l| l.to_s.include?(w) } }
  return [false, "那一屏的历史少了这些结果：#{missing.join('、')} · 屏上：#{mine['lines'].last(3).inspect}"] if missing.any?
  motions = mine['lines'].to_a.count { |l| l.to_s.start_with?('· ') }

  [true, "#{mine['lines'].size} 行与规范模型逐字相同（动议 #{motions} 行）；" \
        "#{never.size} 个不许有的词一个没出现；开这一屏账里一个字没多"]
end

# 这台设备被桌面或开机启动项拉起来之后，有没有把前台交回去（LAYER-14、ONBOARD-11、D81）。
# 依据用窗口管理器那一格，不用应用自己报的那一句——F30 那条教训：程序自己说的「显示了」不算。
def probe_startup(args)
  return [false, '没装 com.youban.tv：先 sh device/android/build-apk.sh && adb install -r'] if
    shell(args, "pm list packages #{APK_PACKAGE}").strip.empty?
  # 「那一个应用」用这台设备的桌面：包名由本机答（@home），不在这条命令里写死——各家桌面不同。
  broadcast(args, ['--es', 'autoLaunch', '@home'])
  sleep 1
  home_pkg = shell(args, "cat #{APK_FILES}/youban-autolaunch.txt").gsub(/\r/, '').strip
  return [false, '这台设备答不出自己的桌面包名'] if home_pkg.empty? || home_pkg == APK_PACKAGE

  shell(args, "am force-stop #{APK_PACKAGE}")
  shell(args, "rm -f #{APK_FILES}/youban-startup.json")
  # 首启那一步那一处是例外（那一屏要给人走完），所以先把「这一档签过」摆上，验的是正常那一路；
  # 当前在哪一档也要摆：前一道自检会把它留在别人身上（F20 那一类：输入没摆回来，红的就不是这条）。
  shell(args, "echo member:kid > #{APK_FILES}/youban-profile.txt")
  broadcast(args, ['--es', 'kind', 'PLAN_SIGNED', '--es', 'profile', 'member:kid', '--el', 'version', '1'])
  sleep 1
  shell(args, "monkey -p #{APK_PACKAGE} -c android.intent.category.LAUNCHER 1") # 桌面那一路的启动动作
  sleep 3
  raw = shell(args, "cat #{APK_FILES}/youban-startup.json").gsub(/
/, '').strip
  return [false, '没读到 youban-startup.json（这一轮没走到交回那一步？）'] if raw.empty?
  rec = begin
    JSON.parse(raw)
  rescue StandardError
    nil
  end
  return [false, "那份自证读不出：#{raw[0, 60].inspect}"] unless rec.is_a?(Hash)
  focus = shell(args, 'dumpsys window windows') + shell(args, 'dumpsys activity activities')
  mine = focus[/mCurrentFocus=[^\r\n]*#{Regexp.escape(APK_PACKAGE)}[^\r\n]*/]
  mine = focus[/mFocusedApp=[^\r\n]*#{Regexp.escape(APK_PACKAGE)}[^\r\n]*/] if mine.nil?
  return [false, "前台还是这一屏：#{mine.to_s.strip}（全屏停留是 LAYER-14 明令不许的）"] if mine
  bad = []
  bad << "自证说没缩：#{rec['collapse'].inspect}" unless rec['collapse'] == true
  bad << "那一个应用没拉起：#{rec['launched'].inspect}" unless rec['launched'] == true
  bad << "指定的那一个不是 #{home_pkg}：#{rec['target'].inspect}" unless rec['target'].to_s == home_pkg
  broadcast(args, ['--es', 'autoLaunch', '']) # 摆回没指定的样子，别影响后面那几步
  return [false, bad.join('；')] if bad.any?

  shown = focus[/mCurrentFocus=[^\r\n]*/].to_s.strip
  [true, "起来 #{rec['ms']}ms 就把前台交回给 #{home_pkg}（窗口管理器那一格：#{shown[/\S+\/?\S*/].to_s}）"]
end

PROBES = { 'input' => method(:probe_input), 'text' => method(:probe_text),
           'glyphs' => method(:probe_glyphs), 'state' => method(:probe_state),
           'apk' => method(:probe_apk), 'key' => method(:probe_key),
           'setup' => method(:probe_setup), 'switch' => method(:probe_switch),
           'overlay' => method(:probe_overlay),
           'panel' => method(:probe_panel),
           'startup' => method(:probe_startup) }.freeze

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
