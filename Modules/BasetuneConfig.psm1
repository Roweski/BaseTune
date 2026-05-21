# =============================================================================
# BasetuneConfig.psm1
# =============================================================================

# Get-TenantMode lives in BasetuneHelpers.psm1 — it's used by both CLI and UI
# and has no WPF dependencies, so it belongs in the shared helpers module.

# ── Helpers: dropdown population ─────────────────────────────────────────────
function script:Add-TenantItemsToDropdown {
    param($Cmb, [string]$SelectTag, [switch]$HideDefaultIfTenants)
    if (-not $Cmb) { return }
    $Cmb.Items.Clear()
    foreach ($key in (Get-SortedTenantKeys)) {
        $node      = $global:tenantStore[$key]
        $label     = if ($node.displayName) { $node.displayName } else { $key }
        $isOffline = $node.authMethod -eq 'None' -or -not $node.authMethod
        $display   = if ($isOffline) { "$label (JSON)" } else { $label }
        $Cmb.Items.Add((New-TenantComboItem $display $key $isOffline)) | Out-Null
    }
    if ($SelectTag) {
        Select-ComboByTag $Cmb $SelectTag | Out-Null
    } elseif ($Cmb.Items.Count -gt 0) {
        $Cmb.SelectedIndex = 0
    }
}

function script:New-TenantComboItem {
    param([string]$Content, [string]$Tag, [bool]$Gray = $false)
    $item = [System.Windows.Controls.ComboBoxItem]::new()
    $item.Content = $Content
    $item.Tag     = $Tag
    if ($Gray) { $item.Foreground = [System.Windows.Media.Brushes]::Gray }
    return $item
}

function script:Get-SortedTenantKeys {
    return $global:tenantStore.Keys | Sort-Object {
        $n = $global:tenantStore[$_]
        if ($n -and $n.PSObject.Properties['displayName'] -and $n.displayName) { $n.displayName } else { $_ }
    }
}

