# AI Config Manager
#
# Arrow-key TUI to point Claude Code, OpenCode, and Codex at a custom gateway
# (AgentRouter, EuroModels, or any OpenAI/Anthropic-compatible base URL), and to
# launch Hermes Desktop's own model setup. Presets live in AI-Config-Presets.json;
# model lists are fetched live when the gateway allows it, with curated fallbacks.
#
# Requires Windows PowerShell 5.1+ or PowerShell 7+, and curl.exe (bundled with
# Windows 10/11). Existing config files are backed up before every write.
#
# Usage:   powershell -ExecutionPolicy Bypass -File .\AI-Config-Manager.ps1
# Selftest: powershell -File .\AI-Config-Manager.ps1 -SelfTest

param([switch]$SelfTest)

$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "AI Config Manager"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Pure scroll-window math (extracted so it can be self-tested without a TTY).
function Get-ScrollWindow {
    param([int]$Selected, [int]$Count, [int]$PageSize, [int]$CurrentTop)
    if ($Count -le $PageSize) { return 0 }
    if ($Selected -lt $CurrentTop) { return $Selected }
    if ($Selected -ge ($CurrentTop + $PageSize)) { return $Selected - $PageSize + 1 }
    return $CurrentTop
}

# Runnable checks for the non-trivial scroll math. Run: powershell -File .\AI-Config-Manager.ps1 -SelfTest
if ($SelfTest) {
    function Assert-Equal($a, $b, $msg) {
        if ($a -ne $b) { Write-Host "FAIL: $msg (expected $b, got $a)" -ForegroundColor Red; exit 1 }
        Write-Host "ok: $msg" -ForegroundColor DarkGray
    }
    Assert-Equal (Get-ScrollWindow 5 10 5 0) 1 "down: selection just past window"
    Assert-Equal (Get-ScrollWindow 9 10 5 0) 5 "down: selection near end"
    Assert-Equal (Get-ScrollWindow 0 10 5 3) 0 "up: selection above window"
    Assert-Equal (Get-ScrollWindow 0 3 5 0) 0 "count fits page"
    Assert-Equal (Get-ScrollWindow 2 100 5 50) 2 "up: from far window"
    Assert-Equal (Get-ScrollWindow 3 100 5 0) 0 "within window: no change"
    Write-Host "All self-test checks passed." -ForegroundColor Green
    exit 0
}

# ---------- UI helpers ----------

