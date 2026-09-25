import 'package:flutter/material.dart';

import 'csv_recorder.dart';
import 'glass.dart';
import 'theme_manager.dart';

// ══════════════════════════════════════════════════════════════════════════
//  connect_flow.dart — the two "nurse isn't standing at the bedside"
//  connect-time dialogs.
//
//  Call maybeShowConnectDialogs(context, mac: ..., deviceName: ...) BEFORE
//  BleManager.connect()/connectByName() for that device. It's a complete
//  no-op — no dialog, no state change, nothing — for any device that has
//  never recorded before, which is the common case (a brand-new device,
//  or the very first connection of the day). Only when this device NAME
//  already has a prior recording on disk does it ask anything at all
//  (matched by name, not MAC — see the doc comment on
//  CsvRecorder.mostRecentRecordingForName for why):
//
//    "Is this a new patient?"
//      YES              → do nothing further; CsvRecorder starts a fresh
//                          recording exactly as it always has.
//      NO                → "Continue from last recording?"
//          YES           → marks the recording for resume (CsvRecorder
//                          reopens the last file and backfills from the
//                          device's history buffer instead of starting
//                          fresh) — the one new code path.
//          NO / dismissed → same as "new patient: yes" — fresh recording,
//                          today's behavior, unchanged.
//
//  So answering "No" to both (or dismissing either dialog, or answering
//  "Yes" to the first) all converge on exactly the same fresh-recording
//  behavior the app already had before this feature existed.
// ══════════════════════════════════════════════════════════════════════════

Future<void> maybeShowConnectDialogs(
  BuildContext context, {
  required String mac,
  required String deviceName,
}) async {
  // Matched by the device's advertised NAME, not its BLE MAC/remoteId —
  // with BLE privacy enabled on the firmware, the MAC now rotates on
  // every power cycle, so a MAC-based match would never recognize the
  // same physical sensor as having recorded before. The name is what a
  // nurse actually renames per-unit, so it's the stable identity here.
  // `mac` is still needed below purely to attach the resume to THIS live
  // connection (markPendingResume keys _pendingResume by the active
  // session's mac, which CsvRecorder._start() consumes the instant this
  // connection's session appears).
  final previous = await CsvRecorder.mostRecentRecordingForName(deviceName);
  if (previous == null) return; // never recorded before — nothing to ask

  if (!context.mounted) return;
  final isNewPatient = await _askYesNo(
    context,
    title: 'NEW PATIENT?',
    message: 'This device has a previous recording on file:\n\n'
        '${previous.name}\n\nIs this a new patient?',
    yesLabel: 'YES — NEW PATIENT',
    noLabel: 'NO',
    accent: ThemeManager.cyan,
  );
  if (isNewPatient != false) {
    return; // Yes, or dismissed → fresh recording, same as always
  }

  if (!context.mounted) return;
  final continueLast = await _askYesNo(
    context,
    title: 'CONTINUE RECORDING?',
    message: 'Continue from the last recording for this device?\n\n'
        'Data recorded on the device while disconnected will be pulled in '
        'automatically.',
    yesLabel: 'YES — CONTINUE',
    noLabel: 'NO — START NEW',
    accent: ThemeManager.green,
  );
  if (continueLast == true) {
    CsvRecorder.instance.markPendingResume(mac, previous);
  }
  // "No", or dismissed → fresh recording, same as always.
}

Future<bool?> _askYesNo(
  BuildContext context, {
  required String title,
  required String message,
  required String yesLabel,
  required String noLabel,
  required Color accent,
}) {
  final tm = ThemeManager.instance;
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: GlassCard(
        borderRadius: 26,
        accent: accent,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: accent,
                  fontSize: 11,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                message,
                style: TextStyle(
                  color: tm.textPrimary,
                  fontSize: 13.5,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: GlassPill(
                      onTap: () => Navigator.pop(ctx, false),
                      child: Center(
                        child: Text(noLabel,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: tm.textSub,
                                fontSize: 11,
                                letterSpacing: 1.5,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GlassPill(
                      onTap: () => Navigator.pop(ctx, true),
                      accent: accent,
                      child: Center(
                        child: Text(yesLabel,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: accent,
                                fontSize: 11,
                                letterSpacing: 1.5,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
