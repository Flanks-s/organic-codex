# Whole-tree component harnesses

Run `python3 tools/m11/component-check.py KIND OUT` on macOS with Xcode selected.
Each kind builds the original product `@main` against the whole product tree
through `check_package.py`, debug, four compiler jobs, with the helper's per-file
`-O`. No source lists, product substitutions, or stand-in types are maintained here.
All 13 kinds remain separate because each flag or Dock mode selects a different
original harness path. No added Swift drivers are needed.

`COMPONENT_COMPILE_ONLY=1` prepares and builds, then exits zero without launching.
The default package, including staged body assets, is `OUT/.package-KIND`.
`M11_CHECK_PACKAGE` overrides that exact package path; use a different path for each
kind when retaining caches across jobs. `CHECK_BODY_ASSETS` can share body staging
between packages. Every invocation writes `OUT/KIND/sources.txt` using the helper's
`--list`. Build/run logs and PID records are in `OUT/KIND`; images and reports go
there too. The entry runs from the repository root for product source audits.

A completed run's last line is `COMPONENT KIND: N checks, M findings`, copied from
that harness's final summary. Exit 0 means no findings, 1 means findings, 2 means
preparation/build failed, and 3 means the harness did not complete or its summary
and exit disagree. Compile-only prints `COMPONENT KIND: compile-only`; it never
claims checks ran. A crash, missing/zero/duplicate summary, or partial probe cannot
produce a successful numeric component line. The full original output is retained.

Overlay sets `M10_FRAMES=1`, as the old content-transition entry did, so its M10 and
M10.1 assertions join the ordinary suite. Normie motion sets
`NORMIE_CHECK_CONFIGURATION=debug`, matching the old script's default debug suite:
its release-only timing assertions remain release-only. Probe selectors that would
skip the full suite are removed from the child environment. Other environment
selectors (including Dock switches and optional Settings reference directories)
retain their product meaning. The Sheets M10.1 summary's separate container-finding
count is evidence already tested by its `check` calls, not extra checks or findings
to add again. No totals are inferred from individual `FAIL`/`FINDING` lines.

## Window and focus audit

Paths below are relative to `Sources/OrganicShell/`. The audit follows each selected
entry and its callees, including lazy controller methods and injected callbacks;
merely compiling AppKit presentation code does not invoke it. None of these paths
calls `NSApp.activate`, orders a window, enters a native modal loop, or presents a
native panel. A view/page's `activate` and `present(..., in: host)` methods here
operate on the unattached view tree. Final no-visible-window assertions corroborate
the call-path audit; they are not the sole basis for it.

Shared preparation is also offscreen: `check_package.py` stages through
`scripts/build-body-assets.py:327` and `tools/bodies/BakePackage.swift:6`. The baker
and its `Bodies/` dependencies encode raster files using Foundation/ImageIO and
Core Graphics; they contain no AppKit window/presentation/activation path.

