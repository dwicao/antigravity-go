package io.github.dwicao.antigravity_go

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.github.dwicao.antigravity_go.permissions.PermissionsPlugin
import io.github.dwicao.antigravity_go.phone.PhonePlugin
import io.github.dwicao.antigravity_go.runtime.AutomationPlugin
import io.github.dwicao.antigravity_go.runtime.RuntimePlugin
import io.github.dwicao.antigravity_go.update.UpdatePlugin
import io.github.dwicao.antigravity_go.voice.VoicePlugin

class MainActivity : FlutterActivity() {
    private val permissionsPlugin = PermissionsPlugin()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(RuntimePlugin())
        flutterEngine.plugins.add(AutomationPlugin())
        flutterEngine.plugins.add(PhonePlugin())
        flutterEngine.plugins.add(VoicePlugin())
        flutterEngine.plugins.add(UpdatePlugin())
        flutterEngine.plugins.add(permissionsPlugin)
    }

    override fun onResume() {
        super.onResume()
        permissionsPlugin.notifyStatusChanged()
    }
}
