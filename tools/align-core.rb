#!/usr/bin/env ruby
# 双内核对齐（M2 / D42）：同一份输入分别喂 Ruby 规范模型与 Kotlin 内核，逐字段比 CommitState。
#
# 为什么要跑这个：规范只有一份是 Ruby 那份，Kotlin 与设备端都是它的搬运工。
# 搬运最容易出错的地方是「某一处判定只在一边有」——那种错靠读代码查不干净，靠这个跑一遍就露出来。
#
# 用法：ruby tools/align-core.rb [ID 前缀]
# 依赖：先 sh tools/build-core.sh（缺依赖时这个脚本会说明缺什么，不会当成通过）。
require 'json'
require 'yaml'
require_relative 'run-fixtures'
require_relative '../model/agreement'

ROOT = File.expand_path('..', __dir__)
CLASSES = File.join(ROOT, 'core/build/classes')
STDLIB = ENV['KOTLIN_STDLIB'] || ['/tmp/kotlinc/lib/kotlin-stdlib.jar',
                                 File.expand_path('~/.cache/youban-kotlin/kotlin-stdlib.jar')]
                                 .find { |p| File.file?(p) }

def die(msg)
  warn "Kotlin 内核对齐：#{msg}"
  warn '这一步不能算通过——补齐后重跑（tools/build-core.sh）。'
  exit 1
end

die("core/build/classes 不存在") unless File.directory?(CLASSES)
die('kotlin-stdlib.jar 找不到（KOTLIN_STDLIB= 指一下）') unless STDLIB

FIELDS = JSON.parse(File.read(File.join(ROOT, 'contract/contract.json')))['commitState']['fields']

cases = []
jobs = []
Dir[File.join(ROOT, 'fixtures', '*.yaml')].sort.each do |path|
  doc = YAML.load_file(path) || {}
  doc.each do |id, spec|
    next unless spec.is_a?(Hash) && spec['cases']
    next if ARGV[0] && !id.start_with?(ARGV[0])

    spec['cases'].each_with_index do |c, i|
      given = (spec['given'] || {}).merge(c['given'] || {})
      w = World.new(given)
      begin
        w.apply(c['when'] || {})
      rescue Unsupported
        next # 这一轮的动作模型还不认，比不了；不算通过也不算失败，跳过（run-fixtures 会把它记成未支持）
      end
      args = w.send(:decide_args)
      mine = w.commit_state
      next unless mine.is_a?(Hash) # 这一轮没有可比的结论（比如还没选人）

      cases << [c['id'] || "#{id}.#{i + 1}", mine]
      jobs << {
        'contract' => File.join(ROOT, 'contract/contract.json'),
        'profile' => w.profile, 'strength' => w.strength,
        # 形态与「已受理的暂停」是这一轮的状态，不传就等于两边喂的输入不同——那是比对器的错，
        # 不是内核的分歧（这种假阳性烧掉过一次，别再犯）。
        'mode' => args[:mode], 'paused' => !args[:motion_state].empty?,
        'pauseMs' => args[:motion_state]['pauseMs'].to_i,
        # 探针那条门槛规则只有一份（Ruby 的 focused_default_ok?）：这里送的是它的结论，
        # 不在比对器里另写一条 0.95/20——设备端要自己判探针时，那两个数得先进契约再说。
        'requested' => args[:requested],
        # 有没有一份签过的约定是这一轮的输入：不带过去就是两边喂的输入不同（AGREE-01）。
        'signed' => w.plan_signed?,
        # 挂着一条要受理的动议是这一轮的输入：设备端的确认键能不能生效就靠它（AGREE-11）。
        'pendingMotion' => w.ledger_pending_motion,
        'probeOk' => args[:probe].nil? ? nil : Core::Capability.focused_default_ok?(args[:probe]),
        # 这一轮做了零点刷新就得告诉内核，否则两边喂的输入不同（DAY-06）。
        # 墙钟与单调钟的原始量一起送过去：滚不滚这一天归内核判（DAY-07），比对器不许替它决定。
        'crossedMidnight' => (c['when'] || {}).any? { |k, v| k.to_s == 'crossedMidnight' && v },
        'clock' => w.clock,
        'plan' => w.plan,
        # 一条账属于哪一台也要送过去：一台设备一本账（DAY-10、D77），别台的事件不进这台账。
        'device' => w.assembly,
        'events' => w.ledger.events.map { |e|
          { 'kind' => e.kind.to_s, 'profile' => e.profile.to_s, 'device' => e.device.to_s,
            'fields' => { 'ms' => (e.fields[:ms] || 0).to_i,
                          'pauseMs' => (e.fields[:pauseMs] || 0).to_i } }
        }
      }
    end
  end
end

if cases.empty?
  puts 'Kotlin 内核对齐：没有可比的 case'
  exit 0
end

