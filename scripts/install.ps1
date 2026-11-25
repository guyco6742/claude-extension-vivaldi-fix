<#
.SYNOPSIS
    Patch the Claude for Chrome extension so it renders correctly in Vivaldi.

.DESCRIPTION
    Copies the installed Claude extension from your Vivaldi profile to a separate
    folder, adds a static `side_panel.default_path` to manifest.json, and prints
    instructions for loading the patched copy as an unpacked extension.

    Does not download anything. Does not require admin. Only touches files under
    the current user's profile.

.PARAMETER Destination
    Target folder for the patched copy. Defaults to
    $env:LOCALAPPDATA\claude-extension-vivaldi-patched.

.PARAMETER Force
    Overwrite the destination folder without prompting if it already exists.

.EXAMPLE
    .\install.ps1
    .\install.ps1 -Destination C:\tools\claude-patched -Force
#>
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'claude-extension-vivaldi-patched'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ExtensionId = 'fcoeoabgfenejglbffodgkkbkcdhcgfn'

function Write-Step    ($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok      ($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2   ($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Write-Err2    ($msg) { Write-Host "    $msg" -ForegroundColor Red }

# --- 1. Locate Vivaldi's Claude extension install -----------------------------
Write-Step "Locating Vivaldi's installed Claude extension"

$vivaldiUserData = Join-Path $env:LOCALAPPDATA 'Vivaldi\User Data'
if (-not (Test-Path $vivaldiUserData)) {
    Write-Err2 "Vivaldi user data not found at: $vivaldiUserData"
    Write-Err2 "Is Vivaldi installed for this user? Aborting."
    exit 1
}

# Search every profile (Default, Profile 1, etc.) for the extension
$extRoots = Get-ChildItem -Path $vivaldiUserData -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName "Extensions\$ExtensionId" } |
    Where-Object { Test-Path $_ }

if (-not $extRoots) {
    Write-Err2 "Claude extension ($ExtensionId) not found in any Vivaldi profile."
    Write-Err2 "Install it from the Chrome Web Store in Vivaldi first, then re-run this script."
    exit 1
}

# Pick the newest version folder across all profiles
$latest = $extRoots |
    ForEach-Object { Get-ChildItem -Path $_ -Directory } |
    Sort-Object { [version]($_.Name -replace '_\d+$','') } -Descending |
    Select-Object -First 1

# Loading the patched copy (same extension ID) can make Vivaldi delete the Web Store
# files, leaving an empty Extensions\<id> folder. Stop before deleting the destination.
if (-not $latest -or -not (Test-Path (Join-Path $latest.FullName 'manifest.json'))) {
    Write-Err2 "Claude extension folder found, but it has no installed version."
    Write-Err2 "Remove 'Claude (Vivaldi-patched)', re-enable or reinstall Claude from the Chrome Web Store, then re-run."
    exit 1
}

Write-Ok "Found: $($latest.FullName)"

# --- 2. Confirm destination ---------------------------------------------------
Write-Step "Preparing destination: $Destination"
if (Test-Path $Destination) {
    if (-not $Force) {
        $reply = Read-Host "Destination exists. Overwrite? (y/N)"
        if ($reply -notmatch '^[yY]') { Write-Host "Aborted."; exit 0 }
    }
    Remove-Item -Recurse -Force $Destination
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null

# --- 3. Copy extension (skip _metadata which holds the CRX signature) --------
Write-Step "Copying extension files"
Get-ChildItem -Path $latest.FullName -Exclude '_metadata' | ForEach-Object {
    Copy-Item -Recurse -Force -Path $_.FullName -Destination $Destination
}
Write-Ok "Copied to $Destination"

# --- 4. Patch manifest.json ---------------------------------------------------
Write-Step "Patching manifest.json"
$manifestPath = Join-Path $Destination 'manifest.json'
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

# Add static side_panel.default_path (the actual fix)
$manifest | Add-Member -NotePropertyName 'side_panel' `
    -NotePropertyValue ([pscustomobject]@{ default_path = 'sidepanel.html' }) -Force

# Remove update_url so Vivaldi doesn't try to auto-replace us with the CWS copy
if ($manifest.PSObject.Properties.Name -contains 'update_url') {
    $manifest.PSObject.Properties.Remove('update_url')
}

# Rename so it's visually distinct in the extensions list
$manifest.name = 'Claude (Vivaldi-patched)'

# Write back with UTF-8 (no BOM) — Chromium is picky about manifest encoding
$json = $manifest | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding $false))
Write-Ok "Added side_panel.default_path, removed update_url"

# --- 4b. Inject tabId when the static path omits it ---------------------------
# The service worker normally opens `sidepanel.html?tabId=N`; without tabId the panel
# never connects to the service worker and claude.ai shows "Can't reach the Claude
# extension". Gate the main module behind a loader that adds the active tab's id.
# ponytail: binds to the tab active when the panel opens; reopen the panel to rebind.
Write-Step "Patching sidepanel.html (tabId loader)"
$htmlPath = Join-Path $Destination 'sidepanel.html'
$html = [System.IO.File]::ReadAllText($htmlPath)
$m = [regex]::Match($html, '<script type="module" crossorigin src="(/assets/sidepanel-[^"]+\.js)"></script>')
if (-not $m.Success) { Write-Err2 "sidepanel module tag not found; extension layout changed."; exit 1 }
$loader = @"
(function () {
  var q = new URLSearchParams(location.search);
  function boot() {
    var s = document.createElement('script');
    s.type = 'module'; s.crossOrigin = ''; s.src = '$($m.Groups[1].Value)';
    document.head.appendChild(s);
  }
  // Active tab of a normal window, never the panel's own tab (Vivaldi hosts it in a tab).
  function activeTab(cb) {
    chrome.tabs.getCurrent(function (self) {
      chrome.tabs.query({ active: true, lastFocusedWindow: true, windowType: 'normal' }, function (tabs) {
        cb(tabs.filter(function (t) {
          var u = t.url || t.pendingUrl || '';
          return (!self || t.id !== self.id) && u && !u.startsWith(location.origin);
        })[0]);
      });
    });
  }
  if (q.get('mode') === 'window') return boot();
  // Vivaldi 8.3 resets the panel to its default path on any URL change (navigation or
  // history.replaceState), which looped forever. So never touch the URL: hand the
  // params to the patched module through window.__vivaldiSearch.
  activeTab(function (active) {
    if (active) { q.set('tabId', active.id); window.__vivaldiSearch = '?' + q; }
    boot();
    chrome.tabs.onRemoved.addListener(function (id) {
      if (String(id) === q.get('tabId')) location.reload(); // reload rebinds to the active tab
    });
  });
})();
"@
[System.IO.File]::WriteAllText((Join-Path $Destination 'vivaldi-tabid.js'), $loader, (New-Object System.Text.UTF8Encoding $false))
$html = $html.Replace($m.Value, '<script src="/vivaldi-tabid.js"></script>')
$modPath = Join-Path $Destination ($m.Groups[1].Value.TrimStart('/'))
$mod = [System.IO.File]::ReadAllText($modPath)
$hits = ([regex]::Matches($mod, [regex]::Escape('new URLSearchParams(window.location.search)'))).Count
if ($hits -eq 0) { Write-Err2 "location.search reads not found in sidepanel module; extension layout changed."; exit 1 }
$mod = $mod.Replace('new URLSearchParams(window.location.search)', 'new URLSearchParams(window.__vivaldiSearch??window.location.search)')
Write-Ok "Redirected $hits location.search reads in the panel module"
# Side panel detection: the panel treats chrome.tabs.getCurrent() === undefined as
# "I am the side panel". Vivaldi returns the panel's own tab, so the panel shows
# "Claude isn't available on this page". Also accept a top-level sidepanel.html
# (framed copies are already handled by the window.top check that precedes it).
$spRe = 'if\(void 0===(\w)\)return\{kind:"sidePanel"\}'
if ([regex]::IsMatch($mod, $spRe)) {
    $mod = [regex]::Replace($mod, $spRe, 'if(void 0===$1||location.pathname==="/sidepanel.html")return{kind:"sidePanel"}')
    Write-Ok "Side panel detection no longer relies on tabs.getCurrent()"
} else {
    Write-Warn2 "Side panel detection check not found; skipped (older extension layout?)."
}
[System.IO.File]::WriteAllText($modPath, $mod, (New-Object System.Text.UTF8Encoding $false))
[System.IO.File]::WriteAllText($htmlPath, $html, (New-Object System.Text.UTF8Encoding $false))
Write-Ok "Added vivaldi-tabid.js loader"

# --- 4c. Accept the side panel as an extension page ---------------------------
# The service worker only trusts senders with no `tab` (true for Chrome's side panel),
# but Vivaldi hosts the panel in a tab, so every panel request is rejected
# ("sender is not an extension page"). Check the sender URL instead: still excludes
# content scripts and web pages.
Write-Step "Patching service worker sender check"
$swPath = (Get-ChildItem (Join-Path $Destination 'assets') -Filter 'service-worker*.js' | Select-Object -First 1).FullName
$sw = [System.IO.File]::ReadAllText($swPath)
$re = 'return void 0===(\w)\.tab&&\1\.id===chrome\.runtime\.id\}'
# 1.0.109+: the check moved to a shared chunk and already verifies the sender URL:
#   void 0===e.tab&&e.id===chrome.runtime.id&&"string"==typeof e.url&&e.url.startsWith(`chrome-extension://${chrome.runtime.id}/`)
# Dropping only the tab condition leaves the same URL-based check as above.
$reNew = 'void 0===(\w)\.tab&&(\1\.id===chrome\.runtime\.id&&"string"==typeof \1\.url&&\1\.url\.startsWith\()'
if ([regex]::IsMatch($sw, $re)) {
    $sw = [regex]::Replace($sw, $re, 'return $1.id===chrome.runtime.id&&($1.url||"").startsWith(chrome.runtime.getURL(""))}')
} else {
    $chunk = Get-ChildItem (Join-Path $Destination 'assets') -Filter '*.js' |
        Where-Object { [regex]::IsMatch([System.IO.File]::ReadAllText($_.FullName), $reNew) } |
        Select-Object -First 1
    if (-not $chunk) { Write-Err2 "sender check not found; extension layout changed."; exit 1 }
    $src = [regex]::Replace([System.IO.File]::ReadAllText($chunk.FullName), $reNew, '$2')
    [System.IO.File]::WriteAllText($chunk.FullName, $src, (New-Object System.Text.UTF8Encoding $false))
    Write-Ok "Sender check patched in $($chunk.Name)"
}
# Same for claude.ai framed in the panel (onMessageExternal): its sender.tab is the
# panel's own tab, so trust it when that tab is sidepanel.html.
$inPanel = '(void 0===$1.tab||($1.tab.url||"").startsWith(chrome.runtime.getURL("sidepanel.html")))'
$n = 0
foreach ($p in @(
    @{ re = '(?<="get_sidepanel_host_info"===\w\.type\)try\{const \w=)void 0===(\w)\.tab'; to = $inPanel },
    @{ re = '(?<=\(ho\.includes\(\w\.type\)\)\{if\()void 0!==(\w)\.tab'; to = "!$inPanel" }
)) {
    if ([regex]::IsMatch($sw, $p.re)) { $sw = [regex]::Replace($sw, $p.re, $p.to); $n++ }
}
if ($n -lt 2) { Write-Warn2 "Only $n/2 external sender checks patched; extension layout changed." }
# The cowork bridge reads the panel's tabId from the sender URL. vivaldi-tabid.js
# never changes the URL (it passes tabId through window.__vivaldiSearch), so the
# bridge rejected every request ("panelTabId does not match the sending document")
# and no tab group was created. Fall back to the tabId the panel sends; the sender
# is already verified as an extension page above.
$tidRe = 'const (\w+)=(\w+)\((\w)\.url\),(\w+)=(\w)\.panelTabId;'
if ([regex]::IsMatch($sw, $tidRe)) {
    $sw = [regex]::Replace($sw, $tidRe, 'const $1=$2($3.url)??$5.panelTabId,$4=$5.panelTabId;')
    Write-Ok "Bridge accepts the panel's tabId when the URL has none"
} else {
    Write-Warn2 "Bridge tabId check not found; skipped."
}
# The panel replaces the bridge's error with a generic "anchor tab group not
# established". Append the real reason so failures are diagnosable from the chat.
$reasonOld = '{content:[{type:"text",text:"anchor tab group not established"}],is_error:!0});o=n.tabGroupId'
if ($mod.Contains($reasonOld)) {
    $mod = $mod.Replace($reasonOld, '{content:[{type:"text",text:"anchor tab group not established: "+(n.error||JSON.stringify(n))}],is_error:!0});o=n.tabGroupId')
    [System.IO.File]::WriteAllText($modPath, $mod, (New-Object System.Text.UTF8Encoding $false))
    Write-Ok "Panel shows the real bridge error"
}
# Surface the real cause instead of a generic message when the anchor group fails.
$sw = $sw.Replace('catch(t){return{ok:!1,error:"anchor tab-group initialization failed"}}', 'catch(t){return{ok:!1,error:"anchor tab-group initialization failed: "+(t&&t.message||t)}}')

[System.IO.File]::WriteAllText($swPath, $sw, (New-Object System.Text.UTF8Encoding $false))
Write-Ok "Sender checks now URL-based"

# --- 4d. Silence two harmless warnings in the extension's error log ------------
# Both come from the extension's own code (they also appear in Chrome); they don't
# break anything, but they fill vivaldi://extensions -> Errors. Each tweak is
# skipped with a warning if the code isn't found (minified names change per version).
Write-Step "Silencing harmless extension warnings"
$assetsDir = Join-Path $Destination 'assets'
$tweaks = @(
    # The silent keep-alive AudioContext is created before any user gesture, so it
    # starts suspended anyway and Chrome logs "AudioContext was not allowed to start".
    @{ what = 'AudioContext autoplay warning'
       old  = 'try{if(!y){y=new AudioContext;'
       new  = 'try{if(!y&&navigator.userActivation?.hasBeenActive){y=new AudioContext;' },
    # debugger.detach callback ignores lastError -> "Unchecked runtime.lastError:
    # Debugger is not attached to the tab". Reading it marks the error as handled.
    @{ what = 'debugger.detach lastError'
       old  = 'chrome.debugger.detach({tabId:t},()=>{e.clearPressNetwork(t),n(!0)})'
       new  = 'chrome.debugger.detach({tabId:t},()=>{void chrome.runtime.lastError,e.clearPressNetwork(t),n(!0)})' }
)
foreach ($tw in $tweaks) {
    $patched = $false
    foreach ($jsFile in Get-ChildItem $assetsDir -Filter '*.js') {
        $text = [System.IO.File]::ReadAllText($jsFile.FullName)
        if ($text.Contains($tw.old)) {
            [System.IO.File]::WriteAllText($jsFile.FullName, $text.Replace($tw.old, $tw.new), (New-Object System.Text.UTF8Encoding $false))
            $patched = $true
            break
        }
    }
    if ($patched) { Write-Ok "Fixed: $($tw.what)" } else { Write-Warn2 "$($tw.what): code not found, skipped (harmless)." }
}

# --- 4e. Emulate tab groups ---------------------------------------------------
# Vivaldi 8.3: chrome.tabs.group() returns an id but groups nothing, so every
# browser tool fails with "anchor tab group not established". Load a shim that
# emulates chrome.tabGroups before the service worker and the panel module.
Write-Step "Adding tab group emulation"
Copy-Item (Join-Path $PSScriptRoot 'vivaldi-groups-shim.js') $Destination
$loaderPath = Join-Path $Destination 'service-worker-loader.js'
[System.IO.File]::WriteAllText($loaderPath, "import './vivaldi-groups-shim.js';`n" + [System.IO.File]::ReadAllText($loaderPath), (New-Object System.Text.UTF8Encoding $false))
$html = [System.IO.File]::ReadAllText($htmlPath).Replace('<script src="/vivaldi-tabid.js"></script>', '<script src="/vivaldi-groups-shim.js"></script><script src="/vivaldi-tabid.js"></script>')
[System.IO.File]::WriteAllText($htmlPath, $html, (New-Object System.Text.UTF8Encoding $false))
Write-Ok "Shim loaded in service worker and side panel"

# --- 5. Verify native messaging host registration ----------------------------
Write-Step "Checking native-messaging host registration for Vivaldi"
$nmKey = 'HKCU:\Software\Vivaldi\NativeMessagingHosts\com.anthropic.claude_browser_extension'
if (Test-Path $nmKey) {
    $nmPath = (Get-ItemProperty $nmKey).'(default)'
    if ($nmPath -and (Test-Path $nmPath)) {
        Write-Ok "Registered: $nmPath"
    } else {
        Write-Warn2 "Registry key exists but manifest file missing: $nmPath"
        Write-Warn2 "Install or repair Claude Desktop if MCP tools fail to connect."
    }
} else {
    Write-Warn2 "Native-messaging host NOT registered for Vivaldi."
    Write-Warn2 "Claude Desktop's MCP browser tools will not reach the Vivaldi extension."
    Write-Warn2 "On Windows, Claude Desktop usually creates this automatically when installed."
    Write-Warn2 "See https://github.com/stolot0mt0m/claude-chromium-native-messaging for manual setup."
}

# --- 6. Next steps ------------------------------------------------------------
Write-Host ""
Write-Host "Done. Manual steps in Vivaldi:" -ForegroundColor Cyan
Write-Host "  1. Open vivaldi://extensions"
Write-Host "  2. Disable (do not remove) the existing 'Claude' extension"
Write-Host "  3. Toggle Developer mode ON (top-right)"
Write-Host "  4. Click 'Load unpacked' and select:"
Write-Host "       $Destination" -ForegroundColor Yellow
Write-Host "  5. Pin the new 'Claude (Vivaldi-patched)' icon and click it"
Write-Host ""
