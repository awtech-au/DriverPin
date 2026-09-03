<#
.SYNOPSIS
    DriverPin - pin your GPU driver so Windows Update stops replacing it.

.DESCRIPTION
    Windows Update sometimes ships a GPU driver older than the one you installed
    yourself, then reinstalls it silently after a reboot or a feature update.

    DriverPin blocks driver installation for ONE device, identified by hardware ID,
    using the same Device Installation Restrictions policy that Group Policy exposes.
    Windows Update keeps delivering every other driver on the machine normally.

.PARAMETER Action
    status   Read-only. Shows your installed driver, what Windows Update wants to
             install, and whether a block is active. Needs no administrator rights.
    block    Pin the currently installed driver for the target GPU.
    unblock  Temporarily lift the block so a vendor installer can run. Keeps the list.
    restore  Remove everything DriverPin set. Windows Update manages drivers again.

.PARAMETER Device
    Substring matched against the adapter name, for machines with more than one GPU.
    Example: -Device "9070"

.PARAMETER SkipUpdateCheck
    Skip the Windows Update query, which needs network and takes a few seconds.

.EXAMPLE
    .\DriverPin.ps1 status

.EXAMPLE
    .\DriverPin.ps1 block -Device "9070 XT"

.LINK
    https://github.com/awtech-au/DriverPin
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'block', 'unblock', 'restore')]
    [string]$Action = 'status',

    [string]$Device,
    [switch]$SkipUpdateCheck,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$script:Version = '1.0.0'

# --------------------------------------------------------------------------
# Registry locations. Every value DriverPin writes lives under one of these.
# --------------------------------------------------------------------------
$RK = @{
    Restrictions  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
    DenyList      = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceIDs'
    WindowsUpdate = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    SearchPolicy  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching'
    SearchPref    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'
    Metadata      = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata'
}

$VendorNames = @{ '1002' = 'AMD'; '10DE' = 'NVIDIA'; '8086' = 'Intel' }

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
function Write-Head($t) {
    Write-Host ""
    Write-Host $t -ForegroundColor White
    Write-Host ('-' * $t.Length) -ForegroundColor DarkGray
}
function Write-Ok($t)    { Write-Host "  [ok]   $t" -ForegroundColor Green }
function Write-Warn2($t) { Write-Host "  [warn] $t" -ForegroundColor Yellow }
function Write-Err2($t)  { Write-Host "  [err]  $t" -ForegroundColor Red }
function Write-Info($t)  { Write-Host "  $t" -ForegroundColor Gray }

# --------------------------------------------------------------------------
# Elevation
# --------------------------------------------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (Test-Admin) { return }
    Write-Warn2 "'$Action' changes machine policy and needs administrator rights."
    Write-Info  "Relaunching with elevation. Approve the UAC prompt."
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), $Action)
    if ($Device)          { $argList += @('-Device', ('"' + $Device + '"')) }
    if ($SkipUpdateCheck) { $argList += '-SkipUpdateCheck' }
    if ($Force)           { $argList += '-Force' }
    try   { Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait }
    catch { Write-Err2 "Elevation was declined. Nothing was changed." }
    exit
}

# --------------------------------------------------------------------------
# Registry helpers.
#
# Note: New-Item -Force on an EXISTING registry key deletes and recreates it,
# silently discarding every value inside. Always test for the key first.
# --------------------------------------------------------------------------
function New-KeyIfMissing($path) {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
}

function Get-KeyValues($path) {
    if (-not (Test-Path $path)) { return @{} }
    $h = @{}
    (Get-ItemProperty $path).PSObject.Properties |
        Where-Object { $_.Name -notlike 'PS*' } |
        ForEach-Object { $h[$_.Name] = $_.Value }
    $h
}

