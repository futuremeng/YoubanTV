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
        val ledger = Ledger()
        eventsJson.lineSequence().forEach { line ->
            val e = Json.parse(line) as? Map<*, *> ?: return@forEach
            val fields = LinkedHashMap<String, Long>()
            (e["fields"] as? Map<*, *>)?.forEach { (k, v) -> fields[k.toString()] = Day.num(v) }
            ledger.append(e["kind"].toString(), (e["profile"] as? String) ?: profile, fields)
        }
        val plan = LinkedHashMap<String, Any>()
        (Json.parse(planJson) as? Map<*, *>)?.forEach { (k, v) -> if (v != null) plan[k.toString()] = v }
        return Json.write(Commit.state(profile, plan, ledger.project(profile), strength, mode))
    }

    /** 这一屏句子里的码位，交给界面层回写成诊断文件（F17 那个抓手）。 */
    @JvmStatic
    fun hex(text: String): String = text.map { String.format("%04x", it.code) }.joinToString(",")
}
