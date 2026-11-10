package com.youban.core

/**
 * 内核的一次性入口：读一份任务 JSON，输出这份 `CommitState`。
 *
 * 存在的理由有两个：
 *   1. `tools/align-core.rb` 用同一个任务分别跑 Ruby 规范模型与这份 Kotlin 内核，逐字段比对（D42）；
 *   2. 设备端（device/android/）把内核带在包里跑，不再靠 adb 把结论推上去——结论是设备自己算的。
 *
 * 任务形状：
 *   {"contract":"/abs/contract/contract.json","profile":"member:kid","strength":"negotiated",
 *    "mode":null,"paused":false,"pauseMs":0,"requested":false,"probeOk":null,
 *    "plan":{"allowanceMs":3600000,"graceMs":1800000,...},
 *    "events":[{"kind":"WATCHED","profile":"member:kid","fields":{"ms":2400000}}]}
 */
object Main {
    // 跨天要归零的量：看过的、超出的、暂停段、这一轮的做题与运动计数。
    private val DAY_SCOPED = setOf("WATCHED", "OVER", "MOTION_SETTLED", "ANSWER", "ROUND_DONE")

    @JvmStatic
    fun main(args: Array<String>) {
        val text = readInput(args)
        // --batch：一次进程跑一批任务（对齐脚本跑完全部夹具case 只启一次 JVM）。
        if (args.contains("--batch")) {
            val jobs = Json.parse(text) as? List<*> ?: error("--batch 要的是一份 JSON 数组")
            jobs.forEach { println(Json.write(run(it as Map<*, *>))) }
            return
        }
        val job = Json.parse(text) as? Map<*, *>
            ?: error("任务不是一份 JSON 对象：${text.take(60)}")
        // --kernel：走设备端那一条入口（Kernel.state），不是 align 那条（Main.run）。
        // 两条入口对「没存过方案」的处理以前不一样，这条入口以前没人测过——所以留着它。
        if (args.contains("--roster")) {
            Commit.useContract(job["contract"].toString())
            println(Kernel.rosterScreen(Json.write(job["plan"] as? Map<*, *> ?: emptyMap<String, Any>()),
                (job["events"] as? List<*> ?: emptyList<Any?>()).joinToString("\n") { Json.write(it as Map<*, *>) },
                job["profile"].toString(), Day.num(job["index"] ?: 0)))
            return
        }
        if (args.contains("--panel")) {
            Commit.useContract(job["contract"].toString())
            println(Kernel.panel(job["contract"].toString(),
                (job["events"] as? List<*> ?: emptyList<Any?>()).joinToString("\n") { Json.write(it as Map<*, *>) },
                job["profile"].toString(), Json.write(job["plans"] as? Map<*, *> ?: emptyMap<String, Any>())))
            return
        }
        if (args.contains("--setup")) {
            Commit.useContract(job["contract"].toString())
            println(Kernel.setupScreen(Json.write(job["plan"] as? Map<*, *> ?: emptyMap<String, Any>()),
                Day.num(job["step"] ?: 0), Day.num(job["version"] ?: 1), false))
            return
        }
        if (args.contains("--kernel")) {
            Commit.useContract(job["contract"].toString())
            val lines = ((job["events"] as? List<*>) ?: emptyList<Any?>())
                .joinToString("\n") { Json.write(it as Map<*, *>) }
            println(Kernel.state(lines, Json.write(job["plan"] as? Map<*, *> ?: emptyMap<String, Any>()),
                job["profile"].toString(), job["strength"] as? String ?: "negotiated", job["mode"] as? String))
            return
        }
        println(Json.write(run(job)))
    }

    private fun run(job: Map<*, *>): Map<String, Any?> {
        // 契约路径必须在读那张表之前定下来：批量模式下漏这一步会静默用相对路径的表，
        // 对齐结果就变成「看起来对了」。
        (job["contract"] as? String)?.let { Commit.useContract(it) }
        val ledger = Ledger(job["device"] as? String)
        val profile = job["profile"] as? String ?: "member:kid"
        for (raw in job["events"] as? List<*> ?: emptyList<Any?>()) {
            val e = raw as? Map<*, *> ?: continue
            val fields = LinkedHashMap<String, Long>()
            (e["fields"] as? Map<*, *>)?.forEach { (k, v) -> fields[k.toString()] = Day.num(v) }
            ledger.append(e["kind"].toString(), (e["profile"] as? String) ?: profile, fields,
                e["device"] as? String)
        }

        // 墙钟跳过了午夜不等于真的过了一天：单调钟没跟上就不滚，也不回放（DAY-07）。
        if (job["crossedMidnight"] as? Boolean == true && rollsDay(job)) {
            ledger.events.removeAll { it.kind in DAY_SCOPED }
        }

        val plan = LinkedHashMap<String, Any>()
        (job["plan"] as? Map<*, *>)?.forEach { (k, v) -> if (v != null) plan[k.toString()] = v }
        val state = Commit.state(
            profile = profile,
            plan = plan,
            q = ledger.project(profile),
            strength = job["strength"] as? String ?: "negotiated",
            mode = job["mode"] as? String,
            paused = job["paused"] as? Boolean ?: false,
            pauseMs = Day.num(job["pauseMs"] ?: 0),
            probeOk = job["probeOk"] as? Boolean,
            requested = job["requested"] as? Boolean ?: false,
            // 有没有一份签过的约定：比对器带过来；没带就看账里的 PLAN_SIGNED（AGREE-01）。
            signed = job["signed"] as? Boolean ?: ledger.events.any { it.kind == "PLAN_SIGNED" },
            pending = (job["pendingMotion"] as? Map<*, *>)?.let { m ->
                LinkedHashMap<String, Any>().also { o -> m.forEach { (kk, vv) -> o[kk.toString()] = vv as Any } }
            }
        )
        return state
    }

    /** 与 Ruby 那边同一条：`crossed && wallClockDeltaMs > 0 && monotonicDeltaMs < wallClockDeltaMs` 就不滚。 */
    private fun rollsDay(job: Map<*, *>): Boolean {
        val clock = job["clock"] as? Map<*, *> ?: return true
        val wall = Day.num(clock["wallClockDeltaMs"])
        val mono = Day.num(clock["monotonicDeltaMs"])
        return !(wall > 0 && mono < wall)
    }

    private fun readInput(args: Array<String>): String {
        val direct = args.firstOrNull { !it.startsWith("-") }
        if (direct != null) {
            // 给路径就读文件，给一窜 JSON 就直接解析（对齐脚本走后面那条）。
            val f = java.io.File(direct)
            return if (direct.length < 512 && f.isFile) f.readText() else direct
        }
        val path = args.indexOfFirst { it == "--file" }
            .takeIf { it >= 0 && it + 1 < args.size }
            ?.let { args[it + 1] }
        if (path != null) {
            return java.io.File(path).readText()
        }
        return System.`in`.bufferedReader().readText()
    }
}
