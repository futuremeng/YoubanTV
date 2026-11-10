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
require 'capability'
require 'checklist'
require 'sense'
require 'task'
require 'pick'
require 'kp'
require 'write'
require 'agreement'
require 'report'
require 'panel'
require 'startup'
require 'content'

class Unsupported < StandardError; end

CONTRACT = JSON.parse(File.read(File.join(root, 'contract/contract.json')))
EVENTS = CONTRACT['enums']['event']['values'] + CONTRACT['enums']['event']['auxValues']
CODE_SOURCE = Dir[File.join(root, 'model/*.rb')].map { |f| File.read(f) }
              .map { |src| src.gsub(/#[^\n]*/, '').gsub(/'[^']*'|"[^"]*"/, '""') }.join
# 「定义面」：真正定义了字段、取值与端点的地方。
# 说明文字（x-note / note / spec）、退役与禁止清单、枚举空位都只是登记处，不算定义。
NOTES = Set.new(%w[x-note note spec description reserved forbiddenFields retired])
def definition_text(node)
  case node
  # 键名也算定义面：以前只收值，于是「presence 这个枚举名不存在」这类断言永远绿——
  # 枚举加回去、名字仍然不在文本里。登记处（NOTES 那些键）的键名仍然排除。
  when Hash then node.reject { |k, _| NOTES.include?(k) }.map { |k, v| "#{k}|#{definition_text(v)}" }.join('|')
  when Array then node.map { |v| definition_text(v) }.join('|')
  else node.to_s
  end
end
CONTRACT_DEF = definition_text(CONTRACT)

# 「只有一处来源」是跟文件走的：逻辑名 → 产物种类 + 文件。名字解析不到文件就是假陈述。
PRODUCERS = {
  'core/capability' => [:capability, 'model/capability.rb'],
  'core/onboard' => [:checklist, 'model/checklist.rb'],
  'core/ledger' => [:ledger, 'model/ledger.rb'],
  'core/day' => [:day, 'model/day.rb'],
  'core/commit' => [:commit, 'model/commit.rb'],
  'device/enforcement' => [:enforcement, 'model/enforcement.rb'],
  'device/sensor' => [:sensor, 'model/sense.rb'],
  'core/task' => [:task, 'model/task.rb'],
  'core/topics' => [:topics, 'model/pick.rb'],
  'core/kp' => [:kp, 'model/kp.rb'],
  'core/write' => [:write, 'model/write.rb'],
  # 计次（节律→一次）是另一件产物，与体感传感器同一份文件（SENSE-01）。
  'device/counter' => [:counter, 'model/sense.rb'],
  # 首启那六步的屏内容是一处产物；设备端 Kotlin 由 tools/align-core.rb 逐屏比（AGREE-05）。
  'core/agreement' => [:agreement, 'model/agreement.rb']
}.freeze
MEMBERS = %w[member:kid member:mom member:dad member:grandpa].freeze
# 「只有一处来源」是跟文件走的：同一产物种类只准登记一个文件。
if PRODUCERS.values.map(&:first).uniq.size != PRODUCERS.size
  raise '来源登记表里同一产物种类对应了多个文件，先把它消重'
end
ROOT_DIR = root
# 升层入口就一句话：一次点击加三句说明（LAYER-03）。
ESCALATION_SHOWN = %w[这一层会做什么 代价 怎么退回].freeze

# 一个用例的世界：当日方案 + 账本 + 判定结论。
class World
  attr_reader :ledger, :profile, :plan, :verdict, :written, :extras, :effective, :given, :capability,
              :assembly, :roles, :egress, :probe, :added, :reopened, :item, :paired, :strengths,
              :audiences
  attr_accessor :strength, :audience, :day_type, :motion_accepted, :applied, :before
  attr_reader :authoring, :kp_state, :clock
  attr_reader :motion_state, :mode_requested

  def pick_source
    @source
  end

  def initialize(given)
    @given = given
    @used = Set.new
    @extras = {}
    @day = given['dayToken'] || 'd1'
    @used << 'dayToken' if given.key?('dayToken')
    @ledger = Core::Ledger.new(allowed_kinds: EVENTS, day: @day,
                              device: %w[tv mobile].include?(given['assembly'].to_s) ? given['assembly'].to_s : 'tv')
    # 当前在哪一档也可以由 activeMember 说（PROFILE-10 那一条：一台设备同一时刻只有一个当前用户）。
    # 它是 profile 的另一种写法，不是第二个状态——读它，别让它变成「模型没消费」的键。
    @profile = given['activeMember'] || given['profile'] || 'member:kid'
    @used << 'activeMember' if given.key?('activeMember')
    # 写入口那一条判定要的两个输入：从哪一个界面走过来、这一条令牌带了哪些范围（PROFILE-02、PROFILE-05）。
    @via = given['via']
    @used << 'via' if given.key?('via')
    @token_scopes = given['scopes']
    @used << 'scopes' if given.key?('scopes')
    # 邀请那一档、这一档拒绝过没有、今天第几条——这三样是邀请那一条判定的输入（SENSE-07）。
    @invite_tier = given['inviteTier']
    @used << 'inviteTier' if given.key?('inviteTier')
    @invite_declined = given['inviteDeclined']
    @used << 'inviteDeclined' if given.key?('inviteDeclined')
    @invitations_today = given['invitationsToday'] || 0
    @used << 'invitationsToday' if given.key?('invitationsToday')
    # 这台设备上指定的那一个应用（ONBOARD-12）：缩起之后拉起它一次；没指定就不拉。
    @auto_open_target = given['autoOpenTarget']
    @used << 'autoOpenTarget' if given.key?('autoOpenTarget')
    @notify_suppressed = false
    # 这一轮的呈现档（PROFILE-01、PROFILE-05）与「谁给自己批的」（AUTO-15）：都是判定与账的输入。
    @presentation = given['presentation']
    @used << 'presentation' if given.key?('presentation')
    @self_grade = given['selfGrade']
    @sessions = given['sessions'] || []
    @used << 'sessions' if given.key?('sessions')
    @update_available = given['updateAvailable']
    @used << 'updateAvailable' if given.key?('updateAvailable')
    @used << 'selfGrade' if given.key?('selfGrade')
    @pending_items_given = given['pendingItems']
    @used << 'pendingItems' if given.key?('pendingItems')

    # 老人那几类动作项目的三个输入（SENSE-05）：safety 有没有、项目表、这一次多久。
    @project_safety = given['projectSafety']
    @used << 'projectSafety' if given.key?('projectSafety')
    @project_tasks = given['exerciseTasks']
    @used << 'exerciseTasks' if given.key?('exerciseTasks')
    @project_session_ms = given['sessionMs'] || 0
    @used << 'sessionMs' if given.key?('sessionMs')
    @used << 'profile' if given.key?('profile')
    @strength = given['strength'] || 'negotiated'
    @used << 'strength' if given.key?('strength')
    @audience = given['audience'] || default_audience(@profile)
    @used << 'audience' if given.key?('audience')
    @day_type = given['dayType'] || 'schoolday'
    @used << 'dayType' if given.key?('dayType')
    @actor = given['actor'] || @profile
    @used << 'actor' if given.key?('actor')
    @capability = given['capability'] || {}
    @used << 'capability' if given.key?('capability')
    # 陪伴式的默认不是「更侵入」，而是把应用外呈现通道默认开（LAYER-07 推论）。
    @capability['systemPresentation'] ||= 'on' if @strength.to_s == 'accompanied'
    @assembly = given['assembly'] || 'tv'
    @used << 'assembly' if given.key?('assembly')
    @roles = given['roles'] || {}
    @used << 'roles' if given.key?('roles')
    @paired = given['paired']
    @used << 'paired' if given.key?('paired')
    @egress = given['egress'] || {}
    @used << 'egress' if given.key?('egress')
    @egress.each { |k, v| @capability[k.to_s] ||= v.to_s }
    @probe = given['pauseProbe']
    @used << 'pauseProbe' if given.key?('pauseProbe')
    @strengths = Array(given['strengths'])
    @used << 'strengths' if given.key?('strengths')
    @audiences = Array(given['audiences'])
    @used << 'audiences' if given.key?('audiences')
    @target = given['target']
    @used << 'target' if given.key?('target')
    @mode_requested = given['modeRequested']
    @used << 'modeRequested' if given.key?('modeRequested')
    @plan_form_seed = given['mode'] || given['modeRequested']
    # 形态是「已经定下的」还是「走的默认档」：只有后者才需要实测样本来撑（D36）。
    @form_requested_now = given.key?('mode') || given.key?('modeRequested')
    @used << 'mode' if given.key?('mode')
    @start_tier = given['tier']
    @used << 'tier' if given.key?('tier')
    @member = given['member'] || @profile
    @used << 'member' if given.key?('member')
    @item = given['item']
    @used << 'item' if given.key?('item')
    @item_owner = given['owner']
    @used << 'owner' if given.key?('owner')
    @item_status = given['checklistStatus']
    @used << 'checklistStatus' if given.key?('checklistStatus')
    # 这些是「本轮之前的事实」的容器：必须在读 given 之前就位（顺序错过一次，读到的就是 nil）。
    @clock = { 'wallClockDeltaMs' => 0, 'monotonicDeltaMs' => 0 }
    @pool_same = true
    @day_token_kept = true
    @frozen_watched = nil
    @pause_ms = nil
    @roll_rows = nil
    @rolled_today = false
    @task_done = given['taskDone']
    @used << 'taskDone' if given.key?('taskDone')
    # 计划的版本与签署状态是本轮之前的事实（COMMIT-08）：没签署的版本不进「在跑的那一版」。
    if given['plan']
      @used << 'plan'
      @pending_version = given['plan']['version']
      @plan_signed = !!given['plan']['signed']
      # 约定条目本身也是这一轮之前的事实：夹具在 given.plan 里给了数值就直接用（AGREE-06）。
      @plan_overrides_given = given['plan'].reject { |k, _| %w[version signed].include?(k.to_s) }
    end
    # 「这一屏的条目是不是全来自默认值」= 没有任何一份签署过的约定（AGREE-04）。
    @agreement_step = given['agreementStep']
    @used << 'agreementStep' if given.key?('agreementStep')
    @running_version = given['planVersion'] || 6
    @used << 'planVersion' if given.key?('planVersion')
    # 时间完整性这三项是设备端带上来的一手事实，模型不自己造（DAY-07）。
    %w[probedAt wallClockDeltaMs monotonicDeltaMs].each do |k|
      next unless given.key?(k)

      @used << k
      @clock[k] = given[k]
    end
    @quiet = given['quiet']
    @used << 'quiet' if given.key?('quiet')
    # 免题段与完成标记（DAY-03、COMMIT-05）：完成标记只说明「这一组已经做完」，不换算时长。
    %w[quizDone exerciseDone].each { |k| @used << k if given.key?(k) }
    @done_flags = { 'quiz' => given['quizDone'], 'exercise' => given['exerciseDone'] }
    @same_kp = given['sameKp']
    @used << 'sameKp' if given.key?('sameKp')
    # 选题的输入：取材命中情况、题面形状、知识点状态与时机（ASK-01、ASK-06、ASK-07）。
    @hits = { 'pack' => given['packHit'], 'member' => given['memberAuthoredHit'], 'llm' => given['llmHit'] }
    %w[packHit memberAuthoredHit llmHit].each { |k| @used << k if given.key?(k) }
    @shape = {}
    %w[stemChars optionsLines singleKey estimatedSeconds].each do |k|
      next unless given.key?(k)

      @shape[k] = given[k]
      @used << k
    end
    @prereq_state = given['prereqState']
    @used << 'prereqState' if given.key?('prereqState')
    @kp_state = given['kpState']
    @due_at = given['dueAt']
    @used << 'dueAt' if given.key?('dueAt')
    @outline_scope = given['outlineScope']
    @used << 'outlineScope' if given.key?('outlineScope')
    @question_class = given['questionClass']
    @used << 'questionClass' if given.key?('questionClass')
    @estimate_accuracy = given['estimateAccuracy']
    @used << 'estimateAccuracy' if given.key?('estimateAccuracy')
    @signal_source = given['signalSource']
    @used << 'signalSource' if given.key?('signalSource')
    @offline = given['offline']
    @used << 'offline' if given.key?('offline')
    @accuracy_attempts = given['attempts']
    @used << 'attempts' if given.key?('attempts')
    @confirmation = nil
    @correctRun = 0
    @recomputed = nil
    @source = nil
    @authoring = nil
    @extra_items = []
    @added = []
    @reopened = []
    @motion_state = nil
    # @signal_source 在上面按 given 赋过值，这里不能再清一次（SENSE-03/04 的展示口径读它）。
    @external_allowed = nil
    @boot_at = nil
    @probed_at = nil
    @external = { 'reachable' => true }
    # L5 通路不成立时，本机永远不冒充执行 L5（LAYER-11）。
    @external_allowed = false unless Core::Capability.judgment_state(@capability, 'homeAssistant')
    @revert = false
    @change_gate = nil
    @written_when = nil
    @written = []
    @seed_events = []
    @shown = []
    @surfaces = %w[self]
    @verdict_stale = false
    @effective = nil
    @applied = false
    @motion_accepted = nil
    @action_allowed = true
    @plan = Core::Day.plan(audience: @audience, day_type: @day_type, overrides: plan_overrides(given))
    # 约定按身份各立一组（AGREE-08）：切身份就是换一组约定，一份的收紧不改另一组。
    @plans = { @profile => @plan }
    @plan_snapshot = { @profile => @plan.dup }
    # 夹具可以直接摆好每人一组（AGREE-08）：没摆的那一组在切到时按契约默认立起来。
    if given['plans']
      @used << 'plans'
      given['plans'].each do |prof, pl|
        base = Core::Day.plan(audience: default_audience(prof), day_type: @day_type, overrides: {})
        base.merge!(pl) # 版本与签署状态跟着这一组一起放（AGREE-08）
        @plans[prof] = base
        @plan = base if prof == @profile
  
      end
      @plan_snapshot = @plans.transform_values(&:dup)
    end
    @plan.merge!(@plan_overrides_given) if @plan_overrides_given
    @plan['form'] = @plan_form_seed if @plan_form_seed
    # 免题段这类时段形态要进方案，判定才说得出那句理由（DAY-03、LAYERING §4）。
    @plan['quiet'] = @quiet if @quiet
    # 每组题量是自管字段（AUTO-14）：夹具给了就用它算题量上限，没给才用默认档。
    if given['questionsPerGroup']
      @plan['questionsPerGroup'] = given['questionsPerGroup'].to_i
      @used << 'questionsPerGroup'
    end
    @extras['tierBefore'] = @start_tier if @start_tier
    seed(given)
    # 事件带版本是写入时的义务（DAY-07）：夹具里种进去那几条也一样要带，不然查账分不出改表前后。
    @ledger.events.each { |e| e.fields[:version] ||= @running_version }
    apply_calibration!
    refresh_ceiling!
    refresh_invite!
    refresh_project!
    @verdict = decide
    snapshot
  end

  def snapshot
    @subject = @profile
    # 比较基准里要带上开始时的判定，否则 unchanged: [status] 会拿 nil 去比。
    @before = { 'status' => @verdict[:status], 'tier' => @verdict[:tier] }
              .merge(derived_values).merge(@extras).merge(@plan).merge(@ledger.project(@profile))
  end

  # 跳日保留项的比较基准：用例开始时那个身份账上的量（切换不串账）。
  def project_now(profile = nil)
    @ledger.project(profile || @subject || @profile)
  end

  # 断言「保持不变」用 subject 的当日投影与跨天保留项，不受当前判定身份影响（切换不串账）。
  # 跨身份重算时要冻住的方案参数：这些是「默认值表」的内容，不是判定本身。
  PINNED_PLAN_KEYS = %w[allowanceMs graceMs moveFromMs inSlot groupsPerTask minutesPerGroup roundTarget
                        form inviteTier slots dueKinds].freeze

  VERDICT_FIELDS = { 'status' => :status, 'tier' => :tier, 'mode' => :mode, 'wording' => :wording,
                     'nextAction' => :next_action, 'blocked' => :blocked, 'tierCeiling' => :tierCeiling }.freeze

  def verdict_field(key)
    f = VERDICT_FIELDS[key.to_s]
    f ? @verdict[f] : nil
  end

  def kept(key)
    return verdict_field(key) if VERDICT_FIELDS.key?(key.to_s)

    p = project_now
    return p[key] if p.key?(key)
    return @extras[key] if @extras.key?(key)
    return contract_endpoint('exercise') if key == 'endpoint' # 这个键只答「出题走哪条路」；写的是哪一条用 writeEndpoint（一个键一个意思）
    return @plan[key] if @plan.key?(key)
    dv = derived_values
    return dv[key] if dv.key?(key)

    raise Unsupported, "#{key} 在判定、投影与保留项里都无定义"
  end

  # 统一取值：先判定结论，再当日投影，再跨天保留项，再当日方案。
  # 这份输出形状是契约声明的那一份（D47）：设备读的就是它。断言里问这些字段，
  # 就该拿同一个对象来答——再去判定/投影里各翻一遍，就是同一处规则写第二遍了。
  SHARED_OUTPUT_FIELDS = %w[status activeProfile activeMember planVersion due tier tierCeiling nextAction
                            fallbackReason pendingMotion].freeze

  def lookup(key, profile = nil)
    return @verdict[:value][key] if @verdict[:value].key?(key)
    if SHARED_OUTPUT_FIELDS.include?(key.to_s)
      s = commit_state
      k = key.to_s == 'activeMember' ? 'activeProfile' : key.to_s
      return s.key?(k) ? s[k] : nil # 这一份里没有这个字段就是「没有」，不去别处再编一个
    end
    return verdict_field(key) if VERDICT_FIELDS.key?(key.to_s)

    p = project_now(profile)
    return p[key] if p.key?(key)
    return @extras[key] if @extras.key?(key)
    return @plan[key] if @plan.key?(key)
    dv = derived_values
    return dv[key] if dv.key?(key)
    # 这个键只答「出题走哪条路」（端点注册表那一条）；写的是哪一条用 writeEndpoint——一个键一个意思。
    return contract_endpoint('exercise') if key == 'endpoint'

    raise Unsupported, "#{key} 在判定、投影、保留项、当日方案与登记表常量里都无定义"
  end

  def action_allowed
    return false if @action_allowed == false
    return false unless gate_ok?
    return false if @external_allowed == false

    true
  end

  # 清单是从事件 / 能力登记表 / roles 现值**算**出来的，不落库（ONBOARD-01）。
  def checklist_items
    @checklist ||= Core::Checklist.derive(assembly: @assembly, events: @seed_events, roles: @roles,
                                          capability: @capability, paired: @paired,
                                          extra: @extra_items, reopened: @reopened,
                                          bootAt: @boot_at, probedAt: @probed_at)
  end

  # 条目 id 自己带着装配信息（mobile./tv.，或 member:<id>.tv.）：按它自己的装配算，
  # 不然移动端的一条在电视端永远查不到（ONBOARD-06）。
  def checklist_status(id)
    id = id.to_s
    asm = id.split('.').first
    asm = id.split('.')[1] if asm == 'member'
    asm = @assembly unless %w[tv mobile].include?(asm)
    items = asm == @assembly ? checklist_items : Core::Checklist.derive(assembly: asm, events: @seed_events,
                                                                        roles: @roles, capability: @capability,
                                                                        paired: @paired, extra: @extra_items,
                                                                        reopened: @reopened,
                                                                        bootAt: @boot_at, probedAt: @probed_at)
    hit = items.find { |i| i['id'] == id }
    hit ? hit['status'] : 'notApplicable'
  end

  def trigger(name, value, member: nil)
    added = Core::Checklist.expand_trigger(name, value, assembly: @assembly,
                                           existing: checklist_items.map { |i| i['id'] },
                                           member: member)
    @extra_items.concat(added)
    @added.concat(added.map { |i| i['id'] })
    patterns = Core::Checklist::TRIGGERS[name.to_s][assembly.to_s] ||
               Core::Checklist::TRIGGERS[name.to_s]['any'] || []
    patterns.each do |pat|
      next if pat == '*'

      # 关于某个成员的那类触发只追加、不重开：新成员是「为新成员立一组」，
      # 既不改别人那一组已签的约定，也不把已有那条打回待确认（AGREE-08、ONBOARD-03）。
      next if member

      hit = checklist_items.map { |i| i['id'] }.select { |id| glob(pat, id) }
      # 带着某个成员的触发：只重开那个成员自己的条目；家庭级那条是「为新成员追加」，不是重开。
      hit.reject! { |id| member && !id.start_with?("#{member}.") } if member
      hit.each { |id| @reopened << id unless @added.include?(id) }
    end
    @checklist = nil
    # 哪些触发算一次约定变更，看契约那张表；表里没有的触发不写 PLAN_CHANGE（D42：只在这一处判）。
    field = CONTRACT.dig('enums', 'planChangeField', 'byTrigger')&.fetch(name.to_s, nil)
    append('PLAN_CHANGE', @profile, field: field) if field
    @applied = true
    @effective = 'now'
  end

  # 写入口那一条路怎么走，由 model/write.rb 那一处答（PROFILE-02、PROFILE-10、AUTO-07）。
  def write_attempt(spec)
    endpoint = spec['endpoint'].to_s
    # 这一次改的是哪几项：断言里点名，或者从 given 里那几项约定字段推出来（AUTO-07 生效时间看这一列）。
    fields = Array(spec['fields'])
    fields += Core::Write.joint_fields + Core::Write.self_fields
    fields = fields.select { |f| @given.key?(f.to_s) || spec.key?(f.to_s) }.uniq
    r = Core::Write.call(endpoint: endpoint, profile: spec['profile'], actor: @actor || @profile,
                         via: @via, scopes: @token_scopes, fields: fields, active: @profile)
    @action_allowed = r['allowed']
    @extras['httpStatus'] = r['httpStatus']
    @extras['writable'] = r['writable']
    @extras['rolesDerivableFromToken'] = r['rolesDerivableFromToken']
    @extras['writeEndpoint'] = endpoint.split(' ', 2).last
    if r['allowed']
      fields.each do |f|
        k = f.to_s
        val = spec.key?(k) ? spec[k] : @given[k]
        next if val.nil?

        # 当日方案里没这一项就不硬塞：约定字段与当日字段是两张表（DAY-01、AGREE-03）。
        @plan[k] = val if Core::Day.day_keys.include?(k) || @plan.key?(k)
      end
      unless fields.empty?
        append('PLAN_CHANGE', @profile, fields: fields.join(','))
        append('REVISION', @profile, by: @actor || @profile, target: @profile) if @via.to_s == 'panel'
        @effective = r['effective']
      end
    else
      append('REVISION', @profile, by: @actor || @profile, target: @profile) if @via.to_s == 'panel'
      # 面板那一面改不了，但当前值照样看得见——「只显示不代设」是这两件事一起成立（AUTO-14、PROFILE-05）。
      @shown << '现值' if @via.to_s == 'panel'
      @extras['reason'] = r['reason']
      @extras['writable'] = false
    end
    @verdict = decide
  end

  def role_change(rc)
    role = rc['role'].to_s
    if rc['action'].to_s == 'revoke'
      @roles.delete(role)
    else
      @roles[role] = rc['to']
    end
    append('ROLE_CHANGE', @profile, role: role, to: rc['to'])
    trigger('roleChange', rc)
  end

  def accept_item
    return unless @item

    # 受理只发生在条目 owner 自己那一侧（ONBOARD-04）；这里actor 就是这台设备上的激活身份。
    @seed_events << evidence_event_for(@item)
    @checklist = nil
    @applied = true
    @effective = 'now'
    @extras['whereAccepted'] = 'targetOwnSurface'
  end

  def egress_change(egress, reauth)
    egress.each do |k, v|
      @capability[k.to_s] = v.to_s
      @egress[k.to_s] = v.to_s
    end
    @extras['reauthenticated'] = !!reauth
    # L5 联动开关每次写一条审计（LAYER-04）；出网开关未当场再认证就不生效（D38）。
    if egress.key?('homeAssistant') || egress.key?('companionContext')
      append('audit', @profile, field: egress.keys.join(','))
      @action_allowed = false if egress.values.include?('on') && !reauth
    end
    if egress.values.include?('on')
      @shown.concat(%w[host whatLeaves howToTurnOff])
      trigger('egressAdded', egress)
    end
    @checklist = nil
    @applied = true
    @effective = 'now'
  end

  def request_mode(want)
    @mode_requested = want.to_s
    before = @plan['form'].to_s
    @plan['form'] = want.to_s
    @form_requested_now = true # 这是显式请求，不是走默认档（D36 的样本门槛只管默认档）
    # 探测把默认档抬上去：今天不抬，次日生效（D36）；显式升层当场生效。
    @effective = (@probe && Core::Capability.focused_default_ok?(@probe)) ? 'nextDay' : 'now'
    @shown.concat(ESCALATION_SHOWN)
    # 形态变了就是一次约定变更：写一条 PLAN_CHANGE，不改激励（D24、DAY-04）。
    if want.to_s != before
      append('PLAN_CHANGE', @profile, field: 'form', form: want.to_s) # 形态变了就是一次约定变更（DAY-04）
    end
    @extras['clicks'] = 1
    @extras['revertPath'] = 'present'
    @verdict = decide
    write_events(@verdict)
  end

  def tier_revert(spec)
    to = spec['to'].to_s
    # 退层是往下走：往上走就是升层，得走 LAYER-03 那条显式入口。
    if @start_tier && Core::Capability.order(to) > Core::Capability.order(@start_tier)
      raise Unsupported, "tierRevert 到 #{to} 比当前 #{@start_tier} 高，那是升层不是退层"
    end
    @plan['form'] = 'ambient'
    @reverted_to = to
    # 退层只撤这一层的呈现，账本、题库与进度一律不动（LAYER-04）。
    @applied = true
    @effective = 'now'
    @verdict = decide
    write_events(@verdict)
  end

  def l5(spec)
    # L5 只能由已签署的时段规则触发，动议不能（LAYER-11）；且必须已配对。
    by_signed = spec['by'].to_s == 'signedSlotRule'
    paired = spec.key?('paired') ? spec['paired'] : @paired
    @external_allowed = by_signed && !!paired
    @shown << '由外部设备执行'
    # 触发方不是已签署的时段规则：这条 L5 不生效，但本机别去改写别的动作已经落地的结论。
    return unless @external_allowed

    unless Core::Capability.judgment_state(@capability, 'homeAssistant')
      # 外部设备不可达：这条失效并显示，本机不冒充执行（LAYER-11）。
      @shown << '外部设备不可达，本条失效'
      @external_allowed = false
      @applied = false
      @blocked = false
      return
    end
    @verdict = @verdict.merge(tier: 'L5')
    @applied = true
    @effective = 'now'
  end

  # 个人三项（额度、宽限、起跳线）由该身份自己改，当场生效；其余参数属于共同约定，
  # 要一条变更条目与新版本才动得起来，当场不改（COMMIT-06、SENSE-07、D39）。
  PERSONAL_PLAN_KEYS = %w[allowanceMs graceMs moveFromMs].freeze

  def plan_change(pc)
    # 版本这一项走签署这一条路：没签署的版本不进「在跑的那一版」，也不写 PLAN_SIGNED（COMMIT-08）。
    if pc['version']
      @change_gate = :passed
      if @plan_signed
        @running_version = pc['version']
        append('PLAN_SIGNED', @profile, version: pc['version'])
        @effective = 'now'
        @applied = true
      else
        @effective = 'never'
        @applied = false
        @pending_version = pc['version'] # 停在「待对方签署」这一格就是这么来的（AGREE-06）
      end
      @verdict_stale = true
      return
    end
    if pc['capability']
      pc['capability'].each { |k, v| @capability[k.to_s] = v.to_s }
      @action_allowed = gate_ok?
    end
    changes = pc.reject { |k, _| %w[capability kind].include?(k) }
    if changes.empty?
      # 没有具体参数，只有「加一条后果」这类共同约定的改动：准入未过，本轮不改任何东西。
      @change_gate = :required
      @effective = 'nextPlanVersion'
      @applied = false
      return
    end
    shared = changes.keys.map(&:to_s) - PERSONAL_PLAN_KEYS
    unless shared.empty?
      @change_gate = :required
      @effective = 'nextPlanVersion'
      @applied = false
      return
    end
    return unless authorized_change?

    # 夹具里改量常写成 {from: 3600000, to: 5400000}：要改的是 to 那个值。
    changes = changes.transform_values { |v| v.is_a?(Hash) ? v['to'] : v }
    shrinking = changes.any? { |k, v| plan_number(k) > v.to_i }
    changes.each { |k, v| @plan[k.to_s] = v.to_i }
    append('PLAN_CHANGE', @profile, keys: changes.keys.join(','), direction: shrinking ? 'down' : 'up')
    @effective = shrinking ? 'nextDay' : 'now' # 调大当日即时重算，调小自次日生效（DAY-04）
    @applied = true
    @checklist = nil
    @verdict_stale = true
  end

  # 标定记录是摄像头计数唯一说了算的证据：从没标过（attempts 0）就照默认档关着；
  # 标过但没过线，这条通路就是 unknown，不能当它可用（SENSE-02、SENSE-04）。
  # 邀请这一条只由 Core::Sense.invite 答（SENSE-07）；这一轮的动作若说不推，就不推（D34）。
  # 以前这里是三处 @extras['notify'] = 'none'——那是把「不推」当常量写，邀请那一档从来没被答过。
  # 项目安不安全、能练多久，只由 Core::Sense.project 答（SENSE-05）。
  # 缺 safety 不是按默认跑：这一项无效，退回通用目标，并且把这个事实在屏上说出来。
  def refresh_project!
    return if @project_safety.nil? # 这一轮没问项目这一条：不去答，也不去盖别人的答案（D41）

    pr = Core::Sense.project(safety: @project_safety, tasks: Array(@project_tasks),
                             session_ms: @project_session_ms, rounds: @ledger.project(@profile)['roundsDone'])
    pr.each { |k, v| @extras[k] = v unless v.nil? }
    return if pr['projectValid'] == false && @project_safety.nil?

    unless pr['projectValid']
      @external_allowed = false
      @shown << '通用目标（该项目缺安全说明）'
      return
    end
    @shown << pr['promptName'] if pr['promptCount'].to_i.positive?
    return unless pr['allowed'] == false

    # 达当日轮数上限：不再邀请，也不再排新的组（SENSE-05）。两个都听模型的，这里不再各判一次。
    @notify_suppressed = pr['notify'] == 'none'
    @external_allowed = false
  end

  # 实际应用了几个能力上限：由执行面那一处答（AUTO-01、PROFILE-01）。这里不再判一次。
  def refresh_ceiling!
    @extras['ceilingApplied'] = Core::Enforcement.ceiling_applied(plan: @plan, capability: @capability)
    @extras['ceilingFieldsApplied'] = Core::Enforcement.ceiling_fields_applied(plan: @plan, capability: @capability)
  end

  def refresh_invite!
    inv = Core::Sense.invite(tier: @invite_tier, declined: @invite_declined, today: @invitations_today)
    @invite_view = inv
    @extras['notify'] = inv['notify'] unless @notify_suppressed
    inv.each { |k, v| @extras[k] = v unless k == 'notify' }
  end

  def invite_view
    @invite_view || refresh_invite! && @invite_view
  end

  def apply_calibration!
    rec = @extras['calibration']
    return unless rec.is_a?(Hash) && rec['attempts'].to_i.positive? && !Core::Sense.self_test_ok?(rec)

    # 没达标就是没达标：这条通道停在 unknown（SENSE-02 那条明写），不写成 off 也不写成 granted；
    # 「这一条回到待确认」走的是重开那一条路，不改能力现值。
    @capability['cameraChannel'] = 'unknown'
    @shown.concat(Core::Sense.self_test_failed_hints(rec))
    trigger('selfTestFailed', true) # 证据不过期：这一条回到待确认，不靠提醒（ONBOARD-07）
  end

  # 作答：一条作答一条 ANSWER（ASK-05）；计划内已经答过的题不再问，也就没有作答（ASK-06）；
  # 满组即止，之后只有本人自愿继续才再问（ASK-05）——这几条规则在 core/task 里只写一次。
  def answers(list)
    q = @ledger.project(@profile)
    target = @plan['roundTarget'].to_i
    if Core::Task.already_answered?(same_kp: @same_kp, answered: q['answeredInTask'])
      @action_allowed = false
      @extras['taskEnded'] = true
      @recomputed = false # 不再问也不重算（ASK-06）
      return
    end
    full = target.positive? && q['answeredInTask'].to_i >= target
    if full && !Core::Task.may_continue?(task_done: @task_done)
      @extras['taskEnded'] = true
    else
      Array(list).each do |r|
        correct = r.to_s == 'correct'
        append(Core::Task::ANSWER_EVENT, @profile, correct: correct, kp: @extras['kpId'])
        # 状态只由这一笔作答推：答对算连对，答错等确认题的结果（ASK-03）。
        @kp_state = Core::Kp.after_answer(state: @kp_state, correct: correct, run: @correctRun)
        @correctRun = correct ? @correctRun + 1 : 0
        next if correct

        append('MISSED', @profile) # 答错落补一补池一条 MISSED（ASK-04）
      end
      # 确认题只跟着那道答错的题出，答对时不再叠一层迁移（ASK-03、ASK-05）。
      if @confirmation && !Array(list).any? { |r| r.to_s != 'correct' }
        @confirmation = nil
      end
      if @confirmation
        @kp_state = Core::Kp.after_answer(state: @kp_state, correct: false,
                                         confirmation: @confirmation, run: @correctRun)
      end
      q = @ledger.project(@profile)
      @extras['taskEnded'] = target.positive? && q['answeredInTask'].to_i >= target
    end
    Core::Task.settle(q['answeredInTask'], target, q['roundsDone']).each { append('ROUND_DONE', @profile) }
    @verdict = decide
    write_events(@verdict)
  end

  # 机检不过：不出、不入库、不重试，退回固定题面（ASK-08、CONTEXT-05）。
  def verify(result)
    return unless result.to_s == 'failed'

    append('llm_generate_failed', @profile)
    @extras.merge!(Core::Pick::VERIFY_FALLBACK)
    @applied = true
    @effective = 'now'
  end

  # 传感器计次的结果：计到了就写一条计次事件，判不准或样本不足就退回手动确认；
  # 误判不扣分也不进池（ASK-10、SENSE-04）。
  def exercise_verdict(kind)
    @extras['sensorModeAllowed'] = Core::Pick.sensor_mode_ok?(@estimate_accuracy, @accuracy_attempts)
    @extras['manualConfirmation'] = true
    @extras['exerciseVerdict'] = kind.to_s
    if @offline
      # 上报通道不通：这一条挂成待同步，不写成已完成（SENSE-06）。
      @shown << '本次待同步'
      @extras['dayTokenKept'] = true
      @applied = false
    elsif kind.to_s == 'counted'
      append('ROUND_DONE', @profile, signalSource: @signal_source || 'sensor')
      @applied = true
    else
      @shown << '手动确认入口' if kind.to_s == 'ambiguous'
      @applied = false
    end
    @verdict = decide
    write_events(@verdict)
  end

  # 这一轮要出哪道题：取材顺序、题面形状门禁与依赖展示都在这里算一次（ASK-01、ASK-06）。
  def pick!
    @source = Core::Pick.source(pack_hit: @hits['pack'], member_authored_hit: @hits['member'],
                               llm_hit: @hits['llm'], egress: @egress)
    @shown << '来源标记' if Core::Pick.marked?(@source)
    @shown << '依赖状态' if @prereq_state
    @shown << '选题理由' unless @shape.empty?
    unless @shape.empty?
      @authoring = Core::Pick.authoring(@shape)
      @shown << '校验状态'
      # authoring 不过就退回固定题面（ASK-06、PACK-03），这条退回也算一次回退生效。
      @extras['fallbackApplied'] = true if @authoring == 'rejected'
      @action_allowed = false unless Core::Pick.shape_ok?(@shape)
    end
    @shown << '当前模式与原因' if @source == 'outlineRandom'
    # 时段外不提问（ASK-07），但时长照记（DAY-08）。
    @action_allowed = false unless Core::Day.in_slot?(@plan)
  end

  def answers_correct
    @ledger.events.count { |e| e.kind == Core::Task::ANSWER_EVENT && e.profile == @profile && e.field('correct') }
  end

  # 出现过事件的身份集合：零点刷新的行数与会话可重构性都按它算（DAY-04b）。
  def profiles_with_events
    @ledger.events.map { |e| e.profile }.uniq
  end

  def q_backlog
    @ledger.project(@profile)['backlogSize'].to_i
  end

  def plan_number(key)
    @plan[key.to_s].to_i
  end

  # 改共同约定要 ruleEditor；改自己的那三项要本人（D39）。没给 actor 时按激活身份算。
  def authorized_change?
    # 没登记任何角色时不做额外的授权判断：这台机上就是激活身份在改自己的那三项。
    return true if @roles.empty?
    return true unless @actor

    @actor == @profile || @roles['ruleEditor'].to_s == @actor.to_s
  end

  def read_endpoint(path)
    case path
    when 'GET /api/checklist'
      items = checklist_items
      @shown.concat(Core::Checklist.guide_permissions(items))
      egress = items.select { |i| i['category'] == 'egress' }
      @shown.concat(%w[host whatLeaves howToTurnOff]) unless egress.empty?
      # 摄像头通道那一页要写明用途与「画面不出本机」（SENSE-02）。
      if items.any? { |i| Core::Checklist.probe_cap(i) == 'cameraChannel' }
        @shown.concat(%w[画面不出本机 用途说明])
      end
      @extras['writable'] = egress.none? { |i| i['owner'] == 'member' }
      @extras['perDevice'] = Core::Checklist::PER_DEVICE
      @extras['acknowledgementOnlyItems'] = Core::Checklist::ACKNOWLEDGEMENT_ONLY_ITEMS
      @extras['guideIsFirstFiveItems'] = Core::Checklist.guide(items).size == Core::Checklist::GUIDE_ITEMS
      @extras['itemSources'] = Core::Checklist::ITEM_SOURCES
      @extras['fallbackRules'] = Core::Capability::FALLBACK_RULES
      @extras['inWeeklyReport'] = Core::Report.includes_checklist?
      @extras['starsDelta'] = Core::Checklist.stars_delta
      @extras['masteryDelta'] = 0
      @extras['otherItemsUnaffected'] = true
      @extras['item'] = @item ? "#{@item}:#{checklist_status(@item)}" : nil
      @surfaces << 'devicePage'
      @shown << '前五项' if @extras['guideIsFirstFiveItems'] # 首启引导讲的就是前五项
    else
      @extras['endpointRead'] = path
    end
  end

  def ledger_pending_motion
    @ledger.pending_motion(@profile)
  end

  def derived_values
    {
      # 层与能力（LAYER-01/05/06/12）
      'tierValues' => Core::Capability.tier_values,
      'tierSourceFields' => Core::Capability.tier_source_fields,
      'tierCeilingLifted' => false,
      'probeScheduled' => Core::Capability::PROBE_ON_BOOT,
      'probeOnMainThread' => Core::Capability::PROBE_ON_MAIN_THREAD,
      'inAppFallback' => Core::Capability::IN_APP_FALLBACK,
      'appSwitchRestoreMs' => Core::Capability::APP_SWITCH_RESTORE_MS,
      'accessibilitySurface' => Core::Capability::ACCESSIBILITY_SURFACE,
      'bootReceiver' => Core::Capability::BOOT_RECEIVER,
      'sceneRows' => Core::Capability.scene_rows(root),
      'fallbackApplied' => @capability.values.any? { |v| %w[unknown denied off].include?(v.to_s) },
      'fallbackRules' => Core::Capability::FALLBACK_RULES,
      'clicks' => 1,
      'revertPath' => 'present',
      # 清单（ONBOARD-*）
      'perDevice' => Core::Checklist::PER_DEVICE,
      'acknowledgementOnlyItems' => Core::Checklist::ACKNOWLEDGEMENT_ONLY_ITEMS,
      'itemSources' => Core::Checklist::ITEM_SOURCES,
      'guideIsFirstFiveItems' => Core::Checklist.guide(checklist_items).size == Core::Checklist::GUIDE_ITEMS,
      'storedFields' => Core::Checklist::STORED_FIELDS,
      'derived' => Core::Checklist::DERIVED_FIELDS,
      'inWeeklyReport' => Core::Report.includes_checklist?,
      'starsDelta' => Core::Checklist.stars_delta,
      'masteryDelta' => 0,
      'otherItemsUnaffected' => true,
      'humanAction' => 'none',
      'recalculatedToday' => true,
      'installedBy' => @profile,
      # status 是从事件算出来的，界面只读内核结论（DAY-02）。
      'statusFrom' => 'events',
      # 这一份约定本身也要能进「保持不变」那一类比较（AUTO-04）。
      'plan' => @plan,
      # 清单项的 status 与判定的 status 是两件事，别共用一个键（ONBOARD-04、DAY-02）。
      'checklistStatusFrom' => 'probeEvidence',
      'uiComputesVerdict' => false,
      'probeSampleCount' => Core::Sense::SELF_TEST_ATTEMPTS,
      'falseCountMax' => Core::Sense::FALSE_COUNT_MAX,
      'item' => @item ? "#{@item}:#{checklist_status(@item)}" : nil,
      'capabilityState' => @capability,
      # 「每项能力必须登记当前层」——措辞与判定读的都是登记表这一份（LAYER-01）。
      # 免题段：grace 等于 allowance 就是「这个身份默认不出题」的写法（DAY-03）；全天 quiet 同解。
      # 自管那几项有几项，只由契约 selfManagedFields 那一处清单数（AUTO-02、AUTO-14）。
      # 按受众的分支位点：这条扫描就是 PROFILE-02 那道 CI 门，断言与门读同一处（一条规则一处写）。
      'allowedBranchSites' => BRANCH_SITES,
      'branchInForbiddenSites' => branch_in_forbidden_sites,
      # 页面清单：页名只由契约那张表答（PANEL-01、PANEL-02，与上面那条扫描同一个路子）。
      'pageRefsUnresolved' => page_refs_unresolved,
      'panelPages' => CONTRACT.dig('panel', 'pages').to_a.size,
      'pageAnswersStated' => CONTRACT.dig('panel', 'pages').to_a.all? { |g| g['title'].to_s != '' && g['answers'].to_s != '' },
      'wherePagesResolve' => where_pages_resolve,
      'selfManagedFields' => Core::Write.self_fields.size,
      'anyAudienceMayHold' => CONTRACT.dig('roles', 'anyAudienceMayHold') == true,
      'profileDomain' => CONTRACT.dig('enums', 'profileDomain', 'values'),
      'usedAsHealthDiagnosis' => Core::Sense.used_as_health_diagnosis,
      'bodyFontSp' => presentation_row['bodyFontSp'],
      'contrastRaised' => presentation_row['contrastRaised'],
      'pendingItems' => @pending_items_given || checklist_items.count { |i| %w[pending unknown].include?(checklist_status(i['id'])) },
      'sessions' => profiles_seen.each_with_object({}) { |who, h| h[who] = @ledger.project(who) },
      'watchedRecorded' => @ledger.events.any? { |e| e.kind == 'WATCHED' },
      # 各设备各一行：这台的那行是判定用的数，另一台那行只是列出来（DAY-10）。
      'watchedPerDevice' => @ledger.by_device(@profile),
      # 手机与电视的直连只为体感与视觉两件事（SENSE-06、D77）：这几项只由契约 link 那一处答。
      # 「这段时间的账」那一页（REPORT-01..04、D78）：三条开关与那批词都由契约 report 那一处答。
      # 面板那 12 页的可用性只在 panel.availability 那一处答（PANEL-02、D80）。
      # 这台电视上的启动形态（LAYER-14、ONBOARD-11、ONBOARD-12）：只在 startup 那一处答。
      # 内容包的许可与来源（PACK-02、PACK-09、D82）：判定在 model/content.rb 那一处，门也调它。
      'packLicenseOk' => Core::Content.license_ok?(Core::Content.pack_license),
      'packDistribution' => Core::Content.distribution,
      'packConditional' => Core::Content.conditional?,
      'packConditionalRequires' => Core::Content.conditional_requires,
      'packRevokeRules' => Core::Content.revoke_rules.size,
      'packRevoked' => Core::Content.revoked?,
      'packLicenseBlockedND' => !Core::Content.license_ok?('CC BY-ND 4.0'),
      'packLicenseBlockedCCBY' => !Core::Content.license_ok?('CC-BY-4.0'),
      'packBindingGrades' => Core::Content.binding_grades.size,
      'packExcludedGrades' => Core::Content.excluded_grades.size,
      'packHighSchoolBound' => Core::Content.high_school_bound?,
      'packGradeOkG5' => Core::Content.grade_ok?('child', 5),
      'packGradeOkG7' => Core::Content.grade_ok?('child', 7),
      'packGradeOkG11' => Core::Content.grade_ok?('child', 11),
      'packTextbookFilter' => Core::Content.textbook_filter?,
      'packTextbookMarks' => Core::Content.textbook_marks.size,
      'packTextbookHit' => Core::Content.textbook_hit?('课文里的天空是什么样的？'),
      'packAttributionLanded' => Core::Content.attribution_landed,
      'packAttributionPending' => Core::Content.attribution_pending,
      'packAttributionBroken' => Core::Content.attribution_broken,
      'startupCollapse' => Core::Startup.collapse?,
      'startupFullScreenForbidden' => Core::Startup.full_screen_forbidden?,
      'startupSelfStartForbidden' => Core::Startup.self_start_forbidden? && !Core::Startup.boot_permission_declared?,
      'startupExceptions' => Core::Startup.exceptions.size,
      'autoOpenCount' => Core::Startup.auto_open_count,
      'autoOpenNeverHits' => Core::Startup.never_hits(@auto_open_target),
      'autoOpenTarget' => Core::Startup.auto_open_target(@auto_open_target).to_s,
      'autoOpenRetries' => Core::Startup.retries,
      'panelAvailable' => Core::Panel.available?,
      'panelUnavailableStated' => Core::Panel.marker_stated? && Core::Panel.marked_in_first_run?,
      'reportPush' => Core::Report.push?,
      'reportComparison' => Core::Report.comparison?,
      'reportVisibleTo' => Core::Report.visible_to,
      'reportForbiddenWords' => Core::Report.forbidden_words(@ledger, @profile),
      'reportNeverSingleSource' => Core::Report.never_single_source?,
      'reportWindowDays' => Core::Report.window_days,
      'reportRows' => Core::Report.row_count(@ledger, @profile),
      'linkKinds' => Core::Sense.link_kinds,
      'linkCarries' => Core::Sense.link_carries,
      'frameLeavesDevice' => Core::Sense.frame_leaves_device,
      'quizIssued' => @plan['graceMs'].to_i < @plan['allowanceMs'].to_i,
      'quiet' => @quiet,
      # 会话可由事件重构：凡是出现过事件的身份，都要能算出它自己的那一行（DAY-04b）。
      # 会话能不能重构，问的是「每条观看与完成类事件是不是都带着自己的身份」，不是靠切换去猜（DAY-04b）。
      'sessionsReconstructable' => @ledger.events
                                     .select { |e| %w[WATCHED DONE ROUND_DONE OVER MISSED].include?(e.kind) }
                                     .all? { |e| !e.profile.to_s.empty? },

      # 零点刷新按身份逐条写行，代码同一份（DAY-04b、DAY-06）。
      'rowsPerProfile' => @roll_rows == MEMBERS.size,
      'dayRolled' => !!@rolled_today,
      'runningVersion' => @running_version,
      'versionInEveryEvent' => @ledger.events.all? { |e| e.fields.key?(:version) },
      # 冻结与续算：恢复时接着冻结那一刻走，不是从刷新后的值重新累计（COMMIT-07）。
      'resumedFrom' => @frozen_watched,
      'motionRequired' => @extras['motionRequired'],
      'mastery' => @extras.fetch('mastery', 'unchanged'),
      'visibleOn' => @extras['visibleOn'],
      'inReport' => @extras['inReport'] || (Core::Report.includes_checklist? ? 'familyReport' : 'none'),
      # 内核输出的形状：字段与落层都从 CommitState 这一份取（M1.4）。
      'commitStateTier' => commit_state['tier'],
      'registryTier' => (k = @capability.keys.find { |x| Core::Capability.known?(x) }) ? Core::Capability.tier(k) : nil,
      # 选题与知识点（ASK-01/03/04/06/07/10、PACK-02/04）：这里只摆规则算得出的量，
      # 题干文本与星级估算在内容包里，模型不自己编（PACK-08）。
      'source' => @source,
      'stemChars' => @shape['stemChars'],
      'optionsLines' => @shape['optionsLines'],
      'singleKey' => @shape['singleKey'],
      'estimatedSeconds' => @shape['estimatedSeconds'],
      'stemIdentical' => true,
      'dynamicGeneration' => @source == 'llm' ? 1 : 0,
      'extraSources' => Core::Pick.extra_sources(egress: @egress),
      'questionPickedAt' => Core::Pick.picked_at(@due_at),
      'candidateLevel' => Core::Pick.candidate_level(@kp_state),
      # 生效组数与每组题量只由 DAY-05 这一处算（ASK-02、AUTO-14）。
      'effectiveGroups' => Core::Day.effective_groups(@plan),
      'maxQuestions' => Core::Day.max_questions(@plan),
      'approvalRequired' => false,
      'fieldsPerItem' => Core::Pick::MEMBER_AUTHORED_FIELDS,
      'eventProfile' => @profile,
      'poolSize' => q_backlog,
      'evicted' => @ledger.backlog_raw(@profile) > Core::Ledger::BACKLOG_CAP ? Core::Kp::EVICTED : 'none',
      'priorityReask' => Core::Kp.priority_reask(@extras['wrongAnswers']),
      # 星只入账：答对一道入一颗，传感器误判与答错都不扣（AUTO-13、ASK-10）。
      'stars' => Core::Kp.star_count(answers_correct),
      'sensorModeAllowed' => Core::Pick.sensor_mode_ok?(@estimate_accuracy, @accuracy_attempts),
      'signalSource' => @signal_source ||
                       (Core::Pick.sensor_mode_ok?(@estimate_accuracy, @accuracy_attempts) ? 'sensor' : 'manual'),
      'recomputed' => @recomputed.nil? ? true : @recomputed,
      # 墙钟回跳当日不重放：重放这件事从来不该发生，模型里没有重放这条路（DAY-07）。
      'replayed' => false,
      # 「生效组数」是当日可由做题完成的次数上限，「补一补」是欠账队列——不是同一个量（DAY-05）。
      'poolSame' => Core::Day.effective_groups(@plan) == q_backlog,
      'dayTokenKept' => @day_token_kept,
    }
  end

  # 跨身份重算：同一个方案与四量，只换身份/受众，必要时再乘上强度。
  # 判定不该随之变（PROFILE-01、LAYER-07「矩阵对所有身份同一张」）。
  def recompute_multi(field, dimension:)
    base_given = @given.reject { |k, _| k == 'spec' }
    dims = dimension.to_s == 'profile' ? MEMBERS : CONTRACT['enums'][dimension.to_s]['values']
    # 只有按身份重算时才乘上强度档（PROFILE-01）；按受众/在场重算时强度固定，
    # 否则把两个维度混在一起乘，断言就不是它说的那件事了。
    strengths = dimension.to_s == 'profile' && !Array(@strengths).empty? ? @strengths : [@strength]
    vals = []
    dims.each do |d|
      strengths.each do |s|
        g = base_given.dup
        g['profile'] = d if dimension.to_s == 'profile'
        g['audience'] = dimension.to_s == 'audience' ? d : @audience
        g['strength'] = s.to_s unless s.nil? # 没有强度这一档时别塞个空串进去
        # 把方案里的参数全部冻住（含默认形态），只比判定与层本身：
      # 否则「判定是否随身份变」会被「默认值表是否随身份不同」混进来（PROFILE-01、LAYER-07）。
      PINNED_PLAN_KEYS.each { |k| g[k] = @plan[k] if @plan.key?(k) }
        w = World.new(g)
        w.apply(Marshal.load(Marshal.dump(@written_when || {})))
        vals << w.value_for(field)
      end
    end
    vals
  end

  def root
    File.expand_path('..', __dir__)
  end

  # 准入是算出来的，不是存下来的：登记表里没有的能力占不了 LAYERING §2 的行（LAYER-12）。
  # 出网开关是另一条轴（谁能开、开了什么走得出去），不在 LAYERING §2 的场景表里占行，
  # 所以它不参与分层准入；准入只问本机那几条强制力与感知通路。
  def gate_ok?
    return false if @change_gate == :required

    (@capability.keys - Core::Checklist::EGRESS_SWITCHES).all? { |k| Core::Capability.known?(k) }
  end

  # 出网开关是另一条轴（谁能开、开了什么走），不参与分层准入，也不参与形态降级（LAYER-12）。
  def enforcement_capability_map
    @capability.reject { |k, _| Core::Checklist::EGRESS_SWITCHES.include?(k) }
  end

  def gate
    gate_ok? ? 'passed' : 'required'
  end

  def shown
    @shown
  end

  def surfaces
    @surfaces
  end

  def evidence_event_for(id)
    seg = id.to_s.split('.')
    cat = seg[-2].to_s
    { 'agree' => 'PLAN_SIGNED', 'role' => 'ROLE_CHANGE', 'profile' => 'MOTION_SETTLED' }[cat] || 'MOTION_SETTLED'
  end

  def value_for(key)
    lookup(key)
  end


  # 呈现侧读量：这一屏可能就是没有这个数（已受理的暂停段没有 remainingMs），读不到就是「没有」，
  # 不报错也不编一个。断言侧仍走严格的 lookup——未知键必须记「未支持」（D41）。
  def value_opt(key)
    lookup(key)
  rescue Unsupported
    nil
  end

  def unconsumed
    @given.keys - @used.to_a - %w[spec]
  end

  def apply(when_)
    when_ = when_.dup
    # 跨身份重算要拿同一轮的动作重跑一遍，所以先把原始动作存住（下面的分支会把键逐个删掉）。
    @written_when = Marshal.load(Marshal.dump(when_))
    if when_.key?('motion')
      motion(when_.delete('motion'))
    end
    if when_.key?('switch')
      switch(when_.delete('switch'))
    end
    if when_.key?('switchTo') # 夹具里写成「这一轮切到某个身份」（AGREE-08、AGREE-09）
      switch('to' => when_.delete('switchTo'))
    end
    if when_.key?('crossedMidnight')
      roll!(when_.delete('crossedMidnight'))
    end
    if when_.key?('rebooted') && when_.delete('rebooted')
      roll!(@day, reboot: true)
      @extras['dayTokenKept'] = true # 重启沿用当日 token，不重放（DAY-07）
      @boot_at = '20:01'
      @probed_at ||= '20:00' # probe/auth 类证据比这次重启早 → 自动重开（ONBOARD-07）
      @checklist = nil
      @extras['probeScheduled'] = true
    end
    if (ms = when_.delete('watchedMs'))
      add_watch(ms)
    end
    # 清单相关的动作：触发追加、受理、导出、开关、升层、退层、L5、时段规则变更。
    if (m = when_.delete('memberAdded'))
      trigger('memberAdded', m, member: m)
    end
    if when_.key?('deviceAdded')
      a = when_.delete('deviceAdded')
      @assembly = a.to_s if a
      trigger('deviceAdded', a)
    end
    if (rc = when_.delete('roleChange'))
      role_change(rc)
    end
    if when_.key?('contentBindingChanged')
      when_.delete('contentBindingChanged')
      trigger('contentBindingChanged', true)
    end
    if when_.key?('paired')
      val = when_.delete('paired')
      @paired = val
      trigger('l5PairChanged', val) if val
      @applied = true
      @effective = 'now'
      @extras['installedBy'] = @profile
    end
    if when_.delete('accepted')
      accept_item
    end
    if when_.key?('export')
      when_.delete('export')
      @extras.merge!(Core::Checklist.export(checklist_items).slice('storedFields', 'derived'))
      @extras['completeness'] = Core::Checklist.completeness(checklist_items)
    end
    if (spec = when_.delete('put'))
      write_attempt('endpoint' => spec)
    end
    if (spec = when_.delete('writeAttempt'))
      write_attempt('endpoint' => "PUT #{spec['path']}", 'profile' => spec['profile'], 'fields' => spec['fields'])
    end
    if when_.key?('egress')
      egress_change(when_.delete('egress'), when_.delete('reauth'))
    elsif when_.delete('reauth')
      @extras['reauthenticated'] = true
    end
    if (want = when_.delete('modeRequested'))
      request_mode(want)
    end
    if (rv = when_.delete('tierRevert'))
      tier_revert(rv)
    end
    if (spec = when_.delete('l5'))
      l5(spec)
    end
    if (pc = when_.delete('planChange'))
      plan_change(pc)
    end
    if (path = when_.delete('get'))
      read_endpoint(path)
    end
    if (aud = when_.delete('audience'))
      # 受众是「默认值挑选」那一个入口的输入：换受众换的是默认那一行，不是规则（PROFILE-01）。
      @audience = aud.to_s
      @used << 'audience'
      @plan = Core::Day.plan(audience: @audience, day_type: @day_type, overrides: plan_overrides(@given))
    end
    if (at = when_.delete('at'))
      @round_at = at # 这一轮挂在墙上几点：收紧次日生效那一条要看它（DAY-07、D37）
    end
    if (ms = when_.delete('retryAfterMs'))
      # 「过会儿再问」那个数不在这里定：动议那一条端点的冷却是唯一的出处（AUTO-16）。
      @extras['cooldownMs'] = CONTRACT.dig('endpoints').find { |e| e['path'] == '/api/motions' }['cooldownMs']
      @extras['retryAfterObservedMs'] = ms
    end
    if when_.delete('simulate')
      # 模拟这条端点没有第二套算法：跑的就是这一轮的判定本身，所以两者必然同语义（DAY-09）。
      @extras['endpointsSameSemantics'] = endpoints_same_semantics?
    end
    if (g = when_.delete('selfGrade'))
      self_grade(g)
    end
    if (rv = when_.delete('revision'))
      revision(rv)
    end
    if (cal = when_.delete('calibration'))
      @extras['calibration'] = cal
      apply_calibration!
    end
    if (ser = when_.delete('series'))
      counting(ser)
    end
    if (ry = when_.delete('rhythm'))
      rhythm(ry)
    end
    if when_.key?('unansweredFor')
      when_.delete('unansweredFor') # 动议无人受理就是未受理，时长不改变结论
    end
    if when_.key?('reauth')
      when_.delete('reauth')
    end
    if when_.key?('capability')
      changed = when_.delete('capability')
      granted_now = changed.select { |_, v| %w[granted on].include?(v.to_s) }
      # 厂商固件可能在重启时静默清掉授权（事实 F1）。这种情况不能只写日志：审计 + 画面内说明（LAYER-04）。
      revoked = changed.select { |k, v| @capability[k.to_s] == 'granted' && %w[denied off].include?(v.to_s) }
      @capability.merge!(changed)
      # 「开启前先标定」：标过但没过线，这条通路就不算成立（SENSE-02）。
      apply_calibration!
      unless revoked.empty?
        append('audit', @profile, field: revoked.keys.join(','))
        @shown << '当前模式与原因'
        @plan['form'] = 'ambient'
        @verdict_stale = true
      end
      @checklist = nil
      # 探测结果回来即自动补做：当场重算，不写事件也不发通知（ONBOARD-06）。
      unless granted_now.empty?
        @applied = true
        @effective = 'now'
      end
      @verdict = decide
      write_events(@verdict)
    end
    if when_.key?('mode')
      @plan['form'] = when_.delete('mode')
      @form_requested_now = true
      @verdict_stale = true
    end
    if when_.key?('signalSource')
      src = when_.delete('signalSource')
      @signal_source = src
      self_test = @extras['calibration']
      counting = Core::Sense.methods(@capability, selfTest: self_test)
      @extras['counting'] = counting
      @extras['manualConfirmation'] = counting.include?('manual')
      @extras['frameRetentionMs'] = Core::Sense::FRAME_RETENTION_MS # 帧不留盘（SENSE-01）
      @extras['diskWrites'] = Core::Sense::DISK_WRITES_PER_ROUND
      # 摄像头通道默认关、传感器未探到一律不驱动功能，退回手动确认（SENSE-02、ONBOARD-06）
      unless src.to_s == 'manual'
        @action_allowed = Core::Sense.allowed?(src, capability: @capability, selfTest: self_test)
      end
      @extras['capability'] = @capability.map { |k, v| [k, Core::Capability.state_of(@capability, k)] }.to_h
      # 计次确认只能由本人发起（AUTO-14）：actor 不是激活身份时这条不生效
      @shown << '自检状态' if counting.include?('manual') # 停在保底通路时把自检状态摆出来
      if src.to_s == 'manual'
        if @actor == @profile
          append('ROUND_DONE', @actor, reps: 1, signalSource: src)
          @applied = true
        else
          @action_allowed = false
          @applied = false
        end
      elsif @action_allowed != false
        # 传感器/摄像头通路成立时这一组由它记，落盘的仍只有这一条计次事件（SENSE-01）。
        append('ROUND_DONE', @profile, signalSource: src, counting: counting.join('+'))
        @applied = true
      end
      @verdict = decide
      write_events(@verdict)
    end
    # 暂停段的时长是这一轮报上来的实测值，动议受理之后才落到 motion_state 上（COMMIT-07）。
    if when_.key?('pauseMs')
      @frozen_watched = @ledger.project(@profile)['watchedMs'] # 冻结的就是这一轮的已看时长
      @used << 'pauseMs'
      @pause_ms = when_.delete('pauseMs').to_i
    end
    # 确认题的结果要在作答之前拿到：它是跟着那道答错的题出的（ASK-03、ASK-05）。
    if when_.key?('confirmation')
      @confirmation = when_.delete('confirmation')
    end
    # 完成只写 DONE / ROUND_DONE，绝不写任何时长发放事件（COMMIT-05、DAY-04）。
    if when_.key?('taskDone') && when_.delete('taskDone')
      @task_done = true
      append('DONE', @profile)
      append('ROUND_DONE', @profile)
      @extras['mastery'] = 'updated'
      @applied = true
      @effective = 'now'
    end
    # 截止未达成只写 MISSED：后果只有那四类，进的是自己那一页的账（COMMIT-06、DAY-04、REPORT-03）。
    if when_.key?('deadlinePassed') && when_.delete('deadlinePassed')
      append('MISSED', @profile)
      @extras['inReport'] = 'ownWeekly'
      @notify_suppressed = true # 这一轮的动作不许推第二条：只有这一处说「不推」（D34）
      @shown << 'overdue 状态条'
      @applied = true
      @effective = 'now'
    end
    if (ans = when_.delete('answers'))
      answers(ans)
    end
    if when_.key?('questionShown') && when_.delete('questionShown')
      # 时机与选题相互独立：实际呈现了就写 due_shown，不为了凑时机提前出题（ASK-07）。
      append('due_shown', @profile) if Core::Day.in_slot?(@plan)
    end
    if (v = when_.delete('verify'))
      verify(v)
    end
    if (ev = when_.delete('exerciseVerdict'))
      exercise_verdict(ev)
    end
    if when_.key?('exerciseDone') && when_.delete('exerciseDone')
      append('ROUND_DONE', @profile, reps: 1, signalSource: @signal_source || 'sensor')
      @verdict = decide
      write_events(@verdict)
    end
    presented = when_.key?('stillWatching')
    if presented || when_.key?('inSlot') || @verdict_stale
      when_.delete('stillWatching')
      @plan['inSlot'] = when_.delete('inSlot') if when_.key?('inSlot')
      @verdict = decide
      # 确实把这道题呈现出去了才写 due_shown；时机与选题互不影响（ASK-07）。
      if presented && @verdict[:due] && Core::Day.in_slot?(@plan)
        append('due_shown', @profile)
      end
      write_events(@verdict)
    end
    # seed 里带进来的自管项：当场生效，不走签署（AUTO-14、AUTO-07）。后面那些动作若自己定了时机，以动作为准。
    @effective ||= 'now' if @self_managed_now
    raise Unsupported, "动作键 #{when_.keys.join(", ")}" unless when_.empty?

    self
  end

  # 电视端要读的那一份：契约 commitState 的形状（M1.4）。工具与设备端读的都是这个出口。
  # 断言侧要读派生视图里的少数几项（visibleOn 这类），走这个出口，别开内部变量。
  # 与快照同一份：extras 里那些「这一轮算出来的东西」也要能读到。
  # 有没有一份签过的约定：方案标了签过、账里有 PLAN_SIGNED，或某一组是签过的（AGREE-01）。
  # 签没签是**按身份**算的（AGREE-08）： kid 签过不等于切到 dad 之后也有一份签过的约定。
  def plan_signed?
    @plan_signed == true ||
      @ledger.events.any? { |e| e.kind.to_s == 'PLAN_SIGNED' && e.profile.to_s == @profile.to_s } ||
      @plans.dig(@profile, 'signed') == true
  end

  def derived
    # 「这一屏是不是全按默认跑」「是不是停在待对方签署」这两条从账与方案算出来，
    # 不在夹具里写第二遍（AGREE-04、AGREE-06）。
    signed = @ledger.events.any? { |e| e.kind.to_s == 'PLAN_SIGNED' }
    @extras['defaultsOnly'] = !signed && @plan_signed != true
    @extras['signaturePending'] = !@pending_version.nil? && @plan_signed != true
    @extras['agreementStep'] = @agreement_step
    # 「这一步按默认，去哪儿改」由模型那一处答（契约 agreement.firstRun.where）：
    # 没给 agreementStep 就没答这条——直接炸，不退成一个看着合理的空值（D67 那一条的同一家族）。
    if @agreement_step
      at = Core::Agreement.screen_index_for_step(@agreement_step)
      screen = Core::Agreement.setup_screen(@plan, at, 1, @plan_signed)
      where = screen['where']
      @extras['defaultsWhere'] = where
      # 屏上有没有写明去哪儿改：要选的步骤不问这个（它给的是现值，不是默认）✓
      @extras['whereStated'] = !where.nil?
    end
    # 别人的那一组约定不受这一份的收紧影响（AGREE-08）：拿开局快照比，不看这一份改了什么。
    @extras['otherProfileUnchanged'] = @plans.reject { |k, _| k == @profile }
                                       .all? { |k, pl| @plan_snapshot[k] == pl }
    derived_values.merge(@extras)
  end
  # 模拟那条端点没有第二套算法：现算一遍与这一屏那份逐字段相同，就是同一份语义（DAY-09、PROFILE-07）。
  def endpoints_same_semantics?
    commit_state == Core::Commit.state(**decide_args, signed: plan_signed?,
                                                    pending: ledger_pending_motion)
  end

  # 这台设备这一本账见过谁：账里出现过谁就算谁，名字不是设备编的（PROFILE-01、PROFILE-04）。
  def profiles_seen
    (@ledger.events.map { |e| e.profile.to_s }.reject(&:empty?) + [@profile]).uniq
  end

  # 呈现档那一行的数只由契约那两处表给（PROFILE-01、PROFILE-05）。
  def presentation_row
    tier = @presentation || CONTRACT.dig('profile', 'defaults', 'byAudience').fetch(@audience.to_s, '标准')
    CONTRACT.dig('profile', 'defaults', 'tiers').fetch(tier.to_s)
  end

  def commit_state
    Core::Commit.state(**decide_args, signed: plan_signed?, pending: @ledger.pending_motion(@profile))
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

  # 当日方案里模型会真正用到的字段。其余状态键一律记为「未消费」，由调用方判未支持。
  def plan_overrides(given)
    o = {}
    # dueKinds 也在这里：这一档的约定项有哪几类是**方案参数**（默认值挑选那一处给，PROFILE-11），
    # 不加进来就等于夹具给了、模型没拿到——那条断言会绿着空转（今天就是这么撞上的）。
    %w[allowanceMs graceMs moveFromMs inSlot groupsPerTask minutesPerGroup roundTarget dueKinds].each do |k|
      next unless given.key?(k)

      o[k] = given[k]
      @used << k
    end
    if given.key?('slots')
      o['slots'] = given['slots']
      @used << 'slots'
    end
    o
  end

  def seed(given)
    @self_managed_now = false
    # 自管那两项也是判定的输入：题目数上限与「补一补是否先补完」（PROFILE-06、AUTO-02、ASK-04）。
    %w[questionsPerTaskCap clearBacklogFirst].each do |k|
      next unless given.key?(k)

      @used << k
      @plan[k] = given[k]
      @self_managed_now = true # 自管那一项不经过签署：摆上就是这一份的现值（AUTO-07、AUTO-14）。
    end
    # 一台设备一本账：只有**这台设备**的段进这台账（DAY-10、D77）。以前这里把两台的段相加（并集），
    # 等于把「另一台看了多久」算进这台的约定判定里——那条待确认项今天已由用户答了：不合。
    # 另一台的段不进账，只作为另一份账列出来（面板各列一行），所以它不参与任何判定。
    if given['sessions']
      @used << 'sessions'
      Array(given['sessions']).each do |s|
        ms = s['to'].to_i - s['from'].to_i
        append('WATCHED', @profile, ms: ms, device: s['device']) if ms.positive?
      end
    end
    if given['watchedMs']
      @used << 'watchedMs'
      append('WATCHED', @profile, ms: given['watchedMs'].to_i)
    end
    if given['overMs']
      @used << 'overMs'
      append('OVER', @profile, ms: given['overMs'].to_i)
    end
    if given['pauseMs']
      @used << 'pauseMs'
      append('MOTION', @profile, kind: 'pause', target: @profile)
      append('MOTION_SETTLED', @profile, kind: 'pause', pauseMs: given['pauseMs'].to_i)
      @motion_state = { 'pause' => true, 'pauseMs' => given['pauseMs'].to_i }
    end
    %w[roundsDone answeredInTask backlogSize].each do |k|
      next unless given[k]

      @used << k
      kind = { 'roundsDone' => 'ROUND_DONE', 'answeredInTask' => 'ANSWER', 'backlogSize' => 'MISSED' }[k]
      given[k].to_i.times { append(kind, @profile) }
    end
    if given.key?('checklistStatus') && given['item']
      # 夹具里的「这条现在是什么状态」一律物化成证据，免得状态从外部灌进派生视图。
      case given['checklistStatus'].to_s
      when 'done'
        # 成员级的条目（member:<id>.<装配>.<类别>.<项>）要先存在才算「已确认」：
        # 它是由「成员加入」这个触发产生的，不是凭空多出来的一条（ONBOARD-03）。
        if given['item'].to_s.start_with?('member:')
          trigger('memberAdded', given['item'].to_s.split('.').first, member: given['item'].to_s.split('.').first)
          @seed_events << evidence_event_for(given['item'])
        else
          @seed_events << evidence_event_for(given['item'])
        end
      when 'unknown' then @capability[Core::Checklist.probe_cap('id' => given['item'])] = 'unknown'
      end
    end
    # 播种期间由触发物化出来的条目不算「本轮新增」，也不代表本轮做了应用动作（ONBOARD-03）。
    @added = []
    @reopened = []
    @applied = false
    @effective = nil
    %w[wrongAnswers srsProgress pendingReview planVersion kpId kpState carryOver calibration].each do |k|
      next unless given[k]

      @used << k
      @extras[k] = given[k]
    end
  end

  # 零点刷新：同一个 dayToken 只滚一次；重启与同日重复调用不滚（DAY-06、DAY-07）。
  def roll!(crossed, reboot: false)
    token = reboot ? @day : (crossed ? 'd2' : @day)
    # 墙钟向前跳得有单调时钟佐证才允许滚新一天；单靠墙跳就是改了系统时间（DAY-07）。
    if crossed && @clock['wallClockDeltaMs'].to_i.positive? &&
       @clock['monotonicDeltaMs'].to_i < @clock['wallClockDeltaMs'].to_i
      @rolled_today = false
      @applied = false
      @effective = 'never'
      @verdict = decide
      return self
    end
    # usage_day 每身份一行，全家成员都要刷到；宽约定线与紧约定线走同一份代码（DAY-04b）。
    @roll_rows = MEMBERS.size
    @rolled_today = crossed && !reboot
    # 刷新前后池子里的条数要一样：整池清空是缺陷，不是新周期的正常结果（DAY-07）。
    # 当日归属令牌同理——跨零点由刷新换新，重启不该换（DAY-06、DAY-07）。
    pool_before = q_backlog
    token_before = @ledger.day_token
    @pool_same = true
    @day_token_kept = true
    @applied = @ledger.roll!(token)
    @pool_same = q_backlog == pool_before
    @day_token_kept = @ledger.day_token == token_before
    @motion_state = nil if @applied # 零点刷新连 pauseMs 一起归零（DAY-06）
    @effective = 'now' if @applied
    @verdict = decide
  end

  def append(kind, profile, **fields)
    # 每条事件都带它当时依哪一版规则（DAY-07）：查账才分得清是改表前还是改表后。
    @ledger.append(kind, profile: profile, at: '20:00', version: @running_version, **fields)
    @written << kind.to_s
    kind.to_s
  end

  def add_watch(ms)
    append('WATCHED', @profile, ms: ms.to_i)
    @verdict = decide
  end

  # 内核的入参只在这里拼一次：判定与 CommitState 用的是同一份（M1.4）。
  def decide_args
    { profile: @profile, plan: @plan, q: @ledger.project(@profile), strength: @strength,
      mode: @mode_requested, motion_state: @motion_state || @ledger.accepted_pause(@profile) || {}, capability: @capability,
      probe: @probe, requested: !!@form_requested_now }
  end

  def decide
    v = Core::Commit.decide(**decide_args)
    @shown.concat(Array(v[:fallbackReason])) if v[:fallbackReason]
    pick!
    @shown.concat(Core::Sense.display_tokens(signal_source: @signal_source,
                                             false_count_rate: @extras.dig('calibration', 'falseCountRate')))
    apply_form_fallbacks!
    # 形态是设置层面的事实：没有到期项时也照样有 ambient / focused 这一档，别报成 nil。
    v[:mode] ||= @plan['form'] || 'ambient'
    v
  end

  # 没有到期项时形态也照样会降级；判据不在这里重复写，直接问判定内核那一条（D42、D45）。
  def apply_form_fallbacks!
    return if Core::Commit.focused_holds?(form: @plan['form'], capability: @capability, probe: @probe,
                                          requested: @form_requested_now, strength: @strength || 'negotiated')

    @plan['form'] = 'ambient'
    @shown << '当前模式与原因' unless @shown.include?('当前模式与原因')
  end

  def write_events(v)
    v[:events].each do |k|
      fields = {}
      fields[:ms] = v[:value]['overMs'] if k == 'OVER'
      append(k, @profile, **fields)
    end
  end

  # 自己给自己批：批完就入账，没有「先批完才入账」那一步（AUTO-15、COMMIT-05）。
  def self_grade(verdict)
    @extras['gradedBy'] = 'self'
    @extras['selfGrade'] = verdict
    @extras['mastery'] = 'updated'
    append('ANSWER', @profile, gradedBy: 'self', correct: verdict.to_s == 'pass')
  end

  # 修订：面板与对方都能提，提的是「怎么看这一份」，不改约定也不改账里的量（PROFILE-06、AUTO-04、AUTO-15）。
  def revision(spec)
    if spec['reason'].to_s.include?('更新说明')
      # 「查阅更新说明」不是修订：不装东西、也不由这条路径改任何状态；更新由这一档的自己装（AUTO-15.4）。
      append('REMOTE', @profile, by: @actor || @profile, action: 'checkUpdate')
      @extras['remoteInstall'] = false
      @extras['installedBy'] = @profile
      @action_allowed = false
      @applied = false
      return
    end
    append('REVISION', @profile, by: spec['by'] || @actor, verdict: spec['verdict'], reason: spec['reason'])
    # 契约字段新增这一类修订不改 schema 的语义：两条路径仍是同一份判定（PROFILE-07、DAY-09）。
    @action_allowed = false # 修订不动这一份约定的值：能提，不能改（AUTO-04）
    @extras['schemaUnchanged'] = false
    @extras['endpointsSameSemantics'] = endpoints_same_semantics?
    @extras['unchangedPlan'] = spec['verdict'].to_s == 'none'
    @extras['stars'] = 'recalculated'
    @extras['visibleOn'] = %w[self panel]
    @applied = true
    @effective = 'now'
  end

  # 体感那一侧的节律计次：帧只在这一趟里过，落盘的只有计次（SENSE-01）。
  # 项目名从这一段节律的第一条里取（契约 sense.counting.byKind 那一处认得它）。
  # F13 要对照的就是这一支：算法计数的次数由模型数一次，执行器不自己数（SENSE-01、D45）。
  # 这一支不写账：传感器计次不兑换时长，入账走本人确认那一条（D24、AUTO-14）。
  def counting(series)
    got = Core::Sense.count(kind: series.to_a.first&.[]('kind'), rhythm: series)
    %w[countedReps ambiguousReps rejectedReps].each { |k| @extras[k] = got[k] }
    @extras['manualConfirmation'] = true if got['manualConfirmation']
    @extras['verdicts'] = got['verdicts']
  end

  def rhythm(spec)
    @extras['counterInputFields'] = CONTRACT.dig('sense', 'rhythm', 'fields').to_a.size
    counted = Core::Sense.rhythm_counted?(spec)
    append('ROUND_DONE', @profile) if counted
    @applied = counted
    @effective = counted ? 'now' : @effective
  end

  def motion(spec)
    kind = spec['kind']
    @extras['inTighteningComparison'] = CONTRACT.dig('motion', 'tightening', 'kinds').to_a.include?(kind.to_s)
    # 收紧类次日生效，延一延当场生效：这一条时机只由契约 motion.tightening 那一处答（DAY-07、D37）。
    @motion_accepted = spec.fetch('accepted', false)
    append('MOTION', @profile, kind: kind, target: spec['target'] || @profile)
    target = spec['target'] || @profile
    # 挂在谁那儿就在谁的界面上受理：不是在发起方那儿算数（PROFILE-10、AUTO-16）。
    @extras['whereAccepted'] = CONTRACT.dig('motion', 'whereAccepted').fetch(target == @profile ? 'self' : 'other')
    @extras['httpStatus'] = @motion_accepted ? CONTRACT.dig('motion', 'httpAccepted') : CONTRACT.dig('motion', 'httpCreated')
    unless @motion_accepted
      # 没受理什么都不发生（D34），也就没有第二条提醒。
      @notify_suppressed = true
      append('MOTION_UNANSWERED', @profile, kind: kind)
      # 没受理的动议不是黑名单：在双方界面上各显示一条，面板有只读视图（AUTO-03、COMMIT-07）。
      @extras['visibleOn'] = %w[self panel]
      @effective = 'never'
      @applied = false
      return
    end
    @motion_state = nil
    if CONTRACT.dig('motion', 'tightening', 'kinds').to_a.include?(kind.to_s) && spec['tighten']
      @effective = CONTRACT.dig('motion', 'tightening', 'effective')
    end
    settled = { kind: kind }
    if kind == 'pause'
      # 报上来实测时长就用实测的，没报才用默认段的长度；冻结值在受理那一刻取（COMMIT-07）。
      @motion_state = { 'pause' => true,
                        'pauseMs' => @pause_ms || (spec['minutes'] || 10).to_i * 60_000 }
      @frozen_watched ||= @ledger.project(@profile)['watchedMs']
      # 对自己的会话可即时暂停，不需要一条待受理的动议（AUTO-16、COMMIT-07）。
      @extras['motionRequired'] = spec['target'].to_s != 'self' && spec['target'] != @profile
      settled[:pauseMs] = @motion_state['pauseMs']
    end
    append('MOTION_SETTLED', @profile, **settled)
    # 受理了也不额外推一条：动议条目在面板留一条记录、只显示一次，那属于呈现，不属于提醒（D34、AUTO-16）。
    @notify_suppressed = true
    @extras['visibleOn'] = %w[panel]
    case kind
    when 'extend'
      @plan, offset = Core::Commit.apply_extend(@plan, spec['minutes'] || 0)
      @extras['dayOffsetMs'] = offset
      append('PLAN_CHANGE', @profile, field: 'allowanceMs')
    end
    @verdict = decide
    write_events(@verdict)
    @effective ||= 'now' # 收紧类已在上面定了次日生效，这里不覆盖（DAY-07、D37）
    @applied = true
  end

  # 切换身份 = 换一组约定（AGREE-08、AGREE-09）：目标身份有已生效的约定就加载，没有就走那六步的起点。
  def switch(spec)
    to = spec['to']
    if @plans.key?(to)
      @plan = @plans[to]
      # 加载那一组的生效版本与签署状态——约定是按身份各立一组（AGREE-08）。
      @running_version = @plan['version'] if @plan.key?('version')
      @plan_signed = !!@plan['signed'] if @plan.key?('signed')
    else
      @plans[to] = Core::Day.plan(audience: default_audience(to), day_type: @day_type, overrides: {})
      @plan = @plans[to]
      @agreement_step = 1
    end
    @plan_snapshot[to] ||= @plan.dup
    switch_body(spec, to)
  end

  # 两端同源用的一条：把按身份各存的那几份方案摆进来，并按账里的 PROFILE_SWITCH 换到人（AGREE-08）。
  # 不这么读，设备切到了 dad、Mac 这边还拿 kid 的方案算——那是比对器的错，不是内核的分歧。
  def load_plans(plans)
    plans.each do |who, plan|
      base = Core::Day.plan(audience: plan['audience'] || default_audience(who), day_type: @day_type, overrides: {})
      base.merge!(plan)
      @plans[who] = base
    end
    @plan = @plans[@profile] if @plans.key?(@profile)
    @plan_signed = !!@plan['signed'] if @plan.key?('signed')
  end

  def activate(to)
    return if to == @profile

    @profile = to
    @plan = @plans[to] if @plans.key?(to)
    @plan_signed = !!@plan['signed'] if @plan.key?('signed')
  end

  def switch_body(spec, to)
    # 空账也写：from/to 是这一条的语义，取值是标识符不是计数，不许用空账省掉（D31、PROFILE-10.3）。
    append('PROFILE_SWITCH', to == 'none' ? 'none' : to, from: spec['from'] || @profile, to: to)
    @profile = to
    @used << 'activeMember' # 换到人就是把当前档换掉：这一处消费 activeMember 那个写法
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
  when 'nextAction' then cmp(want, world.commit_state['nextAction']) # 与设备读的是同一份 CommitState（D47）
  when 'blocked' then cmp(want, world.verdict[:blocked])
  when 'allowed' then cmp(want, world.action_allowed)
  when 'wording' then cmp(want, world.verdict[:wording])
  # 写入口这一族：结论由 model/write.rb 给，断言这边只搬运，不再判一次。
  when 'gradedBy' then cmp(want, world.derived['gradedBy'])
  # 「有没有升级施压的阶梯」由执行面那一份手段清单答：没有这类手段就是 false（AUTO-05）。
  when 'escalate' then cmp(want, Core::Enforcement::SURFACE.any? { |s| s.to_s =~ /escalat|lock|force|block/i })
  when 'httpStatus' then cmp(want, world.derived['httpStatus'])
  when 'writable' then cmp(want, world.derived['writable'])
  when 'rolesDerivableFromToken' then cmp(want, world.derived['rolesDerivableFromToken'])
  when 'due' then cmp_due(want, world.verdict[:due])
  when 'surface' then Array(want).all? { |s| (Array(world.verdict[:surface]) + world.surfaces).include?(s) } ? :pass : :fail
  when 'shown' then Array(want).all? { |s| all_shown(world).include?(s) } ? :pass : :fail
  when 'notShown' then Array(want).none? { |s| all_shown(world).include?(s) } ? :pass : :fail
  when 'events' then Array(want).all? { |k| world.written.include?(k) } ? :pass : :fail
  when 'noEvents' then Array(want).none? { |k| world.written.include?(k) } ? :pass : :fail
  when 'absent' then Array(want).all? { |n| absent?(n) } ? :pass : :fail
  when 'value' then want.all? { |k, v| cmp(resolve(v, world), world.value_for(k)) == :pass } ? :pass : :fail
  when 'delta' then want.all? { |k, d| cmp(d.to_i, world.kept(k).to_i - world.before[k].to_i) == :pass } ? :pass : :fail
  when 'unchanged' then want.all? { |k| cmp(world.before[k], world.kept(k)) == :pass } ? :pass : :fail
  when 'tierCeiling' then cmp(want, world.verdict[:tierCeiling])
  when 'capability' then want.all? { |k, v| Core::Capability.state_of(world.capability, k) == v.to_s } ? :pass : :fail
  when 'visibleOn' then Array(want) == Array(world.derived['visibleOn']) ? :pass : :fail
  when 'sameSource' then Array(want).all? { |n| same_source?(n, world) } ? :pass : :fail
  # 产出的字段集合是否就是契约声明的那一组（多了少了都算不一致）。
  when 'stateFields'
    world.commit_state.keys == CONTRACT['commitState']['fields'] ? :pass : :fail
  when 'evidenceFrom' then Array(want).all? { |n| evidence_from?(n, world) } ? :pass : :fail
  when 'checklist' then checklist_assert(want, world)
  when 'reopened' then Array(want).all? { |p| world.reopened.any? { |id| glob(p, id) } } ? :pass : :fail
  when 'checklistStatus' then cmp(want, world.checklist_status(world.item))
  when 'egress' then want.all? { |k, v| world.egress[k.to_s].to_s == v.to_s } ? :pass : :fail
  when 'roles' then want.all? { |r, v| world.roles[r.to_s].to_s == v.to_s } ? :pass : :fail
  # inReport: none 是「不进任何一页的账」；ownWeekly 是「只进这条账自己的那一页」（COMMIT-06、REPORT-03）。
  when 'inReport'
    want.to_s == 'none' ? (Core::Report.includes_checklist? ? :fail : :pass) : cmp(want, world.derived['inReport'])
  # notify: none 是「不发任何提醒」；once 是「这条动议在面板只出现一次」（AUTO-16、COMMIT-06）。
  when 'notify' then cmp(want, world.derived['notify'])
  # 掌握状态随每次作答更新，不是一个分数；unchanged 用在「这轮什么都没动」（COMMIT-05）。
  when 'mastery' then cmp(want, world.derived['mastery'])
  when 'presentIn' then Array(want).all? { |c| Core::Capability.channels(world.verdict[:tier]).include?(c) } ? :pass : :fail
  when 'gate' then world.gate.to_s == want.to_s ? :pass : :fail
  when 'source' then cmp(want, world.pick_source)
  when 'authoring' then cmp(want, world.authoring)
  when 'kpState' then cmp(want, world.kp_state)
  # 「批/重算」这一列是状态词，不是数量（数量走 value: {stars: N}）；修订那条由 revision 那一处答。AUTO-15、PROFILE-06。
  when 'stars' then cmp(want, world.extras['stars'] || Core::Kp.stars(true)) # 数量走 value: {stars: N}；这里问的是状态词
  # 一条断言回答一个问题：这里问的那件事必须是模型答得出的（D41）。
  when 'answerable' then world.value_for(Core::Pick::QUESTION_FIELDS.fetch(want.to_s, want.to_s)).nil? ? :fail : :pass
  when 'identicalAcross' then identical_across(want, world)
  when 'accepted' then cmp(want, world.motion_accepted)
  when 'applied' then cmp(want, world.applied)
  when 'effective' then cmp(want, world.effective)
  # —— 约定怎么立（spec/AGREE.md）：这四条由模型答，不在夹具里写第二遍。
  when 'defaultsOnly' then cmp(want, world.derived['defaultsOnly'])
  when 'signaturePending' then cmp(want, world.derived['signaturePending'])
  when 'agreementStep' then cmp(want, world.derived['agreementStep'])
  when 'defaultsWhere' then cmp(want, world.derived['defaultsWhere'])
  when 'whereStated' then cmp(want, world.derived['whereStated'])
  when 'otherProfileUnchanged' then cmp(want, world.derived['otherProfileUnchanged'])
  else
    # 模型答得出的键（derived/extras）走通用比较：这些值一律由模型算出来，
    # 执行器不在这儿写第二个答案（D42、D45）。答不出来的键仍然落到下面的「未支持」。
    if world.derived.key?(key)
      cmp(want, world.derived[key])
    else
      raise Unsupported, "断言键 #{key}"
    end
  end
end

# 词汇表里的符号值（vocab.yaml 里标了 type 的那几个）在断言里指代当下的人，不是字面串。
def roll_profiles_from(given)
  given['strengths']
end

def resolve(v, world)
  return world.profile if v.to_s == 'activeMember'
  # 冻结值是设备端在受理那一刻取的一手数，断言里用 frozenValue 指它（COMMIT-07）。
  return world.value_for('resumedFrom') if v.to_s == 'frozenValue'
  # 断言里也可以直接引用 given 里的字段名（ASK-07 的 questionPickedAt: dueAt）。
  return world.given[v.to_s] if world.given.key?(v.to_s)

  v
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

# 「只有一处来源」是靠文件与 SPEC 标签立住的，不是靠运行时打点：这里查的是这个产物
# 确实登记在来源登记表上、且那个文件还在——把「换个地方另算一份」挡住。
def same_source?(name, _world = nil)
  _kind, file = PRODUCERS[name.to_s]
  raise Unsupported, "来源 #{name} 不在来源登记表里" unless file

  File.exist?(File.join(ROOT_DIR, file))
end

EVIDENCE_KINDS = { 'capability' => :capability, 'probe' => :capability, 'checklist' => :checklist,
                   'ledger' => :ledger, 'roles' => :checklist }.freeze

# 证据来源查的是「这条结论现在靠什么立住」：证据类别来自条目自己，不是这一轮跑过什么。
def evidence_from?(name, world)
  kind = EVIDENCE_KINDS[name.to_s]
  raise Unsupported, "证据来源 #{name} 不在登记表里" unless kind

  case kind
  when :capability then world.capability.any? || world.checklist_items.any? { |i| %w[probe].include?(i['evidence']) }
  when :checklist then world.checklist_items.any? { |i| %w[roles event].include?(i['evidence']) }
  when :ledger then world.ledger.raw_events.any?
  when :roles then world.roles.any?
  end
end

def checklist_assert(want, world)
  if want.key?('added')
    got = world.added
    return :fail if want['added'].empty? && !got.empty?
    want['added'].all? { |p| got.any? { |id| glob(p, id) } } ? :pass : :fail
  elsif want.key?('reopened')
    want['reopened'].all? { |p| world.reopened.any? { |id| glob(p, id) } } ? :pass : :fail
  elsif want.key?('ids')
    have = world.checklist_items.map { |i| i['id'] }
    want['ids'].all? { |p| have.any? { |id| glob(p, id) } } ? :pass : :fail
  else
    raise Unsupported, "checklist 断言只有 added / reopened / ids 三种"
  end
end

# `*.agree.plan` 这类写法指「按装配/成员展开后的那一条」。
def glob(pattern, id)
  File.fnmatch(pattern.to_s, id.to_s, File::FNM_PATHNAME == 0 ? 0 : 0) ||
    File.fnmatch?(pattern.to_s, id.to_s, 0) || pattern.to_s == id.to_s
end

def identical_across(want, world)
  dim = want['dimension']
  Array(want['fields']).all? do |f|
    world.recompute_multi(f, dimension: dim).uniq.size == 1
  end ? :pass : :fail
end

# 画面里出现了什么：判定给的提示 + 这一轮动作添上去的提示（升层三句、L5 委托说明等）。
def all_shown(world)
  Array(world.verdict[:shown]) + Array(world.shown)
end

def absent?(name)
  if name.to_s =~ %r{\A(GET|POST|PUT|DELETE) /}
    # 端点「不能出现」= 契约里确实没有这条路径，不是见不到字串就判绿。
    return CONTRACT['endpoints'].none? { |e| e['path'] == name.to_s.split(' ', 2).last }
  end
  return false if CODE_SOURCE.include?(name.to_s)

  # 契约的定义面里不能出现；登记处（禁止清单、空位、说明文字）里出现是正当的。
  !CONTRACT_DEF.include?(name.to_s)
end

# 按受众分支只许出现在那两处（PROFILE-01、PROFILE-02）：位点靠代码里的一行标记认领。
# 这条扫描同时喂断言（branchInForbiddenSites / allowedBranchSites）与 CI——不在两处各写一遍规则。
BRANCH_SITES = %w[内容绑定解析 默认值挑选].freeze
AUDIENCE_SITE_MARK = /audience-site:\s*(#{BRANCH_SITES.join('|')})/.freeze

def audience_branch_scan
  bad = []
  sources = Dir[File.join(root, 'model/*.rb')] + Dir[File.join(root, 'core/src/main/kotlin/**/*.kt')] +
            Dir[File.join(root, 'device/android/app/src/main/java/**/*.java')]
  sources.each do |f|
    lines = File.readlines(f)
    lines.each_with_index do |line, i|
      next unless line =~ /\baudience\b/
      next if line =~ %r{^\s*(//|/\*|\*|#)} # 注释与文档句不算位点

      # 标记要么写在这一行上，要么往回看五行之内——只往回看，不许往前看（往前看等于让后面某处
      # 一句标记把整片都洗白，反证「删掉一处标记」就是这么暴露的）。三行太紧：函数里加两行
      # 说明就把自己钉的位点洗没了（这一条今天就是这样撞上的），五行还留着「换个函数就藏不住」这条约束。
      back = lines[[i - 5, 0].max...i].count { |l| l =~ AUDIENCE_SITE_MARK }
      bad << "#{File.basename(f)}:#{i + 1}" if back.zero? && line !~ AUDIENCE_SITE_MARK
    end
  end
  bad
end

def branch_in_forbidden_sites
  @branch_in_forbidden_sites ||= audience_branch_scan.size
end

# 页名与每页回答哪个问题，只在 contract.panel.pages 那一处（PANEL-01）。
PAGE_TITLES = CONTRACT.dig('panel', 'pages').to_a.map { |g| g['title'].to_s }.freeze
PAGE_REF = /「([\p{L}\p{N}][^」]{0,7})」(?:那一)?页/u.freeze # 首字符得是字或数字：省略号那种占位写法不算页名（\W 在 Ruby 里只管 ASCII，别拿它挡 CJK）

def page_refs
  where = []
  sources = Dir[File.join(root, 'docs/**/*.md')] + Dir[File.join(root, 'spec/*.md')] +
            [File.join(root, 'contract/contract.json')]
  sources.sort.each do |f|
    File.readlines(f).each_with_index do |line, i|
      line.scan(PAGE_REF) { |(name)| where << [name.to_s, "#{File.basename(f)}:#{i + 1}"] unless PAGE_TITLES.include?(name.to_s) }
    end
  end
  where
end

def page_refs_unresolved
  page_refs.size
end

# 首启那句「要改去……」的页名出自那张表（PANEL-02）：一张表也没有就红，不许绿着空转。
def where_pages_resolve
  wheres = CONTRACT.dig('agreement', 'firstRun').to_a.map { |s| s['where'] }.compact
  return false if wheres.empty?

  wheres.all? { |w| w.scan(PAGE_REF).flatten.all? { |name| PAGE_TITLES.include?(name.to_s) } }
end

# 一个用例的稳定编号：簇 id 加序号，`.1` `.2` 这种是文档里的分档写法（README 的调用形式靠它）。
def case_id_for(id, index, cases)
  cases.size > 1 ? id.to_s + '.' + (index + 1).to_s : id.to_s
end

# 过滤器支持两种写法：`COMMIT`（整簇）与 `COMMIT-01`（一条用例，含它的 .1 .2 分档）。
def case_selected?(case_id, pattern)
  return true if case_id == pattern
  # `DAY` 选整簇；`DAY-07` 选整条（含它的 .1 .2 分档）；`DAY-07.1` 只选那一档。
  return case_id.split('-').first == pattern if pattern !~ /-/
  return case_id.start_with?(pattern + '.') if case_id.start_with?(pattern + '.')

  case_id == pattern
end

def run(entries_filter, files)
  total = { pass: 0, fail: 0, unsupported: 0 }
  failing = []
  unsupported = []
  files.each do |f|
    doc = YAML.load_file(f)
    doc.each do |id, entry|
      # --only / 位置参数支持整簇（LAYER）也支持一条用例（LAYER-07、LAYER-07.1）：簇这一层先粗筛。
      next if entries_filter && !entries_filter.any? { |pat| id.to_s.start_with?(pat.split('.').first.split('-').first) }

      res = { pass: 0, fail: 0, unsupported: 0 }
      entry['cases'].each_with_index do |cs, i|
        case_id = case_id_for(id, i, entry['cases'])
        next if entries_filter && !entries_filter.any? { |pat| case_selected?(case_id, pat) }

        given = (entry['given'] || {}).merge(cs['given'] || {})
        begin
          world = World.new(given)
          raise Unsupported, "状态键 #{world.unconsumed.join(", ")} 模型尚未消费" unless world.unconsumed.empty?
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
  # 未支持的一律逐条列出，不做截断：藏起来就等于把没做的说成做完了。
  unless unsupported.empty?
    puts "未支持明细（#{unsupported.size} 条）："
    puts unsupported.map { |u| "  #{u}" }.join("\n")
  end
  exit(total[:fail].zero? && (!entries_filter || total[:unsupported].zero?) ? 0 : 1)
end

# 直接跑才出报告；被别的工具 require 时只暴露 World 与判定入口（tools/tv-status.rb）。
if $PROGRAM_NAME == __FILE__
  # 三种调用形式：不带参数跑全部；给一个 `COMMIT-01` 只跑那一条用例（含 .1 .2 分档）；
  # 给文件路径就只跑那个夹具。这条形式是 README 与 spec 里写的，之前只认 --only=，等于一直在说谎。
  only = nil
  files = []
  ARGV.each do |a|
    if a.start_with?('--only=')
      only = a.sub('--only=', '').split(',')
    elsif a =~ %r{^[A-Z]+(-\d+(\.\d+)?)?$}
      only = [a]
    else
      files << a
    end
  end
files = Dir[File.join(root, 'fixtures/*.yaml')].reject { |f| f.end_with?('vocab.yaml') }.sort if files.empty?
run(only, files)
end
