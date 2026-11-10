// 当日方案：默认值表、四量取数、时段与生效组数。判定在 Commit.kt。
// 表的内容与 model/day.rb 同一份含义；漂移会被 tools/align-core.rb 跑红，不靠注释保证（D42）。
package com.youban.core

object Day {
    /** 契约的位置：设备端会在装包时指一次（Android 上给不了相对路径）。 */
    var contractPath = "contract/contract.json"
    val TIER_ORDER = listOf("L0", "L1", "L1.5", "L2", "L3", "L5")

    // 层的天花板由强度定，与身份无关（LAYER-07）。
    val STRENGTH_TIER_CEILING = mapOf(
        "accompanied" to "L3",
        "negotiated" to "L2",
        "selfManaged" to "L1"
    )

    /**
     * DAY-03 的默认值表在契约里（agreement.defaults）：装机后先按它跑，界面上写明「默认·未签」（AGREE-04）。
     * 这张表原来 Ruby 一份、Kotlin 一份，连「默认是不是在时段内」都只有一边写——那正是对齐门要抓的（D45）。
     * 存过配置的设备沿用原值，由调用方合并 overrides 处理。
     */
    // audience-site: 默认值挑选 —— 与 Ruby 那份同一个位点，允许按受众挑默认那一行（PROFILE-01、PROFILE-02）。
    fun defaultPlan(audience: String, dayType: String): MutableMap<String, Any> {
        val table = agreementDefaults()
        val row = table["$audience $dayType"] as? Map<*, *> ?: table["child schoolday"]
        val out = LinkedHashMap<String, Any>()
        // 先并字段表那一份默认（inSlot 这种不在那张受众表里的项，只在那儿写一次），
        // 再盖下按受众的那一行（DAY-08、D45）——与 Ruby 的 Day.default_plan 同一顺序。
        fieldDefaults().forEach { k, v -> out[k] = v }
        (row as Map<*, *>).forEach { (k, v) ->
            // 契约那张表里存的就是毫秒（agreement.defaults 写的 60*M 那种）：这里再乘一次 60000，
            // 屏幕上就成了「还剩 1800000 分钟」——单位在契约那边定，两边不许各自换算一次（D45）。
            out[k.toString()] = v as Any
        }
        return out
    }

    /** 字段级默认只在这一处读（inSlot 那种不在受众表里的项）。 */
    private fun fieldDefaults(): Map<String, Any> {
        val node = Json.parse(java.io.File(contractPath).readText()) as Map<*, *>
        val fields = ((node["agreement"] as Map<*, *>)["fields"] as? List<*>) ?: emptyList<Any?>()
        val out = LinkedHashMap<String, Any>()
        fields.forEach { raw ->
            val f = raw as Map<*, *>
            val v = f["default"]
            if (v != null) out[f["id"].toString()] = v
        }
        return out
    }

    private fun agreementDefaults(): Map<String, Any> {
        val node = Json.parse(java.io.File(contractPath).readText()) as Map<*, *>
        val defaults = ((node["agreement"] as Map<*, *>)["defaults"] as Map<*, *>)
        return defaults.entries.filter { it.key != "x-note" }.associate { it.key.toString() to (it.value as Any) }
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
