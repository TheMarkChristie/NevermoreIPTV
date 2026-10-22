package com.themarkchristie.nevermoreiptv

import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingSetup: Map<String, Any?>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        readSetup(intent)?.let { pendingSetup = it }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        readSetup(intent)?.let { pendingSetup = it }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nevermore/setup").setMethodCallHandler { call, result ->
            when (call.method) {
                "take" -> {
                    result.success(pendingSetup)
                    pendingSetup = null
                }
                "device" -> result.success(
                    mapOf(
                        "maker" to Build.MANUFACTURER,
                        "model" to Build.MODEL,
                        "android" to Build.VERSION.RELEASE,
                        "sdk" to Build.VERSION.SDK_INT,
                        "abis" to Build.SUPPORTED_ABIS.joinToString(","),
                    )
                )
                else -> result.notImplemented()
            }
        }
    }

    /**
     * A source handed over by the install script. Only the Setup alias carries one: starting it needs
     * WRITE_SECURE_SETTINGS, which adb's shell holds and other apps do not, so no app on the TV can plant a source.
     */
    private fun readSetup(intent: Intent?): Map<String, Any?>? {
        if (intent?.component?.className != "$packageName.Setup") return null
        val extras = intent.extras ?: return null
        val setup = mutableMapOf<String, Any?>()
        for (key in listOf("kind", "name", "url", "username", "password", "guide", "view", "vpn_conf_b64", "vpn_name")) {
            extras.getString(key)?.let { setup[key] = it }
        }
        setup["autorun"] = extras.getBoolean("autorun", false)
        intent.replaceExtras(Bundle())
        return setup
    }
}
