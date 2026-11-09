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
  when Hash then node.reject { |k, _| NOTES.include?(k) }.map { |_, v| definition_text(v) }.join('|')
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
  'core/task' => [:task, 'model/task.rb']
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

  def initialize(given)
    @given = given
    @used = Set.new
    @extras = {}
    @day = given['dayToken'] || 'd1'
    @used << 'dayToken' if given.key?('dayToken')
    @ledger = Core::Ledger.new(allowed_kinds: EVENTS, day: @day)
    @profile = given['profile'] || 'member:kid'
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
    @task_done = given['taskDone']
    @used << 'taskDone' if given.key?('taskDone')
    @same_kp = given['sameKp']
    @used << 'sameKp' if given.key?('sameKp')
    @extra_items = []
    @added = []
    @reopened = []
    @motion_state = nil
    @signal_source = nil
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
    @plan['form'] = @plan_form_seed if @plan_form_seed
    @extras['tierBefore'] = @start_tier if @start_tier
    seed(given)
    apply_calibration!
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
                        form inviteTier slots].freeze

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
    return @plan[key] if @plan.key?(key)
    dv = derived_values
    return dv[key] if dv.key?(key)

    raise Unsupported, "#{key} 在判定、投影与保留项里都无定义"
  end

  # 统一取值：先判定结论，再当日投影，再跨天保留项，再当日方案。
  def lookup(key, profile = nil)
    return @verdict[:value][key] if @verdict[:value].key?(key)
    return verdict_field(key) if VERDICT_FIELDS.key?(key.to_s)
    return contract_endpoint('exercise') if key == 'endpoint'

    p = project_now(profile)
    return p[key] if p.key?(key)
    return @extras[key] if @extras.key?(key)
    return @plan[key] if @plan.key?(key)
    dv = derived_values
    return dv[key] if dv.key?(key)

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
                                          extra: @extra_items, bootAt: @boot_at, probedAt: @probed_at)
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

      hit = checklist_items.map { |i| i['id'] }.select { |id| glob(pat, id) }
      hit.each { |id| @reopened << id unless @added.include?(id) }
    end
    @checklist = nil
    @applied = true
    @effective = 'now'
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
  def apply_calibration!
    rec = @extras['calibration']
    return unless rec.is_a?(Hash) && rec['attempts'].to_i.positive? && !Core::Sense.self_test_ok?(rec)

    @capability['cameraChannel'] = 'unknown'
  end

  # 作答：一条作答一条 ANSWER（ASK-05）；计划内已经答过的题不再问，也就没有作答（ASK-06）；
  # 满组即止，之后只有本人自愿继续才再问（ASK-05）——这几条规则在 core/task 里只写一次。
  def answers(list)
    q = @ledger.project(@profile)
    target = @plan['roundTarget'].to_i
    if Core::Task.already_answered?(same_kp: @same_kp, answered: q['answeredInTask'])
      @action_allowed = false
      @extras['taskEnded'] = true
      return
    end
    full = target.positive? && q['answeredInTask'].to_i >= target
    if full && !Core::Task.may_continue?(task_done: @task_done)
      @extras['taskEnded'] = true
    else
      Array(list).each do |r|
        append(Core::Task::ANSWER_EVENT, @profile, correct: r.to_s == 'correct')
      end
      q = @ledger.project(@profile)
      @extras['taskEnded'] = target.positive? && q['answeredInTask'].to_i >= target
    end
    Core::Task.settle(q['answeredInTask'], target, q['roundsDone']).each { append('ROUND_DONE', @profile) }
    @verdict = decide
    write_events(@verdict)
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
      @extras['inWeeklyReport'] = Core::Checklist.in_report?
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
      'inWeeklyReport' => Core::Checklist.in_report?,
      'starsDelta' => Core::Checklist.stars_delta,
      'masteryDelta' => 0,
      'otherItemsUnaffected' => true,
      'humanAction' => 'none',
      'recalculatedToday' => true,
      'installedBy' => @profile,
      # status 是从事件算出来的，界面只读内核结论（DAY-02）。
      'statusFrom' => 'events',
      # 清单项的 status 与判定的 status 是两件事，别共用一个键（ONBOARD-04、DAY-02）。
      'checklistStatusFrom' => 'probeEvidence',
      'uiComputesVerdict' => false,
      'probeSampleCount' => Core::Sense::SELF_TEST_ATTEMPTS,
      'falseCountMax' => Core::Sense::FALSE_COUNT_MAX,
      'writable' => false,
      'item' => @item ? "#{@item}:#{checklist_status(@item)}" : nil,
      'capabilityState' => @capability,
      # 「每项能力必须登记当前层」——措辞与判定读的都是登记表这一份（LAYER-01）。
      'registryTier' => (k = @capability.keys.find { |x| Core::Capability.known?(x) }) ? Core::Capability.tier(k) : nil
    }
  end

  # 跨身份重算：同一个方案与四量，只换身份/受众，必要时再乘上强度。
  # 判定不该随之变（PROFILE-01、LAYER-07「矩阵对所有身份同一张」）。
  def recompute_multi(field, dimension:)
    base_given = @given.reject { |k, _| k == 'spec' }
    dims = dimension.to_s == 'profile' ? MEMBERS : CONTRACT['enums'][dimension.to_s]['values']
    # 只有按身份重算时才乘上强度档（PROFILE-01）；按受众/在场重算时强度固定，
    # 否则把两个维度混在一起乘，断言就不是它说的那件事了。
    strengths = dimension.to_s == 'profile' && !@strengths.empty? ? @strengths : [@strength]
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
    if (ans = when_.delete('answers'))
      answers(ans)
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

  # 当日方案里模型会真正用到的字段。其余状态键一律记为「未消费」，由调用方判未支持。
  def plan_overrides(given)
    o = {}
    %w[allowanceMs graceMs moveFromMs inSlot groupsPerTask minutesPerGroup roundTarget].each do |k|
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
    v = Core::Commit.decide(profile: @profile, plan: @plan, q: @ledger.project(@profile),
                            strength: @strength, mode: @mode_requested, motion_state: @motion_state || {},
                            capability: @capability, probe: @probe, requested: !!@form_requested_now)
    @shown.concat(Array(v[:fallbackReason])) if v[:fallbackReason]
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
  when 'allowed' then cmp(want, world.action_allowed)
  when 'wording' then cmp(want, world.verdict[:wording])
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
  when 'sameSource' then Array(want).all? { |n| same_source?(n, world) } ? :pass : :fail
  when 'evidenceFrom' then Array(want).all? { |n| evidence_from?(n, world) } ? :pass : :fail
  when 'checklist' then checklist_assert(want, world)
  when 'reopened' then Array(want).all? { |p| world.reopened.any? { |id| glob(p, id) } } ? :pass : :fail
  when 'checklistStatus' then cmp(want, world.checklist_status(world.item))
  when 'egress' then want.all? { |k, v| world.egress[k.to_s].to_s == v.to_s } ? :pass : :fail
  when 'roles' then want.all? { |r, v| world.roles[r.to_s].to_s == v.to_s } ? :pass : :fail
  when 'inReport' then want.to_s == 'none' ? (Core::Checklist.in_report? ? :fail : :pass) : :fail
  when 'presentIn' then Array(want).all? { |c| Core::Capability.channels(world.verdict[:tier]).include?(c) } ? :pass : :fail
  when 'gate' then world.gate.to_s == want.to_s ? :pass : :fail
  when 'identicalAcross' then identical_across(want, world)
  when 'accepted' then cmp(want, world.motion_accepted)
  when 'applied' then cmp(want, world.applied)
  when 'effective' then cmp(want, world.effective)
  else
    raise Unsupported, "断言键 #{key}"
  end
end

# 词汇表里的符号值（vocab.yaml 里标了 type 的那几个）在断言里指代当下的人，不是字面串。
def resolve(v, world)
  return world.profile if v.to_s == 'activeMember'

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

def run(entries_filter, files)
  total = { pass: 0, fail: 0, unsupported: 0 }
  failing = []
  unsupported = []
  files.each do |f|
    doc = YAML.load_file(f)
    doc.each do |id, entry|
      # --only 支持整条 id 也支持前缀（LAYER / LAYER-07 都能选）。
      next if entries_filter && !entries_filter.any? { |p| id.start_with?(p) }

      res = { pass: 0, fail: 0, unsupported: 0 }
      entry['cases'].each_with_index do |cs, i|
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
