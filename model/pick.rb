# SPEC: ASK-01, ASK-02, ASK-06, ASK-07, ASK-08, ASK-09, ASK-10, PACK-01, PACK-02, PACK-03, CONTEXT-03, CONTEXT-04, CONTEXT-05
# 选题管线：此刻该出哪道题的**取材**与**题面形状**规则。取材顺序、ambient 门禁、机检回退这三条
# 各只有一处；题目内容与星级估算来自内容包与方案（core/day），这里不另存一份。
module Core
  module Pick
    # 取材顺序：内容包绑定 → 成员自编 → 实时智能体；三层都落空按大纲随机（ASK-01）。
    # 实时智能体那一层受 aiQuestions 开关管着：开关关着就等于这层落空（ASK-01、COMMIT-09）。
    SOURCE_ORDER = %w[pack member llm outlineRandom].freeze
    # 面板要标来源；大纲随机是本地的兜底题，不标「未校验」（ASK-01、PACK-03）。
    MARKED_SOURCES = %w[pack member llm].freeze
    # ambient 题的硬要求：题干 ≤30 字、每选项 ≤2 行、单键可答、预估 ≤5 秒（ASK-06、COMMITMENTS §表）。
    AMBIENT_SHAPE = { 'stemChars' => 30, 'optionsLines' => 2, 'estimatedSeconds' => 5 }.freeze
    # 成员自编条目的字段：可标状态，但没有审批位（PACK-02）。
    MEMBER_AUTHORED_FIELDS = %w[id kpId kp owner status evidence addedAt].freeze
    # 「这条断言在问什么」与模型能答上的字段一一对应（D41：一条断言回答一个问题）。
    QUESTION_FIELDS = { '这道题是什么时候问的' => 'questionPickedAt' }.freeze

    module_function

    # 包这一层是不是真取得到题：包在、验过、绑定年级里还有没答过的题——三者齐了才算取到（ASK-01）。
    # 取不到就是这一层落空，按上面那条顺序往下走；不在这里编一道题，也不重复出答过的那道。
    def pack_hit(plan: {}, answered: [])
      return false unless Core::Pack.present?

      !Core::Pack.pick(plan, answered_ids: answered).nil?
    rescue StandardError
      false
    end

    def source(pack_hit:, member_authored_hit:, llm_hit:, egress: {})
      return 'pack' if pack_hit
      return 'member' if member_authored_hit
      return 'llm' if llm_hit && Capability.state_of(egress, 'aiQuestions') == 'on'

      'outlineRandom'
    end

    def marked?(source)
      MARKED_SOURCES.include?(source.to_s)
    end

    # 上下文只是提示词素材，不额外增加取材来源（ASK-10、CONTEXT-04）：
    # 伴看上下文开着，来源类别也只多出一条「上下文」，题目本身仍从上面那条顺序里取。
    def extra_sources(egress: {})
      Capability.state_of(egress, 'companionContext') == 'on' ? 1 : 0
    end

    # authoring 门禁：ambient 的形状不达标就不能被标成 ambient（ASK-06）。
    # 门禁只有一条，判定不区分题是从包里来的还是成员自作的（PACK-03「走同一校验」）。
    def shape_ok?(shape)
      return true if shape.nil? || shape.empty?

      s = shape
      s['stemChars'].to_i <= AMBIENT_SHAPE['stemChars'] &&
        s['optionsLines'].to_i <= AMBIENT_SHAPE['optionsLines'] &&
        s['estimatedSeconds'].to_i <= AMBIENT_SHAPE['estimatedSeconds'] &&
        !!s['singleKey']
    end

    def authoring(shape)
      shape_ok?(shape) ? 'passed' : 'rejected'
    end

    # 机检不过：不出、不入库、不重试，退回固定题面（ASK-08、CONTEXT-05）。
    VERIFY_FALLBACK = { 'retried' => false, 'stemIdentical' => true, 'fallbackApplied' => true }.freeze

    # 呈现时机与选题相互独立：什么时候问由 COMMIT/CONTEXT-06 定，管线不为凑时机提前或压住
    # （ASK-07）；时段外不提问，但时长照记（DAY-08）。
    def picked_at(due_at)
      due_at || 'onDemand' # 时机取值：没有定时点就是随叫随到（CONTEXT-06）
    end

    # 传感器出题的启用门槛与 F13 一致：三类题各自的判对率 ≥95%、样本 ≥20（D36、SENSE-04）。
    SENSOR_ACCURACY_MIN = 0.95
    SENSOR_SAMPLE_MIN = 20

    # 出题强度：知识点状态映射到预估星级档（ASK-02「状态与依赖同时决定出题强度」）。
    CANDIDATE_LEVEL = { 'unseen' => 1, 'learning' => 2, 'weak' => 3, 'shaky' => 3, 'mastered' => 5 }.freeze

    def candidate_level(kp_state)
      CANDIDATE_LEVEL.fetch(kp_state.to_s, 1)
    end

    # 有效题组就是 DAY-05 的生效组数，规则只在 core/day 那一处，这里不再算第二遍（ASK-02）。

    def sensor_mode_ok?(accuracy, attempts)
      accuracy.to_f >= SENSOR_ACCURACY_MIN && attempts.to_i >= SENSOR_SAMPLE_MIN
    end
  end
end
