// 约定引擎：status / due / 落层的单点实现，与 model/commit.rb 同一套规则的两个实现（D42）。
// 对齐不是靠注释：tools/align-core.rb 会把两边跑成同一批用例再逐条比对输出。
// 能力与探针的结论由设备端（device/capability）传进来——内核不抄那张表（ARCHITECTURE §1、D45）。
package com.youban.core

import java.io.File

// 设备端把「这一层要的能力齐不齐」答给内核；内核不保存登记表。
fun interface CapabilityView {
    fun completeFor(tier: String): Boolean
}

object Commit {
    val TIER_ORDER = Day.TIER_ORDER

    private var contractPath = "contract/contract.json"

    // 形态首选层那张表只有一处：契约的 commitState.tierFor，按 id 取用（D45）。
    val commitState: Map<*, *> by lazy {
        (Json.parse(File(contractPath).readText()) as Map<*, *>)["commitState"] as Map<*, *>
    }
    val tierRow: Map<String, String> by lazy {
        (commitState["tierFor"] as List<*>).associate {
            val r = it as Map<*, *>
            r["id"].toString() to r["tier"].toString()
        }
    }
    val strengthDefaultTier: Map<String, String> by lazy {
        (commitState["strengthDefaultTier"] as Map<*, *>).mapKeys { it.key.toString() }
            .mapValues { it.value.toString() }
    }
    val stateFields: List<String> by lazy { (commitState["fields"] as List<*>).map { it.toString() } }

    fun useContract(path: String) {
        Day.contractPath = path // 默认值表也在契约里（AGREE-04），设备端只指一次两处都通
        contractPath = path
    }

    // 一个函数答完契约那张表的五行，别处不再各写一份 tier。
    fun tierFor(due: Map<String, Any?>? = null, nextAction: String? = null, persistent: Boolean = false): String {
        if (due == null) return if (persistent) tierRow.getValue("persistent") else tierRow.getValue("noDue")
        if (due["kind"].toString() == "free" || nextAction == "motion") return tierRow.getValue("freeOrMotion")
        return tierRow.getOrDefault(due["mode"].toString(), tierRow.getValue("persistent"))
    }

    // focused 站不站得住，判据只有这四条，别处不要再各写一遍（D42、D45、LAYER-07、LAYER-08）：
    // 一、强度天花板低于 L2；二、实测样本没过门槛；三、L2 要的能力不齐；
    // 三之二的「默认档下能力不明」由 anyEnforcementUnknown 传入，显式请求时不看这一条。
    fun focusedHolds(
        form: String,
        strength: String,
        probeOk: Boolean? = null,
        l2Complete: Boolean? = null,
        anyEnforcementUnknown: Boolean? = null,
        requested: Boolean = false
    ): Boolean {
        if (form != "focused") return false
        val ceiling = strengthDefaultTier.getOrDefault(strength, "L2")
        if (TIER_ORDER.indexOf(ceiling) < TIER_ORDER.indexOf(tierRow.getValue("focused"))) return false
        if (probeOk == false) return false
        if (l2Complete == false) return false
        if (requested) return true
        return anyEnforcementUnknown != true
    }

