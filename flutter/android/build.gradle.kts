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

    // Some plugins (notably file_picker 8.3.7) still pin compileSdk 34, which
    // the Flutter Gradle plugin rejects. Raise every Android library
    // subproject to 36 so the build succeeds without vendoring patched plugin
    // sources.
    //
    // The override has to land *after* the plugin's own build script has set
    // compileSdk, otherwise it gets clobbered. `evaluationDependsOn` above
    // means some subprojects are already evaluated by the time we get here, and
    // calling `afterEvaluate` on those throws — so branch on the project state.
    //
    // AGP types are not on the root buildscript classpath, so the extension is
    // configured reflectively rather than via a typed LibraryExtension cast.
    val raiseCompileSdk = {
        project.extensions.findByName("android")?.let { ext ->
            runCatching {
                ext.javaClass
                    .getMethod("compileSdkVersion", Int::class.javaPrimitiveType)
                    .invoke(ext, 36)
            }
        }
        Unit
    }

    if (project.state.executed) {
        raiseCompileSdk()
    } else {
        project.afterEvaluate { raiseCompileSdk() }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
