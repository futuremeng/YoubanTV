package com.youban.tv;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * 状态入口：Mac 侧（现在是 adb，将来是内核）把内核的 CommitState 送进来。
 *
 * 这一层不判定、不落账、不计时（D47）：收到就交给主界面显示。
 * 注意它只接受结论，不接受「命令」——单方面控制他人的 API 在契约里不存在（spec/AUTONOMY.md）。
 */
public class StateReceiver extends BroadcastReceiver {
    public static final String ACTION = "com.youban.STATE";

    @Override
    public void onReceive(Context context, Intent intent) {
        // 这里必须把结论落到文件再拉起界面：之前只 startActivity 不存 extra，广播发得再多次
        // 屏幕上也不变——那一晚反复对比截屏对不上，就是这个坑。
        String json = intent.getStringExtra("state");
        if (json != null) {
            MainActivity.writeText(MainActivity.path(context, MainActivity.STATE_NAME, true), json);
        }
        Intent forward = new Intent(context, MainActivity.class);
        forward.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        context.startActivity(forward);
    }
}