# --------------------------------------------------------------------------
# GPU discovery
# --------------------------------------------------------------------------
function Get-TargetGpu {
    $devices = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
               Where-Object { $_.InstanceId -like 'PCI\VEN_*' }

    if (-not $devices) {
        throw "No PCI display adapter found. Virtual-only display setups are not supported."
    }

    if ($Device) {
        $filtered = $devices | Where-Object { $_.FriendlyName -like "*$Device*" }
        if (-not $filtered) {
            Write-Err2 "No display adapter matched '$Device'. Found:"
            $devices | ForEach-Object { Write-Info "  - $($_.FriendlyName)" }
            throw "No matching device."
        }
        $devices = $filtered
    }

    foreach ($d in $devices) {
        $ids = @()
        foreach ($k in 'DEVPKEY_Device_HardwareIds', 'DEVPKEY_Device_CompatibleIds') {
            $p = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName $k -ErrorAction SilentlyContinue
            if ($p -and $p.Data) { $ids += $p.Data }
        }

        $ven = if ($d.InstanceId -match 'VEN_([0-9A-Fa-f]{4})') { $Matches[1].ToUpper() } else { $null }
        $dev = if ($d.InstanceId -match 'DEV_([0-9A-Fa-f]{4})') { $Matches[1].ToUpper() } else { $null }

        $drv = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
               Where-Object { $_.DeviceID -eq $d.InstanceId } | Select-Object -First 1

        [pscustomobject]@{
            Name          = $d.FriendlyName
            InstanceId    = $d.InstanceId
            Status        = $d.Status
            VendorId      = $ven
            DeviceId      = $dev
            Vendor        = if ($ven -and $VendorNames.ContainsKey($ven)) { $VendorNames[$ven] } else { "Unknown ($ven)" }
            GenericId     = "PCI\VEN_$ven&DEV_$dev"
            HardwareIds   = $ids
            DriverVersion = $drv.DriverVersion
            DriverDate    = $drv.DriverDate
            DriverVendor  = $drv.DriverProviderName
        }
    }
}

# The IDs written to the deny list: the generic pair plus the two most specific
# hardware IDs. Windows matches a device if ANY of its hardware or compatible IDs
# appears in the list, so the generic entry alone is sufficient. The specific ones
# are kept so a human reading the policy can tell which card it refers to.
function Get-DenyIdsFor($gpu) {
    $ids = @($gpu.GenericId)
    $specific = $gpu.HardwareIds |
        Where-Object { $_ -like "PCI\VEN_$($gpu.VendorId)&DEV_$($gpu.DeviceId)&SUBSYS_*" } |
        Select-Object -First 2
    $ids += $specific
    $ids | Where-Object { $_ } | Select-Object -Unique
}

# --------------------------------------------------------------------------
# Windows Update
# --------------------------------------------------------------------------
function Get-DriverOffers {
    try {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $res = $searcher.Search("IsInstalled=0 and Type='Driver'")
        foreach ($u in $res.Updates) {
            $v = if ($u.Title -match '\(([0-9]+(?:\.[0-9]+)+)\)') { $Matches[1] } else { $null }
            [pscustomobject]@{
                Title    = $u.Title
                Version  = $v
                IsHidden = $u.IsHidden
                Update   = $u
            }
        }
    } catch {
        Write-Warn2 "Could not query Windows Update: $($_.Exception.Message)"
    }
}

function Test-OfferMatchesGpu($offer, $gpu) {
    $vendorPattern = switch ($gpu.Vendor) {
        'AMD'    { 'AMD|Radeon|Advanced Micro' }
        'NVIDIA' { 'NVIDIA|GeForce|Quadro' }
        'Intel'  { 'Intel' }
        default  { $null }
    }
    if (-not $vendorPattern) { return $false }
    ($offer.Title -match $vendorPattern) -and ($offer.Title -match 'Display|Graphics|Video')
}

# --------------------------------------------------------------------------
# Block state
# --------------------------------------------------------------------------
function Get-BlockState($gpu) {
    $restr      = Get-KeyValues $RK.Restrictions
    $deny       = Get-KeyValues $RK.DenyList
    $denyValues = @($deny.Values)
    $covered    = @(Get-DenyIdsFor $gpu | Where-Object { $denyValues -contains $_ })

    [pscustomobject]@{
        DenyEnabled   = ($restr['DenyDeviceIDs'] -eq 1)
        Retroactive   = ($restr['DenyDeviceIDsRetroactive'] -eq 1)
        AdminOverride = ($restr['AllowAdminInstall'] -eq 1)
        ListedIds     = $denyValues
        CoveredIds    = $covered
        IsPinned      = (($restr['DenyDeviceIDs'] -eq 1) -and ($covered.Count -gt 0))
        ExcludeWU     = ((Get-KeyValues $RK.WindowsUpdate)['ExcludeWUDriversInQualityUpdate'] -eq 1)
        SearchPolicy  = (Get-KeyValues $RK.SearchPolicy)['SearchOrderConfig']
        MetadataBlock = ((Get-KeyValues $RK.Metadata)['PreventDeviceMetadataFromNetwork'] -eq 1)
    }
}

