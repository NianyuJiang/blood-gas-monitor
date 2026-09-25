# BloodGas — Multi-Parameter Blood Gas Monitor

A Flutter application for real-time, multi-parameter blood gas monitoring.
It connects over Bluetooth Low Energy (BLE) to **BG_MINI** optical sensors
(firmware: `zephyrproject/apps_nj/ESP32_BG`) and continuously displays and
records pO₂ (lifetime and intensity methods), pCO₂, pH, and temperature for up
to **8 simultaneous devices**.

> **Derived from the NICU Gas Monitor app** (`MGH/app/NICU-App/nicu_app`)
> — same screens, same recording / history-buffer resume / timestamp logic.
> Differences: the 40-byte BG packet (9 values + timestamp), the added
> **pH Ratio** chart (GAS MONITOR and HISTORY, between pCO₂ Ratio and
> Temperature), 44-byte history records, and a separate app identity so it
> installs alongside the NICU app.

| | |
|---|---|
| **Display name** | BloodGas |
| **Android package** | `com.example.blood_gas_monitor` (Kotlin namespace kept as `com.example.gas_monitor`) |
| **iOS bundle ID** | `com.example.bloodGasMonitor` |
| **Framework** | Flutter 3.44 / Dart 3.12 |
| **Platforms** | Android (deployed) · iOS (project configured, requires macOS to build) |
| **Codebase** | 15 Dart source files · ~7,800 lines |

> Derived from the single-parameter Capnography application (`../../CO2-APP/`),
> extended into a multi-parameter, multi-device monitoring platform. Both
> applications share the same layered architecture.

---

## 1. Capabilities

- **Multi-device monitoring** — up to 8 concurrent BLE sensors, each with an
  independent session, waveform buffer, and recording.
- **Nine-channel acquisition** — every BLE packet is decoded into 9 float channels
  plus a device timestamp; 5 physiological parameters are charted live, all 9 are
  recorded.
- **No data loss on disconnect** — the device keeps a ~11.6 h flash history
  buffer; on reconnect ("continue from last recording") the app pulls everything
  it missed and backfills it with real timestamps.
- **Live charting** — one auto-ranging line chart per parameter, with
  tap-to-inspect value tooltips.
- **QR provisioning** — scan a device QR code to connect instantly and attach
  patient metadata; scan a material QR to annotate a recording.
- **Automatic recording** — a CSV session starts on connect and is archived on
  disconnect, with no user action required.
- **Tiered data protection** — per-row disk flush, crash recovery, a 30-day
  trash, and automatic mirroring to public storage that survives app uninstall.
- **Session management** — search, rename, annotate, multi-select, batch export
  (system share sheet), batch save-to-device, and batch delete.
- **Liquid Glass interface** — translucent layered UI with light/dark theming.

---

## 2. Hardware Interface

Firmware reference: `zephyrproject/apps_nj/ESP32_BG/src/main.c`

| Property | Value |
|---|---|
| Advertised name | `BG_MINI_01` (fixed — `CONFIG_BT_DEVICE_NAME_DYNAMIC=n`) |
| Service UUID | `abcdef01-1234-5678-1234-56789abcdef0` |
| Live characteristic | `abcdef02-…` — notify, 40 bytes = 9 × `float32` + 1 × `uint32` (device uptime ms), little-endian |
| History-sync characteristic | `abcdef03-…` — write `uint32` "last seq I have"; notifies 44-byte records, ending with a `seq = 0xFFFFFFFF` sentinel |
| Notification interval | approximately 30 s per device |

### Channel map

