# Recoll Windows build

这个仓库只保存构建入口和补丁，不把 Recoll 源码 vendor 进来。GitHub Actions 每次运行时从官方 Framagit 仓库拉取指定 ref，再用 MSVC、Qt 6.8.2、Qt WebEngine 和 vcpkg 依赖编译 x64 Windows 产物。

默认源码 ref 是 `recoll-v1.44.1`。在 Actions 的 `workflow_dispatch` 中可以填写其他 branch、tag 或 commit。

## 产物

成功的 Actions run 会上传：

- `recoll-windows-x64-<version>.zip`：包含 `recoll.exe`、`recollindex.exe`、`recollq.exe`、Qt runtime、vcpkg runtime 和 Recoll 的 `share` 数据目录。
- 同名 `.sha256` 校验文件。

这是一个可解压运行的 portable 包，不生成官方站点使用的 Inno Setup 安装器。官方 Windows 构建还会额外打包嵌入式 Python、Aspell、Poppler 等过滤器运行时；本仓库先聚焦于可复现的原生 Recoll/Qt 构建和基本过滤器目录。

## 构建触发

- 推送到 `main`
- Actions → `Build Recoll for Windows` → `Run workflow`

源码版本、源码 commit、Qt 版本和 vcpkg baseline 会写入 ZIP 根目录的 `BUILD-METADATA.txt`。

## 来源与许可

Recoll 源码来自 <https://framagit.org/medoc92/recoll>，由其 GPL 许可覆盖。第三方依赖的许可和源码来源以各自的包元数据为准；构建产物会保留 Recoll 的 `COPYING` 文本。
