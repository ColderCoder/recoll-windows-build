$ErrorActionPreference = 'Stop'

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $false)][string[]]$ArgumentList = @()
    )
    Write-Host "> $FilePath $($ArgumentList -join ' ')"
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Copy-RequiredFile {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "Required file was not produced: $LiteralPath"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force
}

function Repair-XapianCMakeConfig {
    param(
        [Parameter(Mandatory = $true)][string]$VcpkgInstallRoot,
        [Parameter(Mandatory = $true)][string]$VcpkgInstall
    )

    $shareRoot = Join-Path $VcpkgInstallRoot 'share'
    $configFiles = @(
        Get-ChildItem -LiteralPath $shareRoot -Recurse -Filter 'xapian-config.cmake' -File
    )
    if ($configFiles.Count -ne 1) {
        throw "Expected exactly one Xapian CMake config below $shareRoot, found $($configFiles.Count)"
    }

    $configFile = $configFiles[0]
    $originalText = Get-Content -LiteralPath $configFile.FullName -Raw
    $configText = [regex]::Replace($originalText, '"/([A-Za-z])/', '"$1:/')
    $sharedMatch = [regex]::Match(
        $configText,
        '(?im)^\s*SET\(XAPIAN_SHARED_LIBRARY\s+"([^"]+)"'
    )
    if (-not $sharedMatch.Success) {
        throw "XAPIAN_SHARED_LIBRARY is missing from $($configFile.FullName)"
    }

    $sharedPath = $sharedMatch.Groups[1].Value
    if (-not (Test-Path -LiteralPath $sharedPath -PathType Leaf)) {
        $releaseLibRoot = Join-Path $VcpkgInstall 'lib'
        $candidates = @(
            Get-ChildItem -LiteralPath $releaseLibRoot -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '(?i)^(?:lib)?xapian.*\.lib$' }
        )
        if ($candidates.Count -ne 1) {
            $candidateNames = if ($candidates.Count -gt 0) { $candidates.Name -join ', ' } else { '<none>' }
            throw "Xapian shared import library is missing at $sharedPath; candidates: $candidateNames"
        }

        $replacementPath = $candidates[0].FullName -replace '\\', '/'
        $configText = $configText.Replace($sharedPath, $replacementPath)
        $sharedPath = $replacementPath
    }

    if ($configText -ne $originalText) {
        Set-Content -LiteralPath $configFile.FullName -Value $configText -NoNewline
    }
    Write-Host "Using Xapian import library: $sharedPath"
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sourceRoot = if ($env:RECOLL_SOURCE_DIR) { $env:RECOLL_SOURCE_DIR } else { Join-Path $repoRoot 'build/recoll-source' }
$buildRoot = Join-Path $repoRoot 'build'
$cmakeBuild = Join-Path $buildRoot 'cmake'
$packageRoot = Join-Path $repoRoot 'dist/recoll-windows-x64'
$vcpkgInstallRoot = Join-Path $repoRoot 'vcpkg_installed'
$vcpkgInstall = Join-Path $repoRoot 'vcpkg_installed/x64-windows'
$installPrefix = Join-Path $buildRoot 'install'
$qtRoot = $env:QT_ROOT_DIR
$vcpkgToolchain = Join-Path $env:VCPKG_ROOT 'scripts/buildsystems/vcpkg.cmake'

if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "Recoll source directory is missing: $sourceRoot" }
if (-not (Test-Path -LiteralPath $qtRoot -PathType Container)) { throw "Qt root is missing: $qtRoot" }
if (-not (Test-Path -LiteralPath $vcpkgInstall -PathType Container)) { throw "vcpkg install directory is missing: $vcpkgInstall" }

Repair-XapianCMakeConfig -VcpkgInstallRoot $vcpkgInstallRoot -VcpkgInstall $vcpkgInstall

