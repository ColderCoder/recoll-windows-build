# Recoll Windows build

这个仓库只保存构建入口和补丁，不把 Recoll 源码 vendor 进来。GitHub Actions 每次运行时从官方 Framagit 仓库拉取指定 ref，再用 MSVC、Qt 6.8.2、Qt WebEngine 和 vcpkg 依赖编译 x64 Windows 产物。

默认源码 ref 是 `recoll-v1.44.1`。在 Actions 的 `workflow_dispatch` 中可以填写其他 branch、tag 或 commit。

## 产物

成功的 Actions run 会上传：

- `recoll-windows-x64-<version>.zip`：包含 `recoll.exe`、`recollindex.exe`、`recollq.exe`、Qt runtime、vcpkg runtime 和 Recoll 的 `share` 数据目录。
- 同名 `.sha256` 校验文件。

这是一个可解压运行的 portable 包，不生成官方站点使用的 Inno Setup 安装器。Action 会同时构建并打包过滤器运行时：

- Python 3.12.10 embeddable runtime，以及 `pychm`、`pyepub`、`py7zr`、`pyhwp`、`lxml` 和其压缩/加密依赖。
- 从 Aspell 0.60.7 源码构建的 MinGW64 Aspell，以及官方扩展英文词典。
- conda-forge Poppler 22.04.0 的 `pdftotext`、`pdfinfo`、`pdfdetach`、`pdftoppm`、DLL 和 `poppler-data`。

运行时目录遵循 Recoll 官方 Windows 打包约定，尤其是 `share/filters/python`、`share/filters/poppler/Library/bin` 和 `share/filters/aspell-installed/mingw32`。打包前会执行 Python 模块导入、Poppler PDF 文本提取、Aspell 词典识别，以及 Recoll 对 TXT/PDF/7z 的实际索引查询冒烟测试。

## 构建触发

- 推送到 `main`
- Actions → `Build Recoll for Windows` → `Run workflow`

源码版本、源码 commit、Qt 版本和 vcpkg baseline 会写入 ZIP 根目录的 `BUILD-METADATA.txt`。

运行时来源、版本和 SHA256 固定在 [`runtime/runtime-manifest.json`](runtime/runtime-manifest.json)；Python wheel 版本固定在 [`runtime/python-requirements.txt`](runtime/python-requirements.txt)。

## 来源与许可

Recoll 源码来自 <https://framagit.org/medoc92/recoll>，由其 GPL 许可覆盖。第三方依赖的许可和源码来源以各自的包元数据为准；构建产物会保留 Recoll 的 `COPYING` 文本。
