// EmberStorm Signer: the developer's own app for signing releases with the
// release key's YubiKey held to the phone (NFC), away from the PC. Never
// published or handed out; nobody else needs it. See signer/README.md.
plugins {
    id("com.android.application")
}

// The release keys, the box's own (box/release.pub), copied in at build so
// the app knows a YubiKey holding one of them - never kept apart to drift.
val releaseKeys = layout.buildDirectory.dir("generated/releasekeys").get().asFile
val copyReleaseKeys by tasks.registering(Copy::class) {
    from(rootProject.file("../box/release.pub"))
    into(releaseKeys)
}

android {
    namespace = "dev.soundstorm.signer"
    compileSdk = 37

    defaultConfig {
        applicationId = "dev.soundstorm.signer"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release { isMinifyEnabled = false }
        // Signed with the debug key, as the EmberStorm app's test builds are,
        // but not debuggable: a session with the server sits in it.
        debug { isDebuggable = false }
    }

    sourceSets["main"].assets.srcDir(releaseKeys)

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

tasks.named("preBuild") { dependsOn(copyReleaseKeys) }

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.17.0")
    // Yubico's own library: talking to the YubiKey over NFC, and its PIV
    // part, where the release key lives (Ed25519, slot 9c).
    implementation("com.yubico.yubikit:android:3.2.1")
    implementation("com.yubico.yubikit:piv:3.2.1")
}
