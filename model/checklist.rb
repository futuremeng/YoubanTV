# SPEC: ONBOARD-01, ONBOARD-02, ONBOARD-03, ONBOARD-04, ONBOARD-05, ONBOARD-06, ONBOARD-07, ONBOARD-08, ONBOARD-09, ONBOARD-10
# 待确认清单：从事件、能力登记表与 roles 现值**算出来**的一张视图。这里不落清单项，也不建表
# （ONBOARD-01、ONBOARD-10）。固定项与元数据只有一处来源——docs/ONBOARDING.md §2 / §3 的表；
# 代码里不另存一份，避免两处各说各话。
require 'set'
require 'json'
require_relative 'capability'

module Core
  module Checklist
    STATUSES = %w[pending done unknown notApplicable].freeze
    # 一台设备一份（ONBOARD-01）。
    PER_DEVICE = true
    # 存储里只落这几项（ONBOARD-10）。
    STORED_FIELDS = %w[id owner where status evidence addedAt].freeze
    DERIVED_FIELDS = %w[owner where addedAt].freeze
    # 不设「我知道了」型条目（ONBOARD-09）。
    ACKNOWLEDGEMENT_ONLY_ITEMS = 0
    GUIDE_ITEMS = 5 # 首启引导 = 固定项前五项（暂定取值）
    # 达成这些条目需要请求的权限，只列当前层必需的（LAYER-02 末段）。
    PERMISSIONS = { 'auth.overlay' => '悬浮窗授权', 'auth.usageAccess' => '使用情况访问' }.freeze
    ITEM_SOURCES = 1 # 只有 derive 这一处生成条目

    # 出网类条目按契约的 egressSwitch 展开，不在代码里手写名单（ONBOARD-08）。
    # 开关名单读 Capability（契约的 egressSwitch 枚举），这里不另存一份（D42）。
    EGRESS_SWITCHES = Capability::EGRESS_SWITCHES

    # 触发 → 追加的条目（ONBOARD-03）。展开规则与 docs/ONBOARDING.md §4 那张表一一对应，
    # 改那张表必须同时改这里。`*` 按装配展开；带 MEMBER_SCOPED 的条目再前置到成员（谁的事谁那侧做）。
    TRIGGERS = {
      'memberAdded' => { 'tv' => %w[*.agree.plan *.agree.slots tv.profile.binding],
                         'mobile' => %w[*.agree.plan *.agree.slots] },
      'deviceAdded' => { 'any' => %w[*] },
      'crossPlatform' => { 'any' => %w[*.agree.plan] },
      'roleChange' => { 'tv' => %w[*.role.holder], 'mobile' => %w[*.egress.state] },
      'memberRemoved' => { 'any' => %w[*.profile.archive] },
      'contentBindingChanged' => { 'any' => %w[*.pack.license] },
      'egressAdded' => { 'any' => %w[*.egress.*] },
      'clockChanged' => { 'any' => %w[*.time.clockDrift] },
      'cameraChannelOn' => { 'mobile' => %w[*.device.calibrate] },
      'l5PairChanged' => { 'tv' => %w[*.device.pair] },
      # 自检不过 → 标定那条回到待确认：证据不过期这一条走的是重开，不是提醒（ONBOARD-07、SENSE-04）。
      'selfTestFailed' => { 'any' => %w[*.device.calibrate] }
    }.freeze
    # 一台设备一份清单，但约定与命名是「某个成员在这台设备上」的事，要多一段前缀（PROFILE-10）。
    MEMBER_SCOPED = %w[agree profile].freeze
    # 系统更新或重启：不新增条目，只把 probe / auth 类的证据作废（ONBOARD-07）。
    REOPEN_CATEGORIES = %w[probe auth].freeze

    module_function

    def doc(root = nil)
      root ||= File.expand_path('..', __dir__)
      File.read(File.join(root, 'docs/ONBOARDING.md'))
    end

    # §2 / §3 的表就是固定项登记表本身。
    def fixed(assembly, root = nil)
      src = doc(root)
      sec = src[/^## #{assembly == 'mobile' ? 3 : 2}\..*?(?=^## )/m].to_s
      rows = sec.lines.select { |l| l.start_with?('| `') }
      rows.flat_map { |l| expand(l) }
    end

    def expand(row)
      cells = row.split('|').map(&:strip)[1..]
      raw = cells[0].to_s[/`([^`]+)`/, 1].to_s
      _id, confirm, owner, where, evidence, fallback = cells[0..5] # id 从 raw 那个反引号里取
      items = []
      if raw.end_with?('.*') && raw.include?('egress')
        EGRESS_SWITCHES.each do |sw|
          items << item(raw.sub(/\.\*\z/, ".#{sw}"), confirm, owner, where, evidence, fallback)
        end
      else
        items << item(raw.sub(/（可选）$/, ''), confirm, owner, where, evidence, fallback)
      end
      items
    end

    def item(id, confirm, owner, where, evidence, fallback)
      { 'id' => id, 'confirm' => confirm.to_s.delete('`').sub(/（可选）$/, ''),
        'owner' => owner_kind(owner), 'ownerText' => owner.to_s,
        'where' => where.to_s.sub(/（.*）/, ''), 'whereKind' => where_kind(where),
        'evidence' => evidence_kind(evidence), 'evidenceText' => evidence.to_s,
        'fallback' => fallback.to_s, 'category' => id.split('.')[1].to_s,
        'optional' => confirm.to_s.include?('可选') }
    end

    def owner_kind(text)
      t = text.to_s
      return 'system' if t.include?('无需成员')
      return 'role:keyHolder' if t.include?('keyHolder')
      return 'role:ruleEditor' if t.include?('ruleEditor')

      'member'
    end

    # 受理只发生在对方自己的界面（ONBOARD-04）。
    def where_kind(text)
      t = text.to_s
      return 'panel' if t.include?('面板')
      return 'page' if t.include?('页')

      'surface'
    end

    def evidence_kind(text)
      t = text.to_s
      return 'event' if t =~ /PLAN_SIGNED|ROLE_CHANGE|MOTION_SETTLED/
      return 'state' if t.include?('现值')
      return 'roles' if t.include?('确认记录') || t.include?('配对记录')
      return 'probe' if t.include?('探针') || t.include?('自检') || t.include?('校验')

      'state'
    end

    # 唯一的条目来源：固定项 + 触发追加。除此之外代码不得凭空生成条目（ONBOARD-03）。
    # reopened：这一轮被某个触发重开的条目。「重开」就是回到待确认，与那条通道的能力现值无关
    # （SENSE-04 自检不过、ONBOARD-07 证据过期走的都是这一条）。
    def derive(assembly:, events: [], roles: {}, capability: {}, paired: nil, extra: [], reopened: [],
               bootAt: nil, probedAt: nil)
      stale = bootAt && probedAt && probedAt < bootAt
      (fixed(assembly) + extra).uniq { |i| i['id'] }.map do |i|
        st = reopened.include?(i['id']) ? 'pending' :
             status_of(i, events: events, roles: roles, capability: capability, paired: paired, stale: stale)
        i.merge('status' => st)
      end
    end

    def status_of(item, events:, roles:, capability:, paired:, stale:)
      case item['evidence']
      when 'event' then events.include?(item_event(item)) ? 'done' : 'pending'
      when 'roles' then roles_match?(item, roles) ? 'done' : 'pending'
      when 'probe' then probe_status(item, capability, stale)
      when 'state' then state_status(item, capability, paired)
      else 'pending'
      end
    end

    def item_event(item)
      cat = item['category']
      return 'PLAN_SIGNED' if cat == 'agree'
      return 'ROLE_CHANGE' if cat == 'role'

      'MOTION_SETTLED'
    end

    def probe_status(item, capability, stale)
      state = Capability.state_of(capability, probe_cap(item))
      return 'unknown' if state == 'unknown'
      return 'pending' if stale
      return 'done' if %w[granted on].include?(state)

      'pending'
    end

    def probe_cap(item)
      key = item['id'].split('.')[2].to_s
      { 'overlay' => 'overlay', 'usageAccess' => 'usageAccess', 'pause' => 'pause',
        'bootReceiver' => 'bootReceiver', 'notifications' => 'notifications',
        'calibrate' => 'cameraChannel',
        'motionSensors' => 'motionSensor', 'license' => 'packVerify' }.fetch(key, key)
    end

    def state_status(item, capability, paired)
      return paired.nil? ? 'pending' : (paired ? 'done' : 'notApplicable') if item['category'] == 'device'

      Capability.state_of(capability, egress_switch(item)) == 'on' ? 'done' : 'pending'
    end

    def egress_switch(item)
      item['id'].split('.')[2].to_s
    end

    def roles_match?(item, roles)
      role = item['owner'].sub('role:', '')
      return !roles.empty? if role.to_s.empty?

      !roles[role].to_s.empty?
    end

    # 触发展开，返回**新增**的条目；同 id 已存在就不再生成（幂等，ONBOARD-03 末段）。
    def expand_trigger(name, value, assembly:, existing: [], member: nil)
      table = TRIGGERS[name.to_s] or return []
      patterns = table[assembly.to_s] || table['any'] || []
      list = []
      patterns.each do |p|
        case p
        when '*' then fixed(assembly).each { |i| list << i }
        when /\.egress\.\*/
          sw = value.is_a?(Hash) ? value.keys.first.to_s : value.to_s
          list << base(assembly, 'egress', sw)
        else
          list << base(assembly, *strip_star(p).split('.'), member: member)
        end
      end
      list.uniq { |i| i['id'] }.reject { |i| existing.include?(i['id']) }
    end

    def strip_star(p)
      p.sub(/\A\*\./, '').sub(/\A(tv|mobile)\./, '')
    end

    def base(assembly, *parts, member: nil)
      tail = parts.flatten.map(&:to_s)
      id = if member && MEMBER_SCOPED.include?(tail.first)
             "#{member}.#{assembly}.#{tail.join('.')}"
           else
             "#{assembly}.#{tail.join('.')}"
           end
      hit = fixed(assembly).find { |i| i['id'].end_with?(tail.join('.')) }
      hit ? hit.merge('id' => id) : item(id, tail.last, '该成员', '「设备」页', '事件',
                                        '按最保守档落并写明原因')
    end

    def pending(items)
      items.select { |i| %w[pending unknown].include?(i['status']) }
    end

    def guide(items)
      items.first(GUIDE_ITEMS)
    end

    def guide_permissions(items)
      guide(items).map { |i| PERMISSIONS[i['id'].sub(/^(tv|mobile)\./, '') ] }.compact
    end

    def completeness(items)
      [items.count { |i| i['status'] == 'done' }, items.size]
    end

    def stars_delta
      0
    end

    def export(items)
      { 'storedFields' => STORED_FIELDS, 'derived' => DERIVED_FIELDS,
        'items' => items.map { |i| i.slice(*STORED_FIELDS) },
        'completeness' => completeness(items) }
    end
  end
end