| Index | Firmware variable | Parameter | Unit | Charted |
|:---:|---|---|:---:|:---:|
| 0 | `phase_diff_avg` | pO₂ Lifetime (phase) | µs | Yes |
| 1 | `mag_ratio` | pO₂ Intensity (magnitude ratio) | — | Yes |
| 2 | `pCO2_ratio` | pCO₂ (405/470 ratiometric) | — | Yes |
| 3 | `pH_ratio` | pH (405/450 ratiometric) | — | Yes |
| 4 | `temperature` | Temperature (thermistor) | °C | Yes |
| 5 | `PCO2_405_mean` | pCO₂ 405 nm photodiode mean | a.u. | Recorded only |
| 6 | `PCO2_470_mean` | pCO₂ 470 nm photodiode mean | a.u. | Recorded only |
| 7 | `PH_405_mean` | pH 405 nm photodiode mean | a.u. | Recorded only |
| 8 | `PH_450_mean` | pH 450 nm photodiode mean | a.u. | Recorded only |
| (9) | `device_time_ms` | device uptime, raw `uint32` — timestamp only | ms | — |

### History record (44 bytes)

`seq (u32) · device_time_ms (u32) · the 9 floats above in the same order`

> **pH calibration.** The calibration QR carries O₂ / CO₂ / temperature vectors
> only; in the CALIB view and the calibrated CSV, pH is still the raw ratio.

> **Calibration status.** These channels are **uncalibrated raw sensor
> quantities**. Converting them to clinical units (for example mmHg) requires a
> calibration curve derived from reference gases; that mapping is not yet
> implemented. Values are presented as reported by the firmware.

> **Non-finite values.** The firmware divides magnitudes and photodiode means, so
> a zero denominator yields `NaN` or `Inf`. Such samples are rendered as an em
> dash, excluded from peak tracking, and omitted from the waveform, so a failing
> channel is visibly distinct from a genuine reading of zero.

---

## 3. Architecture

The application is organised into five layers. Each layer depends only on the
layers below it, which is what allowed the sibling Capnography application to
reuse the storage, charting, and BLE infrastructure unchanged.

```
+-----------------------------------------------------------+
|  5. Presentation    main | monitor | device_detail |       |
|                     history | trash | ble | scan_qr        |
|                     glass.dart | theme_manager.dart        |
+-----------------------------------------------------------+
|  4. Persistence     csv_recorder | backup_store |          |
|                     session_metadata                       |
+-----------------------------------------------------------+
|  3. Session state   device_session  (one per device)       |
+-----------------------------------------------------------+
|  2. Transport       ble_manager  (scan | connect | decode) |
+-----------------------------------------------------------+
|  1. Data contract   gas_params.dart                        |
+-----------------------------------------------------------+
                             ^
                      BG_MINI sensor (BLE)
```

### Data flow

```
BLE notification (24 B)
        |
        v
BleManager._onBytes  ->  decode 6 x float32
        |
        +--> DeviceSession.addSample()  -> ring buffers, current/peak, tick++
        |                                          |
        |                                          v
        |                                   UI rebuilds only the affected card
        |
        +--> sampleStream -> CsvRecorder -> one CSV row, flushed immediately
```

State propagation uses `ValueNotifier` and `ValueListenableBuilder`. Each session
owns its own `tick` notifier, so an incoming packet rebuilds **only that
device's** widgets — the reason 8 concurrent devices render without jank.

### Source map

| File | Lines | Responsibility |
|---|---:|---|
| `gas_params.dart` | 192 | **Single source of truth**: `GasParam` enum, labels, units, colours, CSV keys, adaptive numeric formatting, chart range helper `niceRange()` |
| `ble_manager.dart` | 329 | BLE scanning, connection lifecycle, device cap, packet decoding, `SampleEvent` broadcast |
| `device_session.dart` | 151 | Per-device runtime state: waveform ring buffers, current and peak values, elapsed clock, tick notifier |
| `csv_recorder.dart` | 775 | Session recording, archival, crash recovery, trash lifecycle, CSV parsing |
| `backup_store.dart` | 186 | Public-storage mirroring and permission handling |
| `session_metadata.dart` | 114 | JSON sidecar for titles, notes, and material info |
| `main.dart` | 553 | Application entry, theming, home screen |
| `monitor_page.dart` | 604 | Connected-device list with compact per-device summaries |
| `device_detail_page.dart` | 613 | Per-device view: four live charts, peaks, raw-channel diagnostics |
| `history_page.dart` | 1932 | Session archive, search, multi-select, batch actions, recording detail with charts |
| `trash_page.dart` | 559 | 30-day trash: restore, permanent delete, empty |
| `ble_page.dart` | 793 | Device scanning and pairing UI, known-device list |
| `scan_qr_page.dart` | 650 | Camera QR scanning (device and material modes) |
| `glass.dart` | 249 | Liquid Glass design system: `GlassCard`, `GlassPill`, `LiquidBackground` |
| `theme_manager.dart` | 61 | Light and dark palettes, accent colours |

