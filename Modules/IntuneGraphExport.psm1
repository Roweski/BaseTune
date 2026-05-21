function Export-PoliciesToJson {
    <#
    .SYNOPSIS
        Exports Intune configuration policies to individual JSON files.
        Output is compatible with Intune portal import and offline comparison.

    .PARAMETER Connection
        Graph connection object (from New-GraphConnection).

    .PARAMETER Filter
        Only policies whose name contains this filter string are exported.

    .PARAMETER OutputPath
        Folder where JSON files will be written (e.g. .\JSON\Source).

    .PARAMETER GraphBeta
        Base URI for the Graph beta endpoint.

    .PARAMETER MaxThreads
        Parallel threads for settings expand. Default: 8.

    .EXAMPLE
        Export-PoliciesToJson -Connection $sourceConnection -Filter "Win-L" `
            -OutputPath ".\JSON\Source" -GraphBeta "https://graph.microsoft.com/beta"
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $Connection,

        [Parameter(Mandatory=$false)]
        [string]$Filter = "",

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$GraphBeta,

        [int]$MaxThreads = 8
    )

    # Guard against drive roots (e.g. C:\) — New-Item on an existing drive root throws a terminating error
    $resolvedOut = $OutputPath.TrimEnd('\', '/')
    if ($resolvedOut -match '^[A-Za-z]:$') {
        Write-Log "Export" "Cannot export to a drive root ($OutputPath). Choose a subfolder." "ERROR"
        return
    }

    # Ensure output folder exists. Existing files are NOT cleared — each
    # exported policy overwrites its own JSON file by name, leaving any
    # other files in the folder untouched.
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    # ── Fetch all matching policies ───────────────────────────
    $all = Get-GraphPagedResults -Connection $Connection `
        -Uri "$GraphBeta/deviceManagement/configurationPolicies?`$select=id,name,description,platforms,technologies,templateReference"

 
    $selected = if ($Filter) { 
       $all | Where-Object { $_.name -like "*$Filter*" }
    } else {
       $all
    }

    if ($selected.Count -eq 0) {
        Write-Log "Export" "No policies found matching '*$Filter*'." "WARN"
        return
    }

    Write-Log "Export" "$($selected.Count) policies found matching '*$Filter*'" "OK"

    # ── Expand settings + write JSON in parallel ───────────────
    # Each parallel worker fetches its policy detail, builds the payload, and
    # writes its JSON file directly to disk. Workers emit small status objects
    # back into the pipeline; the downstream ForEach-Object then logs each one
    # AS IT COMPLETES — not after all workers finish.
    #
    # Why direct-to-disk instead of expand-then-write?
    #   1. Partial recovery: if the process crashes (network drop, throttle,
    #      Graph 5xx, host kill) the policies that already completed are on
    #      disk. The previous design held everything in $expanded and only
    #      wrote at the very end — a crash meant losing the whole batch.
    #   2. Lower peak memory: $expanded used to grow linearly with tenant
    #      size. On large tenants (1000+ policies) this stacked tens of MB
    #      of nested JSON-ready hashtables in RAM before any write happened.
    #
    # Why pipe through a second ForEach-Object instead of Write-Log inside
    # the parallel block?
    #   Write-Log inside -Parallel would run in the worker's own runspace,
    #   which has its own $script:LogCallback (= $null) — output would fall
    #   through to Write-Host and miss the UI log entirely. The downstream
    #   ForEach-Object runs in the PARENT runspace where Set-LogCallback
    #   was wired by the runspace work block. -Parallel streams items into
    #   that pipeline as workers complete, so each Saved/Failed message
    #   shows up in real time.
    #
    # $PSScriptRoot inside a module = the Modules folder itself; capture
    # before the parallel block since $PSScriptRoot doesn't survive the
    # runspace boundary.
    $modulesPath = $PSScriptRoot
    $written = 0
    $skipped = 0
    $failed  = 0

    $selected | ForEach-Object -Parallel {
        $policy      = $_
        $modulesPath = $using:modulesPath
        $connection  = $using:Connection
        $graphBeta   = $using:GraphBeta
        $outputPath  = $using:OutputPath

        try {
            Import-Module "$modulesPath\GraphTokenClient.psm1" -Force

            $detail = Invoke-IntuneGraphRequest -Connection $connection `
                -Uri "$graphBeta/deviceManagement/configurationPolicies/$($policy.Id)?`$expand=settings"

            if (-not $detail.name) {
                return [PSCustomObject]@{
                    Status = 'Skipped'
                    Name   = $null
                    Id     = $policy.Id
                    Reason = 'empty name'
                }
            }

            # Build the export payload in a shape the Intune portal's Import
            # Policy feature accepts. Notes:
            #   - [ordered]@{} so ConvertTo-Json keeps the field order below.
            #   - id IS included. The portal ignores it on import (generates
            #     a new one) and Basetune's own offline compare needs it for
            #     the dedup logic in IntuneGraphCompare.psm1.
            #   - technologies joined to comma-separated string (Graph returns
            #     either string or array depending on policy type).
            #   - templateReference only added when present. Endpoint security
            #     template policies have it; settings-catalog policies don't.
            #     A null/empty templateReference on a settings-catalog policy
            #     can break the portal import.
            $payload = [ordered]@{
                name         = [string]$detail.name
                id           = [string]$detail.id
                description  = [string]$detail.description
                platforms    = [string]$detail.platforms
                technologies = [string]($detail.technologies -join ",")
            }
            if ($null -ne $detail.templateReference) {
                $payload.templateReference = $detail.templateReference
            }
            $payload.settings = @(
                foreach ($s in $detail.settings) {
                    @{ settingInstance = $s.settingInstance }
                }
            )

            $safeName = $detail.name -replace '[\\/:*?"<>|]', '_'
            $filePath = "$outputPath\$safeName.json"
            $payload | ConvertTo-Json -Depth 50 | Out-File $filePath -Encoding UTF8

            [PSCustomObject]@{
                Status = 'Written'
                Name   = $detail.name
                File   = "$safeName.json"
            }
        }
        catch {
            [PSCustomObject]@{
                Status = 'Failed'
                Name   = if ($detail -and $detail.name) { $detail.name } else { $policy.name }
                Id     = $policy.Id
                Error  = $_.Exception.Message
            }
        }
    } -ThrottleLimit $MaxThreads | ForEach-Object {
        # Runs in the PARENT runspace as each worker streams a result.
        # Write-Log here goes through the live LogCallback wired by the
        # runspace work block (export Start-Runspace -OnDone path).
        #
        # NB: stash $_ into $result BEFORE the switch. PowerShell rebinds $_
        # inside each switch clause to the matched value (e.g. the string
        # 'Written'), so $_.File from within the clause would resolve against
        # that string and produce $null — empty "Saved: " messages.
        $result = $_
        switch ($result.Status) {
            'Written' {
                Write-Log "Export" "Saved: $($result.File)" "OK"
                $written++
            }
            'Skipped' {
                Write-Log "Export" "Skipping policy with empty name (id: $($result.Id))." "WARN"
                $skipped++
            }
            'Failed' {
                Write-Log "Export" "Failed to export '$($result.Name)' (id: $($result.Id)). $($result.Error)" "ERROR"
                $failed++
            }
        }
    }

    Write-Log "Export" "Done. $written written, $skipped skipped, $failed failed. Output: $OutputPath" "OK"
}

