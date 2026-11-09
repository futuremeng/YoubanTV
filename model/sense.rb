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
