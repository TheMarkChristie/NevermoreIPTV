package com.themarkchristie.nevermoreiptv

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.provider.Settings
import android.view.WindowManager
import android.webkit.CookieManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import java.io.File

private const val VPN_REQUEST = 4711

class MainActivity : FlutterActivity() {
    private var pendingSetup: Map<String, Any?>? = null
    private var setupChannel: MethodChannel? = null
    private var vpnAnswer: MethodChannel.Result? = null

    /** Who wants the screen kept on (the player, the browser, a page waiting for the viewer); on while anyone does. */
    private val awake = HashSet<String>()
    private var webUsed = false

    /** The next stop is Android's installer or its "allow installs" page over the app: the app waits behind them. */
    private var keepAliveOnce = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        readSetup(intent)?.let { pendingSetup = it }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // a setup while the app is open (an adb command without -S): handed to Dart at once, not kept for a start
        // that never comes
        readSetup(intent)?.let { setup ->
            val channel = setupChannel
            if (channel != null) channel.invokeMethod("setup", setup) else pendingSetup = setup
        }
    }

    /**
     * Leaving the app closes it (Mark, 24 Oct 2026: "can we make the app fully close down then its shuts so its a fresh
     * restart"): Home, Back twice or the TV going to standby ends the screen and then the process, so the next start is a
     * cold one on the last channel. A dialog over the app (Android's VPN question) only pauses it, so it does not count.
     */
    override fun onStop() {
        super.onStop()
        if (isChangingConfigurations || isFinishing) return
        if (keepAliveOnce) {
            keepAliveOnce = false
            return
        }
        // the browser's cookies are written to disk in batches: a sign-in made just before Home would be lost
        if (webUsed) {
            try {
                CookieManager.getInstance().flush()
            } catch (_: Exception) {
                // no WebView on this TV
            }
        }
        finishAndRemoveTask()
    }

    override fun onDestroy() {
        super.onDestroy()
        if (!isFinishing || isChangingConfigurations) return
        // the VPN plug-in's services return START_STICKY: left started, Android would re-create them after the kill
        // with a false "VPN is running" notification and no tunnel (review, 24 Oct 2026)
        for (name in listOf(
            "orban.group.wireguard_flutter.VpnForegroundService",
            "com.wireguard.android.backend.GoBackend\$VpnService",
        )) {
            try {
                stopService(Intent(this, Class.forName(name)))
            } catch (_: Exception) {
                // not on the class path, or already gone
            }
        }
        forgetVpnCopy()
        Process.killProcess(Process.myPid())
    }

    /** The plug-in's plain-text copy of the WireGuard file (private key included), kept only while a tunnel runs. */
    private fun forgetVpnCopy() {
        try {
            getSharedPreferences("vpn_prefs", Context.MODE_PRIVATE).edit().clear().commit()
        } catch (_: Exception) {
            // nothing to clear
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nevermore/setup").also { channel ->
            channel.setMethodCallHandler { call, result ->
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
        // Android's "allow this VPN" question (the VPN plug-in asks it but never hears the answer), and the plug-in's
        // copy of the file, cleared whenever the tunnel is down
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
                "forget" -> {
                    forgetVpnCopy()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // the browser's pop-up blocker: no window may open itself (the WebView plug-in lets scripts open them)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nevermore/web").setMethodCallHandler { call, result ->
            when (call.method) {
                "blockPopups" -> {
                    webUsed = true
                    @Suppress("DEPRECATION")
                    val web = WebViewFlutterAndroidExternalApi.getWebView(flutterEngine, (call.arguments as Number).toLong())
                    web?.settings?.javaScriptCanOpenWindowsAutomatically = false
                    result.success(web != null)
                }
                else -> result.notImplemented()
            }
        }
        // a fetched update handed to Android's installer (Settings > Update): the APK sits in the app's cache and the
        // installer reads it through the FileProvider in the manifest; the TV may first want Nevermore allowed to
        // install apps, in which case that settings page opens and the viewer presses Install again afterwards
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nevermore/update").setMethodCallHandler { call, result ->
            when (call.method) {
                "install" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                            keepAliveOnce = true
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                            result.success("allow")
                        } else {
                            val apk = File(call.arguments as String)
                            val uri = FileProvider.getUriForFile(this, "$packageName.files", apk)
                            val open = Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                            keepAliveOnce = true
                            startActivity(open)
                            result.success("started")
                        }
                    } catch (err: Exception) {
                        keepAliveOnce = false
                        result.error("install", err.message ?: err.toString(), null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        // the screen kept on while a channel plays, a site is open or a page waits for the viewer (the TV's screensaver
        // took over the picture, and since 0.7.1 it ends the app); each caller names itself, so one leaving does not
        // clear another's hold
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nevermore/screen").setMethodCallHandler { call, result ->
            when (call.method) {
                "awake" -> {
                    val args = call.arguments
                    val who = if (args is Map<*, *>) args["who"]?.toString() ?: "play" else "play"
                    val on = if (args is Map<*, *>) args["on"] == true else args == true
                    if (on) awake.add(who) else awake.remove(who)
                    if (awake.isEmpty()) {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
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
     * WRITE_SECURE_SETTINGS, which adb's shell holds and ordinary apps do not (a privileged app, or one granted it by
     * hand, could; on Android 14 and later the caller is checked to be the shell itself).
     */
    private fun readSetup(intent: Intent?): Map<String, Any?>? {
        if (intent?.component?.className != "$packageName.Setup") return null
        // Only adb can reach this entry: the .Setup alias needs WRITE_SECURE_SETTINGS (manifest), which the shell holds and
        // an app on the TV cannot get. (launchedFromUid is no use here: from API 34 it is -1 for an adb launch.)
        val extras = intent.extras ?: return null
        val setup = mutableMapOf<String, Any?>()
        for (key in listOf("kind", "name", "url", "username", "password", "guide", "view", "vpn_conf_b64", "vpn_name", "preset")) {
            extras.getString(key)?.let { setup[key] = it }
        }
        setup["autorun"] = extras.getBoolean("autorun", false)
        intent.replaceExtras(Bundle())
        return setup
    }
}
