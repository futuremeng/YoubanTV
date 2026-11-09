// 内核里唯一的 JSON 读写：内核不许依赖任何第三方库（M2 的依赖约束——只用 Kotlin 标准库与 JDK）。
// 存在的理由只有一个：内核要和契约读同一份定义面（D42），不为通用性做优化。
package com.youban.core

object Json {
    fun quote(s: String): String {
        val sb = StringBuilder("\"")
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                else -> sb.append(c)
            }
        }
        return sb.append('"').toString()
    }

    fun write(v: Any?): String = when (v) {
        null -> "null"
        is Boolean -> v.toString()
        is Double -> if (v == v.toLong().toDouble()) v.toLong().toString() else v.toString()
        is Map<*, *> -> v.entries.joinToString(",", "{", "}") { quote(it.key.toString()) + ":" + write(it.value) }
        is List<*> -> v.joinToString(",", "[", "]") { write(it) }
        else -> quote(v.toString())
    }

    fun parse(text: String): Any? = Parser(text).also { it.skip() }.value().also { it.skip() }

    private class Parser(val src: String) {
        var i = 0
        fun skip() { while (i < src.length && src[i].isWhitespace()) i++ }

        fun value(): Any? {
            skip()
            if (i >= src.length) error("JSON 在第 $i 个字符处断了")
            return when (val c = src[i]) {
                '{' -> obj()
                '[' -> arr()
                '"' -> str()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> {
                    if (c == '-' || c.isDigit()) number() else error("JSON 第 $i 个字符不是值：$c")
                }
            }
        }

        private fun obj(): Map<String, Any?> {
            val out = LinkedHashMap<String, Any?>()
            i++ // {
            skip()
            if (i < src.length && src[i] == '}') { i++; return out }
            while (true) {
                skip()
                val key = str()
                skip()
                require(src[i] == ':') { "JSON 第 $i 个字符应为冒号" }
                i++
                out[key] = value()
                skip()
                when (src[i]) {
                    ',' -> { i++; continue }
                    '}' -> { i++; return out }
                    else -> error("JSON 第 $i 个字符应为逗号或右括号")
                }
            }
        }

        private fun arr(): List<Any?> {
            val out = mutableListOf<Any?>()
            i++ // [
            skip()
            if (i < src.length && src[i] == ']') { i++; return out }
            while (true) {
                out += value()
                skip()
                when (src[i]) {
                    ',' -> { i++; continue }
                    ']' -> { i++; return out }
                    else -> error("JSON 第 $i 个字符应为逗号或右方括号")
                }
            }
        }

        private fun str(): String {
            require(src[i] == '"') { "JSON 第 $i 个字符应为左引号" }
            i++
            val sb = StringBuilder()
            while (src[i] != '"') {
                if (src[i] == '\\') {
                    i++
                    sb.append(when (val e = src[i]) {
                        'n' -> '\n'
                        't' -> '\t'
                        else -> e
                    })
                } else sb.append(src[i])
                i++
            }
            i++
            return sb.toString()
        }

        private fun number(): Any {
            val from = i
            if (src[i] == '-') i++
            while (i < src.length && (src[i].isDigit() || src[i] in ".eE+-")) i++
            val raw = src.substring(from, i)
            return if (raw.any { it in ".eE" }) raw.toDouble() else raw.toLong()
        }

        private fun literal(word: String, v: Any?): Any? {
            require(src.startsWith(word, i)) { "JSON 第 $i 个字符不是 $word" }
            i += word.length
            return v
        }
    }
}
