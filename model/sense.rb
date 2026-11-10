# SPEC: SENSE-01, SENSE-02, SENSE-04, SENSE-05, ONBOARD-06, PROFILE-03
# 传感器端：计次信号源的取值与闸门。摄像头通道只在「已开启（开启前必须过标定自检）+
# 自检记录达标」时参与计次，其余情形一律落到加速度计节律 + 手动确认（D36、D4）。
# 这条回退只有一处，不做逐能力特判。
module Core
  module Sense
    SOURCES = %w[sensor manual camera].freeze
    # 摄像头通道的默认值在 Capability::DEFAULT_STATE 里，自检门槛见 docs/facts/probes/f13.yaml。
    FALSE_COUNT_MAX = 0.05
    SELF_TEST_ATTEMPTS = 20
    # 帧只在内存内逐帧处理：落盘只有计次事件，一帧也不留（SENSE-01）。
    FRAME_RETENTION_MS = 0
    CONTRACT = JSON.parse(File.read(File.expand_path('../contract/contract.json', __dir__)))
    INVITE = CONTRACT.fetch('sense').fetch('invite')
    COUNT = CONTRACT.dig('sense', 'counting').to_h.freeze
    # 手机与电视之间的直连只为这两件事：体感与视觉（SENSE-06、D77）。
    # 这条通路不承载计时、不承载判定输入，也不承载另一台的那本账（DAY-10）；
    # 「过界的只有计数与判定」这一句只在这里答一次，界面与断言都读它。
    LINK = CONTRACT.dig('sense', 'link').to_h.freeze

    module_function

    def link_kinds
      LINK.fetch('kinds').to_a
    end

    def link_carries
      LINK.fetch('carries').to_a
    end

    # 画面出不出手机：契约 link.never 里列着这一条，所以答案永远是「不出」（SENSE-01、SENSE-02）。
    # 这条断言的红法只有一种——有人把那条 never 删了或改成正面允许。
    def frame_leaves_device
      !LINK.fetch('never').to_a.include?('画面出手机')
    end

    # 计次只有一处实现（SENSE-01）：三条信号源都归到 {kind, periodMs, amplitude}，
    # 判「这一下算不算一次」就这一支。数字来自 sense.rhythm（节律窗口与最小幅度）+
    # sense.counting（每个项目那条「幅度不够清楚」的线与去重的那条）。
    # F13 要对照的「算法计数」数的就是这里的 countedReps——采样之前先有可复核的一支。
    def count(kind:, rhythm: [])
      gate = CONTRACT.dig('sense', 'rhythm').to_h
      lo = gate['minPeriodMs'].to_i
      hi = gate['maxPeriodMs'].to_i
      min_amp = gate['minAmplitude'].to_i
      row = COUNT.dig('byKind', kind.to_s) || COUNT['default']
      soft = row ? row['amplitudeSoft'].to_i : min_amp
      divisor = COUNT['refractoryDivisor'].to_i
      divisor = 1 if divisor < 1

      verdicts = []
      last_at = nil
      rhythm.to_a.each_with_index do |ev, i|
        period = ev['periodMs'].to_i
        amp = ev['amplitude'].to_i
        at = ev.key?('at') ? ev['at'].to_i : i
        if period < lo || period > hi
          verdicts << 'rejected'
          next
        end
        if amp < soft
          verdicts << 'rejected'
          next
        end
        if amp < min_amp
          verdicts << 'ambiguous'
          next
        end
        # 去重：这一下离上一次「算过的那一次」太近，就是同一次动作被切成了两段。
        if last_at && (at - last_at).abs < lo / divisor
          verdicts << 'rejected'
          next
        end
        last_at = at
        verdicts << 'counted'
      end

      counted = verdicts.count('counted')
      ambiguous = verdicts.count('ambiguous')
      { 'countedReps' => counted, 'ambiguousReps' => ambiguous,
        'rejectedReps' => verdicts.size - counted - ambiguous,
        'verdicts' => verdicts, 'manualConfirmation' => ambiguous.positive?,
        'countedRepsMatchesTarget' => nil }
    end

    # 邀请这一条只由这一处答（SENSE-07）：档位决定频率，quiet 不主动邀请；
    # 拒绝只让本档内不再邀请——不改档位、不减次数、也不参与任何「今天表现」的记录。
    # 在场形态与它无关：presence 不进这里的任何一支。
    # 老人那几类动作项目安不安全、能练多久，只由这一处答（SENSE-05）。
    # safety 缺了不是「按默认跑」，是这一项无效：无效就退回通用目标，且把这个事实显示出来。
    SAFETY = CONTRACT.fetch('sense').fetch('exerciseSafety')
    RHYTHM = CONTRACT.fetch('sense').fetch('rhythm')

    # 什么算一次节律：周期与幅度都要落在登记过的那一段里，缺一项就不算（SENSE-01）。
    def self.rhythm_counted?(spec)
      period = spec['periodMs'].to_i
      amp = spec['amplitude'].to_i
      RHYTHM.fetch('fields').all? { |f| !spec[f].nil? } &&
        period.between?(RHYTHM.fetch('minPeriodMs'), RHYTHM.fetch('maxPeriodMs')) &&
        amp >= RHYTHM.fetch('minAmplitude')
    end

    # 「这一层的说法有没有被当成健康诊断用」——只由契约那一处语言表答（SENSE-03）。
    # 自检不通过要指出是哪一项（SENSE-04）：项与提示的对应只在契约那一处。
    def self.self_test_failed_hints(record)
      CONTRACT.dig('sense', 'selfTest', 'failHintBySignal').to_s.gsub('{}', '') # 让 nil 的情况也走得下去
      hints = CONTRACT.dig('sense', 'selfTest', 'failHintBySignal') || {}
      out = []
      out << hints['falseCountRate'] if record['falseCountRate'].to_f > FALSE_COUNT_MAX
      out << hints['attempts'] if record['attempts'].to_i < SELF_TEST_ATTEMPTS && out.empty?
      out.compact
    end

    def self.used_as_health_diagnosis
      CONTRACT.dig('sense', 'language', 'usedAsHealthDiagnosis') == true
    end
    def self.project(safety:, tasks: [], session_ms: 0, rounds: 0)
      cap_s = SAFETY.fetch('sessionCapMs')
      cap_d = SAFETY.fetch('dailyCapMs')
      valid = safety.to_s != 'missing'
      row = {
        'projectValid' => valid,
        'fallbackApplied' => !valid,
        'sessionCapMs' => cap_s, 'dailyCapMs' => cap_d,
        'sessionCapped' => session_ms.to_i > cap_s,
        'promptCount' => SAFETY.dig('prompt', 'times'),
        'promptName' => SAFETY.dig('prompt', 'name'),
        'dailyInviteCap' => INVITE.fetch('dailyCap'),
        'roundsDone' => rounds.to_i,
        'notify' => nil
      }
      return row unless valid

      balance = Array(tasks).any? { |t| SAFETY.fetch('balanceKinds').include?(t.is_a?(Hash) ? t['safety'].to_s : t.to_s) }
      row['balanceKind'] = balance
      # 达当日轮数上限后不再邀请：这条走的是同一个开关，不另立一个数字（SENSE-05、SENSE-07）。
      row['notify'] = rounds.to_i >= INVITE.fetch('dailyCap').to_i ? 'none' : nil
      row['allowed'] = rounds.to_i < INVITE.fetch('dailyCap').to_i
      row
    end

    def self.invite(tier:, declined: false, today: 0)
      t = tier.to_s
      row = INVITE.fetch('tiers').fetch(t) do
        # 档位没登记就是没这条规则：不邀请，也不编一个频率出来。
        return { 'inviteTier' => tier, 'notify' => 'none', 'inviteIntervalMinMs' => nil,
                 'inviteIntervalMaxMs' => nil, 'dailyInviteCap' => INVITE['dailyCap'],
                 'invitationsToday' => today.to_i, 'reason' => '这一档没有登记' }
      end
      capped = today.to_i >= INVITE.fetch('dailyCap').to_i
      notify = if declined || capped || row.fetch('notify') == 'none'
                 'none'
               else
                 'once'
               end
      { 'inviteTier' => t, 'notify' => notify,
        'inviteIntervalMinMs' => row['intervalMinMs'], 'inviteIntervalMaxMs' => row['intervalMaxMs'],
        'dailyInviteCap' => INVITE['dailyCap'], 'invitationsToday' => today.to_i,
        'reason' => (declined ? '本档内已拒绝' : capped ? '到单日上限' : nil) }
    end
    DISK_WRITES_PER_ROUND = 1
    # 计次入账只认「本人确认」这一条路（AUTO-14）；传感器计次不兑换时长（D24）。
    CONFIRMATION = 'self'.freeze
    # 每条能力提供哪种计数手段：这条对应关系只在这里写一次，出处是 docs/SENSE.md §2。
    SENSING_METHODS = { 'motionSensor' => 'accelerometer', 'proximitySensor' => 'proximity',
                        'cameraChannel' => 'camera' }.freeze

    module_function

    def allowed?(source, capability: {}, selfTest: nil)
      src = source.to_s
      return false unless SOURCES.include?(src)
      return true if src == 'manual'
      # 加速度计节律 + 手动确认是保底通路，「传感器驱动」要节律可用或摄像头通路成立才算立住
      # （SENSE-02、ONBOARD-06）。
      return Capability.granted?(capability, 'motionSensor') || camera_ok?(capability, selfTest) if src == 'sensor'

      camera_ok?(capability, selfTest)
    end

    # 这一轮实际在用什么计数手段：加速度计节律是永远在的保底，摄像头/临近传感器按状态加，
    # 一条高级通路都不成立时补上「手动确认」（SENSE-02、ONBOARD-06）。
    def methods(capability, selfTest: nil)
      list = ['accelerometer'] # 节律计数是永远在的保底档（SENSE-02 表 L1.5 列）
      list << 'proximity' if Capability.granted?(capability, 'proximitySensor')
      list << 'camera' if camera_ok?(capability, selfTest)
      list << 'manual' if list.size == 1 # 只剩节律这一条时，必须保留手动确认（SENSE-04）
      list
    end

    # 开关为 on 表示开启前的标定自检已经过了；给了自检记录就按记录核一次（SENSE-02）。
    def camera_ok?(capability, selfTest)
      return false unless Capability.state_of(capability, 'cameraChannel') == 'on'
      return self_test_ok?(selfTest) if selfTest

      true
    end

    # 计次的说法只描述即时身体效果，不给健康结论；有实测误计率时才按区间描述（SENSE-03）。
    def display_tokens(signal_source:, false_count_rate: nil)
      return [] unless signal_source.to_s == 'sensor'

      ['即时身体效果的说法'] + (false_count_rate.is_a?(Numeric) ? ['计次误差区间'] : [])
    end

    def self_test_ok?(selfTest)
      selfTest['attempts'].to_i >= SELF_TEST_ATTEMPTS &&
        selfTest['falseCountRate'].to_f <= FALSE_COUNT_MAX
    end

    # 传感器不可用不等于阻断：计次退回手动确认，其他功能照走（ONBOARD-06）。
    def degrade
      { mode: 'manualOnly', blocked: false }
    end
  end
end
