package com.youban.core

/**
 * 给设备端（Java）用的入口：结论是设备自己算的，不是别人算好了推过来的。
 *
 * 这是 M3 剩下的最后一件：之前屏幕上那句结论是 Mac 用 adb 推上来的一个文件，
 * 设备只是把它念出来。现在设备自己拿着事件账跑内核，adb 只能往里**追加事件**。
 */
object Kernel {
    /** 契约路径在 Android 上没法用相对路径，装包时由界面层指一次。 */
    @JvmStatic
    fun useContract(path: String) = Commit.useContract(path)

    /**
     * @param eventsJson 事件账，一行一条：`{"kind":"WATCHED","profile":"member:kid","fields":{"ms":2400000}}`
     * @param planJson   当日方案，形状同夹具里的 `given.plan`
     * @return 这份 `CommitState` 的 JSON，界面层照着画，不自己判层级
     */
    @JvmStatic
    fun state(eventsJson: String, planJson: String, profile: String, strength: String, mode: String?): String {
        motionKind.clear()
        val ledger = Ledger()
        eventsJson.lineSequence().forEach { line ->
            val text = line.trim()
            if (text.isEmpty() || !text.startsWith("{")) return@forEach // 空行不是事件：账是追加式的，末尾常有换行
            val e = Json.parse(text) as? Map<*, *> ?: return@forEach
            val fields = LinkedHashMap<String, Long>()
            (e["fields"] as? Map<*, *>)?.forEach { (k, v) -> fields[k.toString()] = Day.num(v) }
            val added = Event(e["kind"].toString(), (e["profile"] as? String) ?: profile, fields)
            ledger.events += added
            // 动议是哪一种（pause / extend / …）也在这一行里，Ledger 的 fields 只存数字，另记一笔。
            ((e["fields"] as? Map<*, *>)?.get("kind") as? String)?.let { motionKind[added] = it }
        }
        val plan = LinkedHashMap<String, Any>()
        (Json.parse(planJson) as? Map<*, *>)?.forEach { (k, v) -> if (v != null) plan[k.toString()] = v }
        // 已受理的暂停是一条事实（MOTION_SETTLED），但**受理了的「延一延」不是暂停**：
        // 只看有没有 MOTION_SETTLED，COMMIT-04 那一步就会从 due 掉回 honored。要看那一条带的是哪一种动议，
        // 而动议的种类在 fields.kind 里——账里的 fields 只放数字，所以这里直接看原始那行。
        val settled = ledger.events.filter {
            it.kind == "MOTION_SETTLED" && it.profile == profile && motionKind[it] == "pause"
        }
        val paused = settled.isNotEmpty()
        val pauseMs = settled.sumOf { it.fields["pauseMs"] ?: 0 }
        return Json.write(Commit.state(profile, plan, ledger.project(profile), strength, mode, paused, pauseMs))
    }

    /** 事件账里每条动议的种类（fields.kind）：Ledger 的 fields 只存数字，种类另记在这儿。 */
    private val motionKind = HashMap<Event, String>()

    /** 这一屏句子里的码位，交给界面层回写成诊断文件（F17 那个抓手）。 */
    @JvmStatic
    fun hex(text: String): String = text.map { String.format("%04x", it.code) }.joinToString(",")
}
