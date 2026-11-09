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
# 两条通路，按设备上「谁认领这个内容」自动选：能开 text/html 的走网页；一台都没有就走图片
# （本地把结论画成一张 1080p 的图，用设备上认 image/* 的应用打开）。都选不出来就报错，不硬演。
# 常用开关：--serial= 设备；--shot= 拉一张截图；--force-stop= 先关掉前台那个应用
#            （不然浏览器会把上一轮的页面留着，看到旧结论——F12 那条老教训）；
#            --font= 设备上可用的中文字体路径；--no-font 不加字体引用。
require 'json'
require 'yaml'
require 'fileutils'
require 'tempfile'
require_relative 'run-fixtures'

REMOTE = '/sdcard/Download/youban-status.html'
REMOTE_IMAGE = '/sdcard/Download/youban-status.png'
LOCAL_IMAGE = '/tmp/youban-status-card.png'
# 本地图形的字体：按 fontconfig 找一个带中文的；画出来是方块就说明这个字体不行（F15）。
FONT_NOTE = '`fc-list :lang=zh` 找得到谁就用谁，找不到就说画不出中文'
CAPTURE = '/sdcard/Download/youban-cap.png'
LOCAL_CAPTURE = '/tmp/youban-present-cap.png'

# 页面底色深灰：画面平均亮度低于这条线才算真的画出来了，白页会接近 255。
DARK_MAX = 200
# 16x16 灰度格的平均差阈值：载入中的黑屏与这张深色卡会差出几十，12 是留了余量的。
DIFF_MAX = 12.0

# 光「画面变暗」不够：电视的相册在载入时会先给一屏黑 + 转圈，亮度也是暗的（实测被它骗过一次）。
# 所以拿本地那张图和截屏各压成 16x16 灰度，比平均差；对不上就是没画到屏幕上。
def matches_card?(local_card)
  return nil unless File.exist?(local_card) && File.exist?(LOCAL_CAPTURE)

  a = gray_grid(local_card)
  b = gray_grid(LOCAL_CAPTURE)
  return nil if a.nil? || b.nil?

  (a.zip(b).sum { |x, y| (x - y).abs } / a.size).round(1)
end

# 出成原始灰度字节再读：txt: 的写法在不同版本里不一样，之前按「(n,n,n)」解析灰度图时读到的全是
# 空——于是两条曲线都成了全 0，差异算出来是 0，把载入中的黑屏也判成「一致」（这条已经踩过）。
def gray_grid(path)
  IO.binread(path) # 先确认文件在，不然给出 nil 让调用别看差值
  bytes = IO.popen(['magick', path, '-colorspace', 'gray', '-resize', '16x16!', '-depth', '8', 'gray:-'],
                   err: File::NULL, &:read)
  return nil unless $?.success? && bytes.bytesize >= 256

  bytes.bytes[0, 256]
end

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

def zh_font
  return nil unless system('fc-list -V >/dev/null 2>&1')

  lines = IO.popen(['fc-list', ':lang=zh'], err: File::NULL, &:read).lines.map { |l| l.split(':').first.to_s.strip }
  # 挑字形完整的常规体：薄体（45 Light 这类）在 72px + 电视缩放后糊成一团（实测画出来像重影）。
  lines.find { |f| f =~ /霞鹜|文楷|仿宋|黑体|Songti|PingFang|Hiragino|Heiti/ } || lines.first
end

# 用本地图形代替设备端界面：布局与措辞照 LAYERING §4，字号按 BOX-A 的观看距离取大（F9）。
def card(st, world)
  line1 = sentence(st, world)
  due = st['due']
  line2 = due ? "还差 #{due['deficit']['amount']} #{due['deficit']['unit']} · #{due['mode'] == 'focused' ? '这一组答完就记为已完成' : '有一组题待做，现在做吗？'}" :
              st['fallbackReason'] ? '本机没有按约定请求到暂停，已改为不打断观看的提示。' : '只有角标与状态句，不打断观看。'
  badge = "#{st['tier']} · #{due ? '待做' : '无到期项'}"
  font = zh_font
  abort '本机找不到带中文的字体，画出来会是方块——不拿方块当显示结果。' unless font

  cmd = ['magick', '-size', '1920x1080', "xc:#101014", '-font', font,
         '-fill', '#f2f2f5', '-pointsize', '72', '-annotate', '+140+460', line1,
         '-pointsize', '46', '-fill', '#a8a8bc', '-annotate', '+140+570', line2,
         '-pointsize', '40', '-fill', '#f2f2f5', '-annotate', '+1640+132', badge,
         '-stroke', '#5a5a6e', '-strokewidth', '2', '-fill', 'none',
         '-draw', 'roundrectangle 1596,86,1880,152 12,12',
         '-pointsize', '34', '-fill', '#7c7c92', '-stroke', 'none', '-annotate', '+140+980',
         "落层 #{st['tier']} · 强度天花板 #{st['tierCeiling']}", LOCAL_IMAGE]
  system(*cmd, err: File::NULL)
  abort '本地图形没画出来（magick 失败）——不拿失败当显示。' unless $?.success? && File.exist?(LOCAL_IMAGE)
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

