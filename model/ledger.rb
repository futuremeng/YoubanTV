# SPEC: COMMIT-11, DAY-01, DAY-04, DAY-04b, PROFILE-04
# 账本：只追加的事件流 + 从事件算出的当日投影。判定不在这里（core/commit）。
# 事件名与必填字段取自 contract/contract.json；这里不另立事件。
require 'set'

module Core
  # 一条事件。契约要求每条都带 at / profile / device（enums.event.requiredFields）。
  class Event
    attr_reader :kind, :profile, :at, :device, :fields

    def initialize(kind, profile:, at:, device: 'tv', **fields)
      @kind = kind.to_s
      @profile = profile
      @at = at
      @device = device
      @fields = fields
    end

    def field(name)
      @fields[name.to_sym] || @fields[name.to_s]
    end

    def to_h
      { 'at' => at, 'profile' => profile, 'device' => device, 'kind' => kind }.merge(fields)
    end
  end

  # 事件流 + 零点幂等。四量一律由事件累加得出，任何模块不得自行记账（DAY-02）。
  class Ledger
    # 补一补池的容量：四量里的 backlogSize 封顶在这里，选题器读同一个数（ASK-04、PACK-04）。
    BACKLOG_CAP = 20

    attr_reader :events, :device

    # 这一本账属于哪一台设备：账本来就在一台设备上（D35），所以「合并另一台的时长」这个入口在模型里没有。
    def initialize(allowed_kinds:, day: 'd0', device: 'tv')
      @events = []
      @allowed = Set.new(allowed_kinds.map(&:to_s))
      @day = day
      @device = device.to_s
    end

    def append(kind, profile:, at:, device: @device, **fields)
      kind = kind.to_s
      raise ArgumentError, "契约里无定义的事件 #{kind}" unless @allowed.include?(kind)
      raise ArgumentError, "profile 只能取 member:<id> 或 none（收到 #{profile}）" unless profile.to_s =~ /\A(member:.+|none)\z/

      ev = Event.new(kind, profile: profile, at: at, device: device, day: @day, **fields)
      @events << ev
      ev
    end

    # 一台设备一本账（DAY-10、D77）：另一台设备的事件不进这台账，也不与这台的段做并集。
    # 不带 device 的事件算本机——老账原样跑，不因这条改动换结论。
    def for_profile(profile)
      @events.select { |e| e.profile == profile && e.field('day') == @day && this_device?(e) }
    end

    def this_device?(event)
      event.device.nil? || event.device.to_s == @device
    end

    # 面板那一页各列一行：按设备数一遍，谁也不并进谁（DAY-10）。这是「列出来」，不是「合起来」。
    def by_device(profile)
      others = @events.map { |e| e.device.to_s }.uniq.sort - [@device]
      rows = { @device => sum_ms(profile, 'WATCHED', 'ms') } # 这台那一行就是判定用的数
      others.each do |dev|
        rows[dev] = @events.select { |e| e.profile == profile && e.kind == 'WATCHED' && e.device.to_s == dev &&
                                         e.field('day') == @day }
                           .sum { |e| e.field('ms').to_i }
      end
      rows
    end

    def kinds(profile = nil)
      (profile ? for_profile(profile) : @events.select { |e| e.field('day') == @day }).map(&:kind)
    end

    def sum_ms(profile, kind, field)
      for_profile(profile).select { |e| e.kind == kind }.sum { |e| e.field(field).to_i }
    end

    def count(profile, kind)
      for_profile(profile).count { |e| e.kind == kind }
    end

    # 未封顶的池条数：用来判断这一轮有没有把最旧的一条挤出池（ASK-04）。
    def backlog_raw(profile)
      @events.count { |e| e.kind == 'MISSED' && e.profile == profile }
    end

    # 当日投影：四量 + 完成数 + 补一补。pauseMs 单列，来自已受理的 pause 动议（COMMIT-07）。
    # 补一补池跳日保留（DAY-06），故不受 day 过滤影响。
    def project(profile)
      scoped = for_profile(profile)
      settled = scoped.select { |e| e.kind == 'MOTION_SETTLED' }
      {
        'watchedMs' => sum_ms(profile, 'WATCHED', 'ms'),
        'overMs' => sum_ms(profile, 'OVER', 'ms'),
        'pauseMs' => settled.sum { |e| e.field('kind') == 'pause' ? e.field('pauseMs').to_i : 0 },
        'roundsDone' => count(profile, 'ROUND_DONE'),
        'answeredInTask' => count(profile, 'ANSWER'),
        # 补一补池容量 20 道，达到容量后最旧的出池，所以这一量封顶在 20（ASK-04）。
        'backlogSize' => [backlog_raw(profile), BACKLOG_CAP].min
      }
    end

    # 受理了的暂停是一条账上的事实，不是这一轮报上来的参数（COMMIT-07）：
    # 设备端只带账本，暂停段的冻结就得能从账里推出来——两端同一条规则，别一边推一边不推。
    def accepted_pause(profile)
      settled = for_profile(profile).select { |e| e.kind == 'MOTION_SETTLED' && e.field('kind').to_s == 'pause' }
      return nil if settled.empty?

      { 'pause' => true, 'pauseMs' => settled.sum { |e| e.field('pauseMs').to_i } }
    end

    # 有没有一条还没人受理的动议：提过、没受理、之后也没落定，才算挂着（AUTO-03、D34）。
    # 这一条只在设备端有用——确认键能生效的唯一前提是「这会儿真挂着一条要受理的动议」（AGREE-11）。
    def pending_motion(profile)
      scoped = for_profile(profile)
      open_ = scoped.select { |e| e.kind == 'MOTION_UNANSWERED' }
      closed = scoped.select { |e| e.kind == 'MOTION_SETTLED' }
      left = open_.reject { |e| closed.any? { |s| s.field('kind') == e.field('kind') } }
      return nil if left.empty?

      last = left.last
      { 'kind' => last.field('kind').to_s }
    end

    # 零点刷新按 dayToken 幂等：同一 token 只滚一次；重启不产生新 token（DAY-06、DAY-07）。
    # 刷的是「当日投影」，历史事件保留（DAY-06 的保留清单）。
    def roll!(day_token)
      return false if @day == day_token

      @day = day_token
      true
    end

    def day_token
      @day
    end

    def day_rolled?(day_token)
      @day == day_token
    end
  end
end
