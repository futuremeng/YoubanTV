// 当日方案：默认值表、四量取数、时段与生效组数。判定在 Commit.kt。
// 表的内容与 model/day.rb 同一份含义；漂移会被 tools/align-core.rb 跑红，不靠注释保证（D42）。
package com.youban.core

object Day {
    val TIER_ORDER = listOf("L0", "L1", "L1.5", "L2", "L3", "L5")

    // 层的天花板由强度定，与身份无关（LAYER-07）。
    val STRENGTH_TIER_CEILING = mapOf(
        "accompanied" to "L3",
        "negotiated" to "L2",
        "selfManaged" to "L1"
    )

    // DAY-03 的默认值表（分钟）。存过配置的设备沿用原值，由调用方合并 overrides 处理。
    fun defaultPlan(audience: String, dayType: String): MutableMap<String, Any> {
        val row = when {
            audience == "grown-up" -> longArrayOf(120, 120, 120) to "ambient"
            audience == "senior" -> longArrayOf(480, 480, 480) to "ambient"
            dayType == "weekend" -> longArrayOf(180, 60, 90) to "focused"
            else -> longArrayOf(60, 30, 60) to "focused"
        }
        return linkedMapOf(
            "allowanceMs" to row.first[0] * MINUTE,
            "graceMs" to row.first[1] * MINUTE,
            "moveFromMs" to row.first[2] * MINUTE,
            "form" to row.second,
            "inSlot" to true
        )
    }

    fun inSlot(plan: Map<String, Any>) = plan.getOrDefault("inSlot", true) as Boolean

    fun slotMode(plan: Map<String, Any>) = plan["slots"] as String?

    // DAY-05：生效组数 = max(自设组数, ceil((moveFrom − grace) ÷ 每组预计分钟))
    fun effectiveGroups(plan: Map<String, Any>): Int {
        val selfSet = num(plan["groupsPerTask"]).toInt()
        val span = num(plan["moveFromMs"]) - num(plan["graceMs"])
        val per = num(plan["minutesPerGroup"])
        if (per <= 0 || span <= 0) return selfSet
        return maxOf(selfSet, Math.ceil(span / MINUTE.toDouble() / per).toInt())
    }

    fun tierCeiling(strength: String) = STRENGTH_TIER_CEILING.getOrDefault(strength, "L2")

    fun tierMin(a: String, b: String): String {
        val x = TIER_ORDER.indexOf(a)
        val y = TIER_ORDER.indexOf(b)
        if (x < 0 || y < 0) return a
        return TIER_ORDER[minOf(x, y)]
    }

    fun num(v: Any?): Long = when (v) {
        null -> 0
        is Number -> v.toLong()
        else -> v.toString().toLongOrNull() ?: 0
    }

    const val MINUTE = 60_000L
}
