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

function Assert-RequiredFile {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "Required file is missing: $LiteralPath"
    }
}

function Repair-XapianCMakeConfig {
    param(
        [Parameter(Mandatory = $true)][string]$VcpkgInstall
    )

    $shareRoot = Join-Path $VcpkgInstall 'share'
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

function Write-SmokePdf {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $stream = "BT`n/F1 24 Tf`n72 720 Td`n(Recoll PDF smoke test) Tj`nET`n"
    $objects = @(
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
        "<< /Length $([Text.Encoding]::ASCII.GetByteCount($stream)) >>`nstream`n$stream" + 'endstream'
    )

    $pdf = "%PDF-1.4`n"
    $offsets = @(0)
    for ($index = 0; $index -lt $objects.Count; $index++) {
        $offsets += [Text.Encoding]::ASCII.GetByteCount($pdf)
        $objectNumber = $index + 1
        $pdf += "$objectNumber 0 obj`n$($objects[$index])`nendobj`n"
    }
    $xrefOffset = [Text.Encoding]::ASCII.GetByteCount($pdf)
    $pdf += "xref`n0 $($objects.Count + 1)`n0000000000 65535 f `n"
    foreach ($offset in $offsets[1..$objects.Count]) {
        $pdf += ("{0:0000000000} 00000 n `n" -f $offset)
    }
    $pdf += "trailer`n<< /Size $($objects.Count + 1) /Root 1 0 R >>`nstartxref`n$xrefOffset`n%%EOF`n"
    [IO.File]::WriteAllText($LiteralPath, $pdf, [Text.Encoding]::ASCII)
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sourceRoot = if ($env:RECOLL_SOURCE_DIR) { $env:RECOLL_SOURCE_DIR } else { Join-Path $repoRoot 'build/recoll-source' }
$buildRoot = Join-Path $repoRoot 'build'
$runtimeRoot = Join-Path $buildRoot 'runtime'
$runtimeManifest = Get-Content -LiteralPath (Join-Path $runtimeRoot 'RUNTIME-MANIFEST.json') -Raw | ConvertFrom-Json
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
if (-not (Test-Path -LiteralPath (Join-Path $runtimeRoot 'filters') -PathType Container)) {
    throw "Runtime staging directory is missing: $runtimeRoot"
}

Repair-XapianCMakeConfig -VcpkgInstall $vcpkgInstall

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

$runtimeFilters = Join-Path $runtimeRoot 'filters'
Copy-Item -Path (Join-Path $runtimeFilters '*') -Destination (Join-Path $shareRoot 'filters') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $runtimeRoot 'RUNTIME-MANIFEST.json') -Destination (Join-Path $packageRoot 'RUNTIME-MANIFEST.json') -Force
Copy-Item -LiteralPath (Join-Path $runtimeRoot 'python-requirements.txt') -Destination (Join-Path $packageRoot 'python-requirements.txt') -Force
Copy-Item -LiteralPath (Join-Path $runtimeRoot 'poppler-environment.yml') -Destination (Join-Path $packageRoot 'poppler-environment.yml') -Force

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
Invoke-Native -FilePath $windeployqt -ArgumentList @('--release', '--no-translations', (Join-Path $packageRoot 'recoll.exe'))

$filterRoot = Join-Path $shareRoot 'filters'
$pythonExe = Join-Path $filterRoot 'python/python.exe'
$popplerBin = Join-Path $filterRoot 'poppler/Library/bin'
$aspellExe = Join-Path $filterRoot 'aspell-installed/mingw32/bin/aspell.exe'
Assert-RequiredFile -LiteralPath $pythonExe
Assert-RequiredFile -LiteralPath (Join-Path $popplerBin 'pdftotext.exe')
Assert-RequiredFile -LiteralPath $aspellExe
$env:RECOLL_FILTERSDIR = $filterRoot
$env:ASPELL_PROG = $aspellExe
$env:PATH = "$packageRoot;$filterRoot;$(Join-Path $filterRoot 'python');$popplerBin;$(Split-Path -Parent $aspellExe);$env:PATH"

Invoke-Native -FilePath $pythonExe -ArgumentList @(
    '-c',
    'import chm, epub, hwp5, lxml.etree, py7zr; print("Packaged Python filters OK")'
)
$popplerVersion = (& (Join-Path $popplerBin 'pdftotext.exe') '-v' 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $popplerVersion -notmatch 'Poppler') {
    throw "Packaged Poppler failed its version smoke test: $popplerVersion"
}
$aspellVersion = (& $aspellExe '--version' 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $aspellVersion -notmatch 'Aspell') {
    throw "Packaged Aspell failed its version smoke test: $aspellVersion"
}

$versionOutput = (& (Join-Path $packageRoot 'recoll.exe') '-v').Trim()
if ($LASTEXITCODE -ne 0) { throw 'The built recoll.exe did not pass the version smoke test' }
& (Join-Path $packageRoot 'recollindex.exe') '-h' | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'The built recollindex.exe did not pass the help smoke test' }

