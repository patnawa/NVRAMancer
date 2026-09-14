# Workspace, verification and recovery

Version 4.44.0.0 follows the six priorities from the project
review. The app opens its working window directly. Connection Doctor is an
optional command; there is no automatic first-run modal. The chosen workspace
and backup directory are saved. English is embedded in the executable and is
the default when a language preference or optional catalog is missing. An
explicit available language remains supported.

## Everyday work

Opening a firmware image is available while offline. Once a programmer and chip
profile are available, ordinary NOR/EEPROM preparation runs automatically for
non-production, non-serial jobs. It reads the chip, saves a backup, and shows
the operation in the main window. Serial and strict production jobs retain
explicit preparation so background activity does not allocate an identity.

**Write** commits the visible plan. Preparation does not issue image program or
erase commands. Preparation and commitment each read the current chip; the
accepted plan is bound to the image, physical snapshot, live ID/UID, geometry,
range and setup. Changed bytes or setup require review of an updated plan.
Editing the image invalidates readiness. Execution rechecks the entire prepared
preimage before mutation, including bytes outside the requested patch.

Multiple matching chip profiles appear in an inline selector. Unreadable images,
unknown or incompatible voltage, identity mismatch, and protection problems
are reported in the workspace. Optional diagnostic and expert operations,
including OTP and explicit erase tools, retain their own interactions.

## Backups and recovery

The default Windows backup directory is
`%LOCALAPPDATA%\NVRAMancer\backups`. **Open backups** opens that directory.
Ordinary reads are saved there too; the write workflow still establishes its
own repeated-read trusted snapshot. A backup failure blocks the write.

Before a desktop Smart Write NOR plan mutates data, its recovery bundle contains:

- The full original backup and its SHA-256 hash.
- A saved copy of the accepted image, including personalization, and its hash.
- A version 2 journal binding chip model/JEDEC ID, capacity, UID when available,
  target range and the complete erase geometry.

The recovery row discovers unfinished journals in the configured backup
directory and legacy `backup` directories. Select a journal and choose
**Prepare interrupted write**. Recovery validates the saved files, rereads the
connected chip, reconstructs the complete intended image from the original
backup plus patch, and plans the differences against the current chip.
**Write** is still required. Completion marks are history; they never replace
physical readback or justify skipping an erased neighbour. The bundle supports
another retry if recovery itself is interrupted.

After successful verification, the journal is retired and the original backup
remains. Even an already-written image must pass verification before its
journal is retired. Version 1 journals remain readable, but lack the saved
image/geometry needed for this workflow; the UI points to their original backup.
Recovery is currently exposed for the shared SPI NOR path. EEPROM and EZP
writes retain automatic backups; they do not advertise journal recovery.

A chip without a usable UID can be checked only by its model/ID, capacity,
geometry and content. This cannot prove which individual physical chip is
connected.

## Shared operation code

`writeworkflow.pas` owns immutable prepared NOR requests and their one-use
execution boundary; both the desktop and headless operation runner use it.
`recoveryworkflow.pas` owns saved-input validation and reconstruction.
`workflowui.inc` contains the desktop presentation and routes explicit actions.
This is an incremental extraction; legacy protocols still have orchestration
in `main.pas`.

The shared NOR and EEPROM engines verify the affected bytes, close the device,
open and initialize a new session, then compare those bytes again. Cleanup,
reopen, short-read or mismatch failures prevent PASS and evidence commitment.
Recovery verifies the reconstructed whole-chip image. `eepromsession.pas` owns
the real programmer open/bus/close lifecycle and voltage restoration around
EEPROM adapters. Reopening a programmer is not a guaranteed chip power cycle.

`chipcatalog.pas` rejects ambiguous names and provides exact `name@JEDEC`
selection keys. Six colliding primary-catalog entries have distinct names and
legacy aliases. The catalog validator treats an ambiguous bare name as an
error. Explicit 3.3 V metadata was added to selected W25Q64JV/W25Q256JV entries
using the manufacturer's [2025 flash selection guide](https://www.winbond.com/export/sites/winbond/product-selection-guide/file/2025-Product-Selection-Guide-Winbond-Code-Storage-Flash-Memory.pdf).
Unknown catalog entries remain unknown.

## Validation

The Windows build runs 37 hardware-free suites, catalog validation and metadata
checks. The expanded prepared/recovery/session suite has 53 assertions,
including reopen corruption, failed cleanup, changed preimages, tampered saved
inputs, repeated recovery and verification-only recovery.

`tools/test_desktop.ps1` runs the real form against an 8 MiB simulated NOR chip,
including automatic preparation, explicit Write and interrupted-write recovery.
It also checks English fallback and the absence of routine modal forms.
See [testing instructions](testing.md).

Physical programmers were not exercised for these changes. Visual automation
was unavailable in this session; the desktop smoke checks behavior and form
state, not visual layout.
