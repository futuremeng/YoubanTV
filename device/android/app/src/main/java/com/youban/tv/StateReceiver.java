package com.youban.tv;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * 事件入口：把设备外面发生的事**作为事件**追到账里，结论由设备上的内核现算。
 *
 * 为什么不走 JSON 字符串：adb shell 会把 `{}",` 这些字符吃掉一份，之前用 --es state '{...}'
 * 发进去、设备收到的是残缺的，屏幕上什至不变——看起来像「广播不通」，其实是参数被屋了两道壳。
 * 现在用分开的小字段，不需要引号：adb shell am broadcast -n com.youban.tv/.StateReceiver
 *   -a com.youban.STATE --es kind WATCHED --es profile member:kid --el ms 3600000
 *
 * 这一层不判定、不落账、不计时（D47）：它只把事实放进账里，剩下的交给内核。
 * 也不接受任何「命令」——单方面控制他人的 API 在契约里不存在（spec/AUTONOMY.md）。
 */
public class StateReceiver extends BroadcastReceiver {
    public static final String ACTION = "com.youban.STATE";

    @Override
    public void onReceive(Context context, Intent intent) {
        String kind = intent.getStringExtra("kind");
        if (kind != null) {
            String profile = intent.getStringExtra("profile");
            long ms = intent.getLongExtra("ms", 0L);
            long pauseMs = intent.getLongExtra("pauseMs", 0L);
            StringBuilder fields = new StringBuilder("\"ms\":" + ms);
            if (pauseMs > 0) {
                fields.append(",\"pauseMs\":").append(pauseMs);
            }
            MainActivity.append(MainActivity.path(context, MainActivity.EVENTS_NAME, true),
                    "{\"kind\":\"" + kind + "\",\"profile\":\"" + (profile == null ? "" : profile)
                            + "\",\"fields\":{" + fields + "}}");
        }
        // 旧路径留着：直接塞一份算好的结论只看排版，屏幕上会写明它是调试来源。
        String json = intent.getStringExtra("state");
        if (json != null) {
            MainActivity.writeText(MainActivity.path(context, MainActivity.STATE_NAME, true), json);
        }
        Intent forward = new Intent(context, MainActivity.class);
        forward.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        context.startActivity(forward);
    }
}
