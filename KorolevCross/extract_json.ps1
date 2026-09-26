param(
    [Parameter(Mandatory=$true)]
    [string]$JarPath
)

$out = "C:\Users\fish\Desktop\KorolevCross\src\main\resources\native\dimension"

if (-not (Test-Path $JarPath)) { Write-Host "JAR not found"; exit 1 }

Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $out | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $out "density_functions") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $out "noise") | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)

$dfIndex = New-Object System.Collections.Generic.List[string]
$noiseIndex = New-Object System.Collections.Generic.List[string]

foreach ($dim in @("overworld", "nether", "end")) {
    $src = "data/minecraft/worldgen/noise_settings/$dim.json"
    $entry = $zip.Entries | Where-Object { $_.FullName -eq $src }
    if ($entry) {
        $dest = Join-Path $out "minecraft_${dim}_noise.json"
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        Write-Host "noise_settings: $dim"
    }
}

foreach ($entry in $zip.Entries) {
    if ($entry.FullName -like "data/minecraft/worldgen/density_function/*.json") {
        $rel = $entry.FullName -replace "data/minecraft/worldgen/density_function/", ""
        $rel = $rel -replace "/", "__"
        $dest = Join-Path (Join-Path $out "density_functions") $rel
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        $dfIndex.Add($rel)
    }
    if ($entry.FullName -like "data/minecraft/worldgen/noise/*.json") {
        $rel = $entry.FullName -replace "data/minecraft/worldgen/noise/", ""
        $rel = $rel -replace "/", "__"
        $dest = Join-Path (Join-Path $out "noise") $rel
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        $noiseIndex.Add($rel)
    }
}

Set-Content -Path (Join-Path $out "df_index.txt") -Value $dfIndex -Encoding ASCII
Set-Content -Path (Join-Path $out "noise_index.txt") -Value $noiseIndex -Encoding ASCII

Write-Host "Extracted: density_functions=$($dfIndex.Count) noise=$($noiseIndex.Count)"
$zip.Dispose()