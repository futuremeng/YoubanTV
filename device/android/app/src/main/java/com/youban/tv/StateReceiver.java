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
            String fieldKind = intent.getStringExtra("fieldKind");
            String accepted = intent.getStringExtra("accepted");
            String actor = intent.getStringExtra("actor");
            boolean actorSeen = false;
            StringBuilder fields = new StringBuilder("\"ms\":" + ms);
            if (pauseMs > 0) {
                fields.append(",\"pauseMs\":").append(pauseMs);
            }
            // 动议是哪一种也要进账：受理了的「延一延」不是暂停，只看有没有 MOTION_SETTLED 会判错。
            if (fieldKind != null && !fieldKind.isEmpty()) {
                fields.append(",\"kind\":\"").append(fieldKind).append('"');
            }
            // 动议的结果也要进账：婉拒与「接受了」是同一条 MOTION_SETTLED，靠 accepted 分（AUTO-03）。
            if (accepted != null && !accepted.isEmpty()) {
                fields.append(",\"accepted\":").append("false".equalsIgnoreCase(accepted) ? "false" : "true");
            }
            // 带 actor 才落这个顶层键：不然每条 WATCHED 都多一个空 actor，那一屏的历史会多出没有的动议。
            // （这一条今天写坏过一次 JSON——多了一个引号，账里每一行都解析不过去，
            //  屏幕上只剩「内核没跑起来」，最难查的那种。）
            String head = "{\"kind\":\"" + kind + "\",\"profile\":\"" + (profile == null ? "" : profile) + "\"";
            if (actor != null && !actor.isEmpty()) {
                head += ",\"actor\":\"" + actor + "\"";
            }
            MainActivity.append(MainActivity.path(context, MainActivity.EVENTS_NAME, true),
                    head + ",\"fields\":{" + fields + "}}");
        }
        // 这台设备指定的那一个应用（ONBOARD-12）：--es autoLaunch <包名>；空串就是取消指定。
        // 界面入口在「设备」页，推到 2.0（D80），所以这条路现在就是 ONBOARDING.md §2b 那条命令。
        String autoLaunch = intent.getStringExtra("autoLaunch");
        if (autoLaunch != null) {
            String value = autoLaunch.trim();
            // 「@home」= 这台设备的桌面：包名由本机答，不在这条命令里写死（各家桌面不同）。
            if ("@home".equals(value)) {
                Intent home = new Intent(Intent.ACTION_MAIN);
                home.addCategory(Intent.CATEGORY_HOME);
                android.content.pm.ResolveInfo ri =
                        context.getPackageManager().resolveActivity(home, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY);
                value = ri == null || ri.activityInfo == null ? "" : ri.activityInfo.packageName;
            }
            MainActivity.writeText(MainActivity.path(context, MainActivity.AUTOLAUNCH_NAME, true), value);
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