    fun decide(
        profile: String,
        plan: Map<String, Any>,
        q: Map<String, Long>,
        strength: String = "negotiated",
        mode: String? = null,
        paused: Boolean = false,
        pauseMs: Long = 0,
        caps: CapabilityView? = null,
        probeOk: Boolean? = null,
        requested: Boolean = false,
        signed: Boolean = true,
        pending: Map<String, Any?>? = null
    ): Map<String, Any?> {
        val watched = q["watchedMs"] ?: 0
        val out = linkedMapOf<String, Any?>(
            "status" to "honored", "due" to null, "tier" to tierFor(), "next_action" to null,
            "wording" to null, "surface" to listOf("self"), "events" to emptyList<String>(),
            "shown" to emptyList<String>(), "value" to emptyMap<String, Any?>(), "blocked" to false,
            "tierCeiling" to Day.tierCeiling(strength), "fallbackReason" to null, "mode" to null, "sentence" to "honored"
        )
        if (profile == "none") {
            // 未选身份：只落账不判定，也不发任何邀请（COMMIT-11）。
            return out + mapOf(
                "tier" to tierFor(persistent = true),
                "sentence" to "unselected",
                "shown" to listOf("选择身份的提示"),
                "value" to mapOf("eventProfile" to "none", "quizIssued" to false,
                    "exerciseInvite" to false, "coWatchInvite" to false)
            )
        }
        if (paused) {
            return out + mapOf(
                "tier" to tierFor(persistent = true), "wording" to "statusSentence",
                "sentence" to "paused", "shown" to listOf("恢复时刻"), "value" to mapOf("pauseMs" to pauseMs)
            )
        }
        if (!Day.inSlot(plan)) {
            val shown = if (Day.slotMode(plan) == "onlyWithinSlots") listOf("下一个可用时刻") else emptyList<String>()
            return out + mapOf("tier" to tierFor(), "sentence" to "outOfSlot", "shown" to shown,
                "value" to mapOf("watchedMs" to watched))
        }

        val grace = Day.num(plan["graceMs"])
        val allowance = Day.num(plan["allowanceMs"])
        if (watched >= allowance) {
            // COMMIT-04：条件是 ≥ allowance；零量不写 OVER（写了只是噪声）。
            val over = maxOf(watched - allowance, 0)
            return out + mapOf(
                "status" to "overdue", "sentence" to "overdue", "tier" to tierFor(persistent = true),
                "wording" to "statusSentence",
                "events" to if (over > 0) listOf("OVER") else emptyList<String>(),
                "shown" to listOf("超出约定分钟数"),
                "value" to mapOf("overMs" to over, "watchedMs" to watched)
            )
        }
        if (watched < grace) {
            // 免题段覆盖全天时要给一句常驻说明；有当日任务额度时带上进度（DAY-03、DAY-05）。
            var shown = listOf("角标剩余")
            if (plan["quiet"].toString() == "allDay") shown = shown + "免题段说明"
            if (plan.containsKey("groupsPerTask")) shown = shown + "进度"
            return out + mapOf(
                "tier" to tierFor(), "sentence" to "honored", "shown" to shown,
                "value" to mapOf("remainingMs" to grace - watched, "watchedMs" to watched)
            )
        }
        return dueOf(out, plan, q, strength, mode, watched, caps, probeOk, requested)
    }

    private fun complete(caps: CapabilityView?, tier: String) = caps?.completeFor(tier) ?: true

