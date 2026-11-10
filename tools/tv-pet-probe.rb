# 角上那一块的自检（spec/PET.md#PET-07、D83）——单独一个文件：这条要自己摆输入、自己离开前台，
# 交给上一条自检的收尾去量会量到进程被回收之后（这台设备真的会回收本进程，见 facts/DEVICES.md#F37）。
#
# 判定只有一句：**名单说了算**。这台设备的机型在 contract.pet.appearance.measuredOn 里，
# 那一块就必须画出来且不压字幕；不在里面就必须连那张图都不解——「默认关」说的就是这一条。
# 依赖 tv-at.rb 里已经定义好的 shell / broadcast / overlay_record / APK_* 那几个（require 的位置在那之后）。

def probe_pet(args)
  return [false, "没装 #{APK_PACKAGE}：先 sh device/android/build-apk.sh && adb install -r"] if
    shell(args, "pm list packages #{APK_PACKAGE}").strip.empty?

  model = shell(args, 'getprop ro.product.model').gsub(/\r/, '').strip
  return [false, '读不到这台设备的机型'] if model.empty?
  conf = JSON.parse(File.read(File.join(__dir__, '..', 'contract', 'contract.json')))['pet']['appearance']
  listed = Array(conf['measuredOn']).map(&:to_s).include?(model)

  shell(args, "appops set #{APK_PACKAGE} SYSTEM_ALERT_WINDOW allow")
  shell(args, "am force-stop #{APK_PACKAGE}")
  shell(args, "rm -f #{APK_FILES}/#{EVENTS_FILE} #{APK_FILES}/youban-overlay.json")
  shell(args, 'input keyevent 224')
  shell(args, "am start -n #{APK_PACKAGE}/.MainActivity")
  sleep 3
  broadcast(args, ['--es', 'kind', 'WATCHED', '--es', 'profile', 'member:kid', '--el', 'ms', '2100000'])
  sleep 1
  broadcast(args, ['--es', 'kind', 'PLAN_SIGNED', '--es', 'profile', 'member:kid', '--el', 'version', '1'])
  sleep 1
  shell(args, 'input keyevent 3') # HOME：那一块只在这张卡正在显示时才有意义
  sleep 2

  rec = overlay_record(args)
  return [false, '没读到 youban-overlay.json'] if rec.nil?
  return [false, "那一张没出来，那一块谈不上：refuse=#{rec['refuse'].inspect}"] unless rec['shown']

  name = rec['pet']
  box = rec['petRect']
  if listed
    if name.nil? || box.nil?
      return [false, "这台设备在实测名单里却没画那一块：pet=#{name.inspect} 为什么=#{rec['petWhy'].inspect}"]
    end

    band = (screen_height(args) * 0.85).round # 字幕带那一截不许进（layering.overlay.subtitleBandPct）
    return [false, "那一块压进字幕带了：下边缘 #{box[3]} > #{band}"] if box[3].to_i > band

    return [true,
            format('机型 %s 在名单里 · 画了 %s · 帧循环在走 · 用量 %s tick', model, name.inspect, jiffie_delta(args))]
  end
  unless name.nil? && box.nil?
    return [false,
            format('名单之外还是画了那一块：%s %s——默认关这条不成立', name.inspect, box.inspect)]
  end

  [true,
   format('机型 %s 在名单外 · 那一块不存在 · 帧循环一次没走 · 用量 %s tick', model, jiffie_delta(args))]
end

# 本进程用了多少：这台电视上老那版 top 没有 -b、列位各家不同，dumpsys cpuinfo 闲置时根本不列这一行，
# 于是量硬事实——/proc/<pid>/stat 的 utime+stime 在一段墙钟里涨了几 tick。
# HZ 在这两台设备上没测，所以不换算成百分数：走与不走两个数一比就够（F37 要的就是这两个数）。
def jiffie_delta(args, seconds = 2)
  raw = shell(args, "pidof #{APK_PACKAGE}").gsub(/\r/, '')
  pid = raw.split.first
  return 'unknown(no-pid)' if pid.nil?

  first = proc_jiffies(args, pid)
  sleep seconds
  second = proc_jiffies(args, pid)
  return 'unknown(no-stat)' if first.nil? || second.nil?

  "#{second - first}/#{seconds}s"
end

# stat 第二个字段是进程名，里面可以带空格——从最后一个右括号之后切，不然整行的列位全偏（F20 那一类）。
def proc_jiffies(args, pid)
  raw = shell(args, "cat /proc/#{pid}/stat").gsub(/\r/, '')
  tail = raw[/\) (.*)\z/m, 1]
  return nil if tail.nil?

  cells = tail.split(/\s+/)
  cells.size < 13 ? nil : cells[11].to_i + cells[12].to_i
end

def screen_height(args)
  shell(args, 'wm size').gsub(/\r/, '')[/\d+x(\d+)/, 1].to_i
end
