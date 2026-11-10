# SPEC: DAY-01, DAY-02, DAY-03, DAY-04b, DAY-05, DAY-06, DAY-08, LAYER-07, AGREE-04
# 当日方案：默认值表、四量、时段规则、生效组数。判定在 core/commit。
module Core
  module Day
    # DAY-03 的默认值表在契约里（agreement.defaults）：装机后先按它跑，界面上写明「默认·未签」（AGREE-04）。
    # 原来这张表在 Ruby 写一份、Kotlin 又写一份——「一处有一条没有」正是对齐门要抓的那种（D45）。
    # 分钟数；存过配置的设备沿用原值，由调用方合并 overrides 处理。
    CONTRACT0 = JSON.parse(File.read(File.expand_path('../contract/contract.json', __dir__)))
    # 字段级默认只在这一处读（inSlot 那种不在受众表里的项）（DAY-08、D45）。
    FIELD_DEFAULTS = CONTRACT0.dig('agreement', 'fields').to_a.map { |f|
      [f['id'].to_s, f['default']]
    }.reject { |_, v| v.nil? }.to_h.freeze
    DEFAULTS = CONTRACT0
                   .fetch('agreement').fetch('defaults')
                   .reject { |k, _| k == 'x-note' }
                   .transform_keys { |k| k.split(' ')}
                   .transform_values(&:dup)
                   .freeze

    # 每组题量的默认值，与 DAY-05 的数字同源；组数与题量都是自管字段，面板只读（AUTO-14）。
    QUESTIONS_PER_GROUP_DEFAULT = 2

    STRENGTH_TIER_CEILING = { 'accompanied' => 'L3', 'negotiated' => 'L2', 'selfManaged' => 'L1' }.freeze

    module_function

    # audience-site: 默认值挑选 —— 按受众挑默认那一行，是允许的两处分支之一（PROFILE-01、PROFILE-02）。
    def default_plan(audience, day_type)
      # 先并字段表那一份默认（inSlot 这种不在那张受众表里的项，只在那儿写一次），
      # 再盖下按受众的那一行（DAY-08、D45）。
      row = DEFAULTS[[audience.to_s, day_type.to_s]] || DEFAULTS[%w[child schoolday]]
      FIELD_DEFAULTS.merge(row)
    end

    # 合并该身份已存过的配置：存过的一律沿用原值（DAY-03 末段）。
    # audience-site: 默认值挑选 —— 就是上面那一处的外层，不是新的分支（PROFILE-01）。
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
    # 当日方案里有哪些量：写入口与断言都读这一处，别在两边各列一张清单。
    # 一次任务最多几题：组数 × 每组题量，再由那一档自己定的上限截住（ASK-04、PROFILE-06、AUTO-14）。
    # 这个截断只在这一处算，界面上与断言里不再各算一次。
    def max_questions(plan)
      n = effective_groups(plan) * plan.fetch('questionsPerGroup', QUESTIONS_PER_GROUP_DEFAULT).to_i
      cap = plan.fetch('questionsPerTaskCap', 0).to_i
      cap.positive? ? [n, cap].min : n
    end

    def day_keys
      # 不问是哪一档：这一张表的形状对谁都一样，所以这里不按受众分支（PROFILE-01）。
      @day_keys ||= DEFAULTS.values.first.keys
    end

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
