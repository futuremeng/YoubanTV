package com.youban.core

/**
 * 给设备端（Java）用的入口：结论是设备自己算的，不是别人算好了推过来的。
 *
 * 这是 M3 剩下的最后一件：之前屏幕上那句结论是 Mac 用 adb 推上来的一个文件，
 * 设备只是把它念出来。现在设备自己拿着事件账跑内核，adb 只能往里**追加事件**。
 */
object Kernel {
    /** 契约的位置：设备端指一次，setup/nextPlan 这些也走它。 */
    /**
     * 换这一档的那一屏：这一台设备上见过谁来用，是从账里读出来的（契约 agreement.perProfile.rosterSource）——
     * 设备上没有成员表，名字也不在这儿编（PROFILE-01）。每一档带着它的版本与签没签（AGREE-08）。
     */
    @JvmStatic
    fun rosterScreen(planJson: String, eventsJson: String, current: String, index: Long): String {
        val node = Json.parse(java.io.File(contractPathFile()).readText()) as Map<*, *>
        val ui = ((node["agreement"] as Map<*, *>)["ui"] as Map<*, *>).mapKeys { it.key.toString() }
        val events = eventsJson.lineSequence().map { it.trim() }.filter { it.startsWith("{") }
            .mapNotNull { Json.parse(it) as? Map<*, *> }.filter { it["profile"] != null }.toList()
        val roster = ArrayList<String>()
        if (!roster.contains(current)) roster.add(current)
        events.forEach { e ->
            val who = e["profile"].toString()
            if (!roster.contains(who)) roster.add(who)
        }
        val lines = ArrayList<String>()
        roster.forEach { who ->
            val signed = events.lastOrNull { it["kind"] == "PLAN_SIGNED" && it["profile"] == who }
            val state = if (signed == null) "未签·按默认" else "已签"
            val version = if (signed == null) {
                "v—"
            } else {
                "v" + (((signed["fields"] as? Map<*, *>)?.get("version")) ?: 1).toString().removeSuffix(".0")
            }
            lines.add(ui["switchRow"].toString().replace("{profile}", who).replace("{state}", state)
                .replace("{version}", version))
        }
        val target = roster.getOrElse(index.toInt().coerceIn(0, roster.size - 1)) { roster.last() }
        return Json.write(linkedMapOf<String, Any?>(
            "lines" to lines,
            "title" to ui["switchDo"],
            "head" to ui["switchHeader"].toString().replace("{from}", current).replace("{to}", target),
            "foot" to ui["switchHint"],
            "target" to target,
            "current" to current,
            "changed" to (target != current)
        ))
    }

    private fun contractPathFile(): String = Day.contractPath

    private val contractPath get() = Day.contractPath
    /** 契约路径在 Android 上没法用相对路径，装包时由界面层指一次。 */
    @JvmStatic
    fun useContract(path: String) = Commit.useContract(path)

    /**
     * @param eventsJson 事件账，一行一条：`{"kind":"WATCHED","profile":"member:kid","fields":{"ms":2400000}}`
     * @param planJson   当日方案，形状同夹具里的 `given.plan`
     * @return 这份 `CommitState` 的 JSON，界面层照着画，不自己判层级
     */
    @JvmStatic
    @JvmOverloads
    fun state(eventsJson: String, planJson: String, profile: String, strength: String, mode: String?,
                signed: Boolean? = null): String {
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
        // 没存过方案不是错误：先按契约那张默认表垫底，再让设备存的那份盖上来（AGREE-13）。
        // 不垫这一层，一台新设备上 allowanceMs 会是 0，屏幕上就成了「超出 0 分钟」（真机上就是这样）。
        val plan = LinkedHashMap<String, Any>()
        val given = Json.parse(planJson) as? Map<*, *>
        Day.defaultPlan(given?.get("audience")?.toString() ?: "child",
            given?.get("dayType")?.toString() ?: "schoolday").forEach { (k, v) -> plan[k] = v }
        given?.forEach { (k, v) -> if (v != null) plan[k.toString()] = v }
        // 已受理的暂停是一条事实（MOTION_SETTLED），但**受理了的「延一延」不是暂停**：
        // 只看有没有 MOTION_SETTLED，COMMIT-04 那一步就会从 due 掉回 honored。要看那一条带的是哪一种动议，
        // 而动议的种类在 fields.kind 里——账里的 fields 只放数字，所以这里直接看原始那行。
        val settled = ledger.events.filter {
            it.kind == "MOTION_SETTLED" && it.profile == profile && motionKind[it] == "pause"
        }
        val paused = settled.isNotEmpty()
        val pauseMs = settled.sumOf { it.fields["pauseMs"] ?: 0 }
        // 有没有一份签过的约定：设备端看账里的 PLAN_SIGNED；比对器把这一轮的方案状态直接带过来（AGREE-01）。
        // 签没签按身份算：kid 签过不代表切到 dad 之后也有一份签过的约定（AGREE-08）。
        val hasSignature = signed
            ?: ledger.events.any { it.kind == "PLAN_SIGNED" && it.profile == profile }
        // 挂着一条要受理的动议：提过、没受理、之后也没落定（AUTO-03、D34）。设备端的确认键只看这个。
        val unanswered = ledger.events.filter { it.kind == "MOTION_UNANSWERED" && it.profile == profile }
        val settledKinds = ledger.events.filter { it.kind == "MOTION_SETTLED" && it.profile == profile }
            .map { motionKind[it] ?: it.fields["kind"]?.toString() }
        val pending = unanswered.lastOrNull()?.let { e ->
            val kind = motionKind[e] ?: e.fields["kind"]?.toString()
            if (kind != null && settledKinds.contains(kind)) null else mapOf("kind" to (kind ?: ""))
        }
        return Json.write(Commit.state(profile, plan, ledger.project(profile), strength, mode, paused, pauseMs,
            signed = hasSignature, pending = pending))
    }

