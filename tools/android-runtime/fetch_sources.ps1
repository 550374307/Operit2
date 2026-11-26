$ErrorActionPreference = "Stop"

$runtimeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$downloadsDir = Join-Path $runtimeDir "downloads"
$sourcesDir = Join-Path $runtimeDir "sources"

New-Item -ItemType Directory -Force -Path $downloadsDir | Out-Null
New-Item -ItemType Directory -Force -Path $sourcesDir | Out-Null

$items = @(
    @{
        Name = "busybox-1.38.0"
        Url = "https://busybox.net/downloads/busybox-1.38.0.tar.bz2"
        Archive = "busybox-1.38.0.tar.bz2"
        Sha256 = "34F9EA6FF8636F2C9241153B9114EEFA9E65674A45318AE1EF95BB5F31C53BB2"
        Extracted = "busybox-1.38.0"
    },
    @{
        Name = "termux-proot-v5.1.107.78"
        Url = "https://github.com/termux/proot/archive/refs/tags/v5.1.107.78.tar.gz"
        Archive = "termux-proot-v5.1.107.78.tar.gz"
        Sha256 = "F3377BA49DCD833370420C34C5081B4C243ECBB85B2A9881A4F4586012599AFA"
        Extracted = "proot-5.1.107.78"
    },
    @{
        Name = "talloc-2.4.3"
        Url = "https://www.samba.org/ftp/talloc/talloc-2.4.3.tar.gz"
        # samba.org answers 503/504 under load and publishes no CDN mirror for
        # the upstream tarballs, so retries against the same host are the only
        # recovery path. The SHA256 check below still rejects any corrupted
        # partial download, and the retry loop backs off (10s..50s).
        Archive = "talloc-2.4.3.tar.gz"
        Sha256 = "DC46C40B9F46BB34DD97FE41F548B0E8B247B77A918576733C528E83ABD854DD"
        Extracted = "talloc-2.4.3"
    },
    @{
        Name = "bash-5.2.37"
        Url = "https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz"
        MirrorUrls = @(
            "https://mirrors.tuna.tsinghua.edu.cn/gnu/bash/bash-5.2.37.tar.gz",
            "https://mirror.csclub.uwaterloo.ca/gnu/bash/bash-5.2.37.tar.gz",
            "https://mirrors.kernel.org/gnu/bash/bash-5.2.37.tar.gz"
        )
        Archive = "bash-5.2.37.tar.gz"
        Sha256 = "9599B22ECD1D5787AD7D3B7BF0C59F312B3396D1E281175DD1F8A4014DA621FF"
        Extracted = "bash-5.2.37"
    }
)

foreach ($item in $items) {
    $archivePath = Join-Path $downloadsDir $item.Archive
    Write-Host "Downloading $($item.Name)"

    # A cached, checksum-verified archive lets CI skip fragile origins such as
    # samba.org entirely on warm runs.
    if (Test-Path -LiteralPath $archivePath) {
        $cachedSha256 = (Get-FileHash -Algorithm SHA256 -Path $archivePath).Hash.ToUpperInvariant()
        if ($cachedSha256 -eq $item.Sha256) {
            Write-Host "Using cached $($item.Archive) (SHA256 verified)"
            $extractPathCached = Join-Path $sourcesDir $item.Extracted
            if (-not (Test-Path -LiteralPath $extractPathCached)) {
                tar -xf $archivePath -C $sourcesDir
            }
            continue
        }
        Write-Warning "Cached $($item.Archive) failed SHA256 verification; re-downloading"
        Remove-Item -LiteralPath $archivePath -Force
    }

    $maxAttempts = 8
    # @($item.MirrorUrls) yields a one-element array holding $null when the key
    # is absent, which made the retry loop alternate between the real URL and an
    # empty one ("Cannot validate argument on parameter 'Uri'"). Drop nulls and
    # blanks so every attempt targets a real source.
    $candidateUrls = @(@($item.Url) + @($item.MirrorUrls) | Where-Object { $_ -and "$_".Trim().Length -gt 0 })
    $downloaded = $false
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $url = $candidateUrls[($attempt - 1) % $candidateUrls.Count]
        try {
            Write-Host "Downloading $($item.Name) from $url (attempt $attempt/$maxAttempts)"
            Invoke-WebRequest -Uri $url -OutFile $archivePath -TimeoutSec 600
            $downloaded = $true
            break
        } catch {
            Write-Warning "Attempt $attempt/$maxAttempts failed for $($item.Name) ($url): $($_.Exception.Message)"
            if ($attempt -lt $maxAttempts) {
                # Cap the backoff at 45s so eight attempts stay under ~5 minutes
                # while still riding out a multi-minute samba.org outage.
                Start-Sleep -Seconds ([Math]::Min(45, 10 * $attempt))
            }
        }
    }
    if (-not $downloaded) {
        throw "Failed to download $($item.Name) after $maxAttempts attempts from: $($candidateUrls -join ', ')"
    }

    $actualSha256 = (Get-FileHash -Algorithm SHA256 -Path $archivePath).Hash.ToUpperInvariant()
    if ($actualSha256 -ne $item.Sha256) {
        throw "$($item.Archive) SHA256 mismatch: $actualSha256"
    }

    $extractPath = Join-Path $sourcesDir $item.Extracted
    if (Test-Path $extractPath) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force
    }

    tar -xf $archivePath -C $sourcesDir
}