| Kind | Define | Original driver | Arguments after output | Offscreen and deciding evidence |
| --- | --- | --- | --- | --- |
| native | `M1_SELFTEST` | `Native/NativeIntegrationVerification.swift:6`, `M1Verification` | none | Yes. Unattached controls at `NativeIntegrationVerification.swift:753`; focus fixture explicitly avoids windows at `Native/NativeComposerBarFocusVerification.swift:34`; final check at `NativeIntegrationVerification.swift:888`. Called Native verification helpers use views and synthetic events, not window presentation. |
| settings | `SETTINGS_SELFTEST` | `Settings/SettingsVerification.swift:39`, `SettingsVerification` | none | Yes. Lazy install is checked at `SettingsVerification.swift:103`; lifecycle uses `acquireContent` at `Settings/SettingsGroup1Verification.swift:116`, never `show` (`Settings/SettingsWindow.swift:39`). Alert bodies are built at `SettingsVerification.swift:245`, never run. Color panel is injected at `SettingsGroup1Verification.swift:185`; fake `show` only records callbacks at line 36. |
| overlay | `OVERLAY_SELFTEST` | `Overlay/OverlayVerification.swift:5`, `OverlayVerification` | none | Yes. Host remains unattached at `OverlayVerification.swift:287`; Group 1 presents into that view at `Overlay/OverlayGroup1Verification.swift:38` and checks visibility at line 120. M10/M10.1 exposure helpers render layers and bitmap fixtures, not native popovers or panels. |
| sheets | `SHEETS_SELFTEST` | `Sheets/SheetsVerification.swift:19`, `SheetsVerification` | none | Yes. `SheetTestWindow.present` only records at `SheetsVerification.swift:14`; injected factories at lines 201, 233 and 243 avoid `SheetAppKitWindow.present` (`Sheets/SheetWindows.swift:46`, which would show a window). Ordinary surfaces present into unattached views; final check at line 280. |
| sheets-m101 | `SHEETS_M101_SELFTEST` | `Sheets/SheetGaussianVerification.swift:5`, `SheetGaussianVerification` | `gaussian-debug` | Yes. `fixture` creates only an `OverlayView` and sheet/toast views at `SheetGaussianVerification.swift:11`; `Scene` renders a layer host at line 47; live component checks explicitly use `windowless:true` at lines 163 and 190; visibility check at line 140. |
| debug | `DEBUG_SELFTEST` | `Debug/DebugVerification.swift:6`, `DebugVerification` | none | Yes. Uses `acquireContent` at `DebugVerification.swift:98` and fake scene hosts. `Debug/DebugWindows.swift:9` loads only the page; the window-ordering `toggle` at line 14 is never called. Page `activate` is lifecycle only. Final check at `DebugVerification.swift:173`. |
| tools | `TOOLS_SELFTEST` | `Tools/ToolsVerification.swift:6`, `ToolsVerification` | none | Yes. Loads only `windowOwner.content` at `ToolsVerification.swift:43`; `Tools/ToolsWindow.swift:27` constructs no window. `present` at line 28 is never called. PDF checks use unattached previews (`Tools/ToolsPDFVerification.swift:130`); PTY fixture runs only printf (`ToolsVerification.swift:204`). |
| header-ax | `HEADER_AX_SELFTEST` | `Debug/DebugHeaderAXVerification.swift:5`, `DebugHeaderAXVerification` | none | Yes. Unattached interaction carrier at `DebugHeaderAXVerification.swift:12`; reads proxy getters and disposes the header at lines 15-27. No window owner or presentation callback. |
| split | `M9_SPLIT_SELFTEST` | `Native/NativeComposerSplitVerification.swift:6`, `NativeComposerSplitVerification` | none | Yes. Entry runs mounted Orb, model sizing, and detached Dock view fixtures at `NativeComposerSplitVerification.swift:23`; no-visible-window check at line 29. `Native/NativeComposerModelSizingVerification.swift:63` uses an unattached `NSHostingView`. |
| split-model | `M9_MODEL_SELFTEST` | `Native/NativeComposerModelSizingVerification.swift:108`, `NativeComposerModelSizingMain` | none | Yes. Independent SwiftUI reference is an unattached `NSHostingView` at `NativeComposerModelSizingVerification.swift:63`; no window presentation, visibility check at line 116. |
| normie-motion | `M10_COMPOSER_SELFTEST` | `Normie/NormieMotionVerification.swift:113`, `NormieMotionVerification` | none | Yes. Actual controller fixture loads and lays out only its view at `NormieMotionVerification.swift:197`; `show` selects its conversation, not a window. Renderer at line 156 uses layers; full suite at line 793 and final check at line 861. Does not call the separate Normie inspector window-host verification suite. |
| dock-switches | `M10_DOCK_SELFTEST` | `Organic/DockMotionVerification.swift:5`, `M10DockVerification` | `--switches` | Yes. Early dispatch at `DockMotionVerification.swift:183` calls only `switches`: unattached root/composer at line 657 and Orb adapter at line 664; resets/disposes at line 670. Other Dock modes are not reached. |
| dock-gaussian | `M10_DOCK_SELFTEST` | `Organic/DockMotionVerification.swift:5`, `M10DockVerification` -> `M10DockGaussianVerification` | `--gaussian` | Yes. Early dispatch at `DockMotionVerification.swift:182` reaches `Organic/DockContentTransitionVerification.swift:10`: layer renderer at line 23, bitmap/component wiring at line 117. Native wiring creates detached views, never a window owner. Other Dock modes are not reached. |

