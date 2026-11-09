# SPEC: DAY-01, DAY-02, DAY-03, DAY-04b, DAY-05, DAY-06, DAY-08, LAYER-07
# 当日方案：默认值表、四量、时段规则、生效组数。判定在 core/commit。
module Core
  module Day
    # DAY-03 的默认值表（分钟）。存过配置的设备沿用原值，由调用方合并 overrides 处理。
    DEFAULTS = {
      %w[child schoolday] => { 'allowanceMs' => 60 * 60_000, 'graceMs' => 30 * 60_000,
                               'moveFromMs' => 60 * 60_000, 'form' => 'focused' },
      %w[child weekend] => { 'allowanceMs' => 180 * 60_000, 'graceMs' => 60 * 60_000,
                             'moveFromMs' => 90 * 60_000, 'form' => 'focused' },
      %w[grown-up schoolday] => { 'allowanceMs' => 120 * 60_000, 'graceMs' => 120 * 60_000,
                                  'moveFromMs' => 120 * 60_000, 'form' => 'ambient' },
      %w[grown-up weekend] => { 'allowanceMs' => 120 * 60_000, 'graceMs' => 120 * 60_000,
                                'moveFromMs' => 120 * 60_000, 'form' => 'ambient' },
      %w[senior schoolday] => { 'allowanceMs' => 480 * 60_000, 'graceMs' => 480 * 60_000,
                                'moveFromMs' => 480 * 60_000, 'form' => 'ambient' },
      %w[senior weekend] => { 'allowanceMs' => 480 * 60_000, 'graceMs' => 480 * 60_000,
                              'moveFromMs' => 480 * 60_000, 'form' => 'ambient' }
    }.freeze

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
