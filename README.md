# DriverPin

**Pin your GPU driver. Stop Windows Update from silently downgrading it.**

Windows Update sometimes decides it knows better than you which graphics driver you should
run. It ships one that is *older* than the driver you installed yourself, reinstalls it
quietly after a reboot or a feature update, and leaves you with stutter, black screens, or a
Radeon or GeForce control panel that suddenly refuses to open.

DriverPin blocks driver installation for **one device**, matched by hardware ID. Every other
driver on the machine keeps updating normally.

```
.\DriverPin.ps1 status
```

That command is read-only, needs no administrator rights, and answers the question that
brought you here:

```
AMD Radeon RX 9070 XT
---------------------
  Vendor          : AMD
  Hardware ID     : PCI\VEN_1002&DEV_7550
  Installed driver: 32.0.31035.1003  (Advanced Micro Devices, Inc.)
  [warn] Driver is NOT pinned. Windows Update may replace it.

  Windows Update offer (ACTIVE):
    Advanced Micro Devices, Inc. Display Driver Update (32.0.22042.14002)
  [err]  DOWNGRADE. Offered 32.0.22042.14002 is OLDER than installed 32.0.31035.1003.
    Fix it with:  .\DriverPin.ps1 block

Untouched by DriverPin
----------------------
  Windows Update still delivers these normally:
    - Realtek SoftwareComponent Driver Update (11.0.6000.398)
    - Micro-Star INT'L CO., LTD. System Driver Update (1.0.0.16)
```

Most people never find out that Windows Update is handing them an older driver. They just
know something broke.

## Requirements

Windows 10 or 11, PowerShell 5.1 or later, which is what ships with Windows. Works with AMD,
NVIDIA and Intel graphics. No install, no dependencies, no binary.

## Usage

```powershell
.\DriverPin.ps1 status     # read-only, no admin needed
.\DriverPin.ps1 block      # pin the driver you have now
.\DriverPin.ps1 unblock    # lift it temporarily, to run a vendor installer
.\DriverPin.ps1 restore    # remove everything, hand control back to Windows
```

`block`, `unblock` and `restore` change machine policy, so they prompt for elevation and
relaunch themselves. On a machine with more than one GPU, pick one with `-Device`:

```powershell
.\DriverPin.ps1 block -Device "9070 XT"
```

If PowerShell refuses to run the script, it is the execution policy, not DriverPin:

```powershell
powershell -ExecutionPolicy Bypass -File .\DriverPin.ps1 status
```

## Installing a new driver later

The deny list blocks driver installation for that device, and that includes the vendor's own
installer. DriverPin sets `AllowAdminInstall`, which normally lets an elevated Adrenalin or
GeForce installer through anyway. If an install still fails:

```powershell
.\DriverPin.ps1 unblock    # install your driver now
.\DriverPin.ps1 block      # then re-pin
```

## What it actually changes

Everything DriverPin writes lives under these keys. Nothing is hidden, and `restore` removes
all of it. Full detail in [docs/registry-reference.md](docs/registry-reference.md).

| Key | Value | Effect |
|---|---|---|
| `...\DeviceInstall\Restrictions\DenyDeviceIDs` | your GPU hardware IDs | Blocks driver installs for that device only |
| `...\DeviceInstall\Restrictions` | `DenyDeviceIDs = 1` | Turns the deny list on |
| `...\DeviceInstall\Restrictions` | `DenyDeviceIDsRetroactive = 0` | Leaves your currently installed driver alone |
| `...\DeviceInstall\Restrictions` | `AllowAdminInstall = 1` | Elevated vendor installers still work |

All under `HKLM\SOFTWARE\Policies\Microsoft\Windows\`. These are the same settings the Group
Policy editor exposes under Device Installation Restrictions. DriverPin also marks a matching
pending update as hidden in the Windows Update queue, so it stops reappearing.

## Why not just use DDU

Use it, if the blunt version is what you want. [Display Driver
Uninstaller](https://www.wagnardsoft.com/) is excellent, and its "Prevent downloads of drivers
from Windows Update" checkbox will solve this. It is also the right tool for cleaning out a
driver that is already broken, which DriverPin does not do.

The difference is scope. DDU and every tutorial on this problem switch off driver delivery for
the **whole machine**, so your chipset, audio and network drivers stop updating too. DriverPin
blocks one device by hardware ID and leaves the rest alone. On the test machine above, the AMD
offer was blocked while four unrelated driver updates stayed available.

Pick DriverPin if you want Windows Update to keep working and just stop touching your GPU.

## Caveats

- **`restore` is thorough.** It removes the global driver-blocking settings too, including
  ones DDU or a tutorial may have set. That is deliberate, since the point is to return to
  Windows defaults, but it means `restore` can undo more than `block` did.
- **Windows Update offers do not name their target device.** On a machine with two GPUs from
  the same vendor, such as a dedicated card plus an integrated one, the same offer is listed
  under both. DriverPin says so rather than guessing.
- **Pinning does not upgrade anything.** It freezes the situation. You still install driver
  updates yourself, from the vendor.
- Requires a PCI display adapter. Virtual-only display setups are not supported.

## Contributing

Issues and pull requests welcome, particularly test reports from NVIDIA and Intel hardware.
Please include the output of `.\DriverPin.ps1 status`.

## License

MIT. See [LICENSE](LICENSE).
