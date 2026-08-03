$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildRoot = Join-Path $repoRoot 'build'
$sourceRoot = Join-Path $buildRoot 'recoll-source'
$patchFile = Join-Path $repoRoot 'patches/recoll-windows-cmake.patch'
$recollRef = if ($env:RECOLL_REF) { $env:RECOLL_REF } else { 'recoll-v1.44.1' }

New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null

if (Test-Path -LiteralPath $sourceRoot) {
    $resolvedSourceRoot = [IO.Path]::GetFullPath($sourceRoot)
    $resolvedBuildRoot = [IO.Path]::GetFullPath($buildRoot)
    if (-not $resolvedSourceRoot.StartsWith($resolvedBuildRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a source path outside the build directory: $resolvedSourceRoot"
    }
    Remove-Item -LiteralPath $sourceRoot -Recurse -Force
}

Write-Host "Cloning Recoll ref $recollRef"
& git init $sourceRoot
if ($LASTEXITCODE -ne 0) {
    throw "git init failed with exit code $LASTEXITCODE"
}
& git -C $sourceRoot remote add origin $env:RECOLL_REPOSITORY
if ($LASTEXITCODE -ne 0) {
    throw "git remote add failed with exit code $LASTEXITCODE"
}
& git -C $sourceRoot fetch --depth 1 origin $recollRef
if ($LASTEXITCODE -ne 0) {
    throw "git fetch failed for $recollRef with exit code $LASTEXITCODE"
}
& git -C $sourceRoot checkout --detach FETCH_HEAD
if ($LASTEXITCODE -ne 0) {
    throw "git checkout failed with exit code $LASTEXITCODE"
}

& git -C $sourceRoot apply --check $patchFile
if ($LASTEXITCODE -ne 0) {
    throw "The Windows CMake patch does not apply to $recollRef"
}
& git -C $sourceRoot apply $patchFile
if ($LASTEXITCODE -ne 0) {
    throw "Applying the Windows CMake patch failed"
}

$sourceRevision = (& git -C $sourceRoot rev-parse HEAD).Trim()
Set-Content -LiteralPath (Join-Path $buildRoot 'source-revision.txt') -Value $sourceRevision -NoNewline

Add-Content -Path $env:GITHUB_ENV -Value "RECOLL_SOURCE_DIR=$sourceRoot"
Add-Content -Path $env:GITHUB_ENV -Value "RECOLL_SOURCE_REVISION=$sourceRevision"

Write-Host "Recoll source revision: $sourceRevision"