function Write-Banner([string]$Title) {
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "  $([string]::new([char]0x2500, $Title.Length + 2))" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Menu {
    param(
        [string]$Title,
        [string[]]$Options,
        [string[]]$Header = @(),
        [int]$DefaultIndex = 0
    )
    if ($Options.Count -eq 0) { return -1 }
    $selected = [Math]::Min($DefaultIndex, $Options.Count - 1)
    $top = 0
    while ($true) {
        Clear-Host
        Write-Banner $Title
        foreach ($h in $Header) { Write-Host "  $h" -ForegroundColor DarkGray }
        if ($Header.Count -gt 0) { Write-Host "" }

        $pageSize = [Math]::Max(5, [Console]::WindowHeight - 9 - $Header.Count)
        $top = Get-ScrollWindow $selected $Options.Count $pageSize $top
        $last = [Math]::Min($top + $pageSize, $Options.Count) - 1
        for ($i = $top; $i -le $last; $i++) {
            if ($i -eq $selected) {
                Write-Host (" > {0}" -f $Options[$i]) -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host ("   {0}" -f $Options[$i]) -ForegroundColor Gray
            }
        }
        if ($top -gt 0 -or $last -lt $Options.Count - 1) {
            Write-Host ""
            Write-Host "  ($($top + 1)-$($last + 1) of $($Options.Count))" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  Up/Dn navigate | Enter select | Esc back" -ForegroundColor DarkGray

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            UpArrow   { if ($selected -gt 0) { $selected-- } }
            DownArrow { if ($selected -lt $Options.Count - 1) { $selected++ } }
            Home      { $selected = 0 }
            End       { $selected = $Options.Count - 1 }
            Enter     { return $selected }
            Escape    { return -1 }
        }
    }
}

function Pause-Screen {
    Write-Host ""
    Read-Host "Press Enter to continue" | Out-Null
}

# ---------- input helpers ----------

function Read-SecretPlain {
    $secure = Read-Host "Enter API Key" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Mask-Key([string]$Key) {
    if ([string]::IsNullOrWhiteSpace($Key)) { return "(empty)" }
    if ($Key.Length -le 8) { return ("*" * $Key.Length) }
    return $Key.Substring(0,4) + ("*" * [Math]::Min(12,$Key.Length-8)) + $Key.Substring($Key.Length-4)
}

function Normalize-BaseUrl([string]$Url) { return $Url.Trim().TrimEnd("/") }

function Get-ModelsEndpoint([string]$BaseUrl) {
    $b = Normalize-BaseUrl $BaseUrl
    if ($b -match "/v1$") { return "$b/models" }
    return "$b/v1/models"
}

# ---------- live model fetch ----------

function Get-LiveModels([string]$BaseUrl, [string]$ApiKey) {
    $endpoint = Get-ModelsEndpoint $BaseUrl
    Write-Host ""
    Write-Host "Fetching models from: $endpoint" -ForegroundColor DarkGray

    $tmp = [IO.Path]::GetTempFileName()
    try {
        $curlArgs = @(
            "-sS", "--fail-with-body",
            "--connect-timeout", "15",
            "--max-time", "45",
            "-H", "Authorization: Bearer $ApiKey",
            "-H", "Accept: application/json",
            "-o", $tmp,
            "-w", "%{http_code}",
            $endpoint
        )
        $status = & curl.exe @curlArgs
        $exit = $LASTEXITCODE
        $body = Get-Content $tmp -Raw -ErrorAction SilentlyContinue

        if ($exit -ne 0 -or $status -notmatch "^2") {
            throw "Request failed. HTTP $status`n$body"
        }

        $json = $body | ConvertFrom-Json
        $ids = @()
        if ($null -ne $json.data) {
            $ids = @($json.data | ForEach-Object {
                if ($_ -is [string]) { $_ } elseif ($_.id) { [string]$_.id }
            })
        } elseif ($null -ne $json.models) {
            $ids = @($json.models | ForEach-Object {
                if ($_ -is [string]) { $_ }
                elseif ($_.id) { [string]$_.id }
                elseif ($_.name) { [string]$_.name }
            })
        }

        $ids = @($ids | Where-Object { $_ } | Sort-Object -Unique)
        if ($ids.Count -eq 0) { throw "API responded successfully, but no model IDs were found in data[].id or models[]." }
        return $ids
    }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# AgentRouter exposes its full model list (with IDs and supported endpoints) at a
# public, no-auth JSON endpoint behind the /pricing page. Unlike /v1/models and
# /api/models, this one is NOT client-gated (no 401). Returns data[].model_name
# and data[].supported_endpoint_types (e.g. ["anthropic","openai"]).
function Get-AgentRouterPricingModels([string]$Url) {
    Write-Host ""
    Write-Host "Fetching model list from: $Url" -ForegroundColor DarkGray
    $tmp = [IO.Path]::GetTempFileName()
    try {
        $curlArgs = @(
            "-sS", "--fail-with-body",
            "--connect-timeout", "15",
            "--max-time", "45",
            "-H", "Accept: application/json",
            "-o", $tmp,
            "-w", "%{http_code}",
            $Url
        )
        $status = & curl.exe @curlArgs
        $exit = $LASTEXITCODE
        $body = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
        if ($exit -ne 0 -or $status -notmatch "^2") { throw "Request failed. HTTP $status`n$body" }
        # PS 5.1 ConvertFrom-Json throws on the empty-string key inside usable_group; we only need data.
        $body = $body -replace ',"usable_group"\s*:\s*\{[^}]*\}', ''
        $json = $body | ConvertFrom-Json
        if (-not $json.success) { throw "Pricing API returned success=false.`n$body" }
        if ($null -eq $json.data) { throw "Pricing API returned no data." }
        return @($json.data)
    }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# ---------- config writers ----------

function Backup-File([string]$Path) {
    if (Test-Path $Path) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $backup = "$Path.backup-$stamp"
        Copy-Item $Path $backup -Force
        return $backup
    }
    return $null
}

function Ensure-Parent([string]$Path) {
    $dir = Split-Path $Path -Parent
    if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

function Load-JsonObject([string]$Path) {
    if (!(Test-Path $Path)) { return [PSCustomObject]@{} }
    $raw = Get-Content $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return [PSCustomObject]@{} }
    try { return $raw | ConvertFrom-Json }
    catch {
        throw "Cannot safely edit $Path because it is not strict JSON. If it is JSONC with comments, back it up and convert it to JSON first."
    }
}

function Set-Prop($Object, [string]$Name, $Value) {
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else { $Object.$Name = $Value }
}

function Save-Json($Object, [string]$Path) {
    Ensure-Parent $Path
    # BOM-less UTF-8 is required: the Claude Desktop app's JSON.parse rejects files
    # that start with a BOM (PowerShell 5.1's Set-Content -Encoding UTF8 adds one).
    $json = $Object | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-HermesModelSetup {
    $hermes = Get-Command hermes -ErrorAction SilentlyContinue
    if ($null -eq $hermes) {
        Write-Host "Hermes is not installed. Install Hermes first, then rerun this option." -ForegroundColor Yellow
        Pause-Screen
        return
    }

    Write-Host "Launching Hermes model setup. Complete prompts manually." -ForegroundColor Cyan
    & $hermes.Source model
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Hermes model setup exited with code $LASTEXITCODE." -ForegroundColor Yellow
    }
    Pause-Screen
}

function Configure-Claude([string]$BaseUrl, [string]$ApiKey, [string]$Model) {
    $claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME ".claude" }
    $path = Join-Path $claudeDir "settings.json"
    $backup = Backup-File $path
    $cfg = Load-JsonObject $path

    if ($null -eq $cfg.PSObject.Properties["env"]) { Set-Prop $cfg "env" ([PSCustomObject]@{}) }
    Set-Prop $cfg.env "ANTHROPIC_BASE_URL" (Normalize-BaseUrl $BaseUrl)
    Set-Prop $cfg.env "ANTHROPIC_AUTH_TOKEN" $ApiKey
    Set-Prop $cfg.env "ANTHROPIC_MODEL" $Model
    Set-Prop $cfg "model" $Model

    Save-Json $cfg $path
    return @{ Path=$path; Backup=$backup }
}

# The Claude Desktop Electron app runs in "3P" mode and reads its gateway
# settings from a managed config file in the configLibrary: the active entry is
# the JSON file named by configLibrary/_meta.json -> appliedId. Its schema:
#   inferenceProvider            = "gateway"
#   inferenceGatewayBaseUrl      = <base URL>
#   inferenceGatewayApiKey       = <api key>
#   inferenceGatewayAuthScheme   = "x-api-key" | "bearer" | "sso"
#   inferenceModels              = [ "model-id", ... ]
# We rewrite that entry (backed up first). The app picks it up on next launch.
function Configure-ClaudeDesktop([string]$BaseUrl, [string]$ApiKey, [string]$Model, [string]$AuthScheme) {
    $dir = Join-Path $env:LOCALAPPDATA "Claude-3p"
    $libraryDir = Join-Path $dir "configLibrary"
    $metaPath = Join-Path $libraryDir "_meta.json"
    if (!(Test-Path $metaPath)) {
        throw "Claude Desktop configLibrary not found at $metaPath. Install and launch the Claude Desktop app once so it initializes its config."
    }
    $meta = Load-JsonObject $metaPath
    $appliedId = [string]$meta.appliedId
    if ([string]::IsNullOrWhiteSpace($appliedId)) {
        throw "No appliedId in $metaPath. Open the Claude Desktop app once so it writes its active config entry."
    }
    $cfgPath = Join-Path $libraryDir "$appliedId.json"
    $backup = Backup-File $cfgPath
    $cfg = Load-JsonObject $cfgPath

    $scheme = if ($AuthScheme) { $AuthScheme } else { "x-api-key" }
    Set-Prop $cfg "inferenceProvider" "gateway"
    Set-Prop $cfg "inferenceGatewayBaseUrl" (Normalize-BaseUrl $BaseUrl)
    Set-Prop $cfg "inferenceGatewayApiKey" $ApiKey
    Set-Prop $cfg "inferenceGatewayAuthScheme" $scheme
    Set-Prop $cfg "inferenceModels" @($Model)

    Save-Json $cfg $cfgPath
    return @{ Path=$cfgPath; Backup=$backup }
}

function Configure-OpenCode([string]$BaseUrl, [string]$ApiKey, [string]$Model, [string]$ProviderKey, [string]$ProviderName, [string]$NpmPackage) {
    $path = Join-Path $HOME ".config\opencode\opencode.json"
    $backup = Backup-File $path
    $cfg = Load-JsonObject $path

    Set-Prop $cfg '$schema' "https://opencode.ai/config.json"
    if ($null -eq $cfg.PSObject.Properties["provider"]) { Set-Prop $cfg "provider" ([PSCustomObject]@{}) }

    $modelObj = [PSCustomObject]@{}
    Set-Prop $modelObj $Model ([PSCustomObject]@{ name = $Model })

    $provider = [PSCustomObject]@{
        npm = $NpmPackage
        name = $ProviderName
        options = [PSCustomObject]@{ baseURL = (Normalize-BaseUrl $BaseUrl); apiKey = $ApiKey }
        models = $modelObj
    }

    Set-Prop $cfg.provider $ProviderKey $provider
    Set-Prop $cfg "model" ("$ProviderKey/" + $Model)

    Save-Json $cfg $path
    return @{ Path=$path; Backup=$backup }
}

# Set a document-ROOT key. Root keys must precede the first [table] header,
# otherwise TOML parses them as members of that table (e.g. windows.model).
# We split the text at the first table header, edit only the root portion, and
# strip any stray copy of this key from inside the tables (self-heals configs
# an earlier version may have mis-written).
function Set-TomlValue([string]$Text, [string]$Key, [string]$Value) {
    $escaped = $Value -replace '\\', '\\\\' -replace '"', '\\"'
    $line = '{0} = "{1}"' -f $Key, $escaped
    $pattern = "(?m)^\s*" + [regex]::Escape($Key) + "\s*=.*$"

    $firstTable = [regex]::Match($Text, '(?m)^[ \t]*\[')
    if ($firstTable.Success) {
        $head = $Text.Substring(0, $firstTable.Index)
        $tail = $Text.Substring($firstTable.Index)
    } else {
        $head = $Text
        $tail = ""
    }

    # Remove any misplaced copy of this key from within the tables.
    $tail = [regex]::Replace($tail, "(?m)^[ \t]*" + [regex]::Escape($Key) + "[ \t]*=.*\r?\n?", "")

    if ($head -match $pattern) {
        $head = [regex]::Replace($head, $pattern, $line, 1)
    } else {
        if ($head -and !$head.EndsWith("`n")) { $head += "`r`n" }
        $head += $line + "`r`n"
    }
    return $head + $tail
}

# Same root-placement logic as Set-TomlValue, but writes the value verbatim
# (no quotes) for bare TOML values like booleans/numbers.
function Set-TomlBareValue([string]$Text, [string]$Key, [string]$Value) {
    $line = '{0} = {1}' -f $Key, $Value
    $pattern = "(?m)^\s*" + [regex]::Escape($Key) + "\s*=.*$"

    $firstTable = [regex]::Match($Text, '(?m)^[ \t]*\[')
    if ($firstTable.Success) {
        $head = $Text.Substring(0, $firstTable.Index)
        $tail = $Text.Substring($firstTable.Index)
    } else {
        $head = $Text
        $tail = ""
    }

    $tail = [regex]::Replace($tail, "(?m)^[ \t]*" + [regex]::Escape($Key) + "[ \t]*=.*\r?\n?", "")

    if ($head -match $pattern) {
        $head = [regex]::Replace($head, $pattern, $line, 1)
    } else {
        if ($head -and !$head.EndsWith("`n")) { $head += "`r`n" }
        $head += $line + "`r`n"
    }
    return $head + $tail
}

# Set a key INSIDE the [shell_environment_policy.set] table (not root). Codex
# exposes these vars to shells it spawns for tools. If the table is missing we
# append it; if the key exists there we replace it in place.
function Set-TomlEnvPolicyValue([string]$Text, [string]$Key, [string]$Value) {
    $escaped = $Value -replace '\\', '\\\\' -replace '"', '\\"'
    $line = '{0} = "{1}"' -f $Key, $escaped

    # Locate the [shell_environment_policy.set] table body (up to the next header).
    $tablePattern = "(?ms)^([ \t]*\[shell_environment_policy\.set\][ \t]*\r?\n)(.*?)(?=^\s*\[|\z)"
    $m = [regex]::Match($Text, $tablePattern)
    if ($m.Success) {
        $header = $m.Groups[1].Value
        $body = $m.Groups[2].Value
        $keyPattern = "(?m)^[ \t]*" + [regex]::Escape($Key) + "[ \t]*=.*$"
        if ($body -match $keyPattern) {
            $body = [regex]::Replace($body, $keyPattern, $line, 1)
        } else {
            if ($body -and !$body.EndsWith("`n")) { $body += "`r`n" }
            $body += $line + "`r`n"
        }
        return $Text.Substring(0, $m.Index) + $header + $body + $Text.Substring($m.Index + $m.Length)
    }

    # Table absent: append a fresh one at end of file.
    if ($Text -and !$Text.EndsWith("`n")) { $Text += "`r`n" }
    return $Text + "`r`n[shell_environment_policy.set]`r`n" + $line + "`r`n"
}

function Configure-Codex([string]$BaseUrl, [string]$ApiKey, [string]$Model, [string]$ProviderKey, [string]$ProviderName) {
    $dir = Join-Path $HOME ".codex"
    $authPath = Join-Path $dir "auth.json"
    $configPath = Join-Path $dir "config.toml"
    $authBackup = Backup-File $authPath
    $configBackup = Backup-File $configPath

    # The Codex desktop app gates on auth.json's auth_mode: while it's "chatgpt"
    # the app forces its built-in ChatGPT provider and ignores model_provider in
    # config.toml entirely. Switch to "apikey" and write BOTH key names the app
    # and CLI have used (OPEN_API_KEY, OPENAI_API_KEY).
    $auth = Load-JsonObject $authPath
    Set-Prop $auth "auth_mode" "apikey"
    Set-Prop $auth "OPEN_API_KEY" $ApiKey
    Set-Prop $auth "OPENAI_API_KEY" $ApiKey
    Save-Json $auth $authPath

    # Codex validates config.toml as all-or-nothing: ONE unsupported value makes
    # it discard the whole file and silently fall back to ChatGPT defaults. So a
    # built-in provider ID (openai) or a stale wire_api value breaks everything.
    $provider = if ($ProviderKey -and $ProviderKey -ne "openai") { $ProviderKey } else { "custom" }
    $providerName = if ($ProviderName) { $ProviderName } else { $provider }
    $envKey = ($provider.ToUpper() -replace '[^A-Z0-9]', '_') + "_API_KEY"

    $toml = if (Test-Path $configPath) { Get-Content $configPath -Raw } else { "" }
    $toml = Set-TomlValue $toml "model_provider" $provider
    $toml = Set-TomlValue $toml "model" $Model
    $toml = Set-TomlValue $toml "preferred_auth_method" "apikey"
    # bare (non-quoted) root key; Set-TomlValue only writes quoted strings, so
    # handle the boolean here but with the same root-vs-table placement rules.
    $toml = Set-TomlBareValue $toml "disable_response_storage" "true"

    $sectionPattern = "(?ms)^\s*\[model_providers\." + [regex]::Escape($provider) + "\]\s*.*?(?=^\s*\[|\z)"
    $section = @(
        "[model_providers.$provider]"
        "name = `"$ProviderName`""
        "base_url = `"$(Normalize-BaseUrl $BaseUrl)`""
        # Do NOT write wire_api: Codex defaults to the Responses API, and pinning
        # it (chat/responses) has caused config rejection or 404s per gateway.
        "env_key = `"$envKey`""
    ) -join "`r`n"
    $section += "`r`n"
    if ($toml -match $sectionPattern) { $toml = [regex]::Replace($toml, $sectionPattern, $section, 1) }
    else {
        if ($toml -and !$toml.EndsWith("`n")) { $toml += "`r`n" }
        $toml += "`r`n$section"
    }
    # Keep the key in [shell_environment_policy.set] too, so shells Codex spawns
    # for tools inherit it.
    $toml = Set-TomlEnvPolicyValue $toml $envKey $ApiKey
    $toml = [regex]::Replace($toml, '(?m)^\s*name\s*=\s*""\s*$', 'name = "custom"')
    Ensure-Parent $configPath
    Set-Content -Path $configPath -Value $toml -Encoding UTF8

    # env_key is resolved against the REAL process environment at Codex startup,
    # not the config's shell policy block. Persist a User env var so the provider
    # can find the key. (Takes effect only after the app is fully restarted.)
    [Environment]::SetEnvironmentVariable($envKey, $ApiKey, "User")
    [Environment]::SetEnvironmentVariable($envKey, $ApiKey, "Process")

    return @(
        @{ Path=$authPath; Backup=$authBackup }
        @{ Path=$configPath; Backup=$configBackup }
    )
}

# Merge a live-fetched list with a preset's curated fallback (deduped, sorted).
# Used so a gateway always shows its known-good models even when the live list
# is partial, and so a failed live fetch degrades to the curated list.
function Merge-Models {
    param($Live, $Curated)
    @( @($Live) + @($Curated) | Where-Object { $_ } | Sort-Object -Unique )
}

# Fetch the live model list for a preset, returning per-client lists.
# Presets with modelsApiUrl (AgentRouter) hit the public pricing JSON and split
# models by supported_endpoint_types; others (EuroModels, Custom) use /v1/models.
function Fetch-PresetModels {
    param($Preset, [string]$ApiKey)
    if ($Preset.modelsApiUrl) {
        $pricing = Get-AgentRouterPricingModels $Preset.modelsApiUrl
        $claude   = @($pricing | Where-Object { $_.supported_endpoint_types -contains "anthropic" } | ForEach-Object { [string]$_.model_name })
        $opencode = @($pricing | Where-Object { $_.supported_endpoint_types -contains "openai" }     | ForEach-Object { [string]$_.model_name })
        return [PSCustomObject]@{ claude = $claude; opencode = $opencode }
    }
    $list = Get-LiveModels $Preset.opencode.baseUrl $ApiKey
    return [PSCustomObject]@{ claude = $list; opencode = $list }
}

# ---------- model picker ----------

function Pick-Model {
    param([string[]]$Models, [bool]$CanRefresh, [string]$GatewayLabel, [string]$ClientLabel)
    $opts = @($Models) + "[ Enter custom model ID ]"
    if ($CanRefresh) { $opts += "[ Refresh model list ]" }
    $opts += "[ Back ]"
    $header = @("Gateway: $GatewayLabel", "Client: $ClientLabel", "Available: $($Models.Count)")
    $idx = Show-Menu -Title "Select Model" -Options $opts -Header $header
    if ($idx -eq -1) { return @{ Action="Cancel"; Model=$null } }
    if ($idx -lt $Models.Count) { return @{ Action="Selected"; Model=$Models[$idx] } }
    $choice = $opts[$idx]
    if ($choice -match "custom") {
        $m = (Read-Host "Enter exact model ID").Trim()
        if ($m) { return @{ Action="Selected"; Model=$m } }
        return @{ Action="Cancel"; Model=$null }
    }
    if ($choice -match "Refresh") { return @{ Action="Refresh"; Model=$null } }
    return @{ Action="Back"; Model=$null }
}

# Loops the model menu (handling Refresh) until a model is chosen or the user backs out.
function Choose-Model {
    param([string[]]$InitialModels, [bool]$CanRefresh, [string]$GatewayLabel, [string]$ClientLabel, $Preset, [string]$ApiKey, [string]$Client)
    $models = $InitialModels
    while ($true) {
        $pick = Pick-Model $models $CanRefresh $GatewayLabel $ClientLabel
        switch ($pick.Action) {
            "Selected" { return $pick.Model }
            "Refresh" {
                try {
                    $fresh = Fetch-PresetModels $Preset $ApiKey
                    $models = Merge-Models $fresh.$Client $Preset.$Client.curatedModels
                } catch {
                    Write-Host ""
                    Write-Host "Refresh failed: $($_.Exception.Message)" -ForegroundColor Red
                    Pause-Screen
                }
                continue
            }
            default { return $null }  # Back / Cancel
        }
    }
}

# ---------- current config view ----------

function Show-Current {
    Clear-Host
    Write-Banner "Current Configuration"

    $claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME ".claude" }
    $cp = Join-Path $claudeDir "settings.json"
    Write-Host "  Claude Code: $cp" -ForegroundColor Gray
    $c = $null
    if (Test-Path $cp) {
        try {
            $c = Get-Content $cp -Raw | ConvertFrom-Json
            Write-Host "    Base URL: $($c.env.ANTHROPIC_BASE_URL)"
            Write-Host "    Model:    $($c.model)"
            Write-Host "    API Key:  $(Mask-Key ([string]$c.env.ANTHROPIC_AUTH_TOKEN))"
        } catch { Write-Host "    Could not parse config." -ForegroundColor Yellow }
    } else { Write-Host "    No config found." -ForegroundColor DarkGray }
    # Claude Code also reads OS env vars; show what it actually inherits, and flag any divergence.
    $osBase = $env:ANTHROPIC_BASE_URL
    if ($osBase) {
        $same = ($osBase -eq [string]$c.env.ANTHROPIC_BASE_URL)
        $osTag = if ($same) { "matches settings.json" } else { "DIFFERS from settings.json" }
        $osColor = if ($same) { "DarkGray" } else { "Yellow" }
        Write-Host "    OS env:   ANTHROPIC_BASE_URL=$osBase ($osTag)" -ForegroundColor $osColor
        if ($env:ANTHROPIC_MODEL) { Write-Host "              ANTHROPIC_MODEL=$($env:ANTHROPIC_MODEL)" -ForegroundColor DarkGray }
    }

    Write-Host ""
    $osVars = @("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL", "OPENAI_API_KEY")
    Write-Host "  Windows environment variables" -ForegroundColor Gray
    foreach ($name in $osVars) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { Write-Host "    $name=$(if ($name -match 'KEY|TOKEN') { Mask-Key $value } else { $value })" }
    }

    Write-Host ""
    Write-Host "  Claude Desktop: 3P gateway config" -ForegroundColor Gray
    $cdDir = Join-Path $env:LOCALAPPDATA "Claude-3p"
    $cdMeta = Join-Path $cdDir "configLibrary\_meta.json"
    if (Test-Path $cdMeta) {
        try {
            $cdM = Get-Content $cdMeta -Raw | ConvertFrom-Json
            $cdId = [string]$cdM.appliedId
            $cdCfgPath = Join-Path $cdDir "configLibrary\$cdId.json"
            if ($cdId -and (Test-Path $cdCfgPath)) {
                $cdCfg = Get-Content $cdCfgPath -Raw | ConvertFrom-Json
                Write-Host "    Config: $cdCfgPath"
                Write-Host "    Base URL:    $($cdCfg.inferenceGatewayBaseUrl)"
                Write-Host "    Auth scheme: $($cdCfg.inferenceGatewayAuthScheme)"
                Write-Host "    API Key:     $(Mask-Key ([string]$cdCfg.inferenceGatewayApiKey))"
                $models = @($cdCfg.inferenceModels | Where-Object { $_ })
                if ($models.Count -gt 0) { Write-Host "    Models:      $($models -join ', ')" }
            } else {
                Write-Host "    No active config entry (appliedId missing or file absent)." -ForegroundColor DarkGray
            }
        } catch { Write-Host "    Could not parse Claude Desktop config." -ForegroundColor Yellow }
    } else {
        Write-Host "    No configLibrary found (Claude Desktop not installed or not launched)." -ForegroundColor DarkGray
    }

    $op = Join-Path $HOME ".config\opencode\opencode.json"
    Write-Host "  OpenCode: $op" -ForegroundColor Gray
    if (Test-Path $op) {
        try {
            $o = Get-Content $op -Raw | ConvertFrom-Json
            $allProvs = @($o.provider.PSObject.Properties)
            $prefix = ($o.model -split "/")[0]
            $active = $allProvs | Where-Object { $_.Name -eq $prefix }
            if ($active) {
                Write-Host "    Provider: $($active.Name) (active)"
                Write-Host "    Base URL: $($active.Value.options.baseURL)"
                Write-Host "    Model:    $($o.model)"
                Write-Host "    API Key:  $(Mask-Key ([string]$active.Value.options.apiKey))"
                $others = @($allProvs | Where-Object { $_.Name -ne $prefix })
                if ($others.Count -gt 0) {
                    $names = ($others | ForEach-Object { $_.Name }) -join ", "
                    Write-Host "    Also configured (inactive): $names" -ForegroundColor DarkGray
                }
            } else {
                Write-Host "    Model:    $($o.model)" -ForegroundColor Yellow
                Write-Host "    No provider matches model prefix '$prefix'." -ForegroundColor Yellow
            }
        } catch { Write-Host "    Could not parse config." -ForegroundColor Yellow }
    } else { Write-Host "    No config found." -ForegroundColor DarkGray }

    $codexDir = Join-Path $HOME ".codex"
    $codexAuth = Join-Path $codexDir "auth.json"
    $codexConfig = Join-Path $codexDir "config.toml"
    Write-Host ""
    Write-Host "  Codex: $codexDir" -ForegroundColor Gray
    if (Test-Path $codexAuth) {
        try {
            $ca = Get-Content $codexAuth -Raw | ConvertFrom-Json
            $key = $ca.OPENAI_API_KEY
            if (!$key -and $ca.tokens) { $key = $ca.tokens.access_token }
            Write-Host "    auth.json API Key: $(Mask-Key ([string]$key))"
        } catch { Write-Host "    Could not parse auth.json." -ForegroundColor Yellow }
    } else { Write-Host "    No auth.json found." -ForegroundColor DarkGray }
    if (Test-Path $codexConfig) {
        Write-Host "    config.toml: $codexConfig"
        $toml = Get-Content $codexConfig -Raw
        $modelLine = [regex]::Match($toml, '(?m)^\s*model\s*=\s*"([^"]+)"').Groups[1].Value
        $providerLine = [regex]::Match($toml, '(?m)^\s*model_provider\s*=\s*"([^"]+)"').Groups[1].Value
        if ($modelLine) { Write-Host "      Model: $modelLine" }
        if ($providerLine) { Write-Host "      Provider: $providerLine" }
    } else { Write-Host "    No config.toml found." -ForegroundColor DarkGray }

    $hermesCandidates = @(
        (Join-Path $HOME ".hermes\config.toml"),
        (Join-Path $HOME ".config\hermes\config.toml"),
        (Join-Path $HOME ".config\hermes\config.json")
    ) | Where-Object { Test-Path $_ }
    if ($hermesCandidates.Count -gt 0) {
        Write-Host "    Hermes config: $($hermesCandidates -join ', ')" -ForegroundColor DarkGray
    }
    Pause-Screen
}