    /**
     * 首启那六步的屏幕内容：一步一问，问什么、有哪些可选、按默认是什么，全在契约里（AGREE-05）。
     * 壳层只做一件事——把这些字串起来。之前界面上自己拼句子，就成了「一处有一条没有」（D47）。
     */
    @JvmStatic
    fun setup(planJson: String): String {
        val node = Json.parse(java.io.File(contractPath).readText()) as Map<*, *>
        val agreement = node["agreement"] as Map<*, *>
        val fields = (agreement["fields"] as List<*>).map { it as Map<*, *> }.associate { it["id"].toString() to it }
        val ui = (agreement["ui"] as Map<*, *>).mapKeys { it.key.toString() }.mapValues { it.value as Any }
        val plan = LinkedHashMap<String, Any>()
        (Json.parse(planJson) as? Map<*, *>)?.forEach { (k, v) -> if (v != null) plan[k.toString()] = v }
        val steps = (agreement["firstRun"] as List<*>).map { raw ->
            val step = raw as Map<*, *>
            val asks = (step["asks"] as? List<*> ?: emptyList<Any?>()).map { it.toString() }
            val out = LinkedHashMap<String, Any?>()
            out["step"] = Day.num(step["step"])
            out["do"] = step["do"] as Any
            out["asks"] = asks
            out["note"] = step["note"]
            out["fields"] = asks.map { id ->
                val f = fields.getValue(id)
                val choices = (f["choices"] as List<*>).map { ch ->
                    val c = ch as Map<*, *>
                    linkedMapOf<String, Any?>("value" to c["value"], "label" to c["label"])
                }
                val current = plan[id] ?: f["default"]
                linkedMapOf<String, Any?>(
                    "id" to id,
                    "label" to f["uiWords"],
                    "choices" to choices,
                    "value" to (current ?: defaultsFor(plan)[id]),
                    "valueLabel" to labelFor(choices, current ?: defaultsFor(plan)[id])
                )
            }
            out
        }
        return Json.write(linkedMapOf<String, Any?>("ui" to ui, "total" to steps.size, "steps" to steps))
    }

    /**
     * 首启的第 index 屏：一步可能出好几屏（一项一屏，遥控器上一屏只改一项）。
     * 抬头、每一项那句「现在是什么」、脚下提示，全都来自契约 agreement.ui（AGREE-05）。
     * 界面上不出现任何字段名：要改哪一项，屏幕上带着 field 这个键，壳层原样交回 cycle。
     */
    @JvmStatic
    fun setupScreen(planJson: String, index: Long, version: Long, signed: Boolean): String {
        val described = Json.parse(setup(planJson)) as Map<*, *>
        val ui = described["ui"] as Map<*, *>
        val screens = screens(described)
        val at = screens.getOrElse(index.toInt().coerceIn(0, screens.size - 1)) { screens.last() }
        val total = screens.size.toLong()
        val lines = ArrayList<String>()
        lines.add(ui["header"].toString().replace("{step}", (index + 1).toString())
            .replace("{total}", total.toString()).replace("{do}", at["do"].toString()))
        if (at["note"] != null) {
            lines.add(ui["noteOnly"].toString().replace("{note}", at["note"].toString()))
        } else if (at["id"] != null) {
            lines.add(ui["field"].toString().replace("{label}", at["label"].toString())
                .replace("{value}", at["valueLabel"].toString()))
        }
        if (index + 1 == total) {
            lines.add((if (signed) ui["signing"] else ui["sign"]).toString().replace("{version}", version.toString()))
        }
        return Json.write(linkedMapOf<String, Any?>(
            "title" to at["do"], "lines" to lines, "field" to at["id"],
            "foot" to if (at["id"] == null) ui["leave"] as Any else ui["hint"] as Any,
            "last" to (index + 1 == total)
        ))
    }

