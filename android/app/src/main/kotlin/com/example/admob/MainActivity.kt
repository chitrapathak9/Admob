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
    private val channel = "com.theadbook.player/battery"

    // Holds the pending Flutter result until the user dismisses the battery settings screen.
    private var pendingResult: MethodChannel.Result? = null

    // ActivityResultLauncher so we are notified when the user returns from the
    // battery optimisation settings intent (granted or denied).
    private lateinit var batteryLauncher: ActivityResultLauncher<Intent>

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)

        // Register the launcher before the activity is started.
        batteryLauncher = registerForActivityResult(
            ActivityResultContracts.StartActivityForResult()
        ) { _ ->
            // User returned from system settings — check the actual status now.
            val granted = isBatteryOptimisationIgnored()
            pendingResult?.success(granted)
            pendingResult = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isBatteryOptimisationIgnored())
                }
                "requestIgnoreBatteryOptimizations" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        if (isBatteryOptimisationIgnored()) {
                            // Already granted — resolve immediately, no need to open settings.
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        pendingResult = result
                        val intent = Intent(
                            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        ).apply {
                            data = Uri.parse("package:$packageName")
                        }
                        batteryLauncher.launch(intent)
                    } else {
                        // Pre-M devices don't have battery optimisations.
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
}
