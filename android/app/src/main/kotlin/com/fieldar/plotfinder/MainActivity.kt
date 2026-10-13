package com.fieldar.plotfinder

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var channels: PlotFinderChannels? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channels = PlotFinderChannels(applicationContext).also {
            it.register(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channels?.dispose()
        channels = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