All 13 selected kinds are offscreen candidates for CI without a real display.
This does not claim WindowServer glass, physical timing, IME, or human visual parity;
the original harness boundaries remain in their reports. No selected kind currently
needs the label **MBA only, not during real-window measurements**. A future change
that adds a visible/focus-taking path must receive that label and be compile-only
during measurements; re-audit reachable code when changing flags, arguments or drivers.

## Clock builder

`scripts/build-uptime-harness.py` now uses `check_package.py` for all three profiles,
including the `OrganicBodyResources` target and staged body bundle. Split/full keep
private copies with their original `@main` attributes removed and use the existing
dispatcher. The builder leaves original files untouched. `--profile m11` and the canonical M11
part of `--extras` call the helper directly with the two current M11 driver files
and both current defines; no shell-script text or heredoc is parsed. Builds retain
release configuration, the original SwiftTerm dependency for Split/full, the fixed binary paths and the `UPTIME_*_BINARY` output lines.
The two clock runners' command lines and successful per-case output formats are unchanged; decision #193 adds explicit failure summaries.

### Decision #193 follow-up

The clock runner now returns nonzero for any nonzero child exit, including
signals/timeouts and failed cases retained in resumed evidence. Its last failure
line names each failed clock and its actual exit code. Successful per-case JSON
output is unchanged. Split preserves the child exit before reading its report;
a missing report now gives a named failure and saved process/evidence receipts
instead of masking the child failure with a traceback.

The complete `scripts/` exit-status audit found:

| Script | Status handling |
| --- | --- |
| `verify-uptime-clocks.py:189` | Fixed: child exits were recorded but `main()` returned no status. The entry now raises `SystemExit(main())` and fails if any child failed. |
| `verify-split-environment.py:79` | Already returned nonzero for failed children; missing reports masked their status. Now records/reports it explicitly. |
| `errors.sh:6` | Fixed: the compiler's status was lost through its display pipeline. Capture it before filtering and return it at line 9. |
| `swapcheck.sh:7` | Fixed: `claude-build.sh` failure was lost through `tail` at line 10. Enable `pipefail` so it stops before window launches. |
| `build.sh:10` | Already captures the compiler status and returns it at line 12; other commands use `set -e`. |
| `claude-build.sh:31` | Already tests compiler failure explicitly and exits 1 at line 33; other commands use `set -e`. |
| `package-bodies.sh:6` | Python child failure propagates under `set -e`. |
| `selftest.sh:15` | Waits for both children and exits with their statuses ORed at line 18. |
| `build-body-assets.py:330` | Compiler, baker and rsync use `check=True` (lines 330, 331, 383); compiler-version lookup uses `check_output` at line 276. |
| `build-uptime-harness.py:59` | All compiler/build invocations use `check=True`; binary-path lookup uses `check_output`. |
| `parity.py:6` | Data reporter; launches no child processes. |

`tools/m11/clock-runner-test.py` runs real fake Python children behind mocked
compiler/probe setup, so no Swift runs on Windows. Five clock tests cover failed
and successful children plus Split failures with and without a report. Three
bundle tests cover complete placement, stale-file synchronization, and a missing
bundle before publishing the fixed binary. The zsh case tests compiler exits 0/7
and a failed swap build, with launch sentinels; its copied swap script redirects
the absolute `open` command to the fake command too. The real-window swap workflow
is never run here.

