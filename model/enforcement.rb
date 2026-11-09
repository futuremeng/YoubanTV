# SPEC: COMMIT-10, LAYER-06, LAYER-04
# 执行面：只有呈现。阻断类手段在此不出现，CI 与夹具的 absent 断言以此处为准。
module Core
  module Enforcement
    # 已批准的全部对外手段。出现别的名字即视为越界（COMMIT-10、LAYER-06）。
    SURFACE = %w[present].freeze
    L5 = %w[requestOnly].freeze # 本机只发请求，由外部设备执行（LAYER-11）

    module_function

    def present(tier, payload)
      raise ArgumentError, "L4 是空位" if tier.to_s == 'L4'

      { shown: true, tier: tier.to_s, payload: payload, external: tier.to_s == 'L5' }
    end

    def uses?(name)
      (SURFACE + L5).include?(name.to_s)
    end
  end
end
