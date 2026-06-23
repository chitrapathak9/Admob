package com.example.admob

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val batteryChannel = "com.theadbook.player/battery"
    private val overlayChannel = "com.theadbook.player/overlay"

    // Pending results held until the user returns from the respective settings screen.
    private var pendingBatteryResult: MethodChannel.Result? = null
    private var pendingOverlayResult: MethodChannel.Result? = null

    private lateinit var batteryLauncher: ActivityResultLauncher<Intent>
    private lateinit var overlayLauncher: ActivityResultLauncher<Intent>

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)

        batteryLauncher = registerForActivityResult(
            ActivityResultContracts.StartActivityForResult()
        ) { _ ->
            val granted = isBatteryOptimisationIgnored()
            pendingBatteryResult?.success(granted)
            pendingBatteryResult = null
        }

        overlayLauncher = registerForActivityResult(
            ActivityResultContracts.StartActivityForResult()
        ) { _ ->
            val granted = canDrawOverlays()
            pendingOverlayResult?.success(granted)
            pendingOverlayResult = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            batteryChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isBatteryOptimisationIgnored())
                }
                "requestIgnoreBatteryOptimizations" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        if (isBatteryOptimisationIgnored()) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        pendingBatteryResult = result
                        val intent = Intent(
                            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        ).apply {
                            data = Uri.parse("package:$packageName")
                        }
                        batteryLauncher.launch(intent)
                    } else {
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            overlayChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "canDrawOverlays" -> {
                    result.success(canDrawOverlays())
                }
                "requestOverlayPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        if (canDrawOverlays()) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        pendingOverlayResult = result
                        val intent = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        ).apply {
                            data = Uri.parse("package:$packageName")
                        }
                        overlayLauncher.launch(intent)
                    } else {
                        // Pre-M devices have overlay allowed by default.
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isBatteryOptimisationIgnored(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun canDrawOverlays(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return Settings.canDrawOverlays(this)
    }
}