# --------------------------------------------------------------------------
# Actions
# --------------------------------------------------------------------------
function Invoke-Status {
    Write-Host ""
    Write-Host "  DriverPin $script:Version" -ForegroundColor Cyan
    Write-Host "  https://github.com/awtech-au/DriverPin" -ForegroundColor DarkGray

    $gpus = @(Get-TargetGpu)

    # Query Windows Update once, not once per adapter.
    $offers = @()
    if (-not $SkipUpdateCheck) {
        Write-Host ""
        Write-Info "Querying Windows Update, this takes a few seconds..."
        $offers = @(Get-DriverOffers)
    }

    foreach ($gpu in $gpus) {
        Write-Head $gpu.Name
        Write-Info "Vendor          : $($gpu.Vendor)"
        Write-Info "Hardware ID     : $($gpu.GenericId)"
        Write-Info "Installed driver: $($gpu.DriverVersion)  ($($gpu.DriverVendor))"

        $state = Get-BlockState $gpu
        if ($state.IsPinned) {
            Write-Ok "Driver is PINNED. Windows Update cannot install a driver for this device."
        } else {
            Write-Warn2 "Driver is NOT pinned. Windows Update may replace it."
        }

        if ($SkipUpdateCheck) { continue }

        $mine = @($offers | Where-Object { Test-OfferMatchesGpu $_ $gpu })

        if (-not $mine) { Write-Ok "No driver offer pending for this GPU." }

        foreach ($o in $mine) {
            $hid = if ($o.IsHidden) { 'hidden' } else { 'ACTIVE' }
            Write-Info ""
            Write-Info "Windows Update offer ($hid):"
            Write-Info "  $($o.Title)"
            if ($o.Version -and $gpu.DriverVersion) {
                try {
                    $offered = [version]$o.Version
                    $current = [version]$gpu.DriverVersion
                    if ($offered -lt $current) {
                        Write-Err2 "DOWNGRADE. Offered $($o.Version) is OLDER than installed $($gpu.DriverVersion)."
                        if (-not $state.IsPinned) { Write-Info "  Fix it with:  .\DriverPin.ps1 block" }
                    } elseif ($offered -gt $current) {
                        Write-Info "  Offered $($o.Version) is newer than installed $($gpu.DriverVersion)."
                    } else {
                        Write-Info "  Same version as installed."
                    }
                } catch {
                    Write-Info "  Could not compare version strings."
                }
            }
        }

    }

    # Windows Update driver offers do not name the device they target, so on a
    # machine with more than one GPU from the same vendor an offer can legitimately
    # appear under both. Say so rather than pretending to know which one it is.
    if ($gpus.Count -gt 1 -and -not $SkipUpdateCheck) {
        $sameVendor = @($gpus | Group-Object Vendor | Where-Object { $_.Count -gt 1 })
        if ($sameVendor) {
            Write-Info ""
            Write-Warn2 "This machine has more than one $($sameVendor[0].Name) adapter."
            Write-Info  "Windows Update offers do not name their target device, so the same offer is"
            Write-Info  "listed under each. A combined driver package can touch both adapters."
        }
    }

    if (-not $SkipUpdateCheck) {
        $isGpuOffer = { param($o) ($gpus | Where-Object { Test-OfferMatchesGpu $o $_ }).Count -gt 0 }
        $others = @($offers | Where-Object { -not (& $isGpuOffer $_) -and -not $_.IsHidden })
        if ($others) {
            Write-Head "Untouched by DriverPin"
            Write-Info "Windows Update still delivers these normally:"
            $others | ForEach-Object { Write-Info "  - $($_.Title)" }
        }
    }

    Write-Head "Policy detail"
    $s = Get-BlockState $gpus[0]
    Write-Info "DenyDeviceIDs enabled       : $($s.DenyEnabled)"
    Write-Info "Applies to installed devices: $($s.Retroactive)   (false = your current driver is left alone)"
    Write-Info "Admin override allowed      : $($s.AdminOverride)   (true = vendor installer still works)"
    $count = if ($s.ListedIds) { $s.ListedIds.Count } else { 0 }
    Write-Info "Deny list entries           : $count"
    $s.ListedIds | ForEach-Object { Write-Info "    $_" }
    Write-Host ""
}

