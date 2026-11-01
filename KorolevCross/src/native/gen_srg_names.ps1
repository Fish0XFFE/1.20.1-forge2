$tsrg = "C:\Users\fish\.gradle\caches\forge_gradle\minecraft_user_repo\de\oceanlabs\mcp\mcp_config\1.20.1-20230612.114412\srg_to_official_1.20.1.tsrg"
$prefixes = @(
  "net/minecraft/world/level/levelgen/DensityFunctions",
  "net/minecraft/world/level/levelgen/DensityFunction",
  "net/minecraft/world/level/levelgen/NoiseChunk",
  "net/minecraft/world/level/levelgen/Beardifier",
  "net/minecraft/world/level/levelgen/synth/NormalNoise",
  "net/minecraft/world/level/levelgen/synth/PerlinNoise",
  "net/minecraft/world/level/levelgen/synth/ImprovedNoise",
  "net/minecraft/world/level/levelgen/synth/BlendedNoise",
  "net/minecraft/world/level/levelgen/synth/SimplexNoise",
  "net/minecraft/world/level/levelgen/DensityFunctions",
  "net/minecraft/util/CubicSpline"
)
$map = New-Object 'System.Collections.Generic.SortedDictionary[string,string]'
$curSrg = $null
$curOff = $null
foreach ($line in [IO.File]::ReadLines($tsrg)) {
  if ($line.Length -eq 0) { continue }
  if ($line[0] -ne "`t") {
    if ($line -match '^\s') { continue }
    $p = $line.Split(' ')
    if ($p.Count -ge 2) { $curSrg = $p[0]; $curOff = $p[1] } else { $curSrg = $p[0]; $curOff = $p[0] }
    continue
  }
  if ($line.StartsWith("`t`t")) { continue }
  if ($line.Contains("(")) { continue }
  $t = $line.Trim().Split("`t")[0].Split(' ')
  if ($t.Count -lt 2) { continue }
  if (-not $curOff) { continue }
  foreach ($pre in $prefixes) {
    if ($curOff.StartsWith($pre)) {
      $key = $curOff.Replace('/', '.') + "." + $t[1]
      $map[$key] = $t[0]
      break
    }
  }
}
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("package com.fish.korolevcross.gpu;")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("import java.util.HashMap;")
[void]$sb.AppendLine("import java.util.Map;")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("public final class SrgNames {")
[void]$sb.AppendLine("    private static final Map<String, String> MAP = new HashMap<>(1024);")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("    private SrgNames() {")
[void]$sb.AppendLine("    }")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("    static String srg(String owner, String name) {")
[void]$sb.AppendLine('        return MAP.get(owner + "." + name);')
[void]$sb.AppendLine("    }")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("    static {")
foreach ($kv in $map.GetEnumerator()) {
  [void]$sb.AppendLine('        MAP.put("' + $kv.Key + '", "' + $kv.Value + '");')
}
[void]$sb.AppendLine("    }")
[void]$sb.AppendLine("}")
$out = "C:\Users\fish\Desktop\KorolevCross\src\main\java\com\fish\korolevcross\gpu\SrgNames.java"
[IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Output "entries=$($map.Count) file=$out"
