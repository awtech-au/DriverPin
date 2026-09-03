# Registry reference

Every change DriverPin makes, what it does, and how to undo it by hand. Nothing here is
undocumented or unusual. All of it is exposed through the Group Policy editor on Windows Pro,
under `Computer Configuration > Administrative Templates > System > Device Installation`.

## Written by `block`

### The deny list

```
HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceIDs
```

String values named `1`, `2`, `3` and so on, each holding one hardware ID:

```
1 = PCI\VEN_1002&DEV_7550
2 = PCI\VEN_1002&DEV_7550&SUBSYS_24371458
3 = PCI\VEN_1002&DEV_7550&SUBSYS_24371458&REV_C0
```

Windows blocks a device if **any** of its hardware or compatible IDs appears in this list, so
the generic `VEN`/`DEV` pair on its own is enough. DriverPin adds the more specific IDs as
well, purely so that a human reading the policy later can tell which card it refers to.

To see the full ID list for your own card:

```powershell
Get-PnpDevice -Class Display | Select-Object FriendlyName, InstanceId
Get-PnpDeviceProperty -InstanceId '<your instance id>' -KeyName DEVPKEY_Device_HardwareIds
```

### The switches

```
HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions
```

| Value | Type | Set to | Meaning |
|---|---|---|---|
| `DenyDeviceIDs` | DWORD | `1` | Enables the deny list. Setting it to `0` suspends the block without losing the list, which is what `unblock` does. |
| `DenyDeviceIDsRetroactive` | DWORD | `0` | Does not apply the block to devices that are already installed. This is what leaves your working driver in place. Setting it to `1` would rip out the current driver. |
| `AllowAdminInstall` | DWORD | `1` | Lets an elevated installer override the restriction, so the AMD or NVIDIA installer still works. |

### Windows Update queue

DriverPin sets `IsHidden` on any pending driver update whose title matches your GPU vendor,
through the built-in `Microsoft.Update.Session` COM interface. No module is downloaded. This
is the same thing Microsoft's old `wushowhide` troubleshooter did.

## Removed by `restore`

`restore` returns the machine to Windows defaults. Alongside its own keys it clears the
global driver-blocking settings, because those are what other tools and tutorials set and
leaving them behind would mean Windows Update is still half disabled.

| Key | Action |
|---|---|
| `...\Policies\...\DeviceInstall\Restrictions` | Deleted, including the deny list |
| `...\Policies\...\DriverSearching` | Deleted |
| `...\Policies\...\Device Metadata` | Deleted |
| `...\Policies\...\WindowsUpdate\ExcludeWUDriversInQualityUpdate` | Value removed |
| `...\CurrentVersion\DriverSearching\SearchOrderConfig` | Reset to `1` |

Hidden driver updates are also unhidden.

## Related settings DriverPin does not touch by default

These are the global switches. They work, but they stop driver delivery for the entire
machine, which is the behaviour DriverPin exists to avoid. Listed here because you will find
them in every other guide on this problem.

| Key | Value | Effect |
|---|---|---|
| `...\Policies\...\WindowsUpdate` | `ExcludeWUDriversInQualityUpdate = 1` | No drivers in quality updates, machine wide |
| `...\CurrentVersion\DriverSearching` | `SearchOrderConfig = 0` | Never look at Windows Update for drivers |
| `...\Policies\...\DriverSearching` | `DontSearchWindowsUpdate = 1` | Policy version of the same thing |
| `...\Policies\...\Device Metadata` | `PreventDeviceMetadataFromNetwork = 1` | Blocks device metadata and icon downloads |

## A trap worth knowing

In PowerShell, `New-Item -Force` on a registry key that **already exists** deletes it and
recreates it empty, silently discarding every value inside. Running this against a populated
deny list wipes it:

```powershell
New-Item -Path $denyListPath -Force | Out-Null   # destroys existing values
```

Test first:

```powershell
if (-not (Test-Path $denyListPath)) { New-Item -Path $denyListPath -Force | Out-Null }
```

DriverPin uses the second form. If you are adapting the approach into your own script, this is
the mistake to avoid.