# 谁认领这类内容：resolve-activity --brief 的最后一行是「包名/组件」，问不到再用 query-activities。
def who_handles(args, mime)
  out, ok = adb(args, 'shell', 'cmd', 'package', 'resolve-activity', '--brief',
               '-a', 'android.intent.action.VIEW', '-d', "file:///probe.#{mime.split('/').last}", '-t', mime)
  pkg = out.lines.last.to_s[/\A([\w.]+)\//, 1] if ok
  return pkg if pkg

  q, ok2 = adb(args, 'shell', 'cmd', 'package', 'query-activities',
               '-a', 'android.intent.action.VIEW', '-d', "file:///probe.#{mime.split('/').last}", '-t', mime)
  ok2 ? q[/packageName=([\w.]+)/, 1] : nil
end

args, rest = parse_args(ARGV)
given, when_ = round_for(args, rest)
world = World.new(given)
abort "状态键 #{world.unconsumed.join(', ')} 模型尚未消费，不硬凑结论" unless world.unconsumed.empty?

world.apply(when_)
st = world.commit_state
puts JSON.pretty_generate(st)

# 电视会自己进屏保：屏保也是深色画面，先戳醒，免得把屏保当成「画出来了」（实测踩过）。
adb(args, 'shell', 'input', 'keyevent', '82')

html_viewer = who_handles(args, 'text/html')
image_viewer = who_handles(args, 'image/png')
if html_viewer
  # 同一台机器上常装两个浏览器：Chromium 按同源策略挡掉 file:// 页面里的字体引用，整页变方块；
  # 系统自带那个不挡。指名它，并在结论里说清是谁画的这一屏。
  local = Tempfile.new(['youban-status', '.html'])
  local.write(page(st, world, font_face(args)))
  local.close
  remote, mime, local_path = REMOTE, 'text/html', local.path
  viewer = html_viewer
elsif image_viewer
  card(st, world)
  remote, mime, local_path = REMOTE_IMAGE, 'image/png', LOCAL_IMAGE
  viewer = image_viewer
else
  abort "这台设备既不认领 text/html 也不认领 image/*：免安装的呈现通路不存在，要在这台设备上看结论只能装设备端 APK。\n"         '（BOX-B 就是这一类：自带 htmlviewer 不接 file:// 的 HTML，见 facts/DEVICES.md#F15）'
end

_out, ok = adb(args, 'push', local_path, remote)
abort "推不到设备：#{_out.strip}（设备是否在线？adb devices 里有没有它）" unless ok

if args[:force_stop]
  focus, = adb(args, 'shell', 'dumpsys', 'window')
  front = focus[/mCurrentFocus=.*?\s([\w.]+)\//, 1]
  # 只关显示它的那个应用：把电视桌面关掉没道理，还会把整个界面折腾一遍（实测过）。
  if front == viewer
    adb(args, 'shell', 'am', 'force-stop', front)
    puts "先关掉前台的 #{front}：不关会看到上一轮留下的那一屏（F12 的老教训）"
    sleep 2 # 立刻 start 会和冷启动抢时序，拿到的是白页（实测见过）
  end
end

puts "通路：#{mime} 交给 #{viewer}"
launch = ['shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW',
          '-d', "file://#{remote}", '-t', mime, '-p', viewer]
_out, ok = adb(args, *launch)
abort "设备没受理这个打开请求：#{_out.strip}\n这条链在这台设备上还没走通，不用截图假装已显示。" if !ok || _out =~ /unable to resolve/

# 三道控制：前台窗口是这个应用、画面不白、截屏和本地那张卡对得上（载入中的黑屏会被第三条挡掉）。
shown = drawn = diff = nil
10.times do
  focus, = adb(args, 'shell', 'dumpsys', 'window')
  shown = focus.include?(viewer)
  FileUtils.rm_f(LOCAL_CAPTURE)
  adb(args, 'shell', 'screencap', '-p', CAPTURE)
  adb(args, 'pull', CAPTURE, LOCAL_CAPTURE)
  drawn = dark_enough?
  diff = local_path == LOCAL_IMAGE ? matches_card?(LOCAL_IMAGE) : nil
  @diff_ok = diff && diff < DIFF_MAX
  break if shown && drawn && (diff.nil? || @diff_ok)

  sleep 1
end
abort "前台窗口不是 #{viewer}：这一屏不是我们推的那页，不用它当证据。" unless shown
abort '画面还是白的：这条链在这台设备上没走通，不用截图假装成功。' unless drawn
if diff
  abort "屏幕上的内容和本地这张卡对不上（平均差 #{diff} ≥ #{DIFF_MAX}）：可能还停在载入画面，不用它当证据。" if diff >= DIFF_MAX

  puts "截屏与本地卡的灰度平均差 #{diff}（阈值 #{DIFF_MAX}）"
end

if args[:shot]
  FileUtils.cp(LOCAL_CAPTURE, args[:shot])
  puts "截图：#{args[:shot]}"
end
puts "已在 #{args[:serial] || '默认设备'} 上显示（呈现通路演练，不是 M3 的界面）"
puts "注意：#{@font_note}" if @font_note
