# SPEC: ASK-05, ASK-06, DAY-05
# 任务与作答：一组题怎么成组、作答怎么写。组数与每组预计分钟这些参数来自方案（core/day），
# 这里只定「成组与收尾」这一条规则，不另存参数（D42）。
module Core
  module Task
    # 作答事件只有一种写法：一条作答一条 ANSWER，对错记在字段上（ASK-09）。
    ANSWER_EVENT = 'ANSWER'.freeze

    module_function

    # 满组即止：够一组就收尾入账，不够就继续问（ASK-05、DAY-05）。
    # 返回还差几组成形——界面用它决定这一轮之后是不是就此结束。
    def settle(answered, target, rounds)
      return [] unless target.to_i.positive?

      completed = answered.to_i / target.to_i
      Array.new([completed - rounds.to_i, 0].max, 'ROUND_DONE')
    end

    # 这道题在计划里已经答过就不再问（ASK-06）：没有新的题，也就没有作答。
    def already_answered?(same_kp:, answered:)
      !!same_kp && answered.to_i.positive?
    end

    # 满组之后只有本人自愿继续才再问（ASK-05）；taskDone 没给时按「本任务已结束」算。
    def may_continue?(task_done:)
      task_done == false
    end
  end
end
