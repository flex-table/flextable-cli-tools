# Bundle a portable set of PostgreSQL client tools for Windows (EDB binaries).
#
# pg_dump.exe/pg_restore.exe/psql.exe dynamic-link libpq + OpenSSL + friends.
# Windows resolves a DLL from the EXE's OWN directory first, so - unlike macOS
# (@loader_path rewriting) and Linux ($ORIGIN rpath) - the portable layout is
# simply the .exe files with their runtime DLLs co-located NEXT TO them at the
# top level (no lib/ subdir, no path rewriting, no Authenticode in this phase).
# The result is zipped and sha256'd for the signed manifest.
#
# The DLL set is SELF-DISCOVERING: rather than a fixed glob list (which silently
# misses a newly-linked DLL when EDB changes its build), we walk the transitive
# PE-import closure of the three executables - mirroring the otool/dylib closure
# in bundle_macos.sh and the ldd closure in bundle_linux.sh. The presence of a
# dependent in $SrcBinDir is the system-DLL filter: an imported DLL that EDB does
# NOT ship (kernel32, msvcrt, ws2_32, advapi32, secur32, …) lives in the Windows
# system dir and is correctly skipped.
#
# Layout produced (everything the app installs into tools/postgresql-<major>/):
#   <out>/postgresql-<major>-windows-x86_64/
#     pg_dump.exe  pg_restore.exe  psql.exe   # executables
#     libpq.dll  libssl-*.dll  libcrypto-*.dll  …   # runtime DLLs (same dir)
#
# Install contract (tool_downloader.rs `stage_and_swap` + `detect_bundle_root`):
# the zip's single top-level dir is the bundle ROOT; the installer copies its
# CONTENTS up. The copy_tree guard rejects symlinks, but EDB ships real DLLs.
#
# Usage:
#   pwsh ops/cli-tools/bundle_windows.ps1 -SrcBinDir <bin> -Major <n> -OutDir <out>
# Example (expanded EDB "PostgreSQL Binaries" zip):
#   pwsh ops/cli-tools/bundle_windows.ps1 -SrcBinDir C:\pgsql\bin -Major 17 -OutDir dist

param(
  [Parameter(Mandatory = $true)][string]$SrcBinDir,
  [Parameter(Mandatory = $true)][string]$Major,
  [string]$Arch = 'x86_64',
  [Parameter(Mandatory = $true)][string]$OutDir,
  # Defaults to the PostgreSQL namespace/tool set; override for another engine,
  # e.g. `-Namespace mysql -Tools 'mysqldump mysql'`. Env fallbacks (BUNDLE_NAMESPACE
  # / BUNDLE_TOOLS) mirror the bash bundlers. pg behavior is byte-identical when
  # neither the params nor the env vars are supplied. Tool names are bare (no
  # .exe); the suffix is appended here so the caller's set matches the bash scripts.
  [string]$Namespace = $env:BUNDLE_NAMESPACE,
  [string]$Tools = $env:BUNDLE_TOOLS
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Namespace)) { $Namespace = 'postgresql' }
if ([string]::IsNullOrWhiteSpace($Tools)) { $Tools = 'pg_dump pg_restore psql' }

# Split the space-separated tool list and append the .exe suffix each needs on
# Windows (only if the caller did not already include it).
$tools = @()
foreach ($t in ($Tools -split '\s+' | Where-Object { $_ -ne '' })) {
  if ($t.ToLower().EndsWith('.exe')) { $tools += $t } else { $tools += "$t.exe" }
}
$name = "$Namespace-$Major-windows-$Arch"
$stage = Join-Path $OutDir $name

# dumpbin.exe ships with the MSVC toolchain on the windows-latest runner. Locate
# it via vswhere; failing hard here is deliberate - silently falling back to a
# fixed DLL glob is exactly the build-specific gap this walk replaces.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
  throw "vswhere.exe not found at $vswhere - cannot locate dumpbin for the PE-import walk"
}
$dumpbin = & $vswhere -latest -find 'VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe' | Select-Object -First 1
if (-not $dumpbin -or -not (Test-Path $dumpbin)) {
  throw "dumpbin.exe not found via vswhere - the MSVC C++ toolset must be installed"
}

