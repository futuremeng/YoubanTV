// 事件账：只追加的事件流 + 从事件算出的当日投影。判定不在这里（见 Commit.kt）。
// 与 model/ledger.rb 是同一套规则的两个实现，对齐由 tools/align-core.rb 逐条比对输出（D42）。
package com.youban.core

data class Event(
    val kind: String,
    val profile: String,
    val fields: Map<String, Long> = emptyMap(),
    val device: String? = null
)

// 这一本账属于哪一台设备：账本来就在一台设备上（D35），所以「把两台的时长相加」这个入口在模型里没有。
class Ledger(val device: String? = null) {
    val events = mutableListOf<Event>()

    fun append(kind: String, profile: String, fields: Map<String, Long> = emptyMap(), device: String? = this.device) {
        events += Event(kind, profile, fields, device)
    }

    // 一台设备一本账（DAY-10、D77）：别台的事件不进这台账，也不与这台的段做并集。
    // 不带设备标记的算本机——老账原样跑，不因这条改动换结论。
    private fun mine(e: Event) = e.device == null || device == null || e.device == device

    // 四量一律由事件累加得出，任何模块不得自行记账（DAY-02）。
    fun project(profile: String): Map<String, Long> = linkedMapOf(
        "watchedMs" to sum(profile, "WATCHED", "ms"),
        "overMs" to sum(profile, "OVER", "ms"),
        // pauseMs 单列，只来自已受理的 pause 动议（COMMIT-07）。
        "pauseMs" to events.filter { mine(it) && it.kind == "MOTION_SETTLED" && it.profile == profile }
            .sumOf { it.fields["pauseMs"] ?: 0 },
        "roundsDone" to count(profile, "ROUND_DONE").toLong(),
        "answeredInTask" to count(profile, "ANSWER").toLong(),
        // 补一补池容量 20 道，达到容量后最旧的出池，所以这一量封顶在 20（ASK-04）。
        "backlogSize" to minOf(backlogRaw(profile), BACKLOG_CAP).toLong()
    )

    // 未封顶的池条数：用来判断这一轮有没有把最旧的一条挤出池（ASK-04）。
    fun backlogRaw(profile: String) = events.count { mine(it) && it.kind == "MISSED" && it.profile == profile }

    private fun sum(profile: String, kind: String, field: String) =
        events.filter { mine(it) && it.kind == kind && it.profile == profile }.sumOf { it.fields[field] ?: 0 }

    private fun count(profile: String, kind: String) =
        events.count { mine(it) && it.kind == kind && it.profile == profile }

    companion object {
        const val BACKLOG_CAP = 20
    }
}
