# SPEC: DAY-01, DAY-02, DAY-03, DAY-04b, DAY-05, DAY-06, DAY-08, LAYER-07, AGREE-04
# 当日方案：默认值表、四量、时段规则、生效组数。判定在 core/commit。
module Core
  module Day
    # DAY-03 的默认值表在契约里（agreement.defaults）：装机后先按它跑，界面上写明「默认·未签」（AGREE-04）。
    # 原来这张表在 Ruby 写一份、Kotlin 又写一份——「一处有一条没有」正是对齐门要抓的那种（D45）。
    # 分钟数；存过配置的设备沿用原值，由调用方合并 overrides 处理。
    DEFAULTS = JSON.parse(File.read(File.expand_path('../contract/contract.json', __dir__)))
                   .fetch('agreement').fetch('defaults')
                   .reject { |k, _| k == 'x-note' }
                   .transform_keys { |k| k.split(' ') }
                   .transform_values(&:dup)
                   .freeze

    # 每组题量的默认值，与 DAY-05 的数字同源；组数与题量都是自管字段，面板只读（AUTO-14）。
    QUESTIONS_PER_GROUP_DEFAULT = 2

    STRENGTH_TIER_CEILING = { 'accompanied' => 'L3', 'negotiated' => 'L2', 'selfManaged' => 'L1' }.freeze

    module_function

    def default_plan(audience, day_type)
      row = DEFAULTS[[audience.to_s, day_type.to_s]] || DEFAULTS[%w[child schoolday]]
      row.dup
    end

    # 合并该身份已存过的配置：存过的一律沿用原值（DAY-03 末段）。
    def plan(audience:, day_type:, stored: {}, overrides: {})
      default_plan(audience, day_type).merge(stored).merge(overrides)
    end

    # 四量只从这里取，别处不得自行累计（DAY-02）。
    def quantities(ledger, profile)
      ledger.project(profile)
    end

    # 时段规则：quiet 与 slots 在约定线之前参与判定（DAY-08）。
    def in_slot?(plan)
      plan.fetch('inSlot', true)
    end

    def slot_mode(plan)
      plan['slots']
    end

    # DAY-05：生效组数 = max(自设组数, ceil((moveFrom − grace) ÷ 每组预计分钟))
    def effective_groups(plan)
      self_set = plan.fetch('groupsPerTask', 0).to_i
      span = plan.fetch('moveFromMs', 0).to_i - plan.fetch('graceMs', 0).to_i
      per = plan.fetch('minutesPerGroup', 0).to_i
      return self_set if per <= 0 || span <= 0

      derived = (span / 60_000.0 / per).ceil
      [self_set, derived].max
    end

    # 层的天花板由强度定，天花板内再取默认档（LAYER-07）。
    def tier_ceiling(strength)
      STRENGTH_TIER_CEILING.fetch(strength.to_s, 'L2')
    end

    def tier_min(a, b)
      order = %w[L0 L1 L1.5 L2 L3 L5]
      [order.index(a), order.index(b)].compact.min ? order[[order.index(a), order.index(b)].min] : a
    end
  end
end
