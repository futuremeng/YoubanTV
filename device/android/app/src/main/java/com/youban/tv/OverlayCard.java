package com.youban.tv;

import android.content.Context;
import android.graphics.BitmapFactory;
import android.graphics.PixelFormat;
import android.graphics.Bitmap;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * L3 那一张「离开本应用仍可见」的浮层（docs/LAYERING.md §1 L3、spec/LAYER.md#LAYER-13）。
 *
 * 三条硬规矩，都在这一处守：
 * <ul>
 *   <li>装完默认不开：悬浮窗权限没授予就什么都不做（契约 devicePermissions 那一条，
 *       授权由面板给出，ONBOARD-06）；</li>
 *   <li>只搬内核的话：屏上那一句是 Kernel.state 的 text / panels，这里不组句、不加提示；</li>
 *   <li>不抢焦点、不进字幕区：窗口是 NOT_FOCUSABLE 的（焦点仍在播放器那一侧），
 *       贴在内容角落且下边缘不超过字幕带上沿（契约 layering.overlay.subtitleBandPct）。</li>
 * </ul>
 * 这一层不采集任何东西：它只在显示的时候读那一本账，读不出结论就不显示（F21 那一条的同一家族）。
 */
final class OverlayCard {
    /** 字幕带要多高，写在契约 layering.overlay 那一处；这里不写死数字。 */
    private static final String CONTRACT_FILE = "contract.json";

    private static LinearLayout view;
    // 角上那一块的帧：只有这一层在显示时才走这张表，收掉就停（PET-07：只在有东西动时画）。
    private static ImageView pet;
    private static String petShown;
    private static String petWhy;
    private static String[] petFrames;
    private static int petFrame;
    private static final Handler ticker = new Handler(Looper.getMainLooper());
    private static final Runnable breathing = new Runnable() {
        @Override
        public void run() {
            if (pet == null || petFrames == null || petFrames.length < 2) {
                return;
            }
            petFrame = (petFrame + 1) % petFrames.length;
            paintFrame();
            ticker.postDelayed(this, PetArt.intervalMs(pet.getContext()));
        }
    };
    private static int[] petRect;
    private static int[] rect;
    // 「有没有去试」与「显示出来了没有」是两件事：装完默认不开说的是前者——不去要、不去加窗。
    // 分开记，设备自检才分得开「系统替我们挡了」与「我们压根不该去试」（F30）。
    private static boolean attempted;
    // 真正交给那一张去画的是哪一句：设备自检拿它和内核那句比，
    // 免得「记录里是内核那句、画出来的是壳层自己那句」（D54 那条的同一家族）。
    private static String rendered;
    // 试了但没显示，卡在哪一步：设备自检把它报出来，不用「授权没赶上」这种猜话糊过去。
    private static String refuse;

    private OverlayCard() {
    }

    /** 权限没授予就是没有这一层——这是「装完默认不开」的实现，不是判断（ONBOARD-06）。 */
    static boolean allowed(Context c) {
        if (Build.VERSION.SDK_INT >= 23) {
            return Settings.canDrawOverlays(c);
        }
        return true;
    }

    /**
     * @param text 内核给的那一句（Kernel.state 的 text；空着就不显示）
     * @return 显示出来了没有；第二项是那块矩形的像素边界
     */
    static boolean show(Context c, String text) {
        return show(c, text, null, null);
    }