The first MBA tool-test attempt exposed a fixture error: fake clock libraries were
injected into the real Python fake child, which macOS aborted with -6. The fixture
now removes that test-only `DYLD_INSERT_LIBRARIES` before launching Python. No
production runner environment was changed. All eight Python tests pass locally;
the shell case is skipped on Windows. The corrected nine-test MBA rerun,
`comp2-run-261112-103334-eyv`, stayed queued behind gate/measurement work and was
canceled at the round's approximately 120-minute limit (recorded helper PID
47721). The latest complete nine-test suite is therefore not MBA-verified. The
shell case and all three bundle tests passed in the first MBA attempt; the four
synthetic-clock failures were the dummy-dylib fixture issue above. The eight
existing component-tool tests passed both locally and on the MBA.

Combined job `comp2-run-261112-092355-lqi` read and saved SwiftPM's generated
accessor before any fixed-copy placement. In
`runs/comp/r4/accessor/resource_bundle_accessor.swift`, its candidates are
`Bundle.main.resourceURL` (line 29), `Bundle(for: BundleFinder.self).resourceURL`
(line 32), and the CLI candidate `Bundle.main.bundleURL` (line 35). Line 39 appends
`bundleName + ".bundle"`. Environment overrides are DEBUG-only (line 13); release
uses the normal candidates. The generated accessor is unchanged.

The builder now copies the complete built resource bundle beside the fixed
executable, satisfying the CLI candidate:

| Profile | Fixed executable | Bundle beside it |
| --- | --- | --- |
| split | `clock-split/fixed/UptimeHarness` | `UptimeHarness_OrganicBodyResources.bundle` |
| m11 | `clock-m11/fixed/Check` | `M111Check_OrganicBodyResources.bundle` |
| full | `clock-full/fixed/UptimeHarness` | `UptimeHarness_OrganicBodyResources.bundle` |

Paths are under the job's private `copy/r4-check/`. Each bundle contains 997 files;
`fixed-bundle.json` records its source, destination, size and executable hash.
Missing bundles fail the builder, and repeated placement removes stale files from
the helper-owned destination. The default flat entry runs the executable in
SwiftPM's build directory, where its bundle already sits beside it. Clock builds
relocate the executable into `fixed/`, so they also need the bundle there.
`check_package.py` and SwiftPM's accessor generation are untouched.

All three release builds succeeded (`-j 4`): split **282.62 s**, m11 **240.08 s**,
full **395.17 s**. Both clock runners ran exactly once with the r1 arguments.
These are the first runtime baselines; findings were left unchanged under #144:

| Runner / clock | Checks | Findings | PNGs | Child exit |
| --- | --- | --- | --- | --- |
| Split current | 357 | 0 | 762 | 0 |
| Split afternoon | 357 | 0 | 762 | 0 |
| Split evening | 357 | 0 | 762 | 0 |
| M11 real | 353 | 14 | 10 | 1 |
| M11 small (frozen 10800) | 371 | 39 | 4 | 1 |
| M11 large (frozen 3456000) | 371 | 39 | 4 | 1 |

Split's PNGs and pixel steps are identical across all three clocks; its runner
exited 0. Each case wrote `clocks-run/split/<case>/report.json`. M11 cases wrote
`clocks-run/m11/<case>/verification.json`; its runner exited 1, with this last line:

```text
UPTIME CLOCKS FAILED: real exit 1; small exit 1; large exit 1
```

Exact runner outputs are `check/runner-split-entry.log` and
`check/runner-m11-entry.log` under the main tree's `runs/comp/r4/`, together with
all case reports, PNGs, process records and generated accessors. The frozen M11
clocks have the same PNG manifest; real differs. Their 39 findings include
geometry/source completion, opening-header/native-admission, and composer
ownership/identity failures in addition to the existing motion findings. These
clock-dependent product observations were not fixed or diagnosed as a specific
source defect.

Default caller/component comparisons:

| Entry | Before | R4 |
| --- | --- | --- |
| M11-1 | 353 checks / 14 findings | 353 checks / 14 findings |
| Header AX | compile-only success | compile-only success |
| split-model | 55 checks / 0 findings | 55 checks / 0 findings |