---

## 4. Data Protection

Recording integrity is treated as the primary requirement of the system.

| Failure mode | Mitigation |
|---|---|
| Application crash or process kill | Every CSV row is flushed to disk immediately on write |
| Recording interrupted mid-session | Orphaned `__pending.csv` files are detected and finalised at next launch |
| Accidental deletion | Deletions are soft — items are retained in trash for **30 days** and can be restored |
| Application uninstall or device change | Each completed recording is mirrored to public storage (see below) |
| Concurrent sessions overwriting each other | Filenames embed a per-device MAC tag plus a uniqueness guard |

### Public-storage mirror

Completed recordings are copied to:

```
Documents/BloodGas Monitor/
```

Files in this directory persist after the application is uninstalled. This
requires the **All files access** permission, which is requested the first time
Save is used. Until it is granted, mirroring silently no-ops and only the
private in-app copy exists.

### Concurrent-session file naming

```
GASMON_<patient>_<macTag>_<startStamp>__<endStamp>.csv
         |          |         |             +-- YYYYMMDD_HHMMSS
         |          |         +---------------- YYYYMMDD_HHMMSS
         |          +-------------------------- last 4 hex digits of device MAC
         +------------------------------------- patient slug, or devN
```

The MAC tag guarantees that two sensors sharing a patient name and starting in
the same second cannot produce the same filename. A `-2`, `-3` counter is
appended to the prefix as a further guard. Because the counter precedes the
timestamps, the archive's filename-based time parsing is unaffected — this is
covered by `test/naming_test.dart`.

---

## 5. CSV Format

Recordings are stored in the application documents directory under
`gas_monitor_records/`.

```
# BloodGas Session
mac,<device MAC>
slot,<display slot>
start_iso,<ISO 8601>
end_iso,<ISO 8601>
name_meta,<optional, from QR>
patient_meta,<optional>
age_meta,<optional>
note_meta,<optional>
---
time,po2_lifetime,po2_intensity,pco2_ratio,ph_ratio,temperature,pco2_405,pco2_470,ph_405,ph_450
<timestamp>,12.3456,0.9876,1.0234,0.8123,25.6000,2048.0000,1990.0000,1500.0000,1800.0000
```

Each data row contains a timestamp followed by all nine channels to four
decimal places, in `kAllParams` order. Backfilled (history-buffer) rows carry
their real, back-calculated timestamps; gaps longer than
`kMissingGapThreshold` (5 min) get a "Missing data" note in the header.

---

## 6. Configuration Reference

Behaviour is controlled by a small set of named constants.

| Setting | File | Symbol |
|---|---|---|
| Maximum concurrent devices | `lib/ble_manager.dart` | `kMaxDevices` (8) |
| Accepted service UUIDs | `lib/ble_manager.dart` | `_knownServiceUuids` |
| Waveform history depth | `lib/device_session.dart` | `maxPoints` (300) |
| Parameter labels, units, colours | `lib/gas_params.dart` | `label`, `unit`, `color` |
| Charted parameter set | `lib/gas_params.dart` | `kChartedParams` |
| Numeric precision | `lib/gas_params.dart` | `decimalsFor()` |
| Trash retention | `lib/csv_recorder.dart` | `kTrashRetentionDays` (30) |
| Public backup folder | `lib/backup_store.dart` | `folderName` |
| Theme palette | `lib/theme_manager.dart` | `static const Color` definitions |
| Application display name | `android/app/src/main/AndroidManifest.xml` | `android:label` |

Because every parameter attribute resolves through `gas_params.dart`, adapting
the application to a different sensor payload is primarily a change to that one
file.

---

## 7. Build and Run