$smokeRoot = Join-Path $buildRoot 'filter-smoke'
if (Test-Path -LiteralPath $smokeRoot) {
    $resolvedSmokeRoot = [IO.Path]::GetFullPath($smokeRoot)
    $resolvedBuildRoot = [IO.Path]::GetFullPath($buildRoot)
    if (-not $resolvedSmokeRoot.StartsWith($resolvedBuildRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove smoke-test data outside the build directory: $resolvedSmokeRoot"
    }
    Remove-Item -LiteralPath $smokeRoot -Recurse -Force
}
$smokeConfig = Join-Path $smokeRoot 'config'
$smokeDb = Join-Path $smokeRoot 'db'
New-Item -ItemType Directory -Force -Path $smokeConfig, $smokeDb | Out-Null
$textPath = Join-Path $smokeRoot 'sample.txt'
Set-Content -LiteralPath $textPath -Value 'Recoll text filter smoke test' -Encoding utf8
$pdfPath = Join-Path $smokeRoot 'sample.pdf'
Write-SmokePdf -LiteralPath $pdfPath
$archivePath = Join-Path $smokeRoot 'sample.7z'
Invoke-Native -FilePath $pythonExe -ArgumentList @(
    '-c',
    'import pathlib, py7zr, sys; archive = pathlib.Path(sys.argv[1]); source = pathlib.Path(sys.argv[2]); handle = py7zr.SevenZipFile(archive, "w"); handle.write(source, source.name); handle.close()',
    $archivePath,
    $textPath
)
Set-Content -LiteralPath (Join-Path $smokeConfig 'recoll.conf') -Value @(
    "topdirs = $smokeRoot"
    "dbdir = $smokeDb"
    "filtersdir = $filterRoot"
) -Encoding utf8
$pdfText = (& (Join-Path $popplerBin 'pdftotext.exe') $pdfPath '-' 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $pdfText -notmatch 'Recoll PDF smoke test') {
    throw "Packaged Poppler could not extract text from the smoke-test PDF: $pdfText"
}
Invoke-Native -FilePath (Join-Path $packageRoot 'recollindex.exe') -ArgumentList @(
    '-c', $smokeConfig, '-i', '-f', '-Z', $textPath, $pdfPath, $archivePath
)
$queryOutput = (& (Join-Path $packageRoot 'recollq.exe') '-c' $smokeConfig '-d' 'Recoll PDF smoke test' 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $queryOutput -notmatch 'sample\.pdf') {
    throw "Recoll did not return the indexed PDF filter result: $queryOutput"
}
$archiveQueryOutput = (& (Join-Path $packageRoot 'recollq.exe') '-c' $smokeConfig '-d' 'Recoll text filter smoke' 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $archiveQueryOutput -notmatch 'sample\.7z') {
    throw "Recoll did not return the indexed 7z/Python filter result: $archiveQueryOutput"
}
Invoke-Native -FilePath (Join-Path $packageRoot 'recollindex.exe') -ArgumentList @('-c', $smokeConfig, '-S')

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
    "Python runtime: $($runtimeManifest.python.version)"
    "Aspell runtime: $($runtimeManifest.aspell.version) with $($runtimeManifest.aspellEnglishDictionary.version) English dictionary"
    "Poppler runtime: $($runtimeManifest.poppler.version) from $($runtimeManifest.poppler.channel)"
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
