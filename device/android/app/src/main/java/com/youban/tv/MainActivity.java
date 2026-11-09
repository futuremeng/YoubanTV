package com.youban.tv;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Bundle;
import android.view.KeyEvent;
import android.widget.TextView;
import java.io.File;
import java.io.FileWriter;

/**
 * 电视端（tv 装配）的主界面：把内核给出的 CommitState 摆到屏幕上。
 *
 * 这一层只呈现与收集输入，不做任何判定：落层、措辞、到期与否全部来自内核那一份
 * （contract/contract.json 的 commitState，规则见 docs/LAYERING.md §4）。
 * 这里不出现连续、成就、打卡、催促（docs/PRODUCT.md §2），也没有计时器与阈值。
 *
 * 状态来源两条，都写进同一个文件再读：
 *   adb broadcast -a com.youban.STATE --es state '<CommitState JSON>'
 *   adb push commitstate.json /sdcard/Download/youban-state.json
 * 输入去向一个文件，由 adb 侧读回（M3 之后走事件存储，仍不在这层判定）：
 *   /sdcard/Download/youban-input.json
 */
public class MainActivity extends Activity {
    /** 内核结论落在这个文件里；设备端只读它，不自己算（D47）。 */
    static final String STATE_FILE = "/sdcard/Download/youban-state.json";
    /** 遥控器按键落在这儿：设备测试从 adb 读回它，验「按键真的到了设备」。 */
    static final String INPUT_FILE = "/sdcard/Download/youban-input.json";

    private TextView sentence;
    private TextView badge;
    private TextView foot;

    private final BroadcastReceiver stateReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            String json = intent.getStringExtra("state");
            if (json != null) {
                write(STATE_FILE, json);
            }
            render();
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.status);
        sentence = (TextView) findViewById(R.id.sentence);
        badge = (TextView) findViewById(R.id.badge);
        foot = (TextView) findViewById(R.id.foot);
        render();
    }

    @Override
    protected void onResume() {
        super.onResume();
        IntentFilter f = new IntentFilter(StateReceiver.ACTION);
        try {
            registerReceiver(stateReceiver, f);
        } catch (Exception ignored) {
            // 注册不上也照常渲染：这一屏的来源还可以是 push 的那个文件。
        }
        render();
    }

    @Override
    protected void onPause() {
        try {
            unregisterReceiver(stateReceiver);
        } catch (Exception ignored) {
            // 没注册成功过，就不必注销。
        }
        super.onPause();
    }

    /**
     * 遥控器按键是这一层存在的理由（facts/DEVICES.md#F16：免安装的通路上没人接按键）。
     * 这里只记下「谁按了什么」，要不要生效由内核按动议那套规则判（spec/AUTONOMY.md）。
     */
    @Override
    public boolean onKeyDown(int code, KeyEvent event) {
        String key = null;
        switch (code) {
            case KeyEvent.KEYCODE_DPAD_CENTER:
            case KeyEvent.KEYCODE_ENTER:
                key = "accept";
                break;
            case KeyEvent.KEYCODE_BACK:
                key = "decline";
                break;
            case KeyEvent.KEYCODE_INFO:
                key = "about";
                break;
            default:
                break;
        }
        if (key == null) {
            return super.onKeyDown(code, event);
        }
        record(key);
        return true;
    }

    private void record(String key) {
        long now = System.currentTimeMillis();
        write(INPUT_FILE, "{\"key\":\"" + key + "\",\"at\":" + now + ",\"monoMs\":"
                + android.os.SystemClock.elapsedRealtime() + "}");
    }

    private void render() {
        String json = read(STATE_FILE);
        if (json == null) {
            sentence.setText("还没有读到内核的结论：这一屏不做任何判定。");
            badge.setText("");
            foot.setText("状态来源：adb broadcast com.youban.STATE 或 " + STATE_FILE);
            return;
        }
        // 只取契约里那几个字段（commitState.fields）；界面不从 status 反推层，层是内核给的。
        String tier = field(json, "tier", "L1");
        String ceiling = field(json, "tierCeiling", "L1");
        String wording = field(json, "wording", "statusSentence");
        String status = field(json, "status", "honored");
        String reason = field(json, "fallbackReason", "");
        sentence.setText(line(status, wording, json));
        badge.setText(tier + " · " + ("due".equals(status) ? "待做" : "无到期项"));
        foot.setText("落层 " + tier + " · 强度天花板 " + ceiling
                + (reason.isEmpty() ? "" : " · " + reason));
    }

    /** 措辞仍按 LAYERING §4 那一句：状态句 + 下一步，不指责、不催促、不承诺兑换。 */
    private String line(String status, String wording, String json) {
        String mode = nested(json, "mode");
        if ("due".equals(status) && "focused".equals(mode)) {
            return "这一组答完就记为已完成。";
        }
        if ("due".equals(status)) {
            return "有一组题待做，现在做吗？";
        }
        if ("overdue".equals(status)) {
            return "超出约定时间。今天已按约定使用完。";
        }
        return "今天已按约定使用。";
    }

    private static String read(String path) {
        try {
            File f = new File(path);
            if (!f.canRead()) {
                return null;
            }
            byte[] buf = new byte[(int) f.length()];
            java.io.InputStream in = new java.io.FileInputStream(f);
            int n = in.read(buf);
            in.close();
            return n <= 0 ? null : new String(buf, 0, n, "UTF-8");
        } catch (Exception e) {
            return null;
        }
    }

    private static void write(String path, String body) {
        try {
            FileWriter w = new FileWriter(path);
            w.write(body);
            w.close();
        } catch (Exception e) {
            // 写不下去就不写：这一层没有「先记着回头补」这条路（不伪造输入）。
        }
    }

    /** 极简取值：这一层不需要 JSON 库，字段少，读不出来就用默认，绝不猜。 */
    static String field(String json, String key, String fallback) {
        String needle = "\"" + key + "\":";
        int i = json.indexOf(needle);
        if (i < 0) {
            return fallback;
        }
        int j = i + needle.length();
        if (j >= json.length() || json.charAt(j) != '"') {
            return fallback;
        }
        int k = json.indexOf('"', j + 1);
        return k < 0 ? fallback : json.substring(j + 1, k);
    }

    /** due 是个子对象：只在里面找一个键，找不到就当没有（不自己判到期）。 */
    private static String nested(String json, String key) {
        int due = json.indexOf("\"due\":");
        if (due < 0 || json.startsWith("null", due)) {
            return "";
        }
        int brace = json.indexOf('{', due);
        int end = brace < 0 ? -1 : json.indexOf('}', brace);
        return brace < 0 || end < 0 ? "" : field(json.substring(brace, end), key, "");
    }
}
