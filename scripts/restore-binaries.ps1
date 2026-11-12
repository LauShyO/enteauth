# Restore the binary files listed in binary-files.txt from upstream.
# Downloads each file from raw.githubusercontent.com at the pinned upstream
# commit and verifies its SHA256. Files already present with a matching hash
# are skipped. Run from the repository root.
$sha = "6b0003ecee71f3c771c07469f5a145a641f02c9a"
$base = "https://raw.githubusercontent.com/ente/ente/$sha"
$root = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path $root "binary-files.txt"
$ok = 0; $fetched = 0; $failed = 0
foreach ($line in Get-Content $manifest) {
    if (-not $line.Trim()) { continue }
    $want, $path = $line -split '\s+', 2
    $dest = Join-Path $root ($path -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (Test-Path $dest) {
        $have = (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower()
        if ($have -eq $want) { $ok++; continue }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    $tmp = "$dest.download"
    try {
        Invoke-WebRequest -Uri "$base/$path" -OutFile $tmp -UseBasicParsing
        $have = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
        if ($have -eq $want) { Move-Item $tmp $dest -Force; $fetched++ }
        else { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; Write-Host "FAILED (hash): $path"; $failed++ }
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Host "FAILED: $path"; $failed++
    }
}
Write-Host "already ok: $ok, fetched: $fetched, failed: $failed"
if ($failed -gt 0) { exit 1 }