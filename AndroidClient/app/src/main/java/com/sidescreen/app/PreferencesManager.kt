package com.sidescreen.app

import android.content.Context
import android.content.SharedPreferences

class PreferencesManager(
    context: Context,
) {
    private val prefs: SharedPreferences = context.getSharedPreferences("app_prefs", Context.MODE_PRIVATE)

    var showStatsOverlay: Boolean
        get() = prefs.getBoolean("show_stats", true)
        set(value) = prefs.edit().putBoolean("show_stats", value).apply()

    var overlayOpacity: Float
        get() = prefs.getFloat("overlay_opacity", 0.8f)
        set(value) = prefs.edit().putFloat("overlay_opacity", value).apply()

    var overlayX: Float
        get() = prefs.getFloat("overlay_x", -1f)
        set(value) = prefs.edit().putFloat("overlay_x", value).apply()

    var overlayY: Float
        get() = prefs.getFloat("overlay_y", -1f)
        set(value) = prefs.edit().putFloat("overlay_y", value).apply()

    var settingsButtonX: Float
        get() = prefs.getFloat("settings_x", -1f)
        set(value) = prefs.edit().putFloat("settings_x", value).apply()

    var settingsButtonY: Float
        get() = prefs.getFloat("settings_y", -1f)
        set(value) = prefs.edit().putFloat("settings_y", value).apply()

    // Corner position: 0=bottom-right, 1=bottom-left, 2=top-right, 3=top-left
    var settingsButtonCorner: Int
        get() = prefs.getInt("settings_corner", 0)
        set(value) = prefs.edit().putInt("settings_corner", value).apply()

    var hideSettingsButton: Boolean
        get() = prefs.getBoolean("hide_settings_button", false)
        set(value) = prefs.edit().putBoolean("hide_settings_button", value).apply()

    // R8/KD3. Opt-out, defaulting on: a cursor that follows the pen is the expected
    // behavior on every comparable device. Turning it off leaves drawing unchanged.
    var stylusHoverEnabled: Boolean
        get() = prefs.getBoolean("stylus_hover", true)
        set(value) = prefs.edit().putBoolean("stylus_hover", value).apply()

    var connectionMode: ConnectionMode
        get() = ConnectionMode.fromName(prefs.getString("connection_mode", null))
        set(value) = prefs.edit().putString("connection_mode", value.name).apply()

    /**
     * Which pen trigger means what, for `StylusInput.restoreBindings` at startup and
     * `StylusInput.currentBindings` after the user rebinds.
     *
     * Empty by default: nothing is bound out of the box, so a device whose triggers
     * have never been pressed behaves exactly as it did before this setting existed.
     */
    var penBindings: Map<StylusInput.Trigger, StylusInput.PenAction>
        get() = decodePenBindings(prefs.getString("pen_bindings", null))
        set(value) = prefs.edit().putString("pen_bindings", encodePenBindings(value)).apply()

    companion object {
        /**
         * `TRIGGER:ACTION` pairs joined by commas — the mapping is at most two
         * entries, so anything heavier than this would be ceremony. Enum *names*,
         * never ordinals: an ordinal silently repoints when someone reorders an enum,
         * turning a saved eraser binding into a right click with no failure anywhere.
         *
         * Neither separator can occur inside a Kotlin enum name, so no escaping is needed.
         */
        fun encodePenBindings(map: Map<StylusInput.Trigger, StylusInput.PenAction>): String =
            map.entries.joinToString(",") { "${it.key.name}:${it.value.name}" }

        /**
         * The inverse, total by construction. Every way a stored string can fail to
         * parse — an unknown trigger, an unknown action, a missing colon, a stray
         * empty field — drops that one entry and keeps the rest, so a downgrade to a
         * build that predates an enum constant, or a rename, costs the user one
         * binding rather than bricking the settings screen with an exception.
         */
        fun decodePenBindings(stored: String?): Map<StylusInput.Trigger, StylusInput.PenAction> {
            if (stored.isNullOrEmpty()) return emptyMap()
            val out = LinkedHashMap<StylusInput.Trigger, StylusInput.PenAction>()
            for (entry in stored.split(",")) {
                val parts = entry.split(":")
                if (parts.size != 2) continue
                val trigger = StylusInput.Trigger.values().firstOrNull { it.name == parts[0] } ?: continue
                val action = StylusInput.PenAction.values().firstOrNull { it.name == parts[1] } ?: continue
                out[trigger] = action
            }
            return out
        }
    }
}