# ---------- presets ----------

function Load-Presets {
    $path = Join-Path $PSScriptRoot "AI-Config-Presets.json"
    if (!(Test-Path $path)) {
        Write-Host "Preset file not found: $path" -ForegroundColor Red
        exit 1
    }
    try { return (Get-Content $path -Raw | ConvertFrom-Json).presets }
    catch {
        Write-Host "Preset file is invalid JSON: $path" -ForegroundColor Red
        exit 1
    }
}

function New-CustomPreset([string]$Url) {
    [PSCustomObject]@{
        label = "Custom"
        dashboard = $null
        fetchModels = $true
        claude    = [PSCustomObject]@{ baseUrl = $Url; curatedModels = @() }
        opencode  = [PSCustomObject]@{ baseUrl = $Url; providerKey = "custom"; providerName = "Custom"; npmPackage = "@ai-sdk/openai-compatible"; curatedModels = @() }
    }
}

function Load-DotEnv {
    $paths = @(
        (Join-Path $PSScriptRoot ".env"),
        (Join-Path $PSScriptRoot ".env.local")
    )
    foreach ($path in $paths) {
        if (Test-Path $path) {
            Get-Content $path | ForEach-Object {
                $line = $_.Trim()
                if ($line -and !$line.StartsWith("#") -and $line.Contains("=")) {
                    $parts = $line.Split("=", 2)
                    $k = $parts[0].Trim()
                    $v = $parts[1].Trim().Trim('"').Trim("'")
                    if ($k -and $v) {
                        [Environment]::SetEnvironmentVariable($k, $v, "Process")
                    }
                }
            }
        }
    }
}