Prerequisites: Flutter 3.44 or later, the Android SDK, and Xcode for iOS builds.

```bash
flutter pub get
```

### Android

```bash
flutter run                     # deploy to a connected device (hot reload enabled)
flutter build apk --release     # -> build/app/outputs/flutter-apk/app-release.apk
```

Install and inspect:

```bash
adb install -r app-release.apk        # -r preserves existing recordings
adb logcat | grep BLE                 # trace decoded sensor packets
```

> **Dropbox-synchronised path.** This repository lives in a Dropbox folder.
> Gradle's file-system watcher conflicts with Dropbox's background syncing and
> aborts with `java.io.IOException: Cannot snapshot ...`. This is disabled in
> `android/gradle.properties` via `org.gradle.vfs.watch=false`, and builds run
> normally in place. If a build ever fails with that error again, verify the
> flag is still present, or build from a local mirror outside Dropbox and copy
> the APK back.

### iOS

The iOS project is fully configured: camera and Bluetooth usage descriptions, a
Podfile targeting iOS 13.0 with the required `permission_handler` macros, app
icons, and bundle identifier. Compilation requires macOS.

```bash
flutter pub get
cd ios && pod install && cd ..
flutter run                     # simulator (no Apple account) or device (free Apple ID)
```

See `../../iOS-build-guide.md` for the full procedure, including cloud-macOS
options.

### Icons

Source artwork lives in `assets/icon/`. After replacing it:

```bash
dart run flutter_launcher_icons   # regenerates Android and iOS icon sets
```

---

## 8. Testing

```bash
flutter analyze                   # static analysis
flutter test                      # unit and widget tests
```

`test/naming_test.dart` is a regression suite for the concurrent-session
filename scheme. It verifies that two sensors sharing a patient name and second
produce distinct filenames, and that both remain parseable by the archive.

---

## 9. Dependencies

| Package | Purpose |
|---|---|
| `flutter_blue_plus` | BLE scanning, connection, notifications |
| `fl_chart` | Real-time and historical line charts |
| `mobile_scanner` 7.x | Camera QR scanning |
| `permission_handler` | Bluetooth, camera, and storage permissions |
| `path_provider` | Platform storage locations |
| `share_plus` | System share sheet for CSV export |
| `shared_preferences` | Known-device persistence |
| `pointycastle` | AES-128 decryption for legacy encrypted packets |
| `google_fonts`, `intl`, `open_file`, `cupertino_icons` | Typography, formatting, file handling, iconography |

> `mobile_scanner` was upgraded from 5.2.3 to 7.x to resolve a native
> null-pointer crash in the camera pipeline on Android 16.

---

## 10. Tooling

`../QRCode/` contains two Python utilities for producing printable labels.

| Script | Output |
|---|---|
| `Generate_Device_QR.py` | Device QR encoding the sensor MAC and patient metadata |
| `Generate_Material_QR.py` | Material or consumable QR for annotating recordings |

```bash
pip install qrcode pillow
python Generate_Device_QR.py
```

Set the target MAC address in the script before generating production labels.

---

## 11. Known Limitations and Roadmap

- **Uncalibrated units** — channels are reported as raw sensor quantities; a
  calibration mapping to clinical units is outstanding.
- **Temperature source** — thermistor on ADC ch4 (own 5 s thread in the
  firmware); the conversion assumes 4095 counts = 3.3 V, which may need
  checking against the ADC's actual full-scale range.
- **pH** — charted and recorded as the raw 405/450 ratio; no calibration yet.
- **Concurrency ceiling** — the 8-device limit reflects Android BLE link
  scheduling reliability rather than device performance. Measured headroom on
  the reference tablet (Exynos 1380, 8 cores, 8 GB RAM) is substantial: the BLE
  stack advertises 16 concurrent LE links, and the application consumes roughly
  half of one core under sustained interaction.
- **Uninstall protection** requires the user to grant All files access.
- Planned: unit calibration, configurable threshold alarms, time-based chart
  axes, and cloud backup.

---

## 12. Notice

This software is intended for research and engineering evaluation. It is not a
certified medical device and must not be used as the basis for clinical
decisions.
