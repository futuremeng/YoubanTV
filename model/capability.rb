# SPEC: LAYER-01, LAYER-02, LAYER-05, LAYER-06, LAYER-07, LAYER-08, LAYER-10, LAYER-11, LAYER-12
# 能力登记表：层的唯一事实来源，也是「请求暂停 / 悬浮窗 / 外部设备」这些能力的探针结果存放处。
# 强度相关文案只读这里（LAYER-05）；场景表在 docs/LAYERING.md §2，那里是准入门（LAYER-12）。
require 'set'
require 'json'

module Core
  module Capability
    # L4 是空位（D23）：它不在取值里，也不在任何分支里。
    TIERS = %w[L0 L1 L1.5 L2 L3 L5].freeze
    TIER_ORDER = TIERS.dup.freeze
    # 携带强度事实的字段只有一个：Capability.tier。别处不得再存一份（LAYER-01）。
    TIER_FIELDS = %w[tier].freeze

    FOCUSED_PAUSE_TIER = 'L2'.freeze # focused 要请求暂停，不得低于 L2（LAYER-07）
    # 机型探测门槛（D36）。与 docs/facts/probes/f12.yaml 的 threshold 由 probe-gate.sh 校一致。
    PROBE_RESPONSE_RATE_MIN = 0.95
    PROBE_SAMPLE_MIN = 20

    # 探针纪律：一律后台跑；ttl 过期或重启后重探（LAYER-05、事实 F1）。
    PROBE_ON_MAIN_THREAD = false
    PROBE_TTL_S = 6 * 3600
    PROBE_ON_BOOT = true

    # 每层的措辞种类与替代通道（LAYER-09、LAYER-10）。应用内替代永远存在（事实 F2）。
    WORDING = {
      'L0' => { kind: 'inform', channels: %w[device] },
      'L1' => { kind: 'inform', channels: %w[device] },
      'L1.5' => { kind: 'statusSentence', channels: %w[device] },
      'L2' => { kind: 'nextStep', channels: %w[device] },
      'L3' => { kind: 'nextStep', channels: %w[device, overlay] },
      'L5' => { kind: 'delegate', channels: %w[device] }
    }.freeze

    # 能力 → 所需层 + 场景行号（LAYERING.md §2）。没占行的能力进不了代码（LAYER-12）。
    REGISTRY = {
      'pause' => { tier: 'L2', scenes: [2] },
      'overlay' => { tier: 'L3', scenes: [13] },
      'systemPresentation' => { tier: 'L3', scenes: [13] },
      'notifications' => { tier: 'L1', scenes: [13] },
      'usageAccess' => { tier: 'L3', scenes: [15] },
      'accessibility' => { tier: 'L3', scenes: [15] },
      'bootReceiver' => { tier: 'L1', scenes: [14] },
      'motionSensor' => { tier: 'L1', scenes: [9, 17] },
      # 临近传感器与加速度计同属第 9 / 17 行那条传感器端计数通路，不另占行。
      'proximitySensor' => { tier: 'L1', scenes: [9, 17] },
      'cameraChannel' => { tier: 'L2', scenes: [9, 17] },
      'homeAssistant' => { tier: 'L5', scenes: [1, 3] },
      'planSigning' => { tier: 'L2', scenes: [7] },
      'slotRules' => { tier: 'L2', scenes: [3] },
      'exerciseCount' => { tier: 'L2', scenes: [6, 17] },
      'diagnostics' => { tier: 'L0', scenes: [10] },
      'updateCheck' => { tier: 'L1', scenes: [12] },
      'profileSwitch' => { tier: 'L1.5', scenes: [16] },
      'checklist' => { tier: 'L1', scenes: [20] }
    }.freeze

    # 出网开关名单只有一处来源：契约的 egressSwitch 枚举（D42）。它们是另一条轴——
    # 不在 LAYERING §2 的场景表里占行，所以不参与分层准入，也不参与形态降级（D45）。
    CONTRACT_ENUMS = JSON.parse(File.read(File.expand_path('../contract/contract.json', __dir__)))
                         .fetch('enums').freeze
    EGRESS_SWITCHES = CONTRACT_ENUMS.fetch('egressSwitch').fetch('values').freeze

    # 强制力的取值范围（LAYER-06）：无障碍只回判定结果，开机广播只是 L3 的触发器。
    ACCESSIBILITY_SURFACE = 'verdictOnly'.freeze
    BOOT_RECEIVER = 'L3Trigger'.freeze
    L5_MODE = 'requestOnly'.freeze
    APP_SWITCH_RESTORE_MS = 5000
    IN_APP_FALLBACK = true

    module_function

    def enforcement_only(capability)
      (capability || {}).reject { |k, _| EGRESS_SWITCHES.include?(k.to_s) }
    end

    def known?(name)
      REGISTRY.key?(name.to_s)
    end

    def tier(name)
      entry = REGISTRY[name.to_s]
      raise ArgumentError, "能力 #{name} 未在登记表登记" unless entry

      entry[:tier]
    end

    def tier_values
      TIERS.size
    end

    def tier_source_fields
      TIER_FIELDS.size
    end

    # 场景表在文档里，模型只数它占了几行（LAYER-12：准入门就是那张表）。
    def scene_rows(root = nil)
      root ||= File.expand_path('..', __dir__)
      src = File.read(File.join(root, 'docs/LAYERING.md'))
      src[/^## 2\..*?(?=^## )/m].to_s.scan(/^\| \d+ \|/).size
    end

    # 未占场景行的能力：准入未过，不得生效。
    def gate(name, rows = nil)
      return :absent unless known?(name)

      needed = REGISTRY[name.to_s][:scenes]
      total = rows || scene_rows
      needed.all? { |n| n <= total } ? :passed : :required
    end

    def wording(tier)
      WORDING.dig(tier.to_s, :kind) || 'unknown'
    end

    def channels(tier)
      WORDING.dig(tier.to_s, :channels) || %w[device]
    end

    # 探针结论能否把 focused 抬成默认档：响应率与样本量两条都过才行（D36）。
    def focused_default_ok?(probe)
      return false unless probe

      probe['responseRate'].to_f >= PROBE_RESPONSE_RATE_MIN && probe['sampleCount'].to_i >= PROBE_SAMPLE_MIN
    end

    # 唯一的回退规则：拿不到证据就把该能力落到它最保守的可用档，并说明原因（ONBOARD-06）。
    # 不做逐能力特判——下面这张表是「每档的保守侧」，不是「每个能力一条 if」。
    FALLBACK_RULES = 1
    CONSERVATIVE = { 'granted' => nil, 'on' => nil, 'unknown' => :fallback, 'denied' => :fallback,
                     'off' => :fallback }.freeze

    def fallback_for(state)
      CONSERVATIVE[state.to_s].nil? ? nil : :fallback
    end

    # 请求层所需能力齐不齐：缺就退回最保守档（LAYER-08 的降级来源）。
    # 每一项是「任一即可」：L3 的应用外呈现只要浮层或系统级通道可用就行，
    # 无障碍只是可选加速器（D16），不列入必需项。
    REQUIREMENTS = { 'L1' => [], 'L1.5' => [], 'L2' => [%w[pause]],
                     'L3' => [%w[overlay systemPresentation]], 'L5' => [%w[homeAssistant]] }.freeze

    def missing_for(tier, capability)
      (REQUIREMENTS[tier.to_s] || []).reject do |any|
        any.any? { |c| judgment_state(capability, c) }
      end.map(&:first)
    end

    # 判定的视角与清单的视角不同：清单问「有没有证据」（没登记就是 unknown），
    # 判定问「这台机行不行」——没探过不拦（D36：默认值不等实测），探过不过才算不行。
    def judgment_state(capability, name)
      cap = capability || {}
      return %w[granted on].include?(cap[name.to_s].to_s) if cap.key?(name.to_s)

      true
    end

    def tier_ok?(tier, capability)
      missing_for(tier, capability).empty?
    end

    def order(tier)
      TIER_ORDER.index(tier.to_s).to_i
    end

    def granted?(capability, name)
      %w[granted on].include?(state_of(capability, name))
    end

    # 有的能力有写死的默认值，不是 unknown，而且这条默认值只在这里写一次（D42）：
    # 出网开关读契约 egressSwitch 的 default（D13、D28），摄像头通道默认关（SENSE-02），
    # 内容包题源是本地通路，默认就是通的（PACK-01「不依赖联网」）。
    EGRESS_DEFAULT = CONTRACT_ENUMS.fetch('egressSwitch').fetch('default').freeze
    DEFAULT_STATE = EGRESS_SWITCHES.each_with_object({}) { |sw, h| h[sw] = EGRESS_DEFAULT }
                          .merge('cameraChannel' => 'off', 'offline' => 'granted').freeze

    def state_of(capability, name)
      (capability || {}).fetch(name.to_s, DEFAULT_STATE.fetch(name.to_s, 'unknown')).to_s
    end
  end
end
