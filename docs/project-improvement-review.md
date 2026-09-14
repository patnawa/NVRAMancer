# NVRAMancer improvement review

This document records the baseline assessment. The resulting changes and their
validation are described in [the implementation notes](workspace-workflow.md).

NVRAMancer's next release should make everyday Windows repair work immediate: open the workspace, recognize the connected setup, read a chip or load an image, and perform the chosen operation without a chain of questions. The existing safety engines provide a substantial foundation for this. The highest return comes from making those engines consistent and easy to use throughout the application.

The assessment applies to version **4.43.0.0**, commit **47e16ae**, with validation performed on September 14, 2026. The Windows build and all **35 registered hardware-free suites passed**. Metadata validation passed, and the four chip tables passed with **1,751 entries, zero errors, and 25 warnings**. These results establish software behavior under the tested conditions; physical hardware validation and interactive Windows usability were not exercised in this assessment.

**The product target is a workspace with zero routine modal interruptions.** Startup guidance, connection status, voltage selection, write planning, progress, and results should live in the main window. A problem should identify the affected action and offer its correction there. Remembering a preference should save repeated setup; fresh chip identity and connection checks should still run automatically when an operation needs them.

| Priority | Improvement | User benefit | Indicative effort |
|---|---|---|---|
| First | Remove the automatic startup doctor; make routine status inline | Open the app and start working | 1–3 days |
| First | Put write preparation and the accepted plan in the workspace | One clear Write action, fewer repeated questions | 1–2 weeks |
| First | Make post-write verification consistent | The same completion guarantee on the normal write paths | 3–7 days for the NOR path |
| Next | Complete interrupted-write recovery | Recover from a disconnect without manually reconstructing the job | 1–2 weeks for an initial NOR implementation |
| Next | Extract operation orchestration from the main form incrementally | Future fixes reach every entry point | Several small changes over 3–6 weeks |
| Next | Give chip profiles stable identities and better voltage metadata | Fewer ambiguous selections and voltage questions | 3–5 days for the schema and initial cleanup; catalog work continues |
| Before enabling gated hardware paths | Scope validation to the actual tested configuration | Measured facts apply to the correct setup | About 1 week of software work, plus bench access |
| Supporting work | Add executable workflow checks and align CLI contracts | Catch shipped behavior that unit tests cannot see | 3–7 days initially |
| Later | Complete selected translations, improve large-image handling, extend production profiles | Better accessibility and broader practical use | Driven by measured demand |

Effort estimates assume one maintainer familiar with the Pascal code. They overlap and are not an additive delivery promise. Physical measurements, hardware availability, and failed bench runs can dominate the validation schedule.

**The foundation is already stronger than the feature count suggests.** NOR and EEPROM planning preserve surrounding bytes, exercise cancellation boundaries, and test failures at individual device calls. The project has typed outcomes, session admission, immutable snapshots, a simulated programmer, and explicit distinctions between requested and measured voltage. These are useful assets to preserve during improvement. [Sources: `docs/testing.md`](testing.md), [`norengine.pas`](../software/norengine.pas), [`eepromengine.pas`](../software/eepromengine.pas), [`sessionstate.pas`](../software/sessionstate.pas).

The release workflow also already pins action revisions and important binary inputs, separates publishing permissions, and defines provenance attestation. Another broad release-security redesign would contribute less to the immediate Windows experience than completing the existing workflows. The configured GitHub environment's live protection rules were not independently verified here. [Sources: `build.yml`](../.github/workflows/build.yml), [`docs/releasing.md`](releasing.md).

**1. Remove the startup interruption at its source.** `FormShow` automatically invokes `MenuConnectionDoctorClick` when `ConnectionDoctorSeen` is false. The shipped settings explicitly set `connection_doctor_seen="0"`, and the doctor ends in `DoctorForm.ShowModal`. A fresh installation therefore has an automatic modal path before ordinary work. This is a concrete mismatch with the desired experience. [Sources: `main.pas`, lines 14985–15015 and 11653](../software/main.pas), [`settings.xml`](../settings.xml).