require 'tempfile'
Tempfile.open(['youban-align', '.json']) do |f|
  f.write(JSON.generate(jobs)); f.flush
  out = IO.popen(['java', '-cp', "#{CLASSES}:#{STDLIB}", 'com.youban.core.Main',
                  '--batch', '--file', f.path], &:read)
  unless $?.success?
    warn out.to_s.lines.last(6).join
    die('Kotlin 内核跑挂了')
  end

  theirs = out.lines.map { |l| JSON.parse(l) }
  die("返回 #{theirs.size} 份，和送进去的 #{cases.size} 份对不上") unless theirs.size == cases.size

  diffs = []
  cases.each_with_index do |(label, mine), i|
    theirs_i = theirs[i]
    # 只比契约里那批字段：其余键是 Ruby 侧的内部量，不进输出形状。
    fields = FIELDS # 字段名来自契约那一份（commitState.fields），不在这里另列一遍
    fields.each do |k|
      a = JSON.parse(JSON.generate(mine[k] || mine[k.to_sym]))
      b = theirs_i[k]
      diffs << "#{label} #{k}: Ruby #{a.inspect} / Kotlin #{b.inspect}" if a != b
    end
  end

  # 首启那六步的屏内容也在这儿比：那一套以前只有 Kotlin 一份，Ruby 这边是补上的（AGREE-05）。
  # 六步摊出来的每一屏，两边各算一次：抬头/那一行/脚下那句/是不是最后一屏，逐字比。
  screen_diffs = []
  [['{}', '空方案'], ['{"audience":"grown-up"}', '换成大人那一档']].each do |plan_json, tag|
    index = 0
    loop do
      mine_s = Core::Agreement.setup_screen(JSON.parse(plan_json), index, 1, false)
      job = { 'contract' => File.join(ROOT, 'contract/contract.json'),
              'plan' => JSON.parse(plan_json), 'step' => index, 'version' => 1 }
      Tempfile.open(['youban-screen', '.json']) do |g|
        g.write(JSON.generate(job)); g.flush
        raw = IO.popen(['java', '-cp', "#{CLASSES}:#{STDLIB}", 'com.youban.core.Main',
                        '--setup', '--file', g.path], &:read)
        unless $?.success?
          warn raw.to_s.lines.last(4).join
          die('Kotlin 首启那一屏跑挂了')
        end
        theirs_s = JSON.parse(raw.to_s.lines.last.to_s.strip)
        %w[title lines field foot last].each do |k|
          a = mine_s[k]
          bq = theirs_s[k]
          screen_diffs << "#{tag} 第#{index + 1}屏 #{k}: Ruby #{a.inspect} / Kotlin #{bq.inspect}" if a != bq
        end
      end
      break if mine_s['last'] || (index += 1) > 12
    end
  end

  # 那一屏只读的条目（AGREE-14）也在这儿比：签过的与还没签的两种账，两边各算一次逐字比。
  [
    { 'profile' => 'member:kid',
      'events' => [{ 'kind' => 'PLAN_SIGNED', 'profile' => 'member:kid', 'at' => 1700000000000,
                     'fields' => { 'version' => 3 } }],
      'plans' => { 'member:kid' => { 'audience' => 'child', 'allowanceMs' => 3600000 } }, 'tag' => '签过的' },
    { 'profile' => 'member:dad', 'plans' => { 'member:dad' => { 'audience' => 'grown-up' } },
      'tag' => '还没签的',
      'events' => [{ 'kind' => 'MOTION', 'profile' => 'member:dad', 'actor' => 'member:kid', 'at' => 5,
                     'fields' => { 'kind' => 'pause' } },
                   { 'kind' => 'MOTION_SETTLED', 'profile' => 'member:dad', 'at' => 6,
                     'fields' => { 'kind' => 'pause', 'accepted' => false } },
                   { 'kind' => 'MOTION_UNANSWERED', 'profile' => 'member:dad', 'at' => 7,
                     'fields' => { 'kind' => 'extend' } }] }
  ].each do |job0|
    mine_p = Core::Agreement.panel(events: job0['events'], profile: job0['profile'], plans: job0['plans'])
    job = { 'contract' => File.join(ROOT, 'contract/contract.json') }.merge(job0.reject { |k, _| k == 'tag' })
    Tempfile.open(['youban-panel', '.json']) do |g|
      g.write(JSON.generate(job)); g.flush
      raw = IO.popen(['java', '-cp', "#{CLASSES}:#{STDLIB}", 'com.youban.core.Main',
                      '--panel', '--file', g.path], &:read)
      unless $?.success?
        warn raw.to_s.lines.last(4).join
        die('Kotlin 那一屏只读的条目跑挂了')
      end
      theirs_p = JSON.parse(raw.to_s.lines.last.to_s.strip)
      %w[title lines foot never].each do |k|
        a = mine_p[k]
        bq = theirs_p[k]
        screen_diffs << "#{job0['tag']} 那一屏 #{k}: Ruby #{a.inspect} / Kotlin #{bq.inspect}" if a != bq
      end
    end
  end

  if screen_diffs.any?
    puts "Kotlin 内核对齐：首启那一套 #{screen_diffs.size} 处不一致"
    screen_diffs.first(8).each { |d| puts "  #{d}" }
    exit 1
  end

  if diffs.empty?
    puts "Kotlin 内核对齐：通过（#{cases.size} 个 case × #{FIELDS.size} 个字段逐位相同 · 首启每一屏逐字相同）"
  else
    puts "Kotlin 内核对齐：#{diffs.size} 处不一致 / #{cases.size} 个 case"
    diffs.first(12).each { |d| puts "  #{d}" }
    exit 1
  end
end
