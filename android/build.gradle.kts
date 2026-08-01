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

    // Force every Android library/app module — including plugins like
    // flutter_pos_printer_platform_image_3 that ship with their own
    // outdated internal compileSdk — to compile against 36 instead.
    // Without this, the app's own compileSdk=36 (set in app/build.gradle.kts)
    // has no effect on plugin modules, which check their OWN declared
    // compileSdk independently and fail against newer androidx dependencies.
    //
    // Uses the AGP 9 unified DSL (CommonExtension) rather than the
    // deprecated AGP-8-era LibraryExtension/BaseAppModuleExtension split,
    // since this project's AGP version defaults to android.newDsl=true.
    afterEvaluate {
        val androidExtension = project.extensions.findByType(
            com.android.build.api.dsl.CommonExtension::class.java
        )
        androidExtension?.compileSdk = 36
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}