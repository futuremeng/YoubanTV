#!/usr/bin/env ruby
# 把内核的 CommitState 显示到一台真机上：这是**呈现通路演练**，不是 M3 的设备端界面。
# 差别要写清：M3 的界面是 device/ 的 tv 装配（现在还没有），这里只是用 adb 把一块网页推到
# 当时在线的那台设备上，用来验证「判定 → 落层 → 这一层该说什么」这条链在真机上对不对。
# 文案按 docs/LAYERING.md §4 那一处规则生成；不出现连续、成就、催促这类东西（PRODUCT §2）。
#
# 用法：
#   ruby tools/tv-present.rb fixtures/layer.yaml LAYER-07 --serial=192.168.1.44:5555
#   ruby tools/tv-present.rb --given='{"profile":"member:kid","watchedMs":4200000}' --when='{"mode":"ambient"}'
#   ruby tools/tv-present.rb fixtures/commit.yaml COMMIT-04 --shot=/tmp/tv.png
# 常用开关：--serial= 设备；--shot= 拉一张截图；--force-stop= 先关掉前台那个应用
#            （不然浏览器会把上一轮的页面留着，看到旧结论——F12 那条老教训）；
#            --font= 设备上可用的中文字体路径；--no-font 不加字体引用。
require 'json'
require 'yaml'
require 'fileutils'
require 'tempfile'
require_relative 'run-fixtures'

REMOTE = '/sdcard/Download/youban-status.html'
CAPTURE = '/sdcard/Download/youban-cap.png'
LOCAL_CAPTURE = '/tmp/youban-present-cap.png'

# 页面底色深灰：画面平均亮度低于这条线才算真的画出来了，白页会接近 255。
DARK_MAX = 200

def dark_enough?
  return false unless File.exist?(LOCAL_CAPTURE)

  stat = IO.popen(['ffmpeg', '-hide_banner', '-i', LOCAL_CAPTURE,
                   '-vf', 'signalstats,metadata=print:key=lavfi.signalstats.YAVG', '-f', 'null', '-'],
                  err: %i[child out], &:read)
  yavg = stat[/YAVG[=:]\s*([\d.]+)/, 1]
  yavg && yavg.to_f < DARK_MAX
end

# 设备上没有中文字形时整页会变成方块——在 Smartisan OD103 的自带浏览器上实测到过（见
# docs/facts/DEVICES.md）。这几个路径按「先找得到谁就用谁」的顺序试，都找不到就明说渲染不出。
CJK_FONTS = %w[/system/fonts/DroidSansFallback.ttf /system/fonts/NotoSansCJK-Regular.ttc
               /system/fonts/NotoSansCJKsc-Regular.otf].freeze

def parse_args(argv)
  out = { serial: nil, shot: nil, given: nil, when_: '{}', force_stop: true, font: nil }
  rest = argv.reject { |a| a.start_with?('--') }
  argv.each do |a|
    case a
    when /\A--serial=(.*)/ then out[:serial] = Regexp.last_match(1)
    when /\A--shot=(.*)/ then out[:shot] = Regexp.last_match(1)
    when /\A--given=(.*)/ then out[:given] = JSON.parse(Regexp.last_match(1))
    when /\A--when=(.*)/ then out[:when_] = Regexp.last_match(1)
    when /\A--font=(.*)/ then out[:font] = Regexp.last_match(1)
    when '--no-font' then out[:font] = false
    when '--no-restart' then out[:force_stop] = false
    end
  end
  [out, rest]
end

def round_for(args, rest)
  return [args[:given] || {}, JSON.parse(args[:when_])] if args[:given]

  file, id = rest
  abort '用法：tv-present.rb <fixtures/x.yaml> <ID[.n]> | --given=… --when=…' unless file && id

  doc = YAML.load_file(file)
  _, body = doc.find { |k, _| k == id.split('.').first }
  abort "#{id} 不在 #{file} 里" unless body

  cs = body['cases'][(id.include?('.') ? id.split('.').last.to_i : 1) - 1]
  [(body['given'] || {}).merge(cs['given'] || {}), cs['when'] || {}]
end

def adb(args, *cmd)
  require 'shellwords'
  full = (['adb'] + (args[:serial] ? ['-s', args[:serial]] : []) + cmd).shelljoin
  [`#{full} 2>&1`, $?.success?]
end

# 措辞只按 LAYERING §4 那一处规则拼：状态 + 恢复/下一步，不指责、不催促、不承诺兑换。
def sentence(st, world)
  watched = world.value_for('watchedMs').to_i / 60_000
  allowance = world.value_for('allowanceMs').to_i / 60_000
  return '还没有选身份：这一条只记在账上，不做判定。' if st['activeProfile'].nil?

  base = "今天已看 #{watched} 分钟，约定 #{allowance} 分钟。"
  if st['due']
    back = "这一组答完（#{st['due']['deficit']['amount']} #{st['due']['deficit']['unit']}）就记为已完成。"
    st['due']['mode'] == 'focused' ? "#{base}#{back}" : "#{base}有一组题待做，现在做吗？"
  elsif st['status'] == 'overdue'
    over = world.value_for('overMs').to_i / 60_000
    "超出约定 #{over} 分钟。今天已按约定使用完。"
  else
    left = world.value_for('remainingMs')
    left ? "#{base}还剩 #{left.to_i / 60_000} 分钟。" : "#{base}这一条按约定使用完了。"
  end
end