# ── Key generation (numeric) ─────────────────────────────────────────────────
function New-TenantKey {
    # Returns the next available integer key (1, 2, 3, …)
    $existingNums = @($global:tenantStore.Keys | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    $next = 1
    while ($existingNums -contains $next) { $next++ }
    return "$next"
}

# ── Required label helpers ────────────────────────────────────────────────────
function script:Show-Required {
    param([string]$Name)
    $ctrl = $global:requiredLabels[$Name]
    if ($ctrl) { $ctrl.Visibility = 'Visible' }
}

function script:Hide-Required {
    param([string]$Name)
    $ctrl = $global:requiredLabels[$Name]
    if ($ctrl) { $ctrl.Visibility = 'Collapsed' }
}

function script:Show-PathNotFound {
    param([string]$Name)
    $ctrl = $global:requiredLabels[$Name]
    if ($ctrl) {
        $ctrl.Text       = 'Path not found'
        $ctrl.Visibility = 'Visible'
    }
}

function Clear-RequiredLabels {
    if (-not $global:requiredLabels) { return }
    foreach ($ctrl in $global:requiredLabels.Values) {
        if ($ctrl) { $ctrl.Text = 'Required'; $ctrl.Visibility = 'Collapsed' }
    }
}

# ── Load config ───────────────────────────────────────────────────────────────
function Load-ConfigUI {
    $configPath = "$global:ScriptRoot\Config\Config.json"
    $global:tenantStore.Clear()

    if (Test-Path $configPath) {
        try {
            $global:cfg = Get-GraphConfig $configPath

            $cfgMaxThreads = if ($global:cfg.PSObject.Properties['settings'] -and $global:cfg.settings -and
                                  $global:cfg.settings.PSObject.Properties['maxthreads'] -and $global:cfg.settings.maxthreads) {
                $global:cfg.settings.maxthreads } else { $null }
            if ($cfgMaxThreads) {
                $global:savedMaxThreads = "$cfgMaxThreads"
            }

            $cfgPaths = if ($global:cfg.PSObject.Properties['settings'] -and $global:cfg.settings -and
                             $global:cfg.settings.PSObject.Properties['path'] -and $global:cfg.settings.path) {
                $global:cfg.settings.path } else { $null }

            if ($cfgPaths -and $cfgPaths.PSObject.Properties['report'] -and $cfgPaths.report -and $cfgPaths.report.Trim()) {
                $global:reportBasePath  = $cfgPaths.report.Trim()
                $global:savedPathReport = $cfgPaths.report.Trim()
            } else {
                $global:savedPathReport = $global:reportBasePath
            }

            if ($global:cfg.PSObject.Properties['tenant'] -and $global:cfg.tenant) {
                foreach ($prop in $global:cfg.tenant.PSObject.Properties) {
                    $global:tenantStore[$prop.Name] = $prop.Value
                }
            }
        } catch {
            $msg = "[ERROR][Config] Failed to load Config.json: $($_.Exception.Message)"
            try { Write-Log $msg } catch { Write-Host $msg }
        }
    }

    Update-ConfigDropdowns
}

# ── Dropdowns ─────────────────────────────────────────────────────────────────
function Update-ConfigDropdowns {
    if ($global:lstTenants) {
        $sel = if ($global:editingTenantKey) { $global:editingTenantKey } else { '' }
        Add-TenantItemsToDropdown $global:lstTenants $sel
    }
}

function Sync-MainTenantDropdowns {
    param([string]$PreferSrcTag = '', [string]$PreferTgtTag = '')
    $selSrc = if ($PreferSrcTag -and $global:tenantStore.Contains($PreferSrcTag)) { $PreferSrcTag } else { '' }
    $selTgt = if ($PreferTgtTag -and $global:tenantStore.Contains($PreferTgtTag)) { $PreferTgtTag } else { '' }
    Add-TenantItemsToDropdown $global:cmbSourceTenant $selSrc
    Add-TenantItemsToDropdown $global:cmbTargetTenant $selTgt
    $global:tenantList = @($global:tenantStore.Keys | ForEach-Object {
        $k = $_; $n = $global:tenantStore[$k]
        [PSCustomObject]@{ Key = $k; Label = if ($n.displayName) { $n.displayName } else { $k }; Node = $n }
    })
}

function Select-ComboByTag {
    param($Cmb, [string]$Tag)
    if (-not $Cmb) { return $false }
    foreach ($item in $Cmb.Items) {
        if ($item.Tag -eq $Tag) { $Cmb.SelectedItem = $item; return $true }
    }
    return $false
}

# ── Secret form helpers (PasswordBox + reveal TextBox) ───────────────────────
# The tenant Client Secret field is two overlapping controls in the XAML:
#   - $cfgTenantClientSecret      : PasswordBox  (masked, default visible)
#   - $cfgTenantClientSecretShown : TextBox       (plain, hidden by default)
# The reveal-toggle ($btnRevealSecret) swaps which one is visible. These
# helpers hide the dual-control detail from the rest of the module.
#
# Read rule: the visible control wins. If user revealed and edited, we read
# the TextBox; otherwise we read the PasswordBox.
# Write rule: writing sets BOTH controls so the reveal-toggle is consistent
# whichever direction the user flips it.
function script:Get-TenantSecretFromForm {
    if ($global:cfgTenantClientSecretShown -and
        $global:cfgTenantClientSecretShown.Visibility -eq 'Visible') {
        return [string]$global:cfgTenantClientSecretShown.Text
    }
    if ($global:cfgTenantClientSecret) {
        return [string]$global:cfgTenantClientSecret.Password
    }
    return ''
}

function script:Set-TenantSecretInForm {
    param([string]$Value)
    if ($global:cfgTenantClientSecret) {
        $global:cfgTenantClientSecret.Password = [string]$Value
    }
    if ($global:cfgTenantClientSecretShown) {
        $global:cfgTenantClientSecretShown.Text = [string]$Value
    }
}

function script:Clear-TenantSecretInForm {
    if ($global:cfgTenantClientSecret)      { $global:cfgTenantClientSecret.Password = '' }
    if ($global:cfgTenantClientSecretShown) { $global:cfgTenantClientSecretShown.Text = '' }
}

# ── Validate + commit form ────────────────────────────────────────────────────
function Commit-TenantForm {

    if (-not $global:cfgTenantDisplayName) { return $true }
    if ($global:pnlTenantForm -and $global:pnlTenantForm.Visibility -ne 'Visible') { return $true }

    Clear-RequiredLabels

    $valid = $true

    $label = $global:cfgTenantDisplayName.Text.Trim()
    if (-not $label -or $label -match '[\\/:*?"<>|]') {
        Show-Required 'DisplayName'
        if (-not $global:cfgTenantDisplayName.IsFocused) {
            $global:cfgTenantDisplayName.Focus() | Out-Null
        }
        $valid = $false
    }

    $authSel = if ($global:cfgTenantAuthMethod.SelectedItem) {
        $global:cfgTenantAuthMethod.SelectedItem.Content } else { 'ClientSecret' }
    $authMethod = switch ($authSel) {
        'Certificate' { 'Certificate' }
        'None (JSON)' { 'None' }
        default       { 'ClientSecret' }
    }

    if ($authMethod -ne 'None') {
        if (-not $global:cfgTenantTenantId.Text.Trim())  { Show-Required 'TenantId';     $valid = $false }
        if (-not $global:cfgTenantClientId.Text.Trim())  { Show-Required 'ClientId';     $valid = $false }
        if ($authMethod -eq 'ClientSecret' -and -not (Get-TenantSecretFromForm).Trim()) {
            Show-Required 'ClientSecret'; $valid = $false
        }
        if ($authMethod -eq 'Certificate' -and -not $global:cfgTenantCertThumbprint.Text.Trim()) {
            Show-Required 'CertThumb'; $valid = $false
        }
    } else {
        if (-not $global:cfgTenantPath.Text.Trim()) { Show-Required 'JsonPath'; $valid = $false }
    }

    if (-not $valid) { return $false }

    $key = if ($global:editingTenantKey) {
        $global:editingTenantKey
    } else {
        New-TenantKey
    }

    $node = [ordered]@{ displayName = $label; authMethod = $authMethod }
    if ($authMethod -ne 'None') {
        $node.tenantId = $global:cfgTenantTenantId.Text.Trim()
        $node.clientId = $global:cfgTenantClientId.Text.Trim()
        if ($authMethod -eq 'ClientSecret') {
            # Plaintext at this layer — Save-Config encrypts before writing
            # to disk. See Get-TenantSecretFromForm for the dual-control
            # (PasswordBox + reveal TextBox) read logic.
            $node.clientSecret = (Get-TenantSecretFromForm).Trim()
        } else {
            $node.certThumbprint = $global:cfgTenantCertThumbprint.Text.Trim()
        }
    } else {
        $typedPath = $global:cfgTenantPath.Text.Trim()
        if (-not $typedPath) { Show-Required 'JsonPath'; return $false }
        if (-not [System.IO.Path]::IsPathRooted($typedPath)) { Show-PathNotFound 'JsonPath'; return $false }
        $isExisting = [bool]$global:editingTenantKey
        if ($isExisting) {
            # For an existing tenant, the path must already exist — don't silently
            # create it. If it's gone (renamed, deleted, wrong) the user needs to
            # fix the path consciously.
            if (-not (Test-Path $typedPath)) { Show-PathNotFound 'JsonPath'; return $false }
        } else {
            # New tenant — create the folder if it doesn't exist yet.
            try { New-Item -ItemType Directory -Path $typedPath -Force | Out-Null } catch { Show-PathNotFound 'JsonPath'; return $false }
        }
        $node.path = $typedPath
    }

    $global:tenantStore[$key] = $node
    $global:editingTenantKey  = $key
    return $true
}

# ── Save ──────────────────────────────────────────────────────────────────────
function Save-Config {
    $configPath = "$global:ScriptRoot\Config\Config.json"
    $configDir  = Split-Path $configPath
    $maxT       = if ($global:savedMaxThreads -match '^\d+$') { [int]$global:savedMaxThreads } else { 8 }
    $pathReport  = if ($global:savedPathReport  -and $global:savedPathReport.Trim())  { $global:savedPathReport.Trim()  } else { $global:reportBasePath }

    $out = [ordered]@{
        settings = [ordered]@{
            maxthreads = $maxT
            path = [ordered]@{ report = $pathReport }
        }
    }

    # Build the tenants block. Important: $global:tenantStore holds PLAINTEXT
    # secrets (decrypted at load by Get-GraphConfig). We must encrypt every
    # ClientSecret tenant before writing to disk.
    #
    # We rebuild each node as a fresh ordered hashtable so we don't mutate the
    # in-memory store — the rest of the session keeps working against plaintext.
    $tenantsObj = [ordered]@{}
    foreach ($k in $global:tenantStore.Keys) {
        $src = $global:tenantStore[$k]
        if ($src -is [System.Collections.IDictionary]) {
            $dst = [ordered]@{}
            foreach ($key in $src.Keys) { $dst[$key] = $src[$key] }
        } else {
            # PSCustomObject (loaded from JSON) — convert to ordered hashtable
            $dst = [ordered]@{}
            foreach ($p in $src.PSObject.Properties) {
                if ($p.Name.StartsWith('__')) { continue }   # skip __invalid etc.
                $dst[$p.Name] = $p.Value
            }
        }

        # Encrypt clientSecret for storage. Empty/missing secrets stay empty
        # (decrypt-failure case: user copied config from another machine and
        # hasn't re-entered the secret yet). Already-encrypted values get
        # re-encrypted as-is — Protect-Secret on a plaintext is the only path.
        if ($dst['authMethod'] -eq 'ClientSecret' -and $dst['clientSecret']) {
            try {
                $dst['clientSecret'] = Protect-Secret ([string]$dst['clientSecret'])
            } catch {
                Write-Log 'Config' "Failed to encrypt clientSecret for tenant '$($dst['displayName'])': $($_.Exception.Message)" 'ERROR'
            }
        }

        $tenantsObj[$k] = $dst
    }
    $out['tenant'] = $tenantsObj

    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    $out | ConvertTo-Json -Depth 8 | Out-File $configPath -Encoding UTF8
    try { $global:cfg = Get-GraphConfig $configPath } catch {}
}

# ── Form state ────────────────────────────────────────────────────────────────
function Show-TenantForm {
    param([switch]$IsNew)
    if ($global:pnlTenantForm)   { $global:pnlTenantForm.Visibility   = 'Visible' }
    if ($global:pnlDefaultPaths) { $global:pnlDefaultPaths.Visibility = 'Collapsed' }
    if ($global:btnRemoveTenant) {
        $global:btnRemoveTenant.IsEnabled = -not $IsNew
    }
    Clear-RequiredLabels
    Update-TenantAuthFields
}

function Hide-TenantForm {
    if ($global:pnlTenantForm)   { $global:pnlTenantForm.Visibility   = 'Collapsed' }
    if ($global:pnlDefaultPaths) { $global:pnlDefaultPaths.Visibility = 'Visible' }
    if ($global:btnRemoveTenant) { $global:btnRemoveTenant.IsEnabled = $false }
    Clear-RequiredLabels
}

# ── Auth field visibility ─────────────────────────────────────────────────────
function Update-TenantAuthFields {
    $sel      = if ($global:cfgTenantAuthMethod.SelectedItem) {
        $global:cfgTenantAuthMethod.SelectedItem.Content } else { 'ClientSecret' }
    $isSecret = $sel -eq 'ClientSecret'
    $isCert   = $sel -eq 'Certificate'
    $isNone   = $sel -eq 'None (JSON)'

    $credVis = if ($isNone) { 'Collapsed' } else { 'Visible' }
    $global:pnlTenantId.Visibility   = $credVis
    $global:pnlClientId.Visibility   = $credVis
    $global:pnlCredential.Visibility = $credVis

    # ── ClientSecret controls ────────────────────────────────────────────────
    # The secret field is dual-control: PasswordBox (cfgTenantClientSecret)
    # masked by default, and TextBox (cfgTenantClientSecretShown) for the
    # reveal-toggle. When auth method != ClientSecret, BOTH halves and the
    # reveal-eye must be collapsed — otherwise the unmasked TextBox or the
    # eye button stays floating in the right column and pushes / overlaps
    # the Certificate Thumbprint controls (which live in the same StackPanel).
    $global:lblTenantSecret.Visibility        = if ($isSecret) { 'Visible' } else { 'Collapsed' }
    $global:cfgTenantClientSecret.Visibility  = if ($isSecret) { 'Visible' } else { 'Collapsed' }
    if ($global:cfgTenantClientSecretShown -and -not $isSecret) {
        # Always collapse the unmasked TextBox when we leave ClientSecret mode.
        # If reveal was previously active it would otherwise keep occupying the
        # row and push the Thumbprint field out of the card.
        $global:cfgTenantClientSecretShown.Visibility = 'Collapsed'
    }
    if ($global:btnRevealSecret) {
        $global:btnRevealSecret.Visibility = if ($isSecret) { 'Visible' } else { 'Collapsed' }
    }

    $global:cfgTenantCertThumbprint.Visibility = if ($isCert)   { 'Visible' } else { 'Collapsed' }
    $global:lblTenantThumb.Visibility          = if ($isCert)   { 'Visible' } else { 'Collapsed' }
    $global:pnlTenantPath.Visibility           = if ($isNone)   { 'Visible' } else { 'Collapsed' }

    # Also hide any Required labels that belong to fields that are now hidden
    if ($isNone) {
        Hide-Required 'TenantId'; Hide-Required 'ClientId'
        Hide-Required 'ClientSecret'; Hide-Required 'CertThumb'
    } elseif ($isSecret) {
        Hide-Required 'CertThumb'; Hide-Required 'JsonPath'
    } elseif ($isCert) {
        Hide-Required 'ClientSecret'; Hide-Required 'JsonPath'
    }
}

# ── New tenant ────────────────────────────────────────────────────────────────
function Start-AddTenant {
    $global:lstTenants.SelectedItem        = $null
    $global:editingTenantKey               = $null
    $global:cfgTenantDisplayName.Text      = ''
    $global:cfgTenantTenantId.Text         = ''
    $global:cfgTenantClientId.Text         = ''
    # Clear both halves of the dual-control secret field + reset reveal-state
    if ($global:cfgTenantClientSecret)      { $global:cfgTenantClientSecret.Password = '' }
    if ($global:cfgTenantClientSecretShown) {
        $global:cfgTenantClientSecretShown.Text       = ''
        $global:cfgTenantClientSecretShown.Visibility = 'Collapsed'
    }
    if ($global:cfgTenantClientSecret)      { $global:cfgTenantClientSecret.Visibility = 'Visible' }
    if ($global:iconEyeOpen)                { $global:iconEyeOpen.Visibility = 'Visible' }
    if ($global:iconEyeOff)                 { $global:iconEyeOff.Visibility  = 'Collapsed' }
    $global:cfgTenantCertThumbprint.Text   = ''
    $global:cfgTenantPath.Text             = ''
    $global:cfgTenantAuthMethod.SelectedIndex = 0
    Update-TenantAuthFields
    Show-TenantForm -IsNew
}

# ── Reset to empty state (no tenant selected) ─────────────────────────────────
function Clear-TenantSelection {
    $global:editingTenantKey = $null
    Hide-TenantForm
    if ($global:lstTenants) {
        $global:suppressEvents = $true
        $global:lstTenants.SelectedItem = $null
        $global:suppressEvents = $false
    }
}

Export-ModuleMember -Function @(
    'New-TenantKey',
    'Load-ConfigUI',
    'Update-ConfigDropdowns',
    'Sync-MainTenantDropdowns',
    'Select-ComboByTag',
    'Commit-TenantForm',
    'Save-Config',
    'Update-TenantAuthFields',
    'Start-AddTenant',
    'Show-TenantForm',
    'Hide-TenantForm',
    'Clear-TenantSelection',
    'Clear-RequiredLabels'
)
