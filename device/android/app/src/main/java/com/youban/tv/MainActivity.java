package com.youban.tv;

import android.app.Activity;
import com.youban.core.Kernel;
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
    /** 事件账：设备端唯一的事实来源，一行一条 JSON。结论由这些事件现算，不存结论（D47）。 */
    static final String EVENTS_NAME = "youban-events.jsonl";
    /** 当日方案：形状同夹具里的 given.plan。这是约定，不是结论。 */
    static final String PLAN_NAME = "youban-plan.json";
    /** 契约随包带（assets/contract.json），第一次起来时解到应用目录给内核读那张层级表。 */
    static final String CONTRACT_NAME = "contract.json";
    /** 设备自己算出的那份结论写在这儿：设备测试把它读回来，与 Mac 上规范模型的结果逐字段比。 */
    static final String STATE_OUT_NAME = "youban-state-out.json";
    /** 旧路径留着只作调试兜底：直接塞一份算好的结论进来看排版。屏幕上会标明这是调试来源。 */
    static final String STATE_NAME = "youban-state.json";
    /** 遥控器按键落在这儿：设备测试从 adb 读回它，验「按键真的到了设备」。 */
    static final String INPUT_NAME = "youban-input.json";
    /** 公共目录做兜底：装了存储权限的开发机可以 adb push 到那儿直接看效果。 */
    static final String PUBLIC_DIR = "/sdcard/Download";

    private String fontNote = null;
    private String debugSource = null;
    // 这一屏正在显示的那份结论。按键时看的是它，不在按键那一刻重跑内核。
    // static 是有意的：广播用 CLEAR_TOP 起Activity 时可以另起一个实例，实例字段会让按键落到
    // 另一个实例上、看到的是自己那份旧结论（真机上就是「按键像没被听见」，见 F22）。
    private static String displayed = null;
    private TextView sentence;
    private TextView badge;
    private TextView foot;
    private TextView panels;

    private final BroadcastReceiver stateReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            // 广播带的是**事件**，不是结论：设备自己拿事件跑内核（M3 最后一件）。
            String event = intent.getStringExtra("event");
            if (event != null) {
                append(path(context, EVENTS_NAME, true), event);
            }
            String json = intent.getStringExtra("state");
            if (json != null) {
                write(path(context, STATE_NAME, true), json); // 调试兜底，见 stateJson()
            }
            render();
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.status);
        useBundledContract();
        useDeviceCjkFont();
        sentence = (TextView) findViewById(R.id.sentence);
        badge = (TextView) findViewById(R.id.badge);
        foot = (TextView) findViewById(R.id.foot);
        panels = (TextView) findViewById(R.id.panels);
        // 字形这一层现在不干预：这台机器上无论用系统族名、设备自带的 .otf/.ttc、还是随包带的字体，
        // 屏幕上都是「每个字同一个字形」，而换一个字体那个字形跟着变——就是每个字都落到了那个字体的
        // .notdef。也就是说：到达 TextView 的码位不是 dex 里那串汉字（dex 里的字节已逐字核过）。
        // 下一步不靠像素猜：把这一屏句子的码位写到设备上，用 adb 读回来看（F17）。
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
        // 按键不许变成回执、签到或第二次提醒（契约 commitState.pendingMotion 那句）。
        // 它唯一能生效的前提：内核说这会儿真挂着一条要受理的动议（AGREE-11、D34）。
        settle(key);
        render();
        return true;
    }

    /**
     * 受理这一步落进事件账：写 MOTION_SETTLED，把那条动议带的时间量原样带过去（COMMIT-07）。
     * 理由这一句是「用遥控器受理」——遥控器打不出字，写明来源比编一句理由诚实（AUTO-03）。
     * 没挂着动议的时候，这里什么都不写：婉拒与未受理在账上是同一件事（D34）。
     */
    private void settle(String key) {
        if (!"accept".equals(key)) {
            return;
        }
        String pending = pendingMotion();
        // 排查用：按键那一刻看到了什么。「没挂着动议」与「没读到结论」在屏上是同一件事，病因不同。
        write(path(this, "youban-settle.json", true), "{\"key\":\"" + key + "\",\"pending\":"
                + (pending == null ? "null" : "\"" + pending + "\"") + ",\"saw\":"
                + (displayed == null ? "\"没有一份算好的结论\""
                   : "\"" + slice(displayed, "\"pendingMotion\":") + "\"") + "}");
        if (pending == null) {
            return;
        }
        StringBuilder line = new StringBuilder("{\"kind\":\"MOTION_SETTLED\",\"profile\":\"").append(profile())
                .append("\",\"fields\":{\"kind\":\"").append(pending).append("\",\"reason\":\"用遥控器受理\"");
        String extra = pendingAmount(pending);
        if (extra != null) {
            line.append(',').append(extra);
        }
        append(path(this, EVENTS_NAME, true), line.append("}}").toString());
    }

    /** 内核算出来的那份结论里，挂着要受理的动议是哪一种（子对象，不看屏上那句话，也不自己判）。 */
    private String pendingMotion() {
        String json = displayed != null ? displayed : stateJson();
        String needle = "\"pendingMotion\":{\"kind\":\"";
        int at = json.indexOf(needle);
        if (at < 0) {
            return null;
        }
        int from = at + needle.length();
        int close = json.indexOf('"', from);
        return close < 0 ? null : json.substring(from, close);
    }

    /** 那条动议提了多少毫秒就按多少受理：从账里最后一条同种动议原样带过来。 */
    private String pendingAmount(String kind) {
        String events = read(path(this, EVENTS_NAME, false));
        if (events == null) {
            return null;
        }
        String found = null;
        for (String line : events.split("\\n")) {
            if (line.contains("\"kind\":\"MOTION\"") && line.contains("\"" + kind + "\"")) {
                for (String key : new String[] {"pauseMs", "ms", "minutes"}) {
                    String v = numberAfter(line, key);
                    if (v != null) {
                        found = "\"" + key + "\":" + v;
                    }
                }
            }
        }
        return found;
    }

    /** 从那份结论里截一小段出来看，够用就行——不为诊断在壳层里写一个 JSON 解析器。 */
    private static String slice(String text, String needle) {
        int at = text.indexOf(needle);
        return at < 0 ? "没有 pendingMotion 这个字段" : text.substring(at, Math.min(text.length(), at + 40));
    }

    private static String numberAfter(String text, String key) {
        int at = text.indexOf("\"" + key + "\":");
        if (at < 0) {
            return null;
        }
        int from = at + key.length() + 3;
        int end = from;
        while (end < text.length() && text.charAt(end) >= '0' && text.charAt(end) <= '9') {
            end++;
        }
        return end > from ? text.substring(from, end) : null;
    }

    private void record(String key) {
        long now = System.currentTimeMillis();
        write(path(this, INPUT_NAME, true), "{\"key\":\"" + key + "\",\"at\":" + now
                + ",\"monoMs\":" + android.os.SystemClock.elapsedRealtime() + "}");
    }

    /**
     * 应用自己的外部目录（不用任何存储权限，adb 也读得到）。
     * 之前直接写 /sdcard/Download：API 28 上没声明存储权限就是写不进去，按键像没被接到一样
     * ——这条是实测踩出来的（facts/DEVICES.md#F17）。公共目录只作兜底。
     */
    static String path(Context c, String name, boolean forWrite) {
        java.io.File dir = c.getExternalFilesDir(null);
        if (dir != null) {
            if (!forWrite || dir.isDirectory()) {
                return new java.io.File(dir, name).getAbsolutePath();
            }
        }
        return PUBLIC_DIR + "/" + name;
    }

    /** 结论在设备上算出来：事件账 + 当日方案 → 内核。别人算好推上来的那份只当调试兜底。 */
    private String stateJson() {
        String plan = read(path(this, PLAN_NAME, false));
        if (plan == null) {
            plan = read(PUBLIC_DIR + "/" + PLAN_NAME);
        }
        if (plan != null) {
            try {
                String events = read(path(this, EVENTS_NAME, false));
                String local = Kernel.state(events == null ? "" : events, plan, profile(), strength(), null);
                debugSource = null;
                displayed = local;
                write(path(this, STATE_OUT_NAME, true), local); // 给设备测试读回去比一遍
                return local;
            } catch (RuntimeException e) {
                debugSource = "内核没跑起来：" + e.getClass().getSimpleName();
                // 异常原文落到设备上：不写出来的话，屏幕上只剩一句兜底话，等于把病因藏起来。
                StringBuilder trace = new StringBuilder(debugSource).append(" | ").append(String.valueOf(e.getMessage()));
                for (StackTraceElement s : e.getStackTrace()) {
                    trace.append("\n  at ").append(s.toString());
                    if (trace.length() > 1200) break;
                }
                write(path(this, "youban-kernel-error.txt", true), trace.toString());
                return null;
            }
        }
        // 没有当日方案时退到调试来源：这一屏会在角标下面写明它是调试塞进来的，不是设备算的。
        String json = read(path(this, STATE_NAME, false));
        debugSource = json != null ? "调试来源：adb 塞好的结论（不是设备算的）" : null;
        return json != null ? json : read(PUBLIC_DIR + "/" + STATE_NAME);
    }

    private String profile() {
        String v = read(path(this, "youban-profile.txt", false));
        return v != null && !v.trim().isEmpty() ? v.trim() : "member:kid";
    }

    private String strength() {
        String v = read(path(this, "youban-strength.txt", false));
        return v != null && !v.trim().isEmpty() ? v.trim() : "negotiated";
    }

    /**
     * 诊断用：把这一屏句子的码位写下来（前 24 个）。
     * 为什么要它：像素只能告诉我「每个字同一个字形」，告不了我到达 TextView 的是什么码位；
     * 而本地的渲染器也不是中文的验收依据（F18）。诊断文件不是结论，修好就删。
     */
    /**
     * 这条链只由**画**来答，不由我看截屏来答：把句子里每个字单独画进一张小图，比它们的字节。
     * 17 个字各画各的 → 得到 17 种不同的图，那就是「每个字同一个字形」这条说法错了；
     * 只得到 1 种 → 塌陷是真的，而且这条判据不依赖字体、不依赖分辨率、也不依赖谁的肉眼。
     */
    private void dumpGlyphCoverage(String s) {
        android.graphics.Paint paint = new android.graphics.Paint();
        paint.setAntiAlias(true);
        paint.setTextSize(64f);
        java.util.HashSet<String> distinct = new java.util.HashSet<String>();
        StringBuilder which = new StringBuilder();
        for (int i = 0; i < s.length() && distinct.size() < 40 && i < 40; i++) {
            char c = s.charAt(i);
            if (c < 0x2E80) {
                continue;
            }
            android.graphics.Bitmap bmp = android.graphics.Bitmap.createBitmap(72, 72,
                    android.graphics.Bitmap.Config.ARGB_8888);
            android.graphics.Canvas canvas = new android.graphics.Canvas(bmp);
            if (sentence.getTypeface() != null) {
                paint.setTypeface(sentence.getTypeface());
            }
            canvas.drawText(String.valueOf(c), 4f, 56f, paint);
            int[] px = new int[72 * 72];
            bmp.getPixels(px, 0, 72, 0, 0, 72, 72);
            int ink = 0;
            int hash = 1;
            for (int p0 = 0; p0 < px.length; p0 += 7) {
                if (((px[p0] >>> 24) & 0xFF) > 24) {
                    ink++;
                }
                hash = hash * 1000003 + px[p0];
            }
            if (ink == 0) {
                which.append(" ").append(String.format("%04x", (int) c)).append("=空白");
            } else {
                distinct.add(Integer.toString(hash));
            }
            bmp.recycle();
        }
        write(path(this, "youban-glyphs.json", true), "{\"distinct\":" + distinct.size()
                + ",\"blank\":\"" + which + "\",\"font\":\"" + String.valueOf(fontNote) + "\"}");
    }

    private void dumpCodepoints(String s) {
        StringBuilder sb = new StringBuilder("{\"len\":" + s.length() + ",\"cps\":[");
        int n = Math.min(24, s.length());
        for (int i = 0; i < n; i++) {
            sb.append(i == 0 ? "\"" : ",\"").append(String.format("%04x", (int) s.charAt(i))).append("\"");
        }
        sb.append("]}");
        write(path(this, "youban-diag.json", true), sb.toString());
    }

    private void render() {
        String json = stateJson();
        if (json == null) {
            sentence.setText("还没有读到内核的结论：这一屏不做任何判定。");
            badge.setText("");
            foot.setText("状态来源：adb broadcast com.youban.STATE 或 " + STATE_NAME);
            return;
        }
        // 只取契约里那几个字段（commitState.fields）；界面不从 status 反推层，层是内核给的。
        String tier = field(json, "tier", "L1");
        String ceiling = field(json, "tierCeiling", "L1");
        String wording = field(json, "wording", "statusSentence");
        String status = field(json, "status", "honored");
        String reason = field(json, "fallbackReason", "");
        // 那句措辞来自内核（句子在契约那一份里）：界面这边不许再拼一遍——之前这里就有四条 if（D47）。
        String said = field(json, "text", "内核没给出这句措辞。");
        sentence.setText(said);
        // 对照：把同一份文案放进那个「画得对」的视图里。屏幕上两行一样就是同一个字符串两条命，
        // 那就是 per-string；两行不一样就是 per-view（画的那一层），字体与码位这两条就可以彻底划掉。
        // 常驻那几条也是内核给的句子（契约 commitState.panels）：界面只串一个分隔符。
        String notes = array(json, "panels");
        if (panels != null) {
            panels.setText(notes);
        }
        dumpCodepoints(said + (notes.isEmpty() ? "" : " · " + notes));
        dumpGlyphCoverage(said);
        badge.setText(tier + " · " + ("due".equals(status) ? "待做" : "无到期项"));
        foot.setText("落层 " + tier + " · 强度天花板 " + ceiling
                + (reason.isEmpty() ? "" : " · " + reason)
                + (debugSource == null ? " · 结论来自设备上的内核" : " · " + debugSource)
                + (fontNote == null ? "" : " · " + fontNote));
    }

    /** 措辞仍按 LAYERING §4 那一句：状态句 + 下一步，不指责、不催促、不承诺兑换。 */

    /**
     * 用设备自带的中文字形。为什么还要显式指一次：只靠 textAppearance 时，这条链落到一个
     * 只有零星汉字的字体上——「约定」「完」画得对，「超」「天」成一排方块（截屏为证）。
     * 而这台机器 `ls /system/fonts` 里根本没有单字面的中文字体：汉字只在两个 .ttc 里，所以要选面（F17）。
     */
    private static final String[] DEVICE_CJK_FONTS = {
            "/system/fonts/NotoSansCJK-Regular.ttc",
            "/system/fonts/NotoSerifCJK-Regular.ttc",
            "/system/fonts/SourceHanSerifSC-Bold.otf",
    };

    /** 这台机器上只有这两个 .ttc 带完整汉字（`ls /system/fonts` 里没有单字面的中文字体）。 */
    private static final int[] TTC_FACES = {2, 1, 3, 0, 7, 6, 5, 4};

    private void useDeviceCjkFont() {
        // 试过了、别再试的那两条：随包带单字面 TTF（阿里普惠，字形齐全）与设备自带 .otf/.ttc，
        // 屏幕上都是同一句里只「约定完」画对，其余成同一个字——连自带完整字体的 TTF 也一样，
        // 堵点不在字体上（见 facts/DEVICES.md#F17）。
        for (String p : DEVICE_CJK_FONTS) {
            if (!new File(p).canRead()) {
                continue;
            }
            for (int i : TTC_FACES) {
                android.graphics.Typeface face = buildFace(p, i);
                if (face == null) {
                    continue;
                }
                // 不干预字形：这条链交给系统的中文回退。之前「每个字同一个字形」是我读低分辨率
                // 截屏读出来的，设备一比就把这条话说清了（见 dumpGlyphCoverage 的 distinct）。
                fontNote = "系统里有这些中文字形：" + p.substring(p.lastIndexOf('/') + 1);
                return;
            }
        }
        fontNote = "设备上没找到可读的中文字体";
    }

    /**
     * .ttc 是多字面的容器，createFromFile 只能拿到第 0 面（那一台是日文面）。选面那一步在
     * 这台设备上做不到：`Typeface.Builder(String, int)` 在我们编译的那个 android.jar 里没有
     * （编译器把它解析成 Builder(AssetManager, String)），低版本只有 createFromFile 这一条。
     * 所以「同一台机器上汉字只装在 .ttc 里」就是这条链现在最后的堵点（F17）——
     * 要么随包带一个单字面的简体字形（OFL 那条路），要么换一台自带单字面 CJK 的设备。
     */
    private static android.graphics.Typeface buildFace(String path, int index) {
        try {
            return index == 0 ? android.graphics.Typeface.createFromFile(path) : null;
        } catch (RuntimeException e) {
            return null;
        }
    }

    /** 契约随包带：内核要从那张表取层级，路径在设备上得自己落一份。 */
    private void useBundledContract() {
        try {
            java.io.InputStream in = getAssets().open(CONTRACT_NAME);
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
            }
            in.close();
            String dest = path(this, CONTRACT_NAME, true);
            // 每次都覆盖：装新版 APK 时若留着上一版解出来的契约，内核会照着旧那张表判，
            // 于是设备与 Mac 两边悄悄用了两份契约——那种错最难查。
            new File(dest).getParentFile().mkdirs();
            write(dest, new String(out.toByteArray(), "UTF-8"));
            com.youban.core.Kernel.useContract(dest);
        } catch (Exception e) {
            fontNote = "契约没解出来：" + e.getClass().getSimpleName();
        }
    }

    /**
     * 事件只追加，不改写：这是设备端唯一的事实来源（D47）。
     * 必须用真正的追加流：连着几条广播进来时，"读全文 + 写全文" 会互相覆盖——
     * COMMIT-04 那一步八条只落了四条，屏幕上就从 due 掉回 honored，看着像判定错了。
     */
    static void append(String path, String line) {
        java.io.File f = new java.io.File(path);
        if (f.getParentFile() != null) {
            f.getParentFile().mkdirs();
        }
        try {
            java.io.FileOutputStream out = new java.io.FileOutputStream(f, true);
            out.write((line + "\n").getBytes("UTF-8"));
            out.close();
        } catch (java.io.IOException e) {
            // 账写不进去就是设备故障，界面仍按现有账显示；不在这层编结论。
        }
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

    /** 给 StateReceiver 用的入口：广播里带的结论要先落到文件（F17 那个坑）。 */
    static void writeText(String path, String body) {
        write(path, body);
    }

    private static void write(String path, String body) {
        try {
            java.io.File f = new java.io.File(path);
            if (f.getParentFile() != null) {
                f.getParentFile().mkdirs();
            }
            FileWriter w = new FileWriter(f);
            w.write(body);
            w.close();
        } catch (Exception e) {
            // 写不下去就不写：这一层没有「先记着回头补」这条路（不伪造输入）。
        }
    }

    /** 极简取值：这一层不需要 JSON 库，字段少，读不出来就用默认，绝不猜。 */
    /** 取一个字符串数组，用「 · 」串起来：没有这个键就当没有这一条。 */
    static String array(String json, String key) {
        int at = json.indexOf("\"" + key + "\":[");
        if (at < 0) {
            return "";
        }
        int from = at + key.length() + 4;
        int to = json.indexOf(']', from);
        if (to < 0) {
            return "";
        }
        String[] parts = json.substring(from, to).split("\",\"");
        StringBuilder sb = new StringBuilder();
        for (String part : parts) {
            String clean = part.replace("\"", "").replace(",", " · ");
            if (!clean.trim().isEmpty()) {
                sb.append(sb.length() == 0 ? "" : " · ").append(clean.trim());
            }
        }
        return sb.toString();
    }

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