    /** 把「六步」摊成屏：不用选的步骤出一屏说明，要选的每项出一屏，最后一屏是签署。 */
    private fun screens(described: Map<*, *>): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        (described["steps"] as List<*>).forEach { raw ->
            val step = raw as Map<*, *>
            val asks = (step["asks"] as? List<*> ?: emptyList<Any?>()).map { it.toString() }
            if (asks.isEmpty()) {
                out += linkedMapOf<String, Any?>(
                    "do" to step["do"], "note" to step["note"], "id" to null,
                    "label" to null, "valueLabel" to step["do"]
                )
            } else {
                (step["fields"] as List<*>).forEach { f ->
                    val field = f as Map<*, *>
                    out += linkedMapOf<String, Any?>(
                        "do" to step["do"], "note" to null, "id" to field["id"],
                        "label" to field["label"], "valueLabel" to field["valueLabel"]
                    )
                }
            }
        }
        // 契约最后一步就是「双方签署」，不再另加一屏；那一屏没有要选的项，只出「确认后写入第几份」那句。
        return out
    }

    /** 左右键在一项的可选值里走一步：可选值在契约 fields.choices，顺序也在那儿（界面上不许另列一份）。 */
    @JvmStatic
    fun cycle(planJson: String, fieldId: String, backward: Boolean): String {
        val described = Json.parse(setup(planJson)) as Map<*, *>
        val step = (described["steps"] as List<*>).firstOrNull { s ->
            ((s as Map<*, *>)["asks"] as? List<*> ?: emptyList<Any?>()).contains(fieldId)
        } as Map<*, *>? ?: return planJson
        val f = ((step["fields"] as List<*>).first { (it as Map<*, *>)["id"] == fieldId }) as Map<*, *>
        val choices = f["choices"] as List<*>
        val values = choices.map { (it as Map<*, *>)["value"] }
        val plan = LinkedHashMap<String, Any>()
        (Json.parse(planJson) as? Map<*, *>)?.forEach { (k, v) -> if (v != null) plan[k.toString()] = v }
        val current = if (fieldId == "audience") plan["audience"] ?: "child" else plan[fieldId]
        val at = values.indexOfFirst { it == current }.let { if (it < 0) 0 else it }
        val next = values[((at + if (backward) -1 else 1) % values.size + values.size) % values.size]
        return nextPlan(planJson, fieldId, next!!)
    }

    /**
     * 改一项之后的方案。换受众要把那一档的默认整行换掉（DAY-01）——这条规则在界面上再写一遍
     * 就是第二个来源，所以给了内核。
     */
    @JvmStatic
    fun nextPlan(planJson: String, fieldId: String, value: Any): String {
        val plan = LinkedHashMap<String, Any>()
        (Json.parse(planJson) as? Map<*, *>)?.forEach { (k, v) -> if (v != null) plan[k.toString()] = v }
        if (fieldId == "audience") {
            val merged = LinkedHashMap<String, Any>()
            (Day.defaultPlan(value.toString(), plan["dayType"]?.toString() ?: "schoolday"))
                .forEach { (k, v) -> merged[k] = v }
            merged["audience"] = value
            plan.keys.filter { it == "inSlot" }.forEach { merged[it] = plan[it] as Any }
            return Json.write(merged)
        }
        plan[fieldId] = value
        return Json.write(plan)
    }

    /** 这是第几份约定：账里签过几份，下一份就是几（AGREE-05）。 */
    @JvmStatic
    fun signingVersion(eventsJson: String): Long =
        eventsJson.lineSequence().count { it.contains("\"PLAN_SIGNED\"") }.toLong() + 1

    private fun defaultsFor(plan: Map<String, Any>): Map<String, Any> =
        Day.defaultPlan(plan["audience"]?.toString() ?: defaultsAudience(plan), plan["dayType"]?.toString() ?: "schoolday")

    private fun defaultsAudience(plan: Map<String, Any>) = "child"

    private fun labelFor(choices: List<Map<String, Any?>>, value: Any?): String =
        choices.firstOrNull { it["value"] == value }?.get("label")?.toString() ?: value.toString()

    /** 事件账里每条动议的种类（fields.kind）：Ledger 的 fields 只存数字，种类另记在这儿。 */
    private val motionKind = HashMap<Event, String>()

    /** 这一屏句子里的码位，交给界面层回写成诊断文件（F17 那个抓手）。 */
    @JvmStatic
    fun hex(text: String): String = text.map { String.format("%04x", it.code) }.joinToString(",")
}
