package com.youban.tv;

import android.app.Activity;
import com.youban.core.Kernel;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
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
    static final String PROFILE_NAME = "youban-profile.txt";
    static final String PROBE_NAME = "youban-probe.json";
    static final String OVERLAY_NAME = "youban-overlay.json";
    /** 这台设备指定的那一个应用（ONBOARD-12）：缩起之后拉起它一次；空就是没指定。 */
    static final String AUTOLAUNCH_NAME = "youban-autolaunch.txt";
    /** 启动形态的自证：这一轮缩没缩、隔了多少毫秒、那一个应用拉起成没成（LAYER-14、设备自检第 11 道）。 */
    static final String STARTUP_NAME = "youban-startup.json";
    static final String PANEL_NAME = "youban-panel.json"; // 那一屏只读的条目：设备自检第 10 道读它 // 那一张到底出没出、落在哪儿：设备自检第 9 道读它 // 上一次到前台是什么时候：证据不过期那一条的凭据（ONBOARD-07）
    /** 公共目录做兜底：装了存储权限的开发机可以 adb push 到那儿直接看效果。 */
    static final String PUBLIC_DIR = "/sdcard/Download";

    private String fontNote = null;
    private String debugSource = null;
    // 这一屏正在显示的那份结论。按键时看的是它，不在按键那一刻重跑内核。
    // static 是有意的：广播用 CLEAR_TOP 起Activity 时可以另起一个实例，实例字段会让按键落到
    // 另一个实例上、看到的是自己那份旧结论（真机上就是「按键像没被听见」，见 F22）。
    private static String displayed = null;
    // 从桌面或开机启动项那一路进来的才算冷启动（LAYER-14）：用 `am start -n` 点名的调试启动不缩，
    // 那样设备测试那两道「真机显示」还能拍到这一屏。
    private boolean fromLauncher = false;
    private long coldStartAt = 0L;
    private int rosterIndex = 0; // 换那一屏的光标在第几档（名单由内核从账里给）
    private boolean noPlan = false; // 这台设备还没存过约定方案（AGREE-13）
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
        // 冷启动那一帧（LAYER-14）：桌面/开机启动项那一路进来，加载完就把前台交回去，不占全屏。
        // 这条不只是礼貌——前台计时看的是「现在前面是什么」（AUTO-11），自己占着全屏就看不见要计时的东西。
        fromLauncher = getIntent() != null && Intent.ACTION_MAIN.equals(getIntent().getAction());
        coldStartAt = android.os.SystemClock.elapsedRealtime();
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
        if (sentence != null && fromLauncher) {
            sentence.post(new Runnable() {
                @Override
                public void run() {
                    maybeHandBack();
                }
            });
        }
    }

    /**
     * 加载完那一帧之后把前台交回去（LAYER-14、ONBOARD-11、ONBOARD-12、D81）。
     * 例外只有契约 startup.coldStart.exceptions 那两处，这里不自己添第三处：
     * 首启那六步那一步（内核给 nextAction = agreement）留在这一屏给人走完；
     * 只读那一屏是按键走进来的，那一屏不归冷启动管。
     */
    private void maybeHandBack() {
        if (!fromLauncher) {
            return;
        }
        fromLauncher = false;
        String target = readOneLine(AUTOLAUNCH_NAME);
        String shape = Kernel.startup(target);
        long ms = android.os.SystemClock.elapsedRealtime() - coldStartAt;
        String action = field(displayed == null ? stateJson() : displayed, "nextAction", "");
        if ("agreement".equals(action)) {
            write(path(this, STARTUP_NAME, true),
                    "{\"collapse\":false,\"why\":\"agreement\",\"ms\":" + ms + ",\"target\":null,\"launched\":null}");
            return;
        }
        Boolean launched = null;
        if (target != null && !target.isEmpty()) {
            launched = launchTarget(target);
            if (!launched) {
                // 拉起失败只说一句事实，重试次数由 startup.autoOpen.retries 那一处给（0）：这里不排退避表。
                String said = field(shape, "failLine", "");
                if (!said.isEmpty()) {
                    OverlayCard.show(getApplicationContext(), said, petName(), petWhy);
                }
            }
        }
        write(path(this, STARTUP_NAME, true), "{\"collapse\":true,\"ms\":" + ms + ",\"target\":"
                + (target == null || target.isEmpty() ? "null" : ("\"" + target + "\""))
                + ",\"launched\":" + (launched == null ? "null" : launched.toString()) + "}");
        finish();
    }

    /** 拉起那一个应用：本机用户指定的一次拉起，不是切源、不是 L5、也不是动议（AUTO-16）。 */
    private boolean launchTarget(String pkg) {
        try {
            Intent it = getPackageManager().getLaunchIntentForPackage(pkg);
            if (it == null) {
                // 桌面这类包不一定带 LAUNCHER 那一项，带的是 HOME（本机答出的那一个就是这种）。
                Intent home = new Intent(Intent.ACTION_MAIN);
                home.addCategory(Intent.CATEGORY_HOME);
                java.util.List<android.content.pm.ResolveInfo> rs =
                        getPackageManager().queryIntentActivities(home, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY);
                for (android.content.pm.ResolveInfo r : rs) {
                    if (r.activityInfo != null && pkg.equals(r.activityInfo.packageName)) {
                        it = new Intent(Intent.ACTION_MAIN);
                        it.addCategory(Intent.CATEGORY_HOME);
                        it.setClassName(r.activityInfo.packageName, r.activityInfo.name);
                        break;
                    }
                }
            }
            if (it == null) {
                return false;
            }
            it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(it);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private String readOneLine(String name) {
        try {
            String body = read(path(this, name, false));
            if (body == null) {
                return null;
            }
            String s = body.trim();
            return s.isEmpty() ? null : s;
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * 桌面与开机启动项那一路进来的是 MAIN/LAUNCHER；singleTask 下第二次进来走的是这里，
     * 不是 onCreate——只在一处设那个标记的话，第二次打开就赖着不走了（真机上就是这个现象）。
     */
    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        boolean launcher = intent != null && Intent.ACTION_MAIN.equals(intent.getAction());
        coldStartAt = android.os.SystemClock.elapsedRealtime();
        if (launcher && sentence != null) {
            fromLauncher = true;
            render();
            sentence.post(new Runnable() {
                @Override
                public void run() {
                    maybeHandBack();
                }
            });
        }
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
        recordProbe();
        render();
    }

    /**
     * 离开本应用才有的那一张（L3：悬浮角标/浮层，LAYERING §1）。
     * 三条同时成立才显示：内核这一轮确有要说的（有到期项，且不是「去立约定」那一步）、
     * 悬浮窗权限被授予过、窗口落得进字幕带以上那块地方。任何一条不成立就是不显示——
     * 不重试、不排队、不提示（ONBOARD-06：未完成只降级）。
     */
    @Override
    protected void onStop() {
        super.onStop();
        boolean shown = false;
        String rect = "null";
        String said = null;
        try {
            String state = stateJson();
            String action = field(state, "nextAction", "");
            if (!action.isEmpty() && !"agreement".equals(action) && !"none".equals(action)) {
                said = field(state, "text", "");
                if (said.isEmpty()) {
                    said = null;
                } else if (OverlayCard.show(getApplicationContext(), said, petName(), petWhy)) {
                    // 用 application context：在 onStop 里加窗时 activity 的窗口令牌正在拆，
                    // 用 activity 加进去的窗只有记录没有画面（mHasSurface=false，F30）。
                                        // 布局落在下一帧：等到量到真实落点为止，量不到就用预测值。
                    int[] box = OverlayCard.rect();
                    int waited = 0;
                    while (waited < 20 && (box == null || box[3] <= box[1])) {
                        try {
                            Thread.sleep(50L);
                        } catch (InterruptedException e) {
                            break;
                        }
                        box = OverlayCard.rect();
                        waited++;
                    }
                    if (box != null) {
                        rect = "[" + box[0] + "," + box[1] + "," + box[2] + "," + box[3] + "]";
                    }
                    shown = true;
                }
            }
        } catch (RuntimeException ignored) {
            // 算不出结论就没有这一张：不在这里编一句，也不留在屏上（F21 那一条的同一家族）。
        }
        // 那一块那三项归 OverlayCard 自己拼（它持有那三个值）：调用处排参数错过一次位。
        write(path(this, OVERLAY_NAME, true),
                overlayRecord(OverlayCard.attempted(), shown, rect, said, OverlayCard.rendered(),
                        OverlayCard.refuse()) + OverlayCard.petRecord() + "}");
    }

    /** 回到前台就收掉那一张：L3 是「离开时才在」，不是常驻（LAYERING §1）。 */
    @Override
    protected void onStart() {
        super.onStart();
        OverlayCard.hide();
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
            case KeyEvent.KEYCODE_DPAD_RIGHT:
            case KeyEvent.KEYCODE_DPAD_UP:
                key = "next";
                break;
            case KeyEvent.KEYCODE_DPAD_LEFT:
            case KeyEvent.KEYCODE_DPAD_DOWN:
                key = "prev";
                break;
            case KeyEvent.KEYCODE_INFO:
                key = "switch"; // 换这一档：这一屏只挑人，改不了任何约定（AGREE-08）
                break;
            // SETTINGS(176) 在这一台电视上被系统吃掉，压根不进 onKeyDown（实测）；
            // BOOKMARK(174) 两边都能到这里，拿来开那一屏只读的条目。
            case KeyEvent.KEYCODE_BOOKMARK:
                key = "panel"; // 那一屏只读的条目（AGREE-14）：没有按钮，也不写账
                break;
            default:
                break;
        }
        if (key == null) {
            return super.onKeyDown(code, event);
        }
        if (setupPlan != null) {
            setupKey(key);
            return true;
        }
        if ("switch".equals(key)) {
            switchKey();
            return true;
        }
        if ("panel".equals(key)) {
            panelKey();
            return true;
        }
        record(key);
        // 按键在账上只有一条生路：挂着一条要受理的动议时，确认键就是那一次受理（AGREE-11、D34）。
        // 除此之外，它只能带人走屏——内核说「还缺一份约定」时，确认键进那六步，一个字段都不写。
        // 回执、签到、第二次提醒这三样一律不进账（契约 commitState.pendingMotion 那句）。
        if (settle(key)) {
            render();
            return true;
        }
        if ("accept".equals(key) && "agreement".equals(field(displayed == null ? stateJson() : displayed, "nextAction", ""))) {
            openSetup();
            return true;
        }
        render();
        return true;
    }

    // 首启那六步。这一层不认字段名：屏幕上问什么、现在是什么、有哪些可选，全是内核从契约里给的（AGREE-05）。
    private String setupPlan = null;
    private int setupIndex = 0;
    private String setupField = null;

    private void openSetup() {
        setupPlan = read(path(this, PLAN_NAME, false));
        if (setupPlan == null) {
            setupPlan = "{}";
        }
        setupIndex = 0;
        renderSetup();
    }

    private void renderSetup() {
        String screen = Kernel.setupScreen(setupPlan, setupIndex,
                Kernel.signingVersion(eventsOrEmpty()), false);
        write(path(this, "youban-setup-screen.json", true), screen);
        sentence.setText(array(screen, "lines"));
        panels.setText("");
        setupField = field(screen, "field", "");
        badge.setText("立约定 · 未签");
        foot.setText(field(screen, "foot", "") + " · 结论来自设备上的内核");
        dumpCodepoints(sentence.getText().toString());
    }

    private void setupKey(String key) {
        if ("next".equals(key) || "prev".equals(key)) {
            if (setupField != null && !setupField.isEmpty()) {
                setupPlan = Kernel.cycle(setupPlan, setupField, "prev".equals(key));
                // 选中的值当场写进方案（未签）：中途走开也只是「按这些还没签的值跑」（AGREE-06）。
                write(path(this, PLAN_NAME, true), setupPlan);
                renderSetup();
            }
            return;
        }
        if ("decline".equals(key)) {
            if (setupIndex > 0) {
                setupIndex--;
            } else {
                setupPlan = null;
            }
            if (setupPlan == null) {
                render();
            } else {
                renderSetup();
            }
            return;
        }
        String screen = Kernel.setupScreen(setupPlan, setupIndex,
                Kernel.signingVersion(eventsOrEmpty()), false);
        if (!flag(screen, "last")) {
            setupIndex++;
            renderSetup();
            return;
        }
        // 最后一步才是签署：这里往账里写 PLAN_SIGNED，下一屏的「没签」那一栏就消失了（AGREE-05）。
        long version = Kernel.signingVersion(eventsOrEmpty());
        append(path(this, EVENTS_NAME, true), "{\"kind\":\"PLAN_SIGNED\",\"profile\":\"" + profile()
                + "\",\"fields\":{\"version\":" + version + "}}");
        setupPlan = null;
        render();
    }

    /**
     * 每一次到前台都记一次探针时间：这是「证据不过期」那一条的凭据（ONBOARD-07）。
     * 开机不单独跑——开机后的第一次到前台就是那一次重跑，所以清单里不许有 BOOT_COMPLETED，
     * 也不许有后台常驻（契约 devicePermissions 那一处、装包清单门）。
     */
    private void recordProbe() {
        write(path(this, PROBE_NAME, true), "{\"at\":" + System.currentTimeMillis()
                + ",\"monoMs\":" + android.os.SystemClock.elapsedRealtime() + "}");
    }

    /**
     * 受理这一步落进事件账：写 MOTION_SETTLED，把那条动议带的时间量原样带过去（COMMIT-07）。
     * 理由这一句是「用遥控器受理」——遥控器打不出字，写明来源比编一句理由诚实（AUTO-03）。
     * 没挂着动议的时候，这里什么都不写：婉拒与未受理在账上是同一件事（D34）。
     */
    /** @return 是否真的落了一条受理（落了就不用再看「缺约定」那一支）。 */
    private boolean settle(String key) {
        if (!"accept".equals(key)) {
            return false;
        }
        String pending = pendingMotion();
        // 排查用：按键那一刻看到了什么。「没挂着动议」与「没读到结论」在屏上是同一件事，病因不同。
        write(path(this, "youban-settle.json", true), "{\"key\":\"" + key + "\",\"pending\":"
                + (pending == null ? "null" : "\"" + pending + "\"") + ",\"saw\":"
                + (displayed == null ? "\"没有一份算好的结论\""
                   : "\"" + slice(displayed, "\"pendingMotion\":") + "\"") + "}");
        if (pending == null) {
            return false;
        }
        StringBuilder line = new StringBuilder("{\"kind\":\"MOTION_SETTLED\",\"profile\":\"").append(profile())
                .append("\",\"fields\":{\"kind\":\"").append(pending).append("\",\"reason\":\"用遥控器受理\"");
        String extra = pendingAmount(pending);
        if (extra != null) {
            line.append(',').append(extra);
        }
        append(path(this, EVENTS_NAME, true), line.append("}}").toString());
        return true;
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

    private static String petWhy;

    /**
     * 这台设备该不该画角上那一块、画哪一只：判定在 Kernel.pet 那一处（名单说了算，两个内核比过），
     * 这里只把方案与机型递过去（spec/PET.md#PET-07、D83）。
     */
    private String petName() {
        String plan = read(path(this, PLAN_NAME, false));
        if (plan == null) {
            plan = read(PUBLIC_DIR + "/" + PLAN_NAME);
        }
        try {
            String name = Kernel.pet(plan == null ? "{}" : plan, Build.MODEL);
            // 画与不画都要说得出为什么：名单里有它却没画，是最难查的那种错（本机看到的是哪一份契约、哪个机型）。
            petWhy = name == null ? listedNote() : null;
            return name;
        } catch (RuntimeException e) {
            // 内核没跑起来就不画：那一块不是结论，缺它不欠什么。但**为什么没画**要能报出来，
            // 不然「名单里却没画」只剩一句猜话（refuse 那一条的同一家族，F30）。
            StringBuilder why = new StringBuilder(e.getClass().getSimpleName()).append(": ")
                    .append(String.valueOf(e.getMessage())).append(" @ ")
                    .append(e.getStackTrace().length > 0 ? e.getStackTrace()[0].toString() : "?");
            for (int k = 1; k < 4 && k < e.getStackTrace().length; k++) {
                why.append("\n  at ").append(e.getStackTrace()[k].toString());
            }
            petWhy = why.toString();
            write(path(this, "youban-pet.txt", true), petWhy);
            return null;
        }
    }

    /** 内核说「不画」时的两句诊断：这台设备看到的名单里有几台、本机机型是什么（PET-07）。 */
    private String listedNote() {
        try {
            org.json.JSONArray list = new org.json.JSONObject(read(path(this, CONTRACT_NAME, true)))
                    .getJSONObject("pet").getJSONObject("appearance").optJSONArray("measuredOn");
            return "本机看到的名单 " + (list == null ? "没有这一格" : list.length() + " 台")
                    + " · Build.MODEL=" + Build.MODEL;
        } catch (Exception e) {
            return "名单读不出来：" + e.getClass().getSimpleName();
        }
    }

    /** 结论在设备上算出来：事件账 + 当日方案 → 内核。别人算好推上来的那份只当调试兜底。 */
    private String stateJson() {
        String plan = read(path(this, PLAN_NAME, false));
        if (plan == null) {
            plan = read(PUBLIC_DIR + "/" + PLAN_NAME);
        }
        if (plan == null) {
            // 这台设备还没存过配置：不是错误，按契约那张默认表跑，屏幕上写明（AGREE-13）。
            plan = "{}";
            noPlan = true;
        }
        // 到这里一定有方案可算：没存过就按契约那张默认表算。结论一律是设备自己算的，
        // adb 塞进来的那份（STATE_NAME）不再当结论用——它只在这台设备上算不出来时当排版兜底。
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
                // 设备上算不出来才退到调试来源，并在角标下面写明它是调试塞进来的，不是设备算的。
            String pushed = read(path(this, STATE_NAME, false));
            debugSource = pushed != null ? "调试来源：adb 塞好的结论（不是设备算的）" : null;
            return pushed != null ? pushed : read(PUBLIC_DIR + "/" + STATE_NAME);
        }
    }

    /** 账还没有第一条的时候交 ""，不交 null：Kotlin 那边这个参数是非空的（真机上就这么炸过一次，见 F22）。 */
    // 换这一档：切过去加载那一组的方案与版本（AGREE-08）。壳层不判谁签过——那一屏的内容也是内核给的。
    private boolean rosterOn = false;
    private boolean panelOn = false;

    private void renderSwitch() {
        String screen = Kernel.rosterScreen(planJsonOrEmpty(), eventsOrEmpty(), profile(), rosterIndex);
        sentence.setText(array(screen, "lines"));
        panels.setText(field(screen, "head", ""));
        badge.setText("换这一档");
        foot.setText(field(screen, "foot", "") + " · 名单从设备上的事件账里读，不在这里编（PROFILE-01）");
        write(path(this, "youban-setup-screen.json", true), screen);
        dumpCodepoints(sentence.getText().toString());
    }

    private void switchKey() {
        if (!rosterOn) {
            rosterOn = true;
            rosterIndex = 0;
            renderSwitch();
            return;
        }
        String screen = Kernel.rosterScreen(planJsonOrEmpty(), eventsOrEmpty(), profile(), rosterIndex);
        if (flag(screen, "changed")) {
            // 切换是一条事件，不改任何约定：切过去之后那一组显示什么，由内核按那一组的方案算（AGREE-08）。
            String target = field(screen, "target", profile());
            append(path(this, EVENTS_NAME, true), "{\"kind\":\"PROFILE_SWITCH\",\"profile\":\"" + target
                    + "\",\"fields\":{},\"from\":\"" + profile() + "\",\"to\":\"" + target + "\"}");
            write(path(this, PROFILE_NAME, true), target);
            rosterOn = false;
            render();
            return;
        }
        // 光标还停在当前这一档：←→ 先挪到另一档，确认键才切。
        rosterIndex = rosterIndex == 0 ? 1 : 0;
        renderSwitch();
    }

    /**
     * 「这一档现在按哪几项跑」那一屏（AGREE-14）：全是读——没有按钮、没有红点、没有完成度，
     * 也不往账里写任何东西。屏上那些字由设备上的内核给（契约 agreement.panel 那一处），
     * 壳层只做一件事：把它们串起来。
     */
    private void renderPanel() {
        String screen = Kernel.panel(path(this, CONTRACT_NAME, false), eventsOrEmpty(), profile(), plansJson());
        sentence.setText(array(screen, "lines"));
        panels.setText("");
        badge.setText(field(screen, "title", ""));
        foot.setText(field(screen, "foot", ""));
        write(path(this, PANEL_NAME, true), screen);
        dumpCodepoints(sentence.getText().toString());
    }

    private void panelKey() {
        if (panelOn) {
            panelOn = false;
            render();
            return;
        }
        panelOn = true;
        renderPanel();
    }

    /** 每一档存过的那一份，按身份收在一起：那一屏读的就是这一份（AGREE-14、AGREE-08）。 */
    private String plansJson() {
        StringBuilder s = new StringBuilder("{");
        java.io.File dir = getExternalFilesDir(null);
        if (dir != null && dir.isDirectory()) {
            java.io.File[] files = dir.listFiles();
            if (files != null) {
                java.util.Arrays.sort(files);
                for (java.io.File f : files) {
                    String n = f.getName();
                    if (!n.startsWith("youban-plan-") || !n.endsWith(".json")) {
                        continue;
                    }
                    String who = n.substring("youban-plan-".length(), n.length() - ".json".length()).replace('_', ':');
                    String body = read(f.getAbsolutePath());
                    if (body == null || body.indexOf('{') < 0) {
                        continue;
                    }
                    if (s.length() > 1) {
                        s.append(',');
                    }
                    s.append("\"").append(who).append("\":").append(body.substring(body.indexOf('{')));
                }
            }
        }
        // 当前这一档存的那一份也并进来（key 用身份本身，不是文件名——文件名里冒号换成了下划线）。
        String own = read(planPath());
        if (own != null && own.indexOf('{') >= 0) {
            if (s.length() > 1) {
                s.append(',');
            }
            s.append("\"").append(profile()).append("\":").append(own.substring(own.indexOf('{')));
        }
        return s.append('}').toString();
    }

    private String planJsonOrEmpty() {
        String plan = read(planPath());
        return plan == null ? "{}" : plan;
    }

    /** 方案按身份各存一份；没有那一份就退到旧的那一份，再退到契约那张默认表（AGREE-13）。 */
    private String planPath() {
        String named = path(this, PLAN_NAME.replace(".json", "") + "-" + profile().replace(":", "_") + ".json", false);
        return new java.io.File(named).exists() ? named : path(this, PLAN_NAME, false);
    }

    private String eventsOrEmpty() {
        String events = read(path(this, EVENTS_NAME, false));
        return events == null ? "" : events;
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
                + (noPlan ? " · 这台设备还没读到已存的约定，按默认跑" : "")
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

    /**
     * 那一张的记录：去没去试（attempted）、显示出来没有（shown）、落在哪儿、说的是哪一句。
     * 这两件分开记是设备自检要能分开「系统挡了」与「我们压根不该去试」。
     */
    private static String overlayRecord(boolean attempted, boolean shown, String rect, String text,
                                      String rendered, String refuse) {
        // 那一块在不在，是自检要读的两项之一：名单说了算，所以「名单里没有它」必须能证伪（PET-07）。
        return "{\"attempted\":" + attempted + ",\"shown\":" + shown + ",\"rect\":" + rect
                + ",\"text\":\"" + quote(text) + "\",\"rendered\":\"" + quote(rendered) + "\""
                + ",\"refuse\":\"" + quote(refuse) + "\"";
    }


    static String read(String path) {
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

    /**
     * 布尔得用布尔的读法。field() 只认字符串，读布尔一律退回兜底——同一类坑在「最后一屏」上
     * 犯过一次（F23），换这一档时又犯了一次：确认键永远切不过去。所以别再拿 field() 读 true/false。
     */
    static boolean flag(String json, String key) {
        return json.contains("\"" + key + "\":true");
    }

    static String quote(String s) {
        StringBuilder out = new StringBuilder();
        for (char ch : (s == null ? "" : s).toCharArray()) {
            if (ch == '"' || ch == '\\') {
                out.append('\\');
                out.append(ch);
                continue;
            }
            // 控制字符与换行不能直接进 JSON 字符串：带着一行栈的记录读回来是 null，等于没记
            // （自检就变成「没读到记录」，把病因遮掉了——这两天在这儿吃了两次）。
            if (ch < 0x20) {
                out.append(ch == '\n' ? "\\n" : " ");
                continue;
            }
            out.append(ch);
        }
        return out.toString();
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
