#!/usr/bin/env ruby
# 把角上那四只画出来（PET-08：风格学 playpets 的形状语言，素材本项目自己画）。
# 形状语言就四条：圆的形、无描边、暖色、可信的接触阴影。每只两帧，帧间只差一次呼吸（≤2px）——
# 不是弹跳、不是入场动画（PET-05 那批不许有的东西）。
# 产出 device/android/app/src/main/assets/pets/<名>.f<帧>.png，装进包里，帧循环只换那一张图。
require 'json'

ROOT = File.expand_path('..', __dir__)
OUT = File.join(ROOT, 'device/android/app/src/main/assets/pets')
W = H = 192 # 画布；电视上按卡的高度缩着画

# 暖色那一片：主体 / 高光 / 接触阴影。描边一律没有（stroke 一次都不用）。
PETS = {
  'sprout' => { # 芽：圆身子顶上一颗新芽，暖橙
    'body' => '#ED9A4E', 'lite' => '#F9D9AE', 'dark' => '#C97A34', 'shadow' => '#6B4326',
    'acc' => '#8FB572', 'eye' => '#3A2A1C'
  },
  'pebble' => { # 石头：一颗晒暖的圆石，灰米色
    'body' => '#B7926B', 'lite' => '#E4D2B6', 'dark' => '#8A6B48', 'shadow' => '#55493A',
    'acc' => '#8A7154', 'eye' => '#332B23'
  },
  'moth' => { # 蛾：两片圆翅膀，暖沙色
    'body' => '#C99A69', 'lite' => '#EBD2AC', 'dark' => '#9C7346', 'shadow' => '#57432F',
    'acc' => '#D8AE7C', 'eye' => '#33281D'
  },
  'ink' => { # 墨点：一滴圆的墨，暖黑但不冷
    'body' => '#3E342F', 'lite' => '#6B584E', 'dark' => '#241D1A', 'shadow' => '#171310',
    'acc' => '#D9A36C', 'eye' => '#F2E4D2' # 深身子就得浅眼睛：一双看不见的眼睛不算可爱
  }
}.freeze

def defs(id, c)
  <<~SVG
    <defs>
      <radialGradient id="g#{id}" cx="34%" cy="26%" r="86%">
        <stop offset="0%" stop-color="#{c['lite']}"/>
        <stop offset="13%" stop-color="#{c['body']}"/>
        <stop offset="100%" stop-color="#{c['dark']}"/>
      </radialGradient>
      <filter id="s#{id}" x="-40%" y="-40%" width="180%" height="180%">
        <feGaussianBlur stdDeviation="5"/>
      </filter>
    </defs>
  SVG
end

# 接触阴影：一颗压扁的椭圆，模糊过——「可信的接触阴影」就是这一颗；不画描边、不画投影方向。
def shadow(id, c)
  %(<ellipse cx="96" cy="166" rx="52" ry="9" fill="#{c['shadow']}" opacity="0.34" filter="url(#s#{id})"/>)
end

# 眼睛：两颗圆，无描边。帧差 = 呼吸（身子上下 ≤2px，眼睛跟着走）。
def eyes(dy, c, r = 5.2)
  %(<circle cx="79" cy="#{90 + dy}" r="#{r}" fill="#{c['eye']}"/>) +
    %(<circle cx="115" cy="#{90 + dy}" r="#{r}" fill="#{c['eye']}"/>)
end

# 身子是两颗圆叠出来的：上面那颗是本体，下面那颗稍宽一点把它坐住——一颗纯圆看着像在飘。
def body(cy, dy, fill)
  %(<ellipse cx="96" cy="#{cy + 26 + dy}" rx="57" ry="26" fill="#{fill}"/>) +
    %(<ellipse cx="96" cy="#{cy + dy}" rx="52" ry="47" fill="#{fill}"/>)
end

def svg_for(name, c, frame)
  dy = frame.zero? ? 0 : -2 # 一次呼吸：整只起来 2px，落回去也是 2px
  # 身子**后面**那一层：翅膀、触角这类。画在身子底下的印记会被身子挡掉——第一版就踩了这个坑。
  behind =
    case name
    when 'moth'
      %(<ellipse cx="50" cy="#{100 + dy}" rx="32" ry="23" fill="#{c['acc']}" opacity="0.72"/>) +
        %(<ellipse cx="144" cy="#{100 + dy}" rx="32" ry="23" fill="#{c['acc']}" opacity="0.72"/>) +
        %(<path d="M92 #{56 + dy} q-7 -9 -12 -10" stroke="#{c['shadow']}" stroke-width="3" fill="none" stroke-linecap="round"/>) +
        %(<path d="M100 #{56 + dy} q7 -9 12 -10" stroke="#{c['shadow']}" stroke-width="3" fill="none" stroke-linecap="round"/>)
    else ''
    end
  # 身子**上面**那一层：芽、石纹、墨点。
  on_top =
    case name
    when 'sprout' # 顶上那颗芽
      %(<path d="M96 #{58 + dy} q-3 -20 -20 -24 q2 18 20 24" fill="#{c['acc']}"/>) +
        %(<path d="M96 #{58 + dy} q4 -18 20 -21 q-3 17 -20 21" fill="#{c['acc']}"/>) +
        %(<rect x="94" y="#{52 + dy}" width="4" height="12" rx="2" fill="#{c['acc']}"/>)
    when 'pebble' # 石面上那两道浅纹：同一颗石头的受光差，不是描边
      %(<ellipse cx="76" cy="#{70 + dy}" rx="17" ry="7" fill="#{c['acc']}" opacity="0.55"/>) +
        %(<ellipse cx="120" cy="#{128 + dy}" rx="13" ry="5" fill="#{c['acc']}" opacity="0.45"/>)
    when 'ink' # 边上那颗小卫星，浅一点才看得出是另一滴
      %(<circle cx="152" cy="#{138 + dy}" r="9" fill="#{c['lite']}"/>)
    else ''
    end
  <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" width="#{W}" height="#{H}" viewBox="0 0 #{W} #{H}">
      #{defs(name, c)}
      #{shadow(name, c)}
      #{behind}
      #{body(102, dy, "url(#g#{name})")}
      #{on_top}
      #{eyes(dy, c)}
    </svg>
  SVG
end

def to_png(svg, path)
  File.write('/tmp/pet.svg', svg)
  ok = system('rsvg-convert', '-w', W.to_s, '-h', H.to_s, '/tmp/pet.svg', '-o', path, out: File::NULL)
  abort "rsvg-convert 画不出 #{path}" unless ok
end

Dir.mkdir(OUT) unless Dir.exist?(OUT)
manifest = {}
PETS.each do |name, c|
  frames = (0..1).map do |f|
    file = "#{name}.f#{f}.png"
    svg = svg_for(name, c, f)
    to_png(svg, File.join(OUT, file))
    file
  end
  manifest[name] = { 'frames' => frames, 'intervalMs' => 1000 }
  puts "#{name.ljust(7)} #{frames.join('  ')}  #{frames.map { |f| File.size(File.join(OUT, f)).to_s + 'B' }.join('/')}"
end
File.write(File.join(OUT, 'frames.json'), JSON.pretty_generate(manifest) + "\n")
puts "→ #{OUT}"
puts "四只 × 两帧 · 一次呼吸 #{2}px · 描边一次没用"