if (Test-Path -LiteralPath $cmakeBuild) { Remove-Item -LiteralPath $cmakeBuild -Recurse -Force }
if (Test-Path -LiteralPath $packageRoot) { Remove-Item -LiteralPath $packageRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $cmakeBuild, $packageRoot | Out-Null

$cmakeArgs = @(
    '-S', (Join-Path $sourceRoot 'src'),
    '-B', $cmakeBuild,
    '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release',
    "-DCMAKE_TOOLCHAIN_FILE=$vcpkgToolchain",
    '-DVCPKG_TARGET_TRIPLET=x64-windows',
    "-DVCPKG_INSTALLED_DIR=$vcpkgInstallRoot",
    "-DCMAKE_PREFIX_PATH=$qtRoot",
    "-DCMAKE_INSTALL_PREFIX=$installPrefix",
    '-DRECOLL_QT6_BUILD=ON',
    '-DRECOLL_ENABLE_WEBENGINE=ON',
    '-DRECOLL_ENABLE_LIBMAGIC=ON',
    '-DRECOLL_ENABLE_SYSTEMD=OFF',
    '-DRECOLL_ENABLE_X11MON=OFF',
    '-DRECOLL_QTGUI=ON'
)
Invoke-Native -FilePath 'cmake' -ArgumentList $cmakeArgs
Invoke-Native -FilePath 'cmake' -ArgumentList @('--build', $cmakeBuild, '--parallel')

$recollExe = Join-Path $cmakeBuild 'recoll.exe'
$recollIndexExe = Join-Path $cmakeBuild 'recollindex.exe'
$recollQExe = Join-Path $cmakeBuild 'recollq.exe'
$rclStartExe = Join-Path $cmakeBuild 'rclstartw.exe'
Copy-RequiredFile -LiteralPath $recollExe -Destination (Join-Path $packageRoot 'recoll.exe')
Copy-RequiredFile -LiteralPath $recollIndexExe -Destination (Join-Path $packageRoot 'recollindex.exe')
Copy-RequiredFile -LiteralPath $recollQExe -Destination (Join-Path $packageRoot 'recollq.exe')
Copy-RequiredFile -LiteralPath $rclStartExe -Destination (Join-Path $packageRoot 'rclstartw.exe')

$shareRoot = Join-Path $packageRoot 'share'
$sourceSrc = Join-Path $sourceRoot 'src'
$examplesRoot = Join-Path $shareRoot 'examples'
$docRoot = Join-Path $shareRoot 'doc'
$imagesRoot = Join-Path $shareRoot 'images'
$translationsRoot = Join-Path $shareRoot 'translations'
$magicRoot = Join-Path $shareRoot 'libmagic/misc'
New-Item -ItemType Directory -Force -Path $shareRoot, $examplesRoot, $docRoot, $imagesRoot, $translationsRoot, $magicRoot, (Join-Path $examplesRoot 'windows') | Out-Null

Copy-Item -LiteralPath (Join-Path $sourceSrc 'filters') -Destination (Join-Path $shareRoot 'filters') -Recurse -Force
Copy-Item -Path (Join-Path $sourceSrc 'sampleconf/*') -Destination $examplesRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $sourceSrc 'windows/mimeconf') -Destination (Join-Path $examplesRoot 'windows/mimeconf') -Force
Copy-Item -LiteralPath (Join-Path $sourceSrc 'windows/mimeview') -Destination (Join-Path $examplesRoot 'windows/mimeview') -Force
Copy-Item -LiteralPath (Join-Path $sourceSrc 'windows/recoll.conf') -Destination (Join-Path $examplesRoot 'windows/recoll.conf') -Force
Copy-Item -LiteralPath (Join-Path $sourceSrc 'python/recoll/recoll/rclconfig.py') -Destination (Join-Path $shareRoot 'filters/rclconfig.py') -Force
Copy-Item -LiteralPath (Join-Path $sourceSrc 'python/recoll/recoll/conftree.py') -Destination (Join-Path $shareRoot 'filters/conftree.py') -Force
Copy-Item -Path (Join-Path $sourceSrc 'qtgui/mtpics/*') -Destination $imagesRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $sourceSrc 'desktop/recoll.ico') -Destination (Join-Path $shareRoot 'recoll.ico') -Force
Copy-Item -LiteralPath (Join-Path $sourceSrc 'doc/user/usermanual.html') -Destination (Join-Path $docRoot 'usermanual.html') -Force
Copy-Item -LiteralPath (Join-Path $sourceSrc 'doc/user/docbook-xsl.css') -Destination (Join-Path $docRoot 'docbook-xsl.css') -Force
Copy-Item -LiteralPath (Join-Path $sourceSrc 'COPYING') -Destination (Join-Path $packageRoot 'COPYING.txt') -Force

$qmDirectory = Join-Path $cmakeBuild 'i18n'
if (Test-Path -LiteralPath $qmDirectory -PathType Container) {
    Copy-Item -Path (Join-Path $qmDirectory '*') -Destination $translationsRoot -Recurse -Force
}

$magicData = Join-Path $vcpkgInstall 'share/libmagic/misc'
if (Test-Path -LiteralPath $magicData -PathType Container) {
    Copy-Item -Path (Join-Path $magicData '*') -Destination $magicRoot -Recurse -Force
}

$vcpkgBin = Join-Path $vcpkgInstall 'bin'
if (Test-Path -LiteralPath $vcpkgBin -PathType Container) {
    Copy-Item -Path (Join-Path $vcpkgBin '*.dll') -Destination $packageRoot -Force
}

$windeployqt = Join-Path $qtRoot 'bin/windeployqt.exe'
Invoke-Native -FilePath $windeployqt -ArgumentList @('--release', '--webengine', '--no-translations', (Join-Path $packageRoot 'recoll.exe'))

$versionOutput = (& (Join-Path $packageRoot 'recoll.exe') '-v').Trim()
if ($LASTEXITCODE -ne 0) { throw 'The built recoll.exe did not pass the version smoke test' }
& (Join-Path $packageRoot 'recollindex.exe') '-h' | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'The built recollindex.exe did not pass the help smoke test' }

$version = (Get-Content -LiteralPath (Join-Path $sourceRoot 'src/RECOLL-VERSION.txt') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+') { throw "Unexpected Recoll version: $version" }

$metadata = @(
    "Recoll version: $version"
    "Version command output: $versionOutput"
    "Source repository: $env:RECOLL_REPOSITORY"
    "Source ref: $env:RECOLL_REF"
    "Source revision: $env:RECOLL_SOURCE_REVISION"
    "Qt version: $env:QT_VERSION"
    "vcpkg commit: $env:VCPKG_COMMIT"
    "Triplet: x64-windows"
)
Set-Content -LiteralPath (Join-Path $packageRoot 'BUILD-METADATA.txt') -Value $metadata

$zipPath = Join-Path $repoRoot "dist/recoll-windows-x64-$version.zip"
$checksumPath = "$zipPath.sha256"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
if (Test-Path -LiteralPath $checksumPath) { Remove-Item -LiteralPath $checksumPath -Force }
Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $checksumPath -Value "$hash  $(Split-Path -Leaf $zipPath)"

Write-Host "Package: $zipPath"
Write-Host "SHA256: $hash"
