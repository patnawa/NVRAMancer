# Hardware in the loop

The HIL workflow validates real USB transports and sacrificial chips on
dedicated self-hosted GitHub runners. It supplements virtual-device and wire-
transcript tests; it does not replace them.

## Safety model

- The weekly schedule is read-only and cannot select destructive mode.
- `tools/hil.ps1` defaults to `ReadOnly`; `tools/hil.sh` refuses destructive
  mode entirely.
- A destructive Windows run requires a manual workflow dispatch, approval of
  the `hardware-in-loop-destructive` environment, a target-specific runner, the
  exact station environment token
  `ASPX_HIL_DESTRUCTIVE=ERASE_SACRIFICIAL_FIXTURE`, an exact chip name, a
  full-chip `.bin`, and its SHA-256.
- The destructive harness takes two matching reads, keeps the backup as an
  artifact, programs and verifies the test image, then restores and verifies
  the backup. Failure to restore is a failed run, never a warning.
- Only socketed sacrificial parts containing synthetic, publishable data belong
  on these stations. Never attach a motherboard, production unit, unique
  firmware, or in-circuit clip to an automated runner.

## Runner layout

Register one runner per controlled fixture and apply exactly one hardware
label:

| Runner OS | Required label | Live path |
|---|---|---|
| Windows | `aspx-hil-ch341` | Application detect/read through CH341 DLL |
| Windows | `aspx-hil-ch347` | Application detect/read through CH347 DLL |
| Windows | `aspx-hil-ezp` | Independent `ezpsmoke` plus application detect/read |
| Linux | `aspx-hil-ch347-libusb` | `ch347smoke` plus headless CLI detect |

All runners also carry the standard `self-hosted` and OS labels. Do not place
the HIL label on a general-purpose developer runner.

T48 is intentionally absent from this runner matrix and from the destructive
workflow target list. Its pre-arrival adapter is read-only, and neither adding
a runner label nor editing a workflow input is authority to unlock mutation.
Follow the staged procedure below after the physical programmer arrives.

Windows stations need 32-bit Lazarus 4.8 at `C:\lazarus32`, Python, `curl`,
`tar`, the approved device driver, and direct USB access. The build downloads
release runtimes only from hash-pinned sources. Linux needs FPC, OpenSSL
`libcrypto`, the libusb 1.0 runtime, and either a udev rule or a narrowly scoped
runner service account allowed to open the CH347. Do not run the whole runner
as root.

Protect the destructive GitHub environment with required reviewers. Set the
station token in the runner service's local environment, not in repository
YAML or workflow inputs. Restrict filesystem and interactive login access to
bench maintainers.

## Read-only runs

The schedule in `.github/workflows/hardware-in-loop.yml` runs every Monday.
Manual dispatch can select one target or all targets. A chip name is optional:
without it, Windows performs identity/detection only; with `-Chip`, the local
harness also saves a two-pass matching dump.

For local diagnosis:

```powershell
powershell -ExecutionPolicy Bypass -File tools\build.ps1 -Release
powershell -ExecutionPolicy Bypass -File tools\hil.ps1 `
  -Mode ReadOnly -Target ch341 -Chip W25Q64BV