The default manifest and source list are byte-identical to the retained before
artifacts and keep SHA256
`cb12f4e954214e9d2019afae9a1f232522b59cba0ec2d35219c33cb77a215bbd`
and `77618e3ecc6d637679775d072a16bda545b181172be3cfec6591d0228eb25cc2`.
All 545 protected product/resource/package/helper files are unchanged in this
round. M11's default exit 1 reflects the retained 14 findings. The combined batch
also exits nonzero for nonzero commands; its original exit 1 included the fixture
failure and the two expected finding exits. No clock baseline was rerun to fix it.

The separate inspection submission `comp2-run-261112-090415-tvc` was canceled while
queued to avoid two queue cycles. All jobs use `--prio build --no-promote --detach`
and only item `comp2`. Both inspection and acceptance stages removed their own
packages/copies before ending. The final fixture rerun remains unverified as described above. After canceling
that queued job, `comp2` was cleaned (116.1 MiB); cleanup waited 50 seconds for an
active measurement to release the tool lock. No operation was performed on item
`comp`. Sources, resources, `Package.swift`, and the default helper are unchanged.
No commit or GitHub write was performed. Full was compile-only; the real-window swap workflow and CI were not run.

### Decision #189 / r3 evidence

Decision #189 control is confirmed by supervisor job
`ctl189-run-261112-060829-kix`: identical M11 release inputs and manifest failed
with flattened sources (exit 1, 35.9 s; `Keyframes.swift:10:9`, non-Sendable
`[NSNumber]` in `Timeline.linearKeys`) and built with preserved directories
(exit 0, 238.7 s). The original source bytes were identical in both layouts.

The reviewed optional `prepare(..., keep_tree=False)` / `--keep-tree` proposal is
applied. The default still links `Sources/Check/<basename>`; the opt-in layout
keeps repository-relative directories under `Sources/Check/`, including the
original directory of replaced product sources. External generated drivers go
under `tools/added/`. The split, M11 and full clock builds opt in with
`keep_tree=True`. No concurrency checks are suppressed.

The one approved product edit is retained after matching all three host totals:

```diff
-    #if M10_DOCK_SELFTEST
+    #if M10_DOCK_SELFTEST && !(ORB_SELFTEST || ISLAND_SELFTEST)
```

This is the inner guard at `Sources/OrganicShell/Orb/OrbComponent.swift:758`;
it is the only product-source change. The builder itself leaves original files
untouched while preparing private entry-stripped copies.

R3 baseline job `comp2-run-261112-071622-zov` and after job
`comp2-run-261112-074708-gyo` staged real resources using
`scripts/package-bodies.sh` at the host runner's expected
`build/OrganicShell.app/Contents/Resources/Bodies` path. Both validated the
catalogue, sprite index and shader before running the hosts.

| Check | Before checks / findings | After checks / findings |
| --- | --- | --- |
| Dock host | 21791 / 0 | 21791 / 0 |
| Orb host | 509 / 0 | 509 / 0 |
| Island host | 977 / 0 | 977 / 0 |
| Default M11-1 | 353 / 14 | 353 / 14 |
| idle61 short inspector (`IDLE61_ONLY=1`) | 77 / 0 | 77 / 0 |

The M11 and idle61 before numbers are the accepted r2 baselines. All 521
recorded inputs matched that exact tree before r3 edits. The r2 host runs used
unstaged resources and are excluded from this comparison. The new before
manifest and source list also match the r2 artifacts byte for byte.

Default M11 `Package.swift` and `check_package.py --list` output are byte-identical
before and after. The reference/after artifacts are
`before/m11-default-Package.swift`, `after/m11-default-Package.swift`,
`before/m11-default-sources.txt`, and `after/m11-default/sources.txt` under the
main tree's `runs/comp/r3/`. The after M11 run exited 1 for the same 14 findings;
no findings were fixed. idle61 exited 0. Header AX passed compile-only using the
default helper layout (`COMPONENT_COMPILE_ONLY=1`).

All three clock profiles built in release, with `-j 4` and preserved directories:

| Profile | Build exit | Swift build time | First compile error |
| --- | --- | --- | --- |
| split | 0 | 283.79 s | none |
| m11 | 0 | 239.70 s | none |
| full | 0 | 403.30 s | none |

The runners used the same commands/arguments as r1 `clocks-run-1.txt`, pointing
to each profile's fixed binary. Their first runtime results are blocked:

- Split: the `current` gate aborted with
  `OrganicBodyResources/resource_bundle_accessor.swift:44: Fatal error: unable to find bundle named UptimeHarness_OrganicBodyResources`.
  The runner then exited 1 reading the absent `current/report.json`.
  Afternoon/evening were not reached, and no Split check total was produced.
- M11: `real`, `small`, and `large` each exited **-5 (SIGTRAP)** with
  `OrganicBodyResources/resource_bundle_accessor.swift:44: Fatal error: unable to find bundle named M111Check_OrganicBodyResources`.
  Each produced **0 PNGs** and no verification summary. The runner itself
  exited 0 because it records child results rather than failing for their exits.
  That outer exit is not a passing clock comparison.

Exact M11 runner output:

```json
{"name": "real", "exitCode": -5, "elapsedSeconds": 0.7178187080000001, "PNGCount": 0, "PNGManifestSHA256": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"}
{"name": "small", "exitCode": -5, "elapsedSeconds": 0.09038745799999992, "PNGCount": 0, "PNGManifestSHA256": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"}
{"name": "large", "exitCode": -5, "elapsedSeconds": 0.09025570900000002, "PNGCount": 0, "PNGManifestSHA256": "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"}
```

The fixed clock copies cannot locate their resource bundles. This is a runtime
packaging blocker, not evidence about clock-sensitive product behavior. It is
left unchanged under decision #144's first-run rule. Clock comparisons remain
unverified. Full was compile-only as requested; no full-profile runtime was run.

The six keep-tree tests and eight component tooling tests pass locally without
running Swift. Set `CHECK_PACKAGE_BASELINE` to the unchanged helper and run
`python3 tools/m11/check-package-tree-test.py` to include both default-output
comparison tests; the other four tests run without that optional reference.

Complete receipts, generated manifests/source lists, logs and PNGs were pulled
to the main tree's `runs/comp/r3/` (`summary.json`, `before/`, `after/`). Both jobs
removed their own packages, copies and staged app resources before ending.
`comp2` was cleaned afterward (138.7 MiB). No operation was performed on item
`comp`, and no CI or GitHub writes were performed.

Queued-only submissions `comp2-run-261112-070838-cnh` and
`comp2-run-261112-074308-ady` were canceled before execution and replaced,
respectively, to confine baker eviction to the own item and to disable automatic
priority promotion. The after job used `--prio build --no-promote --detach`.

## Portable tooling validation

Run `python3 tools/m11/component-check-test.py` on Windows or macOS. The eight
unittest cases cover all 13 original summary formats; missing, partial, duplicate,
zero and contradictory summaries; abnormal exits; compile-only/build-failure paths;
stale receipts; private-package path guards; full-suite environment selection; and all three clock package
profiles. Compiler execution, body baking and symlinking are mocked in the package
profile test. It checks the real generated manifest/resource dependency, original
source hashes, private entry stripping, canonical M11 additions and fixed-binary
receipts. These are tooling tests, not component acceptance counts.

## MBA verification, 2026-11-12

Compile-only job `comp-run-261112-013619-nbk` built all 13 kinds successfully,
each from 516 Swift sources. It waited 2,230 seconds at build priority and ran
for 2,415 seconds. No product changes or source substitutions were required.
Complete build logs, source receipts and process records are under
`runs/comp/compile-1/`; `runs/comp/compile-results.json` summarizes the results.
Execution and clock-profile results are separate from this compile evidence.

Job `comp-run-261112-025411-zxz` completed these original harness runs:

```text
COMPONENT dock-switches: 3 checks, 0 findings
COMPONENT split-model: 55 checks, 0 findings
COMPONENT header-ax: 6 checks, 0 findings
```