Remove the automatic invocation, retain Connection Doctor as an optional command, and show a compact connection state in the existing workspace. When no programmer is connected, keep opening and inspecting files available. For a missing driver, show the affected programmer and an Install driver link in that area; other usable programmers should remain available.

The main window is already created as a Repair workspace, and hardware detection is already implemented. Improve this existing entry point rather than adding onboarding screens. Move any slow startup probing off the form creation path so the window can become usable immediately. Restore ordinary preferences such as window geometry, workspace, language, programmer, and port; re-establish live operation facts separately. [Sources: `FormCreate`, lines 14874–14933](../software/main.pas), [`workspacemodel.pas`](../software/workspacemodel.pas).

Acceptance criteria: a fresh settings file reaches the workspace without a modal; an unplugged or unsupported programmer does not prevent loading a firmware image; repeated detection failures update one status area; opening the app never starts a destructive operation. Measure time until the workspace becomes interactive before setting a startup-performance target.

**2. Make a prepared Write button the single normal commitment.** The project currently uses modal voltage questions, mismatch warnings, Smart Write preview dialogs, ordinary write confirmations, and SFDP save/name questions. Several concern information that can be displayed or resolved beside the operation. `ConfirmSmartWritePreview` even uses an information dialog for preview-only and no-change results. [Sources: `main.pas`, `AskChipVccFromDatasheet` at 5270, `VoltageWarningOK` at 6989, `ConfirmSmartWritePreview` at 15928, and `MenuSFDPDetectClick` at 17160](../software/main.pas).

Use the main window to show the detected chip, image name and size, target rail, preparation state, and a compact plan. A normal known-chip write should follow this sequence:

1. Open or drop the image into the workspace.
2. Prepare the trusted read, backup, fit checks, and differential plan automatically when the setup is sufficiently known.
3. Display the change scope beside an explicit Write button.
4. Run the accepted plan, verify it, and leave the result in the same place.

The Write button itself commits the visible plan. There should be no subsequent generic “Are you sure?” dialog for that same action. If preparation is still running, show progress. If a rail, chip, or image changes, invalidate the prepared operation automatically and update the button state. The existing session-state model already contains useful revocation rules for this behavior. Avoid rescanning or rebuilding a plan just because the window repainted.

Unknown voltage belongs beside the voltage control: “Select this part's supply voltage.” An image-size problem belongs beside the image. A live-ID mismatch belongs beside the selected chip, with a matching-profile action. Repeating a warning should not become the means of approving a known mismatch. Resolve the configuration and enable the relevant action when its prerequisites hold.

Keep backups automatic with collision-resistant filenames, a predictable writable location, and an Open backup folder link. Show successful completion inline without an OK dialog. An SFDP-derived profile can offer Save profile as an optional action after detection, without interrupting the read. For unusual OTP and permanent-lock commands, use an explicitly labeled dedicated operation surface that shows their effect before execution.

This approach follows Microsoft's guidance to show contextual validation errors within the page and to use confirmation dialogs sparingly. The guidance concerns interaction design; the implementation can stay in Lazarus/LCL. [Microsoft, “Dialog controls”](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/dialogs-and-flyouts/dialogs), [Microsoft, “Commanding basics”](https://learn.microsoft.com/en-us/windows/apps/design/basics/commanding-basics).

Acceptance criteria: zero modal interruptions for startup, a normal read, a successful prepared write, and a no-change preview; no repeated question for unchanged setup; one explicit write commitment; an image or hardware change cannot execute an older plan. Progress must remain responsive, and cancellation must respect the engine's existing critical-command boundaries.