    private fun dueOf(
        out: MutableMap<String, Any?>,
        plan: Map<String, Any>,
        q: Map<String, Long>,
        strength: String,
        mode: String?,
        watched: Long,
        caps: CapabilityView?,
        probeOk: Boolean?,
        requested: Boolean
    ): Map<String, Any?> {
        val roundTarget = Day.num(plan.getOrDefault("roundTarget", 5)).toInt()
        val moveFrom = Day.num(plan["moveFromMs"])
        val quizOpen = watched < moveFrom && (q["answeredInTask"] ?: 0) < roundTarget
        val exerciseOpen = watched >= moveFrom && (q["roundsDone"] ?: 0) < Day.num(plan.getOrDefault("exerciseRounds", 1))
        if (!quizOpen && !exerciseOpen) {
            return out + mapOf("tier" to tierFor(), "events" to listOf("DONE"), "value" to mapOf("watchedMs" to watched))
        }

        // 表的字面：COMMIT-02 是 grace ≤ watched < moveFrom；COMMIT-03 是 watched ≥ moveFrom。
        val kind = if (watched >= moveFrom && exerciseOpen) "exercise" else "quiz"
        var want = (mode ?: plan["form"] ?: "ambient").toString()
        val ceiling = strengthDefaultTier.getOrDefault(strength, "L2")
        val l2Complete = complete(caps, tierRow.getValue("focused"))
        if (!focusedHolds(want, strength, probeOk, l2Complete, anyEnforcementUnknown = !l2Complete, requested = requested)) {
            want = tierRow.getValue("ambient").let { want = want; false }
                .let { tierRow.get("ambient")?.let { _ -> "ambient" } ?: want }
        }
        var tier = Day.tierMin(tierFor(due = mapOf("kind" to kind, "mode" to want), nextAction = kind), ceiling)
        var fallback: String? = null
        if (!complete(caps, tier)) {
            want = "ambient"
            tier = Day.tierMin(tierFor(due = mapOf("kind" to kind, "mode" to want)), ceiling)
            fallback = "当前模式与原因"
        }
        val shown = if (want == "focused") listOf("约定", "该做的事", "窗口期") else listOf("角标剩余", "当前模式与原因")
        return out + mapOf(
            "status" to "due", "sentence" to if (want == "focused") "dueFocused" else "dueAmbient",
            "tier" to tier, "mode" to want, "next_action" to kind,
            "tierCeiling" to ceiling,
            "wording" to if (want == "focused") "nextStep" else "statusSentence",
            "due" to linkedMapOf<String, Any?>("kind" to kind, "mode" to want,
                "deficit" to (if (kind == "quiz") "questions" else "reps"), "window" to "present"),
            "events" to emptyList<String>(), "shown" to shown, "fallbackReason" to fallback,
            "value" to mapOf("ruleId" to "present", "watchedMs" to watched,
                "playerPaused" to (fallback == null), "resumedAfterAnswer" to (fallback == null), "retried" to false)
        )
    }

    // 内核输出的形状：字段名就是契约 commitState.fields 那一行（M1.4）。
    fun state(
        profile: String,
        plan: Map<String, Any>,
        q: Map<String, Long>,
        strength: String = "negotiated",
        mode: String? = null,
        paused: Boolean = false,
        pauseMs: Long = 0,
        caps: CapabilityView? = null,
        probeOk: Boolean? = null,
        requested: Boolean = false,
        signed: Boolean = true,
        pending: Map<String, Any?>? = null
    ): Map<String, Any?> {
        val v = decide(profile, plan, q, strength, mode, paused, pauseMs, caps, probeOk, requested)
        return linkedMapOf<String, Any?>(
            "status" to v["status"],
            "activeProfile" to if (profile == "none") null else profile,
            "planVersion" to Day.num(plan.getOrDefault("planVersion", 1)),
            "due" to dueShape(v, plan, q),
            "tier" to v["tier"],
            "tierCeiling" to v["tierCeiling"],
            // 一份签过的约定都没有：下一步就是去把它立起来，界面上仍是 L1 那一行 + 常驻一栏（AGREE-01、AGREE-04）。
            "nextAction" to if (!signed && v["due"] == null) "agreement" else v["next_action"],
            "wording" to v["wording"],
            "surface" to v["surface"],
            "fallbackReason" to v["fallbackReason"],
            "text" to textOf(v, plan, q),
            "panels" to panelsOf(v, plan, q) +
                if (signed) emptyList() else listOf((commitState["panels"] as Map<String, String>).getValue("约定未立")),
            "pendingMotion" to pending
        )
    }

