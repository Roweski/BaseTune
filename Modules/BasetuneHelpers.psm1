# =============================================================================
# BasetuneHelpers.psm1
# Cross-layer helpers used by both CLI and UI.
#
# Loaded as the FIRST nested module by IntuneGraphModules.psd1 so every
# subsequent module (GraphTokenClient, IntuneGraphPolicies, etc.) can call
# Write-Log without an explicit import.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Logging — Write-Log with optional GUI callback (Set-LogCallback)
#
# Three sinks:
#   - CLI:    no callback set → Write-Host with colour
#   - UI runspace:  callback enqueues to a ConcurrentQueue, drained by
#                   a DispatcherTimer on the UI thread
#   - File:   if Set-LogFile path is set, every message is also appended
#             to that file (best-effort, never throws)
#
# Previously named Write-GraphLog / Set-GraphLogCallback / Set-GraphLogFile
# and lived in GraphTokenClient.psm1. The functions are generic logging
# plumbing — nothing Graph-specific about them — so they moved here when
# the helpers module was created.
# ─────────────────────────────────────────────────────────────────────────────

$script:LogCallback = $null
$script:LogFile     = $null

function Write-Log {
    param([string]$Label, [string]$Message, [string]$Level = "INFO")

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $formatted = "[$Level][$Label] $Message"
    $fileEntry = "$timestamp $formatted"

    # Write to log file if one is set (best-effort, never throw)
    if ($script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value $fileEntry -Encoding UTF8 } catch {}
    }

    # If a GUI callback is set, forward there (no console output from runspaces)
    if ($script:LogCallback) {
        & $script:LogCallback $formatted
        return
    }

    $color = switch ($Level) {
        "INFO"  { "Cyan" }
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "White" }
    }

    Write-Host $formatted -ForegroundColor $color
}

function Set-LogCallback {
    param([scriptblock]$Callback)
    $script:LogCallback = $Callback
}

function Set-LogFile {
    param([string]$Path)
    $script:LogFile = $Path
}

# ─────────────────────────────────────────────────────────────────────────────
# Tenant auth-method classifier
# Decides whether a tenant should be treated as Online (call Graph) or Offline
# (read JSON from disk). Used by both the CLI and the UI; the single source of
# truth lives here.
#
# Input : Node — the raw tenant node (PSCustomObject from Config.json, or an
#                ordered hashtable built by Commit-TenantForm). May be $null.
#                The UI typically calls this with $entry.Node from $tenantList.
# Output: 'Offline' if Node is missing, has no authMethod, or authMethod='None';
#         'Online'  otherwise.
# ─────────────────────────────────────────────────────────────────────────────
function Get-TenantMode {
    param($Node)
    if (-not $Node) { return 'Offline' }

    # Support both PSCustomObject (from JSON) and IDictionary (ordered hash)
    $auth = if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Contains('authMethod')) { $Node['authMethod'] } else { $null }
    } else {
        if ($Node.PSObject.Properties['authMethod']) { $Node.authMethod } else { $null }
    }

    if (-not $auth -or $auth -eq 'None') { return 'Offline' }
    return 'Online'
}

# ─────────────────────────────────────────────────────────────────────────────
# Secret encryption — DPAPI (Data Protection API)
#
# Encrypts strings (clientSecret values) so they're not stored as plaintext in
# Config.json. Uses Windows DPAPI with CurrentUser scope — the encrypted blob
# can only be decrypted by the same Windows user on the same machine.
#
# Why CurrentUser scope?
#   - LocalMachine: any user (including service accounts, admin RDP sessions)
#     on the same box can decrypt. Worse than plaintext in user-profile.
#   - Roaming/portable: would need own key file + key rotation. Massive
#     overkill for a local admin tool.
#   - CurrentUser matches what Microsoft Graph PowerShell SDK, AzureAD, and
#     Connect-AzAccount use for cached token storage. Standard for the
#     ecosystem.
#
# Storage format: encrypted values are prefixed with "DPAPI:" so we can tell
# plaintext from encrypted at read time without a try/catch dance. Anything
# starting with "DPAPI:" is treated as an encrypted blob; anything else is
# treated as plaintext (and migrated on first read — see Get-GraphConfig).
#
# Decrypt-failure behaviour: when a config was encrypted by a DIFFERENT user
# or on a DIFFERENT machine (e.g. copied from a colleague), DPAPI throws a
# CryptographicException. Unprotect-Secret swallows this and returns $null;
# the caller logs a clear "re-enter the secret" message. The tenant still
# appears in the UI — only the credential is missing.
# ─────────────────────────────────────────────────────────────────────────────

$script:DpapiPrefix = 'DPAPI:'

function Test-SecretEncrypted {
    param([string]$Value)
    return ($Value -is [string]) -and $Value.StartsWith($script:DpapiPrefix)
}

function Protect-Secret {
    param([Parameter(Mandatory)][string]$Plain)

    if ([string]::IsNullOrEmpty($Plain)) { return '' }

    # ConvertFrom-SecureString (no -Key) uses DPAPI CurrentUser scope.
    # Result is a hex-encoded encrypted blob; we prefix it so reads can
    # detect encrypted vs plaintext without try/catch.
    $secure  = ConvertTo-SecureString -String $Plain -AsPlainText -Force
    $blob    = ConvertFrom-SecureString -SecureString $secure
    return "$($script:DpapiPrefix)$blob"
}

function Unprotect-Secret {
    param([string]$Encrypted)

    if ([string]::IsNullOrEmpty($Encrypted)) { return '' }
    if (-not (Test-SecretEncrypted $Encrypted)) {
        # Caller passed plaintext (e.g. legacy Config.json). Return as-is so
        # the load path can keep working; Get-GraphConfig handles migration.
        return $Encrypted
    }

    $blob = $Encrypted.Substring($script:DpapiPrefix.Length)
    try {
        # -ErrorAction Stop converts the non-terminating "not a valid encrypted
        # string" error into a terminating exception that the catch below
        # handles. Without Stop, ConvertTo-SecureString writes to the host's
        # error stream BEFORE throwing — that output bypasses our try/catch
        # and ends up in the parent CMD window when the user has tampered
        # with the DPAPI blob (or it was encrypted on another machine).
        $secure = ConvertTo-SecureString -String $blob -ErrorAction Stop
        # Marshal the SecureString back to a plain string. Yes, this defeats
        # SecureString's whole point — but the secret has to leave SecureString
        # at some point to be sent as a form-encoded POST body to the token
        # endpoint, and there's no Graph SDK that accepts SecureString here.
        # The plaintext lives in the GC heap for the duration of the token
        # exchange, then drops out of scope.
        $bstr  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } catch {
        # CryptographicException, FormatException, or "not a valid encrypted
        # string" — wrong user, wrong machine, corrupted blob, or tampered
        # input. Caller (Get-GraphConfig) detects $null and logs an actionable
        # error in the UI log instead of letting it leak to the host stream.
        return $null
    }
}

Export-ModuleMember -Function @(
    'Write-Log',
    'Set-LogCallback',
    'Set-LogFile',
    'Get-TenantMode',
    'Protect-Secret',
    'Unprotect-Secret',
    'Test-SecretEncrypted'
)