**3. Give every normal write path the same verification guarantee.** The README describes a second verification in a fresh USB session as part of every write. The implementation does not apply that guarantee universally. `ReVerifyInFreshSession` has one application call, in the legacy `ButtonWriteClick` path. Normal SPI NOR writes return earlier into `MenuSmartWriteClick`; that handler runs `TNORPlanExecutor.ExecuteBound`. The NOR executor verifies plan blocks, closes the session, and can commit success evidence without a second post-write reopen and read. The headless runner uses that executor too. [Sources: `README.md`, lines 210–223](../README.md), [`main.pas`, lines 11987–11990, 12161–12176, and 16051–16054](../software/main.pas), [`norengine.pas`, lines 627–669](../software/norengine.pas).

This is a confirmed implementation/documentation gap, not evidence of a demonstrated corrupt write. The existing full affected-block verification is meaningful. Reopening before execution to validate the preimage, which `ExecuteBound` does, is a separate guarantee from reopening after programming to verify the result.

Add the post-write reopen verification to shared orchestration, expose its completion separately in the outcome, and commit final PASS evidence only after all required stages finish. The expected bytes should come from the immutable accepted plan or final image, including preserved neighboring bytes, rather than a mutable editor buffer. A fresh USB session should continue to be described separately from a physical power cycle.

Acceptance criteria: simulated corruption visible only after reopen produces a failed outcome; reopen failure cannot become PASS; a no-change plan still performs required physical verification; GUI and CLI report the same completed stages. Correct the universal README claim immediately while the implementation is being aligned.

**4. Finish recovery as an ordinary workspace action.** Journaling is integrated into NOR Smart Write: it starts beside the backup and appends completed erase/program marks. However, searches across the application find no callers of `LoadJournal` or `DecideResume` outside `writejournal.pas`; their consumers are tests. The README's resumable-write claim therefore exceeds the currently exposed application workflow. [Sources: `main.pas`, `TNORUIBridge.Receive` at 1008 and journal setup at 16559](../software/main.pas), [`writejournal.pas`, `LoadJournal` and `DecideResume`](../software/writejournal.pas), [`README.md`, line 63](../README.md).

After an interruption, show an inline recovery card tied to the interrupted job. It should identify the chip, image, original backup, and last recorded work, then offer recovery inspection and an explicit recovery action. It should not take over startup with a modal. Give a support technician a simple route to the original backup even when resuming is not admissible.

Safe recovery needs more than connecting the existing decision function to a button. Reconstruct the intended final contents from the original trusted backup plus the accepted image. Read the actual interrupted device again and build a recovery plan against those intended contents. Otherwise an erased neighbor can be mistaken for the new baseline and permanently lost. Journal completion marks are useful history, but a completed command is not a substitute for checking the current physical contents.

Bind recovery to a versioned chip/geometry profile, the image and target range, and the backup hash. Use a chip UID where available; JEDEC ID plus capacity identifies a model, not an individual physical device. The current header has no UID or geometry-profile hash. Any sector erased again during recovery must have all required pages restored, including pages marked completed in an earlier attempt. [Source: `TJournalHeader`, lines 74–95, and `DecideResume`, line 475](../software/writejournal.pas).

Acceptance criteria: interrupt after erase, mid-program, during a journal append, and before evidence commit; restart the process; verify that the final whole-chip image matches the original backup with only the intended patch applied. Changed input artifacts must produce an inline refusal with a usable restore route. Gate initial resume support to the NOR combinations covered by these scenarios.

**5. Extract orchestration to make the quiet workflow maintainable.** `main.pas` contains **17,707 lines** and combines workspace layout, dialogs, settings, hardware selection, voltage decisions, backups, planning, execution, and production evidence. The issue is the number of responsibilities and paths, not the language or the line count by itself. The existing LCL-free core means a broad language or framework migration is unnecessary for this roadmap.

There are currently three important entry paths:

| Entry point | Operation route | Practical consequence |
|---|---|---|
| Windows GUI | Main-form handlers → planners/engines and legacy paths | Presentation and operation orchestration remain intertwined |
| `NVRAMancer.exe` command line | Hidden LCL application → many GUI handlers | Full catalog and machine contract, with dependencies on form state |
| `NVRAMancerCLI.exe` | `headlesscli` → `operationrunner` → NOR engine | A cleaner boundary with a smaller and different feature set |

[Sources: `NVRAMancer.lpr`](../software/NVRAMancer.lpr), [`cli.pas`](../software/cli.pas), [`headlesscli.pas`](../software/headlesscli.pas), [`docs/design-cross-platform.md`](design-cross-platform.md).

Introduce a shared operation coordinator around the existing engines. It should own immutable prepared jobs, admission results, backup references, execution, verification, recovery, and final outcomes. The GUI supplies user choices and renders state. CLI entry points supply parsed requests and render machine results. Hardware access for a job should retain a clear thread/session owner.

Start with the Windows NOR read/prepare/write path because it directly enables the desired experience. Preserve the current production identity, profile, backup, and evidence requirements during migration; simply routing the GUI through today's smaller runner would lose responsibilities. Migrate EEPROM and specialized paths in later bounded changes. Keep the existing virtual-device tests as invariants while adding tests for the new coordinator.

**6. Improve the catalog to eliminate questions the application could answer.** Only **109 of 1,751 shipped entries** have an explicit `vcc` attribute: five in the main table and 104 in the EZP table. Other supported voltage resolution mechanisms already exist, so this is not a count of unusable chips. It is evidence that verified structured metadata would reduce dependence on name conventions and operator questions. [Sources: the four `chiplist*.xml` files and [`validate_chiplist.py`](../tools/validate_chiplist.py)].

The validator also reports three duplicate names in the main table: `EN25Q32A`, `TS25L512A`, and `W25Q256JV`. In each case the entries have different IDs. For example, the two W25Q256JV entries use `EF4019` and `EF7019`. `SelectChip` accepts a display name and `SelectChipAny` searches catalogs in order, so a name is insufficient to select a unique definition. [Sources: `chiplist.xml`](../chiplist.xml), [`findchip.pas`, line 189](../software/findchip.pas), [`main.pas`, line 11049](../software/main.pas).

Add a stable profile identifier, separate display names from identities, preserve aliases, and record provenance for voltage ranges, geometry, and command behavior. Match an unambiguous live identity automatically. When evidence genuinely permits multiple profiles, show those choices inline with the differences that matter. Name-only CLI selection should refuse unresolved ambiguity instead of silently depending on catalog order.

Begin with the parts used on the supported Windows benches and the known collisions. Prefer manufacturer-documented voltage ranges and retain the existing conservative resolver for incomplete records. Catalog counts and command examples should be generated or checked: the README currently says 33 suites and 658 main-table entries, while the current suite catalog contains 35 suites and the main table contains 968 entries.

**7. Scope hardware evidence before graduating new capabilities.** `validationgate.BuildTable` is empty, so CH347/libusb writes and SPI NAND mutation have no release evidence in that table. The signal-characterization table is also empty. These are explicit pending capabilities, not proof that every already-supported programmer has never been used on real hardware. [Sources: `validationgate.pas`, line 290](../software/validationgate.pas), [`signalchar.pas`, line 230](../software/signalchar.pas).

The future activation boundary needs strengthening. `IsReleasedIn` receives a capability and chooses evidence for that capability; it does not receive the current chip/programmer/driver configuration to match. Signal lookup matches programmer identity and rail, while the CH347 backend supplies the generic identity `CH347`. Adding a measurement or completed checklist in the current model can therefore apply more broadly than the specific board and configuration tested. This is a latent scope problem: the empty tables do not currently confer those permissions. [Sources: `OutstandingItems` and `IsReleasedIn`](../software/validationgate.pas), [`LookupSignalCharacterisationIn`](../software/signalchar.pas), [`ch347hw.pas`, line 257](../software/ch347hw.pas).