# Return the imported DLL names of a PE file (lowercased). `dumpbin /DEPENDENTS`
# prints an "Image has the following dependencies:" block of bare `<name>.dll`
# lines; everything else (headers, summary, blanks) is ignored.
function Get-PeImports {
  param([string]$File)
  $out = & $dumpbin /NOLOGO /DEPENDENTS $File 2>$null
  $names = @()
  foreach ($line in $out) {
    $m = [regex]::Match($line.Trim(), '(?i)^([^\s\\/:*?"<>|]+\.dll)$')
    if ($m.Success) { $names += $m.Groups[1].Value.ToLower() }
  }
  return $names
}

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# Case-insensitive index of files actually present in $SrcBinDir, keyed by lower-
# case name. Membership here is the system-DLL filter for the closure walk.
$srcByName = @{}
foreach ($f in Get-ChildItem -Path $SrcBinDir -File) {
  $srcByName[$f.Name.ToLower()] = $f.FullName
}

Write-Host "==> staging $name"
foreach ($t in $tools) {
  $src = Join-Path $SrcBinDir $t
  if (-not (Test-Path $src)) { throw "missing executable: $src" }
  Copy-Item -Force -Path $src -Destination (Join-Path $stage $t)
}

Write-Host "DEBUG post-copy: PWD=$PWD NETCWD=$([System.Environment]::CurrentDirectory) stage=$stage"
Get-ChildItem -Force $stage -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("DEBUG   [{0}] {1} {2}" -f $_.Mode, $_.Name, $_.Length) }

Write-Host "==> walking the PE-import closure of the executables"
# BFS over the transitive dependents. Seed with the 3 exes (already staged); for
# each file, enqueue every imported DLL that EDB ships in $SrcBinDir and isn't yet
# staged, copying it next to the exes at the top level. A dependent NOT in
# $SrcBinDir is a system DLL and is skipped - no fixed glob, no path rewriting.
$staged = @{}
foreach ($t in $tools) { $staged[$t.ToLower()] = $true }

$queue = [System.Collections.Queue]::new()
foreach ($t in $tools) { $queue.Enqueue((Join-Path $stage $t)) }

while ($queue.Count -gt 0) {
  $file = $queue.Dequeue()
  foreach ($dep in (Get-PeImports -File $file)) {
    if ($staged.ContainsKey($dep)) { continue }
    if (-not $srcByName.ContainsKey($dep)) { continue }  # system DLL: skip
    $dest = Join-Path $stage $dep
    Copy-Item -Force -Path $srcByName[$dep] -Destination $dest
    $staged[$dep] = $true
    $queue.Enqueue($dest)
  }
}

# libpq.dll is PostgreSQL's core client lib; if the walk did not pull it in, the
# source tree is wrong and the bundle would not run on a clean host. This guard is
# namespace-specific (other engines ship a different core DLL), so it only applies
# to the pg default.
if ($Namespace -eq 'postgresql' -and -not (Test-Path (Join-Path $stage 'libpq.dll'))) {
  throw "libpq.dll not found in the import closure of $SrcBinDir - the bundle would not run on a clean host"
}
foreach ($t in $tools) {
  if (-not (Test-Path (Join-Path $stage $t))) { throw "missing executable in stage: $t" }
}

Write-Host "==> zipping + sha256"
if (Test-Path (Join-Path $OutDir "$name.zip")) { Remove-Item -Force (Join-Path $OutDir "$name.zip") }
# ABSOLUTE paths: [ZipFile]::CreateFromDirectory resolves a RELATIVE path against
# .NET's CurrentDirectory (NOT PowerShell's $PWD, which can differ), silently zipping
# an empty/wrong dir -> a 0-byte bundle. Resolve both to full paths first.
$stageFull = (Resolve-Path -LiteralPath $stage).Path
$zipFull = Join-Path ((Resolve-Path -LiteralPath $OutDir).Path) "$name.zip"
# The 4-arg overload with includeBaseDirectory=$true zips $stage AS a single
# top-level wrapper dir (<namespace>-<major>-windows-x86_64/...). The default
# (contents-only) overload would drop that wrapper and break detect_bundle_root,
# which requires the zip's single top entry to be the bundle ROOT.
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stageFull, $zipFull, [System.IO.Compression.CompressionLevel]::Optimal, $true)

$sha = (Get-FileHash -Algorithm SHA256 -Path $zipFull).Hash.ToLower()
$sizeMb = [math]::Round((Get-Item $zipFull).Length / 1048576, 1)

Write-Host ""
Write-Host "bundle : $zipFull"
Write-Host "sha256 : $sha"
Write-Host "sizeMb : $sizeMb"
Write-Host "platform-key: windows-$Arch"
