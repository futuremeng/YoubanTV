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
        Intent forward = new Intent(context, MainActivity.class);
        forward.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        context.startActivity(forward);
    }
}