Use explicit station/board profiles with hardware revision, adapter, driver or library version, rail, validated clock range, and supported chip/operation combinations. Match runtime facts or an explicitly selected fixture profile to that evidence. In the workspace, a remembered verified setup should operate quietly; replacing a fixture or changing a material configuration should update its validation state.

Prioritize the Windows hardware actually used by the maintainer. Completing Linux or NAND expansion should follow demand and bench evidence. The present Linux HIL script is read-only, and the scheduled Windows harness can run detection-only when no chip is supplied. Extend the harness to exercise the claimed operation before treating a green workflow as evidence for it. [Sources: `tools/hil.sh`](../tools/hil.sh), [`tools/hil.ps1`, lines 114–135](../tools/hil.ps1), [`docs/hardware-in-loop.md`](hardware-in-loop.md).

**8. Test the delivered workflows and clarify the two CLIs.** Freshly compiled `NVRAMancerCLI.exe` returned exit code 2 for both `--gates` and `--scan tests/sfdp/w25q64-uniform.bin --json`. It successfully decoded that fixture with `--sfdp-decode`. The headless parser does not accept JSON or gates switches and declares only exit codes 0, 1, and 2. The GUI-backed CLI implements the 14-outcome contract. The README describes the switches as shared, and the NAND design document specifically gives a headless `--gates` example. [Sources: `headlesscli.pas`, lines 20–24 and 124–139](../software/headlesscli.pas), [`clicontract.pas`](../software/clicontract.pas), [`README.md`, lines 252–254](../README.md), [`docs/design-spi-nand.md`, line 138](design-spi-nand.md).

Correct the executable names and supported-option examples now. Then reuse `clicontract` in the headless frontend and move toward one documented machine interface as the coordinator grows. This is supporting engineering work; Windows GUI usability should determine the release order.

Add process-level tests for documented commands, malformed inputs, JSON output, refusal paths, and successful offline operations. Expose the simulator explicitly to the CLI for reproducible read/prepare/write/restart scenarios; neither current CLI parser offers it as a normal named backend. In UI/coordinator tests, assert that ordinary flows generate no modal requests and that known failures never request an override to an impossible state.

