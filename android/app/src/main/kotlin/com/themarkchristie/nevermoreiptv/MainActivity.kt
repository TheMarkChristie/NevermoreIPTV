package com.themarkchristie.nevermoreiptv

import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi

private const val VPN_REQUEST = 4711

class MainActivity : FlutterActivity() {
    private var pendingSetup: Map<String, Any?>? = null
    private var vpnAnswer: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        readSetup(intent)?.let { pendingSetup = it }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        readSetup(intent)?.let { pendingSetup = it }
    }

    /**
     * Leaving the app closes it (Mark, 24 Oct 2026: "can we make the app fully close down then its shuts so its a fresh
     * restart"): Home, Back twice or the TV going to standby ends the screen and then the process, so the next start is a
     * cold one on the last channel. A dialog over the app (Android's VPN question) only pauses it, so it does not count.
     */
    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations && !isFinishing) finishAndRemoveTask()
    }

    override fun onDestroy() {
        super.onDestroy()
        if (isFinishing && !isChangingConfigurations) Process.killProcess(Process.myPid())
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
        // Android's "allow this VPN" question (the VPN plug-in asks it but never hears the answer)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nevermore/vpn").setMethodCallHandler { call, result ->
            when (call.method) {
                "allow" -> {
                    val ask = VpnService.prepare(this)
                    if (ask == null) {
                        result.success(true)
                    } else {
                        vpnAnswer?.success(false)
                        vpnAnswer = result
                        startActivityForResult(ask, VPN_REQUEST)
                    }
                }
                else -> result.notImplemented()
            }
        }
        // the browser's pop-up blocker: no window may open itself (the WebView plug-in lets scripts open them)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nevermore/web").setMethodCallHandler { call, result ->
            when (call.method) {
                "blockPopups" -> {
                    @Suppress("DEPRECATION")
                    val web = WebViewFlutterAndroidExternalApi.getWebView(flutterEngine, (call.arguments as Number).toLong())
                    web?.settings?.javaScriptCanOpenWindowsAutomatically = false
                    result.success(web != null)
                }
                else -> result.notImplemented()
            }
        }
        // the screen kept on while a channel plays (the TV's screensaver took over the picture)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nevermore/screen").setMethodCallHandler { call, result ->
            when (call.method) {
                "awake" -> {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VPN_REQUEST) {
            vpnAnswer?.success(resultCode == RESULT_OK)
            vpnAnswer = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
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
