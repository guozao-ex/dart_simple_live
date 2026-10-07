allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// auto_orientation_v2 插件的 android/build.gradle 未 apply Kotlin 插件，
// 导致其 Kotlin 源码(AutoOrientationPlugin.kt)不被编译，宿主引用时找不到符号。
// 这里在子项目评估前补 apply Kotlin 插件。
subprojects {
    if (project.name == "auto_orientation_v2") {
        project.pluginManager.apply("org.jetbrains.kotlin.android")
        // 对齐 JVM target：插件脚本默认 Java 1.8，Kotlin 插件默认 JVM 21，需一致
        project.afterEvaluate {
            (project.extensions.findByName("kotlin") as? org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension)?.compilerOptions?.jvmTarget?.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
            val androidExt = project.extensions.findByName("android") as? com.android.build.gradle.LibraryExtension
            androidExt?.compileOptions?.sourceCompatibility = JavaVersion.VERSION_11
            androidExt?.compileOptions?.targetCompatibility = JavaVersion.VERSION_11
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