Keep the strong existing fault and preservation suites. Add a checked-compiler lane: FPC provides `-Cr` for range checks and `-Co` for integer-overflow checks. The Lazarus Debug configuration enables checks, but the ordinary standalone suite commands do not explicitly request them. Three focused suites rebuilt with both flags passed: write journal, SFDP profile, and NOR engine. [Sources: `NVRAMancer.lpi`](../software/NVRAMancer.lpi), [`build.ps1`](../tools/build.ps1), [Free Pascal, “Compiler options”](https://docs.freepascal.org/docs-html/current/user/usersu70.html).

A few small build fixes are warranted: require Python when validation is part of the build contract; include `chiplist-imsprog.xml` in the POSIX validator inputs; and check the compiler exit code immediately when building the EZP tools. Those tool builds currently check only whether an executable exists, which can accept an old executable after a failed local rebuild. The suite helper, by contrast, recreates its output directory. PowerShell tracks native-program failure through exit codes independently of its ordinary error handling. [Sources: `build.sh`, lines 44–55](../tools/build.sh), [`build.ps1`, lines 111–129 and 419–424](../tools/build.ps1), [Microsoft, “about_Error_Handling”](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_error_handling?view=powershell-7.6).

**9. Make later investments follow the Windows workflow.** Most non-English catalogs report roughly 18–20% coverage against the 497 English message IDs; Thai reports 20.3%. Complete the main workspace, progress, result, and inline-correction messages in the languages actually used, with human review of electrical and irreversible-operation wording. Coverage is a maintenance indicator, not a direct measurement of user comprehension. [Source: `check_project_metadata.py`](../tools/check_project_metadata.py) and [`software/lang`](../software/lang).

For large images, measure preparation time, peak memory, transfer time, verification time, and cancellation latency on representative 8, 16, 32, and 64 MiB workloads. The planner materializes a complete desired image and stores bytes in program/verify steps; the GUI also creates streams and byte-array snapshots, while the Windows executable targets 32-bit. This suggests a possible memory and copy-cost limit, but no performance bottleneck was measured here. Introduce a bounded snapshot store or chunked comparisons only where measurements justify it, retaining immutable expected bytes. [Sources: `norplanner.pas`, lines 342–447](../software/norplanner.pas), [`main.pas`, `StreamBytes` at 16028](../software/main.pas), [`NVRAMancer.lpi`](../software/NVRAMancer.lpi).

If production demand requires larger NOR parts, design canonical profile version 2 with explicit address strategies, four-byte opcodes, and sector geometry. The current strict GUI Smart Write path rejects chips above 16 MiB because profile v1 cannot bind that command behavior. Version migration must be explicit because these bytes are authenticated. This work should follow a usable, validated Windows workflow. [Sources: `chipprofile.pas`](../software/chipprofile.pas), [`main.pas`, strict-profile checks near 16275](../software/main.pas).

**The first delivery should be small and visible.** Remove the automatic connection doctor, preserve optional access to diagnostics, replace routine preview/status dialogs with an in-window preparation/result area, and correct the overstated CLI and recovery claims. Then implement consistent post-write verification and the first recovery workflow through a shared coordinator. Preserve the portable Windows package and existing backend compatibility while these changes land.

Success should be measured as fewer operator interruptions and more complete operations: zero routine modals, one explicit commitment per prepared write, no stale-plan execution, consistent final verification, and demonstrable recovery after interruption. The initial release does not need another programmer, a new desktop framework, or a setup wizard to achieve those outcomes.

**Validation record and sources.** Repository links above refer to the source snapshot identified at the start. The following results were obtained on Windows with the installed Lazarus/FPC 3.2.2 toolchain:

| Check | Result |
|---|---|
| `powershell -NoProfile -ExecutionPolicy Bypass -File tools/build.ps1` | Exit 0; all 35 registered suites, tools, headless executable, and Windows GUI built |
| `python tools/check_project_metadata.py` | Passed; suite catalogs agree; localization gaps reported |
| Four-table `validate_chiplist.py` invocation | 1,751 entries; 0 errors; 25 warnings |
| Checked build: `writejournal_tests` | 69 assertions, 0 failures |
| Checked build: `sfdpprofile_tests` | 63 assertions, 0 failures |
| Checked build: `norengine_tests` | 85 assertions, 0 failures |
| Headless `--gates` | Rejected as unknown option; exit 2 |
| Headless `--scan ... --json` | Rejected as unknown option; exit 2 |
| Headless `--sfdp-decode tests/sfdp/w25q64-uniform.bin` | Exit 0; decoded 8 MiB geometry, 256-byte pages |

The 25 chip-table warnings include expected non-power-of-two DataFlash geometries as well as identity/name and opcode warnings; they should not all be classified as invalid chips. The checked builds covered three focused suites, not all 35. No live chip read/write, graphical interaction run, fresh release-package installation, performance benchmark, or remote release-permission verification is claimed.

External primary references, accessed September 14, 2026:

- Microsoft. [Dialog controls](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/dialogs-and-flyouts/dialogs). Contextual inline validation and dialog behavior.
- Microsoft. [Commanding basics](https://learn.microsoft.com/en-us/windows/apps/design/basics/commanding-basics). Placement of actions and restrained use of confirmation dialogs.
- Free Pascal. [Compiler options](https://docs.freepascal.org/docs-html/current/user/usersu70.html). Range and integer-overflow checking options.
- Microsoft. [about_Error_Handling](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_error_handling?view=powershell-7.6). Native-command exit-code handling.
