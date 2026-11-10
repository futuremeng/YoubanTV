require 'json'

# SPEC: COMMIT-10, LAYER-06, LAYER-04
# 执行面：只有呈现。阻断类手段在此不出现，CI 与夹具的 absent 断言以此处为准。
module Core
  module Enforcement
    # 已批准的全部对外手段。出现别的名字即视为越界（COMMIT-10、LAYER-06）。
    SURFACE = %w[present].freeze
    L5 = %w[requestOnly].freeze # 本机只发请求，由外部设备执行（LAYER-11）

    CONTRACT = JSON.parse(File.read(File.expand_path('../contract/contract.json', __dir__)))
    # 「哪些字段算能力上限」只由契约 forbiddenFields.kinds.ceiling 那一处点名。
    # 代码里不许自己列这些名字：列了既成第二处，又把「这些名字不该存在」那条 absent 断言弄脏
    # （断言问的是名字不出现在定义与代码里，见 PROFILE-01）。
    CEILING_KINDS = CONTRACT.dig('forbiddenFields', 'kinds', 'ceiling').to_a.freeze
    # 那张表空着就是没人答过这个问题——不许退成「0 个上限」这种看着绿的回答。
    raise '契约 forbiddenFields.kinds.ceiling 没登记：这条结论答不出来，不许当通过' if CEILING_KINDS.empty?

    module_function

    # 「这一台、这一档，实际应用了几个能力上限」——只由这一处答（AUTO-01、PROFILE-01）。
    # 这些字段在契约里无定义，所以这个数今天恒为 0；它不是常量：哪一天真的有人把它们塞进
    # 当日方案或设备能力里并且用上，这里就不是 0，AUTO-01 那三条会当场红。要改这条结论得改契约，
    # 而改契约要让 PROFILE-01 的 absent 断言红。
    def ceiling_applied(plan: {}, capability: {})
      ceiling_fields_applied(plan: plan, capability: capability).size
    end

    def ceiling_fields_applied(plan: {}, capability: {})
      (plan.keys + capability.keys).map(&:to_s) & CEILING_KINDS
    end

    def present(tier, payload)
      raise ArgumentError, "L4 是空位" if tier.to_s == 'L4'

      { shown: true, tier: tier.to_s, payload: payload, external: tier.to_s == 'L5' }
    end

    def uses?(name)
      (SURFACE + L5).include?(name.to_s)
    end
  end
end
