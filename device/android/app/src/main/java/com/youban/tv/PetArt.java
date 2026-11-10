package com.youban.tv;

import android.content.Context;

import org.json.JSONObject;

/**
 * 角上那一块的帧表（spec/PET.md#PET-07、D83）。
 *
 * 间隔与帧数都从契约那一处读，这里不写死数字——两个内核比的是同一份（tools/align-core.rb）。
 * 图本身是 tools/make-pet-art.rb 画出来的（PET-08：风格学来的形状语言，素材自己画）。
 */
final class PetArt {
    private static final String CONTRACT_FILE = "contract.json";
    private static final int DEFAULT_INTERVAL_MS = 1000;

    private PetArt() {
    }

    /** 这只的帧文件名，按顺序；解不出就是空的——空着那一块不画，不猜。 */
    static String[] frames(Context c, String name) {
        String[] out = new String[framesCount(c)];
        for (int i = 0; i < out.length; i++) {
            out[i] = name + ".f" + i + ".png";
        }
        return out;
    }

    static int framesCount(Context c) {
        return field(c, "idleFrames", 2);
    }

    /** 一次呼吸隔多久：契约里那一格（1s）。这里不另定节奏（PET-07）。 */
    static int intervalMs(Context c) {
        return field(c, "frameIntervalMs", 1000);
    }

    private static int field(Context c, String key, int fallback) {
        try {
            JSONObject ap = new JSONObject(MainActivity.read(MainActivity.path(c, CONTRACT_FILE, false)))
                    .getJSONObject("pet").getJSONObject("appearance");
            return ap.has(key) ? ap.getInt(key) : fallback;
        } catch (Exception ignored) {
            return fallback;
        }
    }
}