The same job attempted all three clock profiles. The resource target built and
the M11 profile reached compilation without parsing a shell script, but the r1 release
attempts reported these diagnostics:

| Clock profile | First r1 diagnostic |
| --- | --- |
| split | `Engine/Keyframes.swift:10:9`: stored property 'linearKeys' of 'Sendable'-conforming struct 'Timeline' has non-Sendable type '[NSNumber]' |
| m11 | `Engine/Keyframes.swift:10:9`: stored property 'linearKeys' of 'Sendable'-conforming struct 'Timeline' has non-Sendable type '[NSNumber]' |
| full | `Organic/DraggedGlyphVerification.swift:49:46`: ambiguous use of 'verificationGlyphLayer' |

Paths in that table are relative to `Sources/OrganicShell/`. No product fix,
source exclusion, or concurrency-check suppression was applied. No fixed clock
binary was produced, so the two clock-comparison runners could not be exercised.
Logs and receipts are in the Mac runner's `runs/comp/run-1/` and
`runs/comp/clocks-build-1/` directories.

The remaining execution job, `comp-run-261112-033222-ejo`, was canceled while
still queued at the round's time limit (recorded helper PID 57440). Consequently
`native`, `settings`, `overlay`, `sheets`, `sheets-m101`, `debug`, `tools`, `split`,
`normie-motion` and `dock-gaussian` have successful compile-only receipts but no
first execution result from this round. The prepared later run groups were not
submitted. All 13 are offscreen candidates for a CI baseline; CI execution and
baseline acceptance remain unverified.

All completed artifacts were pulled before `mac.ps1 clean comp` removed the
11,910 MiB private item. At the end of r1, no `comp` job remained queued or running. Changes are
uncommitted on `lane/comp`; no CI baseline or GitHub publication was performed.

## Baselines (decisions #144, #195, #197; infra lane, 2026-11-12)

First runs are baselines; findings are not fixed in the harness round (#144). MBA = MacBook Air, 2x built-in display;
CI = GitHub macOS runner, 1x 1024x768 screen, Reduce Motion and Reduce Transparency switched off (#171).

| Kind | MBA first run (checks / findings) | CI (`@component`, `ci/comp-ci-1`, confirmed by `-2`) | Notes |
|---|---:|---:|---|
| native | 2575 / 0 | 2575 / 80 (79 counted) | CI-only: typed/full byte mismatches, CI environment (1x screen) baseline; 1 timing line never counts |
| settings | 3633 / 3 | not on CI | Needs `SETTINGS_PARITY_REFERENCE` (`runs/parity-settings-all`) and `SETTINGS_M9C_REFERENCE` (`runs/parity-settings-m9c2-044931`), both restored from the 11-07 MBP archive. Without them: 2407 / 38. The 3: `Text parity appearance … has the measured native text origin` (Show All (29), Show All (30), #1E1E1E); `SETTINGS_TEXT_APPEARANCE_REFERENCE` was not set (it falls back to the M9C set) and no older value of it was found |
| overlay | does not complete | not on CI | Debt #75: `peek-row-adapter-in` accum 1.0x grows memory until SIGKILL, debug and release |
| sheets | 165 / 2 | not on CI | Debt #76 |
| sheets-m101 | 1236 / 1 | not on CI | Debt #77 |
| debug | 455 / 0 | 455 / 0 | |
| tools | 424 / 0 | 424 / 0 | |
| header-ax | 6 / 0 | 6 / 0 | |
| split | 357 / 0 | 357 / 14 | CI-only, CI environment (1x screen) baseline: 2.0x truncation/editor remainder, raster step |
| split-model | 55 / 0 | 55 / 12 | CI-only, CI environment (1x screen) baseline: 2.0x truncation/editor remainder |
| normie-motion | 44147 / 0 | 44148 / 0 | |
| dock-switches | 3 / 0 | 3 / 0 | |
| dock-gaussian | 2418 / 1 | 2418 / 1 | Debt #78 |