    /**
     * @param petName 内核说这一档画哪一只（Kernel.pet 给）；null 就是这台设备不画——
     *                「默认关」在这一层就是这一句：名单里没有这台设备，连那张图都不去解（PET-07）。
     */
    static boolean show(Context c, String text, String petName, String why) {
        // 先把上一轮的记录清空再往下摆：hide() 里也会清一次，摆在前面的赋值会被它抹掉——
        // 第一版就是把这个赋值写在 hide() 之前，画了那只却报「没画」（记录比画面先说谎）。
        hide();
        attempted = false;
        rect = null;
        petRect = null;
        refuse = null;
        petWhy = why;
        if (text == null || text.trim().isEmpty()) {
            return false;
        }
        // 权限没授予就连窗都不加——这一句是「装完默认不开」的实现，不是判断（ONBOARD-06）。
        if (!allowed(c)) {
            return false;
        }
        petShown = petName;
        attempted = true;
        WindowManager wm = (WindowManager) c.getSystemService(Context.WINDOW_SERVICE);
        if (wm == null) {
            return false;
        }

        int width = wm.getDefaultDisplay().getWidth();
        int height = wm.getDefaultDisplay().getHeight();
        int band = (int) (height * subtitleBandPct(c));

        LinearLayout card = new LinearLayout(c);
        card.setOrientation(LinearLayout.HORIZONTAL);
        card.setGravity(Gravity.CENTER_VERTICAL);
        card.setPadding(18, 14, 24, 14);
        card.setBackgroundColor(0xC0101010);
        if (petName != null) {
            petFrames = PetArt.frames(c, petName);
            if (petFrames.length > 0) {
                pet = new ImageView(c);
                int side = Math.round(28f * c.getResources().getDisplayMetrics().density);
                LinearLayout.LayoutParams ip = new LinearLayout.LayoutParams(side, side);
                ip.rightMargin = 16;
                card.addView(pet, ip);
                paintFrame();
            }
        }
        TextView words = new TextView(c);
        card.addView(words);
        words.setText(text);
        rendered = words.getText().toString(); // 交出去的是视图真正拿到的那一句
        words.setTextColor(0xFFFFFFFF);
        words.setTextSize(24f); // L3 那一张仍是正文级字号（docs/ARCHITECTURE.md §字号）

        WindowManager.LayoutParams lp = new WindowManager.LayoutParams();
        lp.type = Build.VERSION.SDK_INT >= 26
                ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                : WindowManager.LayoutParams.TYPE_PHONE;
        // 不抢焦点：遥控器焦点留在播放器那一侧；也不接受触摸，退回用返回键（LAYER-13）。
        lp.flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN;
        lp.format = PixelFormat.TRANSLUCENT;
        lp.width = WindowManager.LayoutParams.WRAP_CONTENT;
        lp.height = WindowManager.LayoutParams.WRAP_CONTENT;
        lp.gravity = Gravity.TOP | Gravity.END;
        lp.x = Math.round(width * 0.02f);
        lp.y = Math.round(height * 0.04f);

        // 落点按 gravity 算准：这一份就是设备自检读的那块矩形，量的是真实尺寸。
        // 「贴到最底下」这种改法要能在字幕带那一条上咬住，靠的是这里跟着 gravity 走，
        // 而不是等布局回调（自检是「离开→读记录」，中间没有下一次渲染）。
        // 截图在这台电视上拍不到这一层（screencap 不含悬浮窗，见 facts/DEVICES.md#F30），
        // 所以位置由这里报，显示由窗口管理器那一条自证。
        card.measure(View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
        int w = card.getMeasuredWidth();
        int h = card.getMeasuredHeight();
        int left = (lp.gravity & Gravity.HORIZONTAL_GRAVITY_MASK) == Gravity.START
                ? lp.x : width - lp.x - w;
        int top = (lp.gravity & Gravity.VERTICAL_GRAVITY_MASK) == Gravity.BOTTOM
                ? height - lp.y - h : lp.y;
        rect = new int[] {left, top, left + w, top + h};
        if (rect[3] > height - band) {
            // 落进字幕带了：这一张宁可没有，也不压字幕（LAYER-13）——位置摆错就是不显示，不是显示成半个。
            rect = null;
            refuse = "落点进字幕带了";
            return false;
        }

        try {
            wm.addView(card, lp);
        } catch (Exception ignored) {
            // 加不上就是没有这一层：不重试、不排队、不提示（L3 未完成只降级，ONBOARD-06）。
            refuse = "窗口加不上";
            return false;
        }
        view = card;
        petRect = pet == null ? null : new int[] {rect[0], rect[1], rect[0] + side(pet), rect[1] + rect[3] - rect[1]};
        if (pet != null) {
            ticker.removeCallbacks(breathing);
            ticker.postDelayed(breathing, PetArt.intervalMs(c)); // 两帧之间隔着 1s：一次呼吸，不是弹跳
        }
        return true;
    }

    /** 显示出来了的那块矩形；还没量到或没显示就是 null。 */
    static int[] rect() {
        return rect;
    }

    /** 角上那一块自己的矩形；这台设备不画就是 null（自检拿它判「名单说了算」那条）。 */
    /** 真正交给视图的那一只的名字；这台设备不画就是 null。 */
    static String petName() {
        return petShown;
    }

    /**
     * 那一块那三项由这里拼，不在调用处排参数：排错过一次，pet / petRect / petWhy 互相串位，
     * 读出来的「为什么没画」其实是落点（F30 那一条的同一家族——记录错位比没记录更坏）。
     */
    static String petRecord() {
        String box = petRect == null ? "null"
                : "[" + petRect[0] + "," + petRect[1] + "," + petRect[2] + "," + petRect[3] + "]";
        return ",\"pet\":" + (petShown == null ? "null" : "\"" + MainActivity.quote(petShown) + "\"")
                + ",\"petRect\":" + box + ",\"petWhy\":\"" + MainActivity.quote(petWhy) + "\"";
    }

    static int[] petRect() {
        return petRect;
    }

    private static int side(View v) {
        return v.getWidth() > 0 ? v.getWidth() : v.getMeasuredWidth();
    }

    private static void paintFrame() {
        try {
            pet.setImageBitmap(BitmapFactory.decodeStream(
                    pet.getContext().getAssets().open("pets/" + petFrames[petFrame])));
        } catch (Exception ignored) {
            // 图没解出来就是没有那一块：不重试、不提示（PET-06 那一条的同一家族）。
            pet.setImageDrawable(null);
        }
    }

    static String refuse() {
        return refuse;
    }

    static String rendered() {
        return rendered;
    }

    static boolean attempted() {
        return attempted;
    }

    /** 字幕带上沿：浮层不许越过它（spec/LAYER.md#LAYER-13）。 */
    static double subtitleBandPct(Context c) {
        try {
            String raw = MainActivity.read(MainActivity.path(c, CONTRACT_FILE, false));
            int i = raw.indexOf("\"subtitleBandPct\"");
            if (i < 0) {
                return 0.15d;
            }
            int j = raw.indexOf(':', i) + 1;
            StringBuilder num = new StringBuilder();
            while (j < raw.length() && (Character.isDigit(raw.charAt(j)) || raw.charAt(j) == '.')) {
                num.append(raw.charAt(j++));
            }
            double v = num.length() > 0 ? Double.parseDouble(num.toString()) : 0.15d;
            return v > 0.5d ? v / 100.0d : v; // 契约里也可能写成百分数：两种写法同一个意思
        } catch (Exception ignored) {
            return 0.15d;
        }
    }

    /** 回到前台就收掉：这一层不是常驻，是「离开时才在」（LAYERING §1）。 */
    static void hide() {
        ticker.removeCallbacks(breathing);
        pet = null;
        petShown = null;
        petWhy = null;
        petFrames = null;
        petFrame = 0;
        petRect = null;
        if (view != null) {
            try {
                ((WindowManager) view.getContext().getSystemService(Context.WINDOW_SERVICE)).removeView(view);
            } catch (Exception ignored) {
                // 已经不在了。
            }
            view = null;
        }
        rect = null;
    }
}
