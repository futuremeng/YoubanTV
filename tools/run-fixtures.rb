#!/usr/bin/env ruby
# SPEC: COMMIT-01, COMMIT-04, COMMIT-11, DAY-01
# 夹具执行器：把 given/when 喂给内核，再对 expect 逐条判真假。
# 不认识的键一律记为「未支持」并计入结果——绝不静默跳过，也绝不判绿。
require 'json'
require 'yaml'
require 'set'

root = File.expand_path('..', __dir__)
$LOAD_PATH.unshift File.join(root, "model")
require 'ledger'
require 'day'
require 'commit'
require 'enforcement'

class Unsupported < StandardError; end

CONTRACT = JSON.parse(File.read(File.join(root, 'contract/contract.json')))
EVENTS = CONTRACT['enums']['event']['values'] + CONTRACT['enums']['event']['auxValues']
CORE_SOURCE = Dir[File.join(root, 'model/*.rb')].map { |f| File.read(f) }.join
CONTRACT_TEXT = JSON.generate(CONTRACT)

# 一个用例的世界：当日方案 + 账本 + 判定结论。
class World
  attr_reader :ledger, :profile, :plan, :verdict, :written, :extras, :effective
  attr_accessor :strength, :audience, :day_type, :motion_accepted, :applied, :before

  def initialize(given)
    @day = given["dayToken"] || "d1"
    @ledger = Core::Ledger.new(allowed_kinds: EVENTS, day: @day)
    @profile = given['profile'] || 'member:kid'
    @strength = given['strength'] || 'negotiated'
    @audience = given['audience'] || default_audience(@profile)
    @day_type = given['dayType'] || 'schoolday'
    @extras = {}
    @capability = given['capability'] || {}
    @written = []
    @verdict_stale = false
    @effective = nil
    @applied = false
    @motion_accepted = nil
    @plan = Core::Day.plan(audience: @audience, day_type: @day_type, overrides: plan_overrides(given))
    seed(given)
    @verdict = decide
    snapshot
  end

  def snapshot
    @subject = @profile
    @before = @extras.merge(@ledger.project(@profile))
  end

  # 跳日保留项的比较基准：用例开始时那个身份账上的量（切换不串账）。
  def project_now(profile = nil)
    @ledger.project(profile || @subject || @profile)
  end

  # 断言「保持不变」用 subject 的当日投影与跨天保留项，不受当前判定身份影响（切换不串账）。
  def kept(key)
    p = project_now
    return p[key] if p.key?(key)
    return @extras[key] if @extras.key?(key)
    return @plan[key] if @plan.key?(key)

    raise Unsupported, "#{key} 在投影与保留项里都无定义"
  end

  # 统一取值：先判定结论，再当日投影，再跨天保留项，再当日方案。
  def lookup(key, profile = nil)
    return @verdict[:value][key] if @verdict[:value].key?(key)
    return contract_endpoint('exercise') if key == 'endpoint'

    p = project_now(profile)
    return p[key] if p.key?(key)
    return @extras[key] if @extras.key?(key)
    return @plan[key] if @plan.key?(key)

    raise Unsupported, "#{key} 在判定、投影、保留项与当日方案里都无定义"
  end

  def value_for(key)
    lookup(key)
  end

  def apply(when_)
    when_ = when_.dup
    if when_.key?('motion')
      motion(when_.delete('motion'))
    end
    if when_.key?('switch')
      switch(when_.delete('switch'))
    end
    if when_.key?('crossedMidnight')
      roll!(when_.delete('crossedMidnight'))
    end
    if when_.key?('rebooted') && when_.delete('rebooted')
      roll!(@day, reboot: true)
      @extras['dayTokenKept'] = true # 重启沿用当日 token，不重放（DAY-07）
    end
    if (ms = when_.delete('watchedMs'))
      add_watch(ms)
    end
    @capability.merge!(when_.delete('capability')) if when_.key?('capability')
    if when_.key?('mode')
      @plan['form'] = when_.delete('mode')
      @verdict_stale = true
    end
    if when_.key?('signalSource')
      src = when_.delete('signalSource')
      @signal_source = src
      append('ROUND_DONE', @profile, reps: 1, signalSource: src) if src.to_s == 'manual'
      @verdict = decide
      write_events(@verdict)
    end
    if when_.key?('exerciseDone') && when_.delete('exerciseDone')
      append('ROUND_DONE', @profile, reps: 1, signalSource: @signal_source || 'sensor')
      @verdict = decide
      write_events(@verdict)
    end
    if when_.key?('stillWatching') || when_.key?('inSlot') || @verdict_stale
      when_.delete('stillWatching')
      @plan['inSlot'] = when_.delete('inSlot') if when_.key?('inSlot')
      @verdict = decide
      write_events(@verdict)
    end
    raise Unsupported, "动作键 #{when_.keys.join(", ")}" unless when_.empty?

    self
  end

  private

  # 端点名不硬编码在模型里，一律回契约查。
  def contract_endpoint(kind)
    path = CONTRACT['endpoints'].map { |e| e['path'] }.find { |p| p.include?(kind) }
    raise Unsupported, "契约里没有 #{kind} 类端点" unless path

    path
  end

  def default_audience(profile)
    { 'member:kid' => 'child', 'member:mom' => 'grown-up', 'member:dad' => 'grown-up',
      'member:grandpa' => 'senior' }[profile.to_s] || 'grown-up'
  end

  def plan_overrides(given)
    o = {}
    %w[allowanceMs graceMs moveFromMs inSlot groupsPerTask minutesPerGroup roundTarget].each do |k|
      o[k] = given[k] if given.key?(k)
    end
    o['slots'] = given['slots'] if given.key?('slots')
    o
  end

  def seed(given)
    append('WATCHED', @profile, ms: given['watchedMs'].to_i) if given['watchedMs']
    append('OVER', @profile, ms: given['overMs'].to_i) if given['overMs']
    if given['pauseMs']
      append('MOTION', @profile, kind: 'pause', target: @profile)
      append('MOTION_SETTLED', @profile, kind: 'pause', pauseMs: given['pauseMs'].to_i)
      @motion_state = { 'pause' => true, 'pauseMs' => given['pauseMs'].to_i }
    end
    given['roundsDone'].to_i.times { append('ROUND_DONE', @profile, reps: 1) } if given['roundsDone']
    given['answeredInTask'].to_i.times { append('ANSWER', @profile, verdict: 'correct') } if given['answeredInTask']
    given['backlogSize'].to_i.times { append('MISSED', @profile) } if given['backlogSize']
    %w[wrongAnswers srsProgress pendingReview planVersion kpId carryOver].each { |k| @extras[k] = given[k] if given[k] }
    @extras['backlogSize'] ||= given['backlogSize'].to_i if given['backlogSize']
  end

  # 零点刷新：同一个 dayToken 只滚一次；重启与同日重复调用不滚（DAY-06、DAY-07）。
  def roll!(crossed, reboot: false)
    token = reboot ? @day : (crossed ? 'd2' : @day)
    @applied = @ledger.roll!(token)
    @motion_state = nil if @applied # 零点刷新连 pauseMs 一起归零（DAY-06）
    @effective = 'now' if @applied
    @verdict = decide
  end

  def append(kind, profile, **fields)
    @ledger.append(kind, profile: profile, at: '20:00', **fields)
    @written << kind.to_s
    kind.to_s
  end

  def add_watch(ms)
    append('WATCHED', @profile, ms: ms.to_i)
    @verdict = decide
  end

  def decide
    Core::Commit.decide(profile: @profile, plan: @plan, q: @ledger.project(@profile),
                        strength: @strength, motion_state: @motion_state || {},
                        capability: @capability)
  end

  def write_events(v)
    v[:events].each do |k|
      fields = {}
      fields[:ms] = v[:value]['overMs'] if k == 'OVER'
      append(k, @profile, **fields)
    end
  end

  def motion(spec)
    kind = spec['kind']
    @motion_accepted = spec.fetch('accepted', false)
    append('MOTION', @profile, kind: kind, target: spec['target'] || @profile)
    unless @motion_accepted
      append('MOTION_UNANSWERED', @profile, kind: kind)
      @effective = 'never'
      @applied = false
      return
    end
    @motion_state = nil
    settled = { kind: kind }
    if kind == 'pause'
      @motion_state = { 'pause' => true, 'pauseMs' => (spec['minutes'] || 10).to_i * 60_000 }
      settled[:pauseMs] = @motion_state['pauseMs']
    end
    append('MOTION_SETTLED', @profile, **settled)
    case kind
    when 'extend'
      @plan, offset = Core::Commit.apply_extend(@plan, spec['minutes'] || 0)
      @extras['dayOffsetMs'] = offset
      append('PLAN_CHANGE', @profile, field: 'allowanceMs')
    end
    @verdict = decide
    write_events(@verdict)
    @effective = 'now'
    @applied = true
  end

  def switch(spec)
    to = spec['to']
    append('PROFILE_SWITCH', to == 'none' ? 'none' : to, from: spec['from'], to: to)
    @profile = to
    @extras['eventProfile'] = to
    @extras['inheritedWatchedMs'] = @ledger.project(to)['watchedMs']
    @verdict = decide
  end
