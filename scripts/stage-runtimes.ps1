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

function Get-RemoteFile {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$ManifestEntry,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $existingHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($existingHash -eq $ManifestEntry.sha256.ToLowerInvariant()) {
            Write-Host "Using cached runtime file: $Destination"
            return
        }
        Remove-Item -LiteralPath $Destination -Force
    }

    $temporary = "$Destination.download"
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Force
    }
    Write-Host "Downloading $($ManifestEntry.url)"
    Invoke-WebRequest -Uri $ManifestEntry.url -OutFile $temporary -MaximumRedirection 5
    $downloadHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($downloadHash -ne $ManifestEntry.sha256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $temporary -Force
        throw "SHA256 mismatch for $($ManifestEntry.url): expected $($ManifestEntry.sha256), got $downloadHash"
    }
    Move-Item -LiteralPath $temporary -Destination $Destination -Force
}

function Assert-RequiredFile {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        throw "Required runtime file is missing: $LiteralPath"
    }
}

function Remove-GeneratedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$ParentDirectory
    )
    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return
    }
    $resolvedTarget = [IO.Path]::GetFullPath($LiteralPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolvedParent = [IO.Path]::GetFullPath($ParentDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not $resolvedTarget.StartsWith($resolvedParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a generated directory outside its build root: $resolvedTarget"
    }
    Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildRoot = Join-Path $repoRoot 'build'
$downloadRoot = Join-Path $buildRoot 'runtime-downloads'
$runtimeRoot = Join-Path $buildRoot 'runtime'
$manifestPath = Join-Path $repoRoot 'runtime/runtime-manifest.json'
$requirementsPath = Join-Path $repoRoot 'runtime/python-requirements.txt'
$popplerEnvironmentPath = Join-Path $repoRoot 'runtime/poppler-environment.yml'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

New-Item -ItemType Directory -Force -Path $buildRoot, $downloadRoot | Out-Null
Remove-GeneratedDirectory -LiteralPath $runtimeRoot -ParentDirectory $buildRoot
New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null

$pythonArchive = Join-Path $downloadRoot 'python-3.12.10-embeddable-amd64.zip'
$getPipScript = Join-Path $downloadRoot 'get-pip.py'
$aspellArchive = Join-Path $downloadRoot 'aspell-0.60.7.tar.gz'
$aspellDictionaryArchive = Join-Path $downloadRoot 'aspell6-en-2019.10.06-0.zip'
$py7zrArchive = Join-Path $downloadRoot 'py7zr-0.22.0.tar.gz'
$pychmArchive = Join-Path $downloadRoot 'pychm-with-chmlib.tar.gz'
$pyepubArchive = Join-Path $downloadRoot 'pyepub.tar.gz'
$pyhwpArchive = Join-Path $downloadRoot 'pyhwp-0.1b15-win.tgz'

Get-RemoteFile -ManifestEntry $manifest.python -Destination $pythonArchive
Get-RemoteFile -ManifestEntry $manifest.pipBootstrap -Destination $getPipScript
Get-RemoteFile -ManifestEntry $manifest.aspell -Destination $aspellArchive
Get-RemoteFile -ManifestEntry $manifest.aspellEnglishDictionary -Destination $aspellDictionaryArchive
Get-RemoteFile -ManifestEntry $manifest.py7zr -Destination $py7zrArchive
Get-RemoteFile -ManifestEntry $manifest.pychm -Destination $pychmArchive
Get-RemoteFile -ManifestEntry $manifest.pyepub -Destination $pyepubArchive
Get-RemoteFile -ManifestEntry $manifest.pyhwp -Destination $pyhwpArchive

$filtersRoot = Join-Path $runtimeRoot 'filters'
$pythonRoot = Join-Path $filtersRoot 'python'
$sitePackages = Join-Path $pythonRoot 'Lib/site-packages'
New-Item -ItemType Directory -Force -Path $pythonRoot, $sitePackages | Out-Null
Expand-Archive -LiteralPath $pythonArchive -DestinationPath $pythonRoot -Force

$pythonExe = Join-Path $pythonRoot 'python.exe'
Assert-RequiredFile -LiteralPath $pythonExe
$pythonPth = Get-ChildItem -LiteralPath $pythonRoot -Filter 'python*._pth' -File | Select-Object -First 1
if (-not $pythonPth) {
    throw "The embedded Python archive did not contain a python*._pth file"
}
[IO.File]::WriteAllText(
    $pythonPth.FullName,
    "python312.zip`r`n.`r`nLib/site-packages`r`nimport site`r`n",
    [Text.Encoding]::ASCII
)

$env:PIP_NO_CACHE_DIR = '1'
Invoke-Native -FilePath $pythonExe -ArgumentList @(
    $getPipScript,
    '--no-warn-script-location',
    '--disable-pip-version-check',
    'pip==25.1.1',
    'setuptools==75.8.0',
    'wheel==0.45.1'
)
Invoke-Native -FilePath $pythonExe -ArgumentList @(
    '-m', 'pip', 'install',
    '--disable-pip-version-check',
    '--no-cache-dir',
    '--no-compile',
    '--only-binary=:all:',
    '--target', $sitePackages,
    '-r', $requirementsPath
)

$archiveExtractRoot = Join-Path $buildRoot 'runtime-extract'
Remove-GeneratedDirectory -LiteralPath $archiveExtractRoot -ParentDirectory $buildRoot
New-Item -ItemType Directory -Force -Path $archiveExtractRoot | Out-Null
$tar = if (Test-Path -LiteralPath 'C:/Windows/System32/tar.exe' -PathType Leaf) {
    'C:/Windows/System32/tar.exe'
} else {
    (Get-Command tar.exe -ErrorAction Stop).Source
}

Invoke-Native -FilePath $tar -ArgumentList @('-xzf', $py7zrArchive, '-C', $archiveExtractRoot)
Invoke-Native -FilePath $tar -ArgumentList @('-xzf', $pychmArchive, '-C', $archiveExtractRoot)
Invoke-Native -FilePath $tar -ArgumentList @('-xzf', $pyepubArchive, '-C', $archiveExtractRoot)
Invoke-Native -FilePath $tar -ArgumentList @('-xzf', $pyhwpArchive, '-C', $archiveExtractRoot)

$py7zrSource = Join-Path $archiveExtractRoot 'py7zr-0.22.0/py7zr'
$chmSource = Join-Path $archiveExtractRoot 'pychm-with-chmlib/build/lib.win-amd64-cpython-312/chm'
$epubSource = Join-Path $archiveExtractRoot 'pyepub/epub'
$hwpSource = Join-Path $archiveExtractRoot 'pyhwp-0.1b15/src/hwp5'
foreach ($source in @($py7zrSource, $chmSource, $epubSource, $hwpSource)) {
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Expected runtime package directory is missing: $source"
    }
}
Assert-RequiredFile -LiteralPath (Join-Path $py7zrSource 'version.py')
Assert-RequiredFile -LiteralPath (Join-Path $chmSource '_chmlib.cp312-win_amd64.pyd')
Copy-Item -LiteralPath $py7zrSource -Destination $sitePackages -Recurse -Force
Copy-Item -LiteralPath $chmSource -Destination $sitePackages -Recurse -Force
Copy-Item -LiteralPath $epubSource -Destination $sitePackages -Recurse -Force
Copy-Item -LiteralPath $hwpSource -Destination $sitePackages -Recurse -Force

Invoke-Native -FilePath $pythonExe -ArgumentList @(
    '-c',
    'import chm, epub, hwp5, lxml.etree, py7zr; print("Python filter runtime OK")'
)

$popplerPrefix = $env:POPLER_ENV_PREFIX
if (-not $popplerPrefix -or -not (Test-Path -LiteralPath $popplerPrefix -PathType Container)) {
    throw 'POPLER_ENV_PREFIX is not set to the conda-forge Poppler environment'
}
$popplerLibrary = Join-Path $popplerPrefix 'Library'
$popplerBin = Join-Path $popplerLibrary 'bin'
$popplerRuntime = Join-Path $filtersRoot 'poppler'
$popplerRuntimeBin = Join-Path $popplerRuntime 'Library/bin'
New-Item -ItemType Directory -Force -Path $popplerRuntimeBin | Out-Null
foreach ($tool in @('pdfdetach.exe', 'pdftotext.exe', 'pdfinfo.exe', 'pdftoppm.exe')) {
    Copy-Item -LiteralPath (Join-Path $popplerBin $tool) -Destination $popplerRuntimeBin -Force
}
$popplerDlls = @(Get-ChildItem -LiteralPath $popplerBin -Filter '*.dll' -File)
$popplerDlls += @(Get-ChildItem -LiteralPath $popplerPrefix -Filter '*.dll' -File -ErrorAction SilentlyContinue)
$popplerLibraryLib = Join-Path $popplerLibrary 'lib'
if (Test-Path -LiteralPath $popplerLibraryLib -PathType Container) {
    $popplerDlls += @(Get-ChildItem -LiteralPath $popplerLibraryLib -Filter '*.dll' -File)
}
$popplerDlls = @($popplerDlls | Sort-Object -Property FullName -Unique)
if ($popplerDlls.Count -eq 0) {
    throw "The conda-forge Poppler environment has no DLLs in $popplerBin"
}
foreach ($popplerDll in $popplerDlls) {
    Copy-Item -LiteralPath $popplerDll.FullName -Destination $popplerRuntimeBin -Force
}
$popplerVCRuntime = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
foreach ($runtimeDll in $popplerVCRuntime) {
    Assert-RequiredFile -LiteralPath (Join-Path $popplerRuntimeBin $runtimeDll)
}
$popplerShare = Join-Path $popplerLibrary 'share'
if (-not (Test-Path -LiteralPath $popplerShare -PathType Container)) {
    throw "The conda-forge Poppler environment has no share directory: $popplerShare"
}
Copy-Item -LiteralPath $popplerShare -Destination $popplerRuntime -Recurse -Force
Invoke-Native -FilePath (Join-Path $popplerRuntimeBin 'pdftotext.exe') -ArgumentList @('-v')

$aspellBuildRoot = Join-Path $buildRoot 'aspell-build'
Remove-GeneratedDirectory -LiteralPath $aspellBuildRoot -ParentDirectory $buildRoot
New-Item -ItemType Directory -Force -Path $aspellBuildRoot | Out-Null
$aspellPrefix = Join-Path $filtersRoot 'aspell-installed/mingw32'
$bashCommand = Get-Command bash.exe -ErrorAction SilentlyContinue
if (-not $bashCommand) {
    $msysCandidates = @()
    if ($env:MSYS2_LOCATION) {
        $msysCandidates += Join-Path $env:MSYS2_LOCATION 'usr/bin/bash.exe'
        $msysCandidates += Join-Path $env:MSYS2_LOCATION 'bin/bash.exe'
    }
    $msysCandidates += @('C:/msys64/usr/bin/bash.exe', 'C:/msys64/bin/bash.exe')
    foreach ($candidate in $msysCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $bashCommand = Get-Item -LiteralPath $candidate
            break
        }
    }
}
if (-not $bashCommand) {
    throw 'MSYS2 bash.exe was not found; the MSYS2 setup step must run before stage-runtimes.ps1'
}
$cygpathCommand = Get-Command cygpath.exe -ErrorAction SilentlyContinue
if (-not $cygpathCommand) {
    $cygpathCandidates = @()
    if ($env:MSYS2_LOCATION) {
        $cygpathCandidates += Join-Path $env:MSYS2_LOCATION 'usr/bin/cygpath.exe'
    }
    $cygpathCandidates += Join-Path (Split-Path (Split-Path $bashCommand.Source -Parent) -Parent) 'usr/bin/cygpath.exe'
    foreach ($cygpathCandidate in $cygpathCandidates) {
        if (Test-Path -LiteralPath $cygpathCandidate -PathType Leaf) {
            $cygpathCommand = Get-Item -LiteralPath $cygpathCandidate
            break
        }
    }
}
if (-not $cygpathCommand) {
    throw 'MSYS2 cygpath.exe was not found'
}
$aspellScript = Join-Path $repoRoot 'scripts/build-aspell.sh'
$aspellScriptUnix = (& $cygpathCommand.Source -u $aspellScript).Trim()
$env:RECOLL_ASPELL_SOURCE_TARBALL = $aspellArchive
$env:RECOLL_ASPELL_BUILD_ROOT = $aspellBuildRoot
$env:RECOLL_ASPELL_PREFIX = $aspellPrefix
$env:MSYSTEM = 'MINGW64'
$env:MSYS2_ARG_CONV_EXCL = '*'
Invoke-Native -FilePath $bashCommand.Source -ArgumentList @(
    '--noprofile', '--norc', '-lc',
    "export MSYSTEM=MINGW64; export PATH=/mingw64/bin:/usr/bin:`$PATH; bash '$aspellScriptUnix'"
)

$aspellDictionaryRoot = Join-Path $aspellPrefix 'lib/aspell-0.60'
New-Item -ItemType Directory -Force -Path $aspellDictionaryRoot | Out-Null
Expand-Archive -LiteralPath $aspellDictionaryArchive -DestinationPath $aspellDictionaryRoot -Force
$aspellExe = Join-Path $aspellPrefix 'bin/aspell.exe'
Assert-RequiredFile -LiteralPath $aspellExe
Assert-RequiredFile -LiteralPath (Join-Path $aspellDictionaryRoot 'en.dat')
$aspellDicts = (& $aspellExe '--lang=en' 'dicts' 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $aspellDicts -notmatch '(?im)^\s*en\s*$') {
    throw "Aspell cannot see the packaged English dictionary: $aspellDicts"
}

Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $runtimeRoot 'RUNTIME-MANIFEST.json') -Force
Copy-Item -LiteralPath $requirementsPath -Destination (Join-Path $runtimeRoot 'python-requirements.txt') -Force
Copy-Item -LiteralPath $popplerEnvironmentPath -Destination (Join-Path $runtimeRoot 'poppler-environment.yml') -Force

Write-Host 'Embedded Python, Aspell and Poppler runtimes staged successfully.'
