param(
  [string]$Site,
  [string]$HostName = $(if ($env:WYSE_HOST) { $env:WYSE_HOST } else { "wyse" }),
  [string]$IdentityFile = $(if ($env:WYSE_KEY) { $env:WYSE_KEY } else { "" })
)

$ErrorActionPreference = "Stop"

$sites = @{
  "webtv.site" = "/home/user/unsync-host-tv/serve/media"
  "webradio.site" = "/home/user/unsync-host-radio/serve/media"
}

if (-not $sites.ContainsKey($Site)) {
  throw "Unknown site '$Site'. Use webtv.site or webradio.site."
}

$target = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")).Path $Site
$targetMedia = Join-Path $target "media"
New-Item -ItemType Directory -Force $targetMedia | Out-Null

$source = "${HostName}:$($sites[$Site])"
$args = @()
if ($IdentityFile) {
  $args += @("-i", $IdentityFile)
}
$args += @("-r", $source, $target)

Write-Host "Syncing $source -> $targetMedia"
& scp @args