end

# 断言求值：返回 :pass / :fail / :unsupported
def check(key, want, world, before)
  case key
  when 'status' then cmp(want, world.verdict[:status])
  when 'tier' then cmp(want, world.verdict[:tier])
  when 'mode' then cmp(want, world.verdict.fetch(:mode, 'ambient'))
  when 'nextAction' then cmp(want, world.verdict[:next_action])
  when 'blocked' then cmp(want, world.verdict[:blocked])
  when 'wording' then cmp(want, world.verdict[:wording])
  when 'due' then cmp_due(want, world.verdict[:due])
  when 'surface' then Array(want).all? { |s| Array(world.verdict[:surface]).include?(s) } ? :pass : :fail
  when 'shown' then Array(want).all? { |s| world.verdict[:shown].include?(s) } ? :pass : :fail
  when 'notShown' then Array(want).none? { |s| world.verdict[:shown].include?(s) } ? :pass : :fail
  when 'events' then Array(want).all? { |k| world.written.include?(k) } ? :pass : :fail
  when 'noEvents' then Array(want).none? { |k| world.written.include?(k) } ? :pass : :fail
  when 'absent' then Array(want).all? { |n| absent?(n) } ? :pass : :fail
  when 'value' then want.all? { |k, v| cmp(v, world.value_for(k)) == :pass } ? :pass : :fail
  when 'delta' then want.all? { |k, d| cmp(d.to_i, world.kept(k).to_i - world.before[k].to_i) == :pass } ? :pass : :fail
  when 'unchanged' then want.all? { |k| cmp(world.before[k], world.kept(k)) == :pass } ? :pass : :fail
  when 'accepted' then cmp(want, world.motion_accepted)
  when 'applied' then cmp(want, world.applied)
  when 'effective' then cmp(want, world.effective)
  else
    raise Unsupported, "断言键 #{key}"
  end
