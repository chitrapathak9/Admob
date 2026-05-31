package com.example.admob

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
	override fun onReceive(context: Context, intent: Intent?) {
		val action = intent?.action
		// Some Android TV / tablet firmwares emit QUICKBOOT_POWERON instead of
		// (or in addition to) BOOT_COMPLETED on a fast/warm boot.
		if (action != Intent.ACTION_BOOT_COMPLETED &&
			action != "android.intent.action.QUICKBOOT_POWERON") {
			return
		}
		val launch = Intent(context, MainActivity::class.java).apply {
			addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
		}
		context.startActivity(launch)
	}
}