function Export-CachedPoliciesToJson {
    <#
    .SYNOPSIS
        Exports a subset of already-loaded (cached) policies to JSON files.
        No Graph API calls are made — all data comes from the in-memory cache
        populated by Read-PoliciesFromTenant / Read-PoliciesFromJson.
        Output is compatible with the Intune portal import and offline compare.

    .PARAMETER Policies
        Array of policy objects as cached by the Load runspace.
        Each object must carry: PolicyId, Name, Description, Platforms,
        Technologies, TemplateReference, Settings.

    .PARAMETER SelectedNames
        Array of policy names to export. Only policies whose Name is in this
        list are written to disk. Pass $null or an empty array to export all.

    .PARAMETER OutputPath
        Folder where JSON files will be written.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [array]$Policies,

        [Parameter(Mandatory=$false)]
        [string[]]$SelectedNames = @(),

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    # Guard against drive roots
    $resolvedOut = $OutputPath.TrimEnd('\', '/')
    if ($resolvedOut -match '^[A-Za-z]:$') {
        Write-Log "Export" "Cannot export to a drive root ($OutputPath). Choose a subfolder." "ERROR"
        return
    }

    # Ensure output folder exists. Existing files are NOT cleared — each
    # exported policy overwrites its own JSON file by name, leaving any
    # other files in the folder untouched. The UI export is typically a
    # partial (selection-based) export, so wiping the folder would destroy
    # policies the user didn't intend to remove.
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    # Filter to selected names when provided
    $toExport = if ($SelectedNames -and $SelectedNames.Count -gt 0) {
        $Policies | Where-Object { $SelectedNames -contains $_.Name }
    } else {
        $Policies
    }

    if ($toExport.Count -eq 0) {
        Write-Log "Export" "No policies to export." "WARN"
        return
    }

    Write-Log "Export" "$($toExport.Count) policies selected for export" "OK"

    $written = 0
    $skipped = 0
    $failed  = 0

    foreach ($policy in $toExport) {
        try {
            if (-not $policy.Name) {
                Write-Log "Export" "Skipping policy with empty name (id: $($policy.PolicyId))." "WARN"
                $skipped++
                continue
            }

            # Build the export payload — same shape as Export-PoliciesToJson so
            # the output is interchangeable with a direct-API export.
            $payload = [ordered]@{
                name         = [string]$policy.Name
                id           = [string]$policy.PolicyId
                description  = [string]$policy.Description
                platforms    = [string]$policy.Platforms
                technologies = [string]($policy.Technologies -join ",")
            }
            if ($null -ne $policy.TemplateReference) {
                $payload.templateReference = $policy.TemplateReference
            }
            $payload.settings = @(
                foreach ($s in $policy.Settings) {
                    @{ settingInstance = $s.settingInstance }
                }
            )

            $safeName = $policy.Name -replace '[\\/:*?"<>|]', '_'
            $filePath = "$OutputPath\$safeName.json"
            $payload | ConvertTo-Json -Depth 50 | Out-File $filePath -Encoding UTF8

            Write-Log "Export" "Saved: $safeName.json" "OK"
            $written++
        }
        catch {
            Write-Log "Export" "Failed to export '$($policy.Name)'. $($_.Exception.Message)" "ERROR"
            $failed++
        }
    }

    Write-Log "Export" "Done. $written written, $skipped skipped, $failed failed. Output: $OutputPath" "OK"
}

Export-ModuleMember -Function @(
    'Export-PoliciesToJson',
    'Export-CachedPoliciesToJson'
)