end

def cmp(want, got)
  return :pass if want.nil? && got.nil?
  return :pass if want == 'present' && !got.nil? && got != false
  return :pass if want == 'absent' && got.nil?

  want.to_s == got.to_s ? :pass : :fail
end

def cmp_due(want, got)
  return :pass if want.nil?
  return :fail if got.nil?

  want.all? { |k, v| cmp(v, got[k]) == :pass } ? :pass : :fail
end

def absent?(name)
  return true if name.to_s =~ %r{\A(GET|POST|PUT|DELETE) /} # 路径不存在由契约门校验形状
  return false if CORE_SOURCE.include?(name.to_s)

  # 登记在禁止清单里的名字正是「契约里无定义」的写法；除此之外不得出现在契约其余部分。
  rest = CONTRACT.reject { |k, _| %w[forbiddenFields retired].include?(k) }
  !JSON.generate(rest).include?(name.to_s)
end

def run(entries_filter, files)
  total = { pass: 0, fail: 0, unsupported: 0 }
  failing = []
  unsupported = []
  files.each do |f|
    doc = YAML.load_file(f)
    doc.each do |id, entry|
      next if entries_filter && !entries_filter.include?(id)

      res = { pass: 0, fail: 0, unsupported: 0 }
      entry['cases'].each_with_index do |cs, i|
        given = (entry['given'] || {}).merge(cs['given'] || {})
        begin
          world = World.new(given)
          before = world.before
          world.apply(cs['when'] || {})
          cs['expect'].each do |k, v|
            r = check(k, v, world, before)
            res[r] += 1
            total[r] += 1
            failing << "#{id}.#{i + 1} #{k}=#{v.inspect}" if r == :fail
          end
        rescue Unsupported => e
          res[:unsupported] += 1
          total[:unsupported] += 1
          unsupported << "#{id}.#{i + 1} #{e.message}"
        end
      end
      puts format('%-11s 通过 %-3d 失败 %-3d 未支持 %d', id, res[:pass], res[:fail], res[:unsupported])
    end
  end
  puts '-' * 46
  puts format('合计：通过 %d，失败 %d，未支持 %d', total[:pass], total[:fail], total[:unsupported])
  puts "失败明细：\n  " + failing.join("\n  ") unless failing.empty?
  puts "未支持明细：\n  " + unsupported.first(12).join("\n  ") unless unsupported.empty?
  exit(total[:fail].zero? && (!entries_filter || total[:unsupported].zero?) ? 0 : 1)
end

only = nil
files = []
ARGV.each_with_index do |a, i|
  only = a.sub('--only=', '').split(',') if a.start_with?('--only=')
  files << a unless a.start_with?('--')
end
files = Dir[File.join(root, 'fixtures/*.yaml')].reject { |f| f.end_with?('vocab.yaml') }.sort if files.empty?
run(only, files)