Load-DotEnv

if ([Console]::IsInputRedirected) {
    Write-Host "This TUI requires an interactive terminal. Run it directly, not piped." -ForegroundColor Red
    exit 1
}

$presets = Load-Presets

while ($true) {
    $targetIdx = Show-Menu -Title "AI Config Manager" -Options @(
        "Configure Claude Code",
        "Configure OpenCode",
        "Configure Codex",
        "Configure Hermes Desktop",
        "Configure Claude Desktop",
        "Configure Both (Claude Code + OpenCode)",
        "View current configuration",
        "Exit"
    )
    if ($targetIdx -eq -1 -or $targetIdx -eq 7) { break }
    if ($targetIdx -eq 6) { Show-Current; continue }
    if ($targetIdx -eq 3) { Invoke-HermesModelSetup; continue }

    $doClaude = $targetIdx -in 0,5
    $doOpenCode = $targetIdx -in 1,5
    $doCodex = $targetIdx -eq 2
    $doClaudeDesktop = $targetIdx -eq 4

    $gwOpts = @($presets | ForEach-Object { $_.label }) + "[ Custom base URL ]"
    $gwIdx = Show-Menu -Title "Select Gateway" -Options $gwOpts
    if ($gwIdx -eq -1) { continue }

    if ($gwIdx -lt $presets.Count) {
        $preset = $presets[$gwIdx]
    } else {
        while ($true) {
            $u = Normalize-BaseUrl ((Read-Host "Enter custom Base URL").Trim())
            if ($u -match "^https?://") { $preset = New-CustomPreset $u; break }
            Write-Host "Enter a full http:// or https:// URL." -ForegroundColor Yellow
        }
    }

    # Never pass the reserved built-in ID "openai" as a provider key — Codex
    # rejects the whole config if a custom provider reuses a built-in ID.
    $codexProviderKey = if ($preset.codex -and $preset.codex.providerKey) { $preset.codex.providerKey } elseif ($preset.id) { $preset.id } elseif ($preset.opencode -and $preset.opencode.providerKey) { $preset.opencode.providerKey } else { $null }
    $codexProviderName = if ($preset.codex -and $preset.codex.providerName) { $preset.codex.providerName } elseif ($preset.label) { $preset.label } elseif ($preset.opencode -and $preset.opencode.providerName) { $preset.opencode.providerName } else { $null }
    if ($doCodex -and [string]::IsNullOrWhiteSpace($codexProviderKey)) {
        while ([string]::IsNullOrWhiteSpace($codexProviderKey)) {
            $codexProviderKey = (Read-Host "Codex provider key (for [model_providers.<key>])").Trim()
        }
        while ([string]::IsNullOrWhiteSpace($codexProviderName)) {
            $codexProviderName = (Read-Host "Codex provider display name").Trim()
        }
    }

    $envVarName = if ($codexProviderKey) { ($codexProviderKey.ToUpper() -replace '[^A-Z0-9]', '_') + "_API_KEY" } else { "CUSTOM_API_KEY" }
    $envDefaultKey = [Environment]::GetEnvironmentVariable($envVarName, "Process")
    if ([string]::IsNullOrWhiteSpace($envDefaultKey)) { $envDefaultKey = $env:CUSTOM_API_KEY }

    Clear-Host
    Write-Banner "API Key - $($preset.label)"
    if ($preset.dashboard) {
        Write-Host "  Get a key at: $($preset.dashboard)" -ForegroundColor DarkGray
        Write-Host ""
    }
    if ($envDefaultKey) {
        Write-Host "  Found pre-saved key in .env / environment: $(Mask-Key $envDefaultKey)" -ForegroundColor Green
        Write-Host "  (Press Enter to use pre-saved key, or type a new key below)" -ForegroundColor DarkGray
        Write-Host ""
    }
    $apiKey = Read-SecretPlain
    if ([string]::IsNullOrWhiteSpace($apiKey) -and $envDefaultKey) {
        $apiKey = $envDefaultKey
    }
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-Host "API key cannot be empty." -ForegroundColor Red
        Pause-Screen
        continue
    }

    $live = $null
    $fetchOk = $false
    if ($preset.fetchModels) {
        try {
            $live = Fetch-PresetModels $preset $apiKey
            $fetchOk = $true
        } catch {
            $hasCurated = ($preset.claude.curatedModels.Count -gt 0 -or $preset.opencode.curatedModels.Count -gt 0)
            if ($hasCurated) {
                Write-Host ""
                Write-Host "Live model list unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "Showing known models instead." -ForegroundColor DarkGray
            } else {
                Write-Host ""
                Write-Host "Could not fetch models:" -ForegroundColor Red
                Write-Host $_.Exception.Message -ForegroundColor Yellow
                Write-Host ""
                Write-Host "Tip: the script requests $(Get-ModelsEndpoint $preset.opencode.baseUrl). If that's wrong, choose Custom base URL." -ForegroundColor DarkGray
                Pause-Screen
                continue
            }
        }
    }
    $canRefresh = $fetchOk
    $liveClaude = if ($live) { $live.claude } else { $null }
    $liveOpenCode = if ($live) { $live.opencode } else { $null }

    while ($true) {
        $claudeModel = $null
        $opencodeModel = $null
        $codexModel = $null
        $claudeDesktopModel = $null

        if ($doClaude -or $doClaudeDesktop) {
            $cm = Merge-Models $liveClaude $preset.claude.curatedModels
            if ($doClaude) {
                $claudeModel = Choose-Model $cm $canRefresh $preset.label "Claude Code" $preset $apiKey "claude"
                if (!$claudeModel) { break }
            }
            if ($doClaudeDesktop) {
                $claudeDesktopModel = Choose-Model $cm $canRefresh $preset.label "Claude Desktop" $preset $apiKey "claude"
                if (!$claudeDesktopModel) { break }
            }
        }
        if ($doOpenCode -or $doCodex) {
            $om = Merge-Models $liveOpenCode $preset.opencode.curatedModels
            if ($doOpenCode) {
                $opencodeModel = Choose-Model $om $canRefresh $preset.label "OpenCode" $preset $apiKey "opencode"
                if (!$opencodeModel) { break }
            }
            if ($doCodex) {
                $codexModel = Choose-Model $om $canRefresh $preset.label "Codex" $preset $apiKey "opencode"
                if (!$codexModel) { break }
            }
        }

        $summary = @()
        $targetName = if ($doClaude -and $doOpenCode) { 'Claude Code + OpenCode' } elseif ($doClaude) { 'Claude Code' } elseif ($doClaudeDesktop) { 'Claude Desktop' } elseif ($doCodex) { 'Codex' } else { 'OpenCode' }
        $summary += "Target:  $targetName"
        $summary += "Gateway: $($preset.label)"
        if ($doClaude)          { $summary += "Claude model:        $claudeModel" }
        if ($doClaudeDesktop)   { $summary += "Claude Desktop model:$claudeDesktopModel" }
        if ($doOpenCode)        { $summary += "OpenCode model:      $opencodeModel" }
        if ($doCodex)           { $summary += "Codex model:         $codexModel" }
        $summary += "API Key: $(Mask-Key $apiKey)"

        $cIdx = Show-Menu -Title "Confirm" -Options @(
            "Apply configuration",
            "Choose another model",
            "Cancel"
        ) -Header $summary

        if ($cIdx -eq 1 -or $cIdx -eq -1) { continue }
        if ($cIdx -eq 2) { break }

        try {
            Write-Host ""
            if ($doClaude) {
                $r = Configure-Claude $preset.claude.baseUrl $apiKey $claudeModel
                Write-Host "[OK] Claude Code configured" -ForegroundColor Green
                Write-Host "     $($r.Path)"
                if ($r.Backup) { Write-Host "     Backup: $($r.Backup)" -ForegroundColor DarkGray }
            }
            if ($doClaudeDesktop) {
                $r = Configure-ClaudeDesktop $preset.claude.baseUrl $apiKey $claudeDesktopModel
                Write-Host "[OK] Claude Desktop configured (3P gateway config)" -ForegroundColor Green
                Write-Host "     $($r.Path)"
                if ($r.Backup) { Write-Host "     Backup: $($r.Backup)" -ForegroundColor DarkGray }
                Write-Host ""
                Write-Host "  Next steps in the Claude Desktop app:" -ForegroundColor Cyan
                Write-Host "  1. Fully quit and reopen the app (tray icon > Quit, not just close window)" -ForegroundColor Gray
                Write-Host "  2. If a setup/login screen appears, open the app menu (top-left) > Developer >" -ForegroundColor Gray
                Write-Host "     Configure Third-Party Inference to verify the gateway config loaded" -ForegroundColor Gray
                Write-Host "  3. The gateway base URL, API key, and model are pre-configured by this script" -ForegroundColor Gray
                Write-Host "  4. If the model list looks wrong, the model IDs must match what your gateway" -ForegroundColor Gray
                Write-Host "     expects (each gateway uses its own model ID format)" -ForegroundColor Gray
            }
            if ($doOpenCode) {
                $r = Configure-OpenCode $preset.opencode.baseUrl $apiKey $opencodeModel $preset.opencode.providerKey $preset.opencode.providerName $preset.opencode.npmPackage
                Write-Host "[OK] OpenCode configured" -ForegroundColor Green
                Write-Host "     $($r.Path)"
                if ($r.Backup) { Write-Host "     Backup: $($r.Backup)" -ForegroundColor DarkGray }
                if ($preset.id -eq "agentrouter") {
                    Write-Host "     If OpenCode rejects the key, run: opencode providers login --provider agentrouter" -ForegroundColor DarkGray
                }
            }
            if ($doCodex) {
                # Codex appends /responses to base_url, so AgentRouter needs the
                # root host (not /v1). Presets provide codex.baseUrl for this;
                # fall back to opencode.baseUrl for presets/custom without one.
                $codexBaseUrl = if ($preset.codex -and $preset.codex.baseUrl) { $preset.codex.baseUrl } else { $preset.opencode.baseUrl }
                $results = Configure-Codex $codexBaseUrl $apiKey $codexModel $codexProviderKey $codexProviderName
                Write-Host "[OK] Codex configured" -ForegroundColor Green
                foreach ($item in $results) {
                    Write-Host "     $($item.Path)"
                    if ($item.Backup) { Write-Host "     Backup: $($item.Backup)" -ForegroundColor DarkGray }
                }
            }
            Write-Host ""
            Write-Host "Configuration complete." -ForegroundColor Green
            Write-Host "Close existing Claude Code, OpenCode, or Codex sessions and start a new terminal session."
        } catch {
            Write-Host ""
            Write-Host "Configuration failed:" -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Yellow
        }
        Pause-Screen
        break
    }
}
