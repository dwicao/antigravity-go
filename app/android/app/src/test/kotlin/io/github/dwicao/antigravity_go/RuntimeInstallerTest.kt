package io.github.dwicao.antigravity_go.runtime

import org.junit.Assert.assertEquals
import org.junit.Test

class RuntimeInstallerTest {
    @Test
    fun selectsExpectedAndroidPlatformManifest() {
        assertEquals("android_arm64", RuntimeInstaller.platformKey(arrayOf("arm64-v8a")))
        assertEquals("android_amd64", RuntimeInstaller.platformKey(arrayOf("x86_64")))
    }
}
