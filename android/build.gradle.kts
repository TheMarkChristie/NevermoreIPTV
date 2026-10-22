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
// wireguard_flutter_plus compiles against API 31 while its own libraries need 33 or later: build it at the app's level
subprojects {
    if (project.name == "wireguard_flutter_plus") {
        val raise: Project.() -> Unit = {
            extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)?.compileSdk = 36
        }
        if (project.state.executed) project.raise() else project.afterEvaluate { raise() }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
