allprojects {
    repositories {
        google()
        mavenCentral()
        // Jellyfin prebuilt FFmpeg decoder (org.jellyfin.media3:media3-ffmpeg-decoder)
        maven { url = uri("https://s01.oss.sonatype.org/content/repositories/releases/") }
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