def font_face(args)
  return '' if args[:font] == false

  path = args[:font] || CJK_FONTS.find { |f| adb(args, 'shell', 'test', '-f', f)[1] }
  # 找不到中文字形就明说：宁可少显示，也不给一台只会画方块的设备伪造「已显示」。
  @font_note = path ? nil : '这台设备的系统字体里没有中文字形，页面上会是方块——换字体或换设备再看'
  # !important 是必要的：下面的 body 规则在后面，同优先级会把字体盖掉（实测整页变方块）。
  path ? "@font-face{font-family:yb;src:url(file://#{path})}body{font-family:yb,sans-serif !important}" : ''
end

def page(st, world, css = '')
  due = st['due']
  badge = %(<div class="badge">#{st['tier']} · #{due ? '到期' : '无到期项'}</div>)
  sheet = if due && due['mode'] == 'focused'
            %(<div class="sheet"><b>这一组答完就记为已完成</b><div>还差 #{due['deficit']['amount']} #{due['deficit']['unit']}</div></div>)
          else
            ''
          end
  reason = st['fallbackReason'] ? %(<div class="reason">本机没有按约定请求到暂停，已改为不打断观看的提示。</div>) : ''
  <<~HTML
    <!doctype html><meta charset="utf-8"><title>伴看板状态</title>
    <style>
      #{css}
      body{margin:0;background:#101014;color:#f2f2f5;font-size:28px;line-height:1.6}
      .wrap{padding:6vh 6vw;min-height:88vh;display:flex;flex-direction:column;justify-content:center}
      .badge{position:fixed;top:3vh;right:3vw;font-size:24px;opacity:.75;border:1px solid #444;border-radius:8px;padding:.2em .6em}
      .sheet{position:fixed;left:50%;bottom:6vh;transform:translateX(-50%);background:#1b1b22;border:1px solid #3a3a46;
             border-radius:12px;padding:2vh 3vw;max-width:70vw}
      .reason{margin-top:2vh;font-size:24px;opacity:.8}
      .line{font-size:44px;max-width:80vw}
      .foot{margin-top:3vh;font-size:22px;opacity:.55}
    </style>
    <div class="wrap">
      <div class="line">#{sentence(st, world)}</div>
      #{reason}
      <div class="foot">落层 #{st['tier']} · 强度天花板 #{st['tierCeiling']}</div>
      #{badge}
      #{sheet}
    </div>
  HTML
end

args, rest = parse_args(ARGV)
given, when_ = round_for(args, rest)
world = World.new(given)
abort "状态键 #{world.unconsumed.join(', ')} 模型尚未消费，不硬凑结论" unless world.unconsumed.empty?

world.apply(when_)
st = world.commit_state
puts JSON.pretty_generate(st)

css = font_face(args)
html = page(st, world, css)
file = Tempfile.new(['youban-status', '.html'])
file.write(html)
file.close

_out, ok = adb(args, 'push', file.path, REMOTE)
abort "推不到设备：#{_out.strip}（设备是否在线？adb devices 里有没有它）" unless ok

if args[:force_stop]
  focus, = adb(args, 'shell', 'dumpsys', 'window')
  pkg = focus[/mCurrentFocus=.*?\s([\w.]+)\//, 1]
  if pkg
    adb(args, 'shell', 'am', 'force-stop', pkg)
    puts "先关掉前台的 #{pkg}：不关就会看到上一轮留下的页面（F12 的老教训）"
    sleep 2 # 立刻 start 会和冷启动抢时序，拿到的是白页（实测见过）
  end
end
launch = ['shell', 'am', 'start', '-a', 'android.intent.action.VIEW',
          '-d', "file://#{REMOTE}", '-t', 'text/html']
# 同一台机器上常装两个浏览器：Chromium 会按同源策略挡掉 file:// 页面里的字体引用，整页变方块；
# 系统自带那个不挡。装得下就指名它，并在结论里说清是谁画的这一屏。
list_out, = adb(args, 'shell', 'pm', 'list', 'packages')
browser = %w[com.android.browser com.android.htmlviewer].find { |pkg| list_out.include?(pkg) }
if browser
  launch += ['-p', browser]
  puts "指名由 #{browser} 显示（Chromium 会挡 file:// 的字体引用，中文会变方块）"
end
# 「受理了」不等于「画出来了」：冷启动的浏览器会先给一张白页（实测见过），所以这里等的是画面本身。
launch << '-W' # -W 等启动完成再返回，免得和冷启动抢时序
_out, ok = adb(args, *launch)
abort "设备没能受理这个打开请求：#{_out.strip}\n这条链在真机上还没验证过，不用截图假装已显示。" unless ok
if args[:force_stop]
  focus, = adb(args, 'shell', 'dumpsys', 'window')
  puts "前台窗口：#{focus[/mCurrentFocus=.*?\s([\w.]+)\//, 1] || '看不出来'}"
end

# 页面底色是深灰，白页的平均亮度接近 255：拿它当「确实画出来了」的判据（F12 同一条纪律）。
drawn = nil
10.times do
  FileUtils.rm_f(LOCAL_CAPTURE)
  adb(args, 'shell', 'screencap', '-p', CAPTURE)
  adb(args, 'pull', CAPTURE, LOCAL_CAPTURE)
  drawn = dark_enough?
  break if drawn

  sleep 1
end
abort '页面没有画出来（一直是白页）：这条链在这台设备上没走通，不用截图假装成功。' unless drawn

if args[:shot]
  adb(args, 'shell', 'cp', CAPTURE, '/sdcard/Download/youban-status.png')
  _out, ok = adb(args, 'pull', '/sdcard/Download/youban-status.png', args[:shot])
  puts(ok ? "截图：#{args[:shot]}" : "截图失败：#{_out}")
end
puts "已推到 #{args[:serial] || '默认设备'}：#{REMOTE}（呈现通路演练，不是 M3 的界面）"
puts "注意：#{@font_note}" if @font_note