    /** 常驻提示条与角标上那些小条：名字在 shown 里，句子在契约的 panels 表里，数量从事件账的量来填。 */
    @Suppress("UNCHECKED_CAST")
    fun panelsOf(v: Map<String, Any?>, plan: Map<String, Any>, q: Map<String, Long>): List<String> {
        val panels = commitState["panels"] as Map<String, String>
        val named = ((v["shown"] as? List<*>) ?: emptyList<Any?>())
            .map { it.toString() }.filter { panels.containsKey(it) }
        val value = v["value"] as Map<String, Any?>
        return named.map { name ->
            when (name) {
                "角标剩余" -> panels.getValue(name).replace("{minutes}", minutes(value["remainingMs"]).toString())
                "超出约定分钟数" -> panels.getValue(name).replace("{minutes}", minutes(value["overMs"]).toString())
                "进度" -> panels.getValue(name)
                    .replace("{done}", q.getOrDefault("answeredInTask", 0).toString())
                    .replace("{target}", (Day.effectiveGroups(plan) * Day.num(plan.getOrDefault("groupsPerTask", 1))).toString())
                else -> panels.getValue(name)
            }
        }
    }

    private fun minutes(ms: Any?): Long = Math.ceil(Day.num(ms) / 60_000.0).toLong()

    /**
     * 那句措辞的唯一拼法：句子与填空的小表都在契约里（commitState.sentences / .fill）。
     * 与 Ruby 的 `text_of` 同一条，改句子只改契约（D47）；改这里忘了改那边，align 会红。
     */
    @Suppress("UNCHECKED_CAST")
    fun textOf(v: Map<String, Any?>, plan: Map<String, Any>, q: Map<String, Long>): String {
        val sentences = commitState["sentences"] as Map<String, String>
        val fill = commitState["fill"] as Map<String, Any>
        val unitTable = fill["unit"] as Map<String, String>
        val kindTable = fill["kind"] as Map<String, String>
        val key = (v["sentence"] as? String) ?: if (v["status"] == "overdue") "overdue" else "honored"
        val deficit = dueShape(v, plan, q)?.get("deficit") as Map<String, Any?>?
        return sentences.getValue(key)
            .replace("{amount}", (deficit?.get("amount") ?: 0).toString())
            .replace("{unit}", unitTable[deficit?.get("unit").toString()] ?: "")
            .replace("{kind}", kindTable[((v["due"] as? Map<*, *>)?.get("kind")).toString()] ?: "")
    }

    /** 形状照契约 dueFields；绝对时刻由设备端时钟填，内核只给相对量与当下窗口。
     * 欠量与 Ruby 那边同一公式（`model/commit.rb` 的 `due_shape`）：
     * 做题看 `roundTarget − answeredInTask`，运动看 `exerciseRounds − roundsDone`，不为负。
     * 两处各写一份就是 D46 要避免的事，改的时候两边同步（`tools/align-core.rb` 会卡住不同步）。
     */
    @Suppress("UNCHECKED_CAST")
    fun dueShape(v: Map<String, Any?>, plan: Map<String, Any>, q: Map<String, Long>): Map<String, Any?>? {
        val due = v["due"] as Map<String, Any?>? ?: return null
        val value = v["value"] as Map<String, Any?>
        val kind = due["kind"].toString()
        val unit = if (kind == "quiz") "questions" else if (kind == "exercise") "reps" else "none"
        val amount = when (kind) {
            "quiz" -> maxOf(Day.num(plan.getOrDefault("roundTarget", 5)) - q.getOrDefault("answeredInTask", 0), 0)
            "exercise" -> maxOf(Day.num(plan.getOrDefault("exerciseRounds", 1)) - q.getOrDefault("roundsDone", 0), 0)
            else -> 0L
        }
        return linkedMapOf<String, Any?>(
            "kind" to due["kind"],
            "mode" to due["mode"],
            "deficit" to linkedMapOf("kind" to unit, "unit" to unit, "amount" to amount),
            "window" to mapOf("earliest" to due["window"], "latest" to due["window"]),
            "howToAsk" to if (due["mode"] == "focused") "requestPauseThenAnswer" else "badgeOnly",
            "ruleId" to (value["ruleId"] ?: "present"),
            "nextAction" to v["next_action"]
        )
    }

    private fun indexOf(tier: String) = TIER_ORDER.indexOf(tier)
}