function Invoke-Block {
    # Resolve the target before asking for elevation, so an ambiguous request is
    # rejected without making the user approve a UAC prompt first.
    $gpus = @(Get-TargetGpu)
    if ($gpus.Count -gt 1 -and -not $Force) {
        Write-Err2 "Found $($gpus.Count) display adapters. Narrow it with -Device, or pass -Force to pin all of them."
        $gpus | ForEach-Object { Write-Info "  - $($_.Name)" }
        return
    }

    Assert-Admin

    New-KeyIfMissing $RK.Restrictions
    New-KeyIfMissing $RK.DenyList

    # Query Windows Update once up front rather than inside the per-adapter loop.
    $offers = if ($SkipUpdateCheck) { @() } else { @(Get-DriverOffers) }

    foreach ($gpu in $gpus) {
        Write-Head "Pinning $($gpu.Name)"
        Write-Info "Installed driver: $($gpu.DriverVersion)"

        $existing = @((Get-KeyValues $RK.DenyList).Values)
        $slot = 1
        foreach ($id in (Get-DenyIdsFor $gpu)) {
            if ($existing -contains $id) { Write-Info "already listed: $id"; continue }
            while (Get-ItemProperty $RK.DenyList -Name "$slot" -ErrorAction SilentlyContinue) { $slot++ }
            Set-ItemProperty -Path $RK.DenyList -Name "$slot" -Type String -Value $id
            Write-Ok "blocked: $id"
        }

        # Hide any pending offer for this GPU so it stops reappearing in the list.
        foreach ($o in $offers) {
            if ((Test-OfferMatchesGpu $o $gpu) -and -not $o.IsHidden) {
                try {
                    $o.Update.IsHidden = $true
                    Write-Ok "hid update: $($o.Title)"
                } catch {
                    Write-Warn2 "Could not hide '$($o.Title)': $($_.Exception.Message)"
                }
            }
        }
    }

    Set-ItemProperty -Path $RK.Restrictions -Name 'DenyDeviceIDs'            -Type DWord -Value 1
    Set-ItemProperty -Path $RK.Restrictions -Name 'DenyDeviceIDsRetroactive' -Type DWord -Value 0
    Set-ItemProperty -Path $RK.Restrictions -Name 'AllowAdminInstall'        -Type DWord -Value 1
    Write-Ok "policy enabled, non-retroactive, admin override on"

    gpupdate /force /target:computer | Out-Null
    Write-Host ""
    Write-Ok "Done. Your driver is pinned."
    Write-Info "Before installing a new driver from the vendor, run:  .\DriverPin.ps1 unblock"
    Write-Host ""
}

function Invoke-Unblock {
    Assert-Admin
    if (-not (Test-Path $RK.Restrictions)) {
        Write-Warn2 "No DriverPin policy found. Nothing to unblock."
        return
    }
    Set-ItemProperty -Path $RK.Restrictions -Name 'DenyDeviceIDs' -Type DWord -Value 0
    gpupdate /force /target:computer | Out-Null
    Write-Host ""
    Write-Ok "Block lifted. The deny list is kept, just switched off."
    Write-Warn2 "Windows Update can install a GPU driver again until you re-pin."
    Write-Info "Install your driver now, then run:  .\DriverPin.ps1 block"
    Write-Host ""
}

function Invoke-Restore {
    Assert-Admin
    Write-Head "Removing all DriverPin policy"
    foreach ($p in @($RK.Restrictions, $RK.SearchPolicy, $RK.Metadata)) {
        if (Test-Path $p) { Remove-Item $p -Recurse -Force; Write-Ok "removed $p" }
    }
    if (Test-Path $RK.WindowsUpdate) {
        Remove-ItemProperty $RK.WindowsUpdate -Name 'ExcludeWUDriversInQualityUpdate' -ErrorAction SilentlyContinue
        Write-Ok "cleared ExcludeWUDriversInQualityUpdate"
    }
    New-KeyIfMissing $RK.SearchPref
    Set-ItemProperty -Path $RK.SearchPref -Name 'SearchOrderConfig' -Type DWord -Value 1
    Write-Ok "restored default driver search behaviour"

    foreach ($o in (Get-DriverOffers)) {
        if ($o.IsHidden) {
            try { $o.Update.IsHidden = $false; Write-Ok "unhid: $($o.Title)" } catch { }
        }
    }

    gpupdate /force /target:computer | Out-Null
    Write-Host ""
    Write-Ok "Windows Update manages your drivers again. A reboot is recommended."
    Write-Host ""
}

# --------------------------------------------------------------------------
# A failure here is a user-facing problem, not a bug to be dumped as a stack
# trace. Print the message and exit non-zero so scripts can react.
try {
    switch ($Action) {
        'status'  { Invoke-Status }
        'block'   { Invoke-Block }
        'unblock' { Invoke-Unblock }
        'restore' { Invoke-Restore }
    }
} catch {
    Write-Host ""
    Write-Err2 $_.Exception.Message
    Write-Host ""
    exit 1
}
