// 仓库分层：库依赖解析在 settings.gradle.kts 的
// dependencyResolutionManagement（PREFER_PROJECT 模式）下被子项目自带
// 仓库架空——真正生效的库仓库是这里的 allprojects（google()/
// mavenCentral()；插件/构建脚本解析走 pluginManagement）。
// （transfer-1 批次 2026-11-13：镜像前置——国内网络对 dl.google.com
// 的大 jar（lint 等）间歇超时；aliyun google/central 为官方仓镜像，
// 未收录工件自动回落官方仓。海外环境零影响。）
allprojects {
    repositories {
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/central")
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
