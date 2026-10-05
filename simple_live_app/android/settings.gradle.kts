pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

// 部分插件（如 dynamic_color 1.9.0）的 Kotlin DSL 脚本使用顶层 kotlin{}
// 扩展，但自身未应用 Kotlin 插件；在此为所有子项目预应用并默认对齐
// JVM_1_8（AGP 默认 Java 目标），自带声明者（如 dynamic_color 的 17）会覆盖。
gradle.beforeProject {
    if (path != ":") {
        pluginManager.apply("org.jetbrains.kotlin.android")
        extensions.configure(
            org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension::class.java
        ) {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)
            }
        }
    }
}

include(":app")