```

```bash
ASPX_HIL_ARTIFACT_DIR="$PWD/hil-results" ./tools/hil.sh readonly
```

The EZP smoke tool reads USB descriptors, runs CHECK_CHIP, and, when a chip is
present, reads the first block. The CH347 smoke tool sends only JEDEC-ID (`9Fh`)
and status-register (`05h`) reads. The headless CLI detect path performs stable
identity reads. None sends write-enable, erase, or program opcodes.

## XGecu T48 preview

The T48 preview uses a separately installed, explicitly selected
[`minipro`](https://gitlab.com/DavidGriffith/minipro/-/tree/cae74c0607077d6260b24995f5e4c0d0b66a6a2e)
executable. That tool and its GPL device database are not part of NVRAMancer's
MIT release. Record its version, source revision, executable SHA-256 and
absolute path with every run; do not silently substitute another executable
found on `PATH`.

The upstream T48 work established that a USB VID/PID alone does not uniquely
identify this model, so a run is admitted only when the live tool query says
exactly `T48`; see the upstream
[support investigation](https://gitlab.com/DavidGriffith/minipro/-/issues/270).
The chip must likewise use one exact `minipro` device/package name. Do not use
fuzzy mapping, skip-ID/force options, or SPI auto-detection; the upstream
[progress tracker](https://gitlab.com/DavidGriffith/minipro/-/issues/294)
still records limitations in that path.

### Pre-arrival evidence

Hardware-free tests may establish all of the following before the unit exists:

- argv is passed directly to the selected executable without a command shell;
- missing tool and missing programmer are different failures;
- only an exact T48 response is accepted, while TL866II+ and T56 responses are
  rejected;
- exact device/package selection is mandatory for ID, read and verify;
- nonzero exit, malformed output, timeout and cancellation fail closed;
- a dump must be newly created and exactly the expected capacity before it can
  be published, and two successful reads must match; and
- no read-only code path can launch erase, write, firmware update, raw SPI,
  scripts, Smart Write, NAND/eMMC or Production operations.

This is command-policy evidence only. It cannot graduate a hardware capability.

### First-unit read-only procedure

Use a socketed sacrificial SPI NOR containing synthetic, publishable data. Do
not attach a customer chip, motherboard, in-circuit clip, unique firmware or
the only copy of anything. Start with mutation disabled and read-only safe mode
latched.

1. Record the T48 hardware revision, firmware, host OS, USB driver, exact
   `minipro` build/revision and SHA-256, NVRAMancer commit, socket adapter, exact
   chip/package, chip lot and expected capacity. Redact the programmer serial
   before publishing an artifact if it identifies the owner.
2. With the T48 disconnected, prove that the selected tool can be found but
   programmer presence fails separately. Connect it and repeat two fresh live
   model queries. Both must identify exactly `T48` and report the same firmware
   and device identity.
3. Run live chip ID twice in fresh sessions. Both results must match the known
   sacrificial part. An all-zero, all-one, unknown or changing identity fails
   the run.
4. Read the full chip twice to two new artifact names. Require the exact
   expected byte count and matching SHA-256 hashes. Run independent verify
   against that image, then verify its hash with a host tool.
5. Prove detect/read are non-mutating: verify the known fixture image before
   and after the sequence with a previously validated programmer or genuinely
   independent tool path, and retain both results.
6. Exercise cancellation, timeout and USB unplug during separate reads. Each
   must terminate, close the child process/device, report the correct failure,
   and leave no stale, partial or apparently successful dump.
7. With the correct sacrificial part for each rail, measure socket VCC and the
   relevant signal levels during ID and read at 3.3 V and 1.8 V. Never expose a
   1.8 V-only chip to the 3.3 V test. Record instruments, measured values and
   tolerances rather than copying nominal programmer specifications.
8. Archive the application log, direct argv log, two dumps, hashes, independent
   verification result and the inventory above under one run identifier.

Do not add T48 to the scheduled runner matrix until this read-only procedure
passes on the maintained fixture. A read-only workflow addition must still be
reviewed to prove that no mutation verb or unsafe override can be selected.

### Destructive graduation checklist

Erase and write must remain unreachable until one reviewed evidence bundle
from the physical programmer proves every item below:

- exact T48 model, hardware revision and firmware, plus the supported Windows
  driver/tool combination;
- stable chip ID and two matching exact-size full reads in fresh sessions;
- independently confirmed non-mutating device-info, detect, ID, read and verify
  paths;
- safe timeout, cancellation and unplug cleanup with no stale output published;
- measured 3.3 V and 1.8 V socket-rail and signal behaviour on appropriate
  sacrificial fixtures; and
- a synthetic sacrificial cycle of trusted backup, erase, blank check, exact-
  size pattern write, full read/verify through an independent path, backup
  restore and a second independent restore verification after reopening the
  programmer.

The evidence must name the exact chip/package, adapter, chip lot, tool and
application revisions and include hashes for the backup, pattern, programmed
readback and restored readback. A maintainer must then add and review an
explicit validation-gate record before the GUI, CLI or HIL workflow can expose
T48 mutation. Completing the checklist by itself does not change the lock.

## Destructive fixture cycle

Use the workflow UI, choose exactly one Windows target, choose `destructive`,
and provide:

- the exact database chip name;
- an absolute path to a station-local, full-capacity `.bin` containing only a
  synthetic test pattern; and
- the image's exact SHA-256.

Approval authorizes one run, not permanent mutation rights. The station must
also hold the local token. CH341/CH347 use transactional Smart Write and a
separate verify; EZP uses its native whole-chip erase/program/full-verify path.

Every run uses a timestamp-and-GUID artifact name, so a rerun cannot overwrite
an earlier last-known-good fixture image. If restoration fails, disconnect
power, preserve the `*-restore-backup.bin`
artifact, and investigate before reusing the fixture. Do not rerun a different
image over a failed restore.

## Current limitation

The workflow and harness are ready, but they produce real coverage only after
the repository owner registers and maintains the labeled physical runners.
An absent runner leaves a scheduled job queued; a passing compile-only CI job
is not evidence that a programmer has been validated on silicon. Record the
programmer hardware revision, driver/library version, chip lot, adapter, and
measured rail voltage in the runner inventory outside the repository.
