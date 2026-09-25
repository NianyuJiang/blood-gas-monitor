// Verifies the multi-device filename scheme:
//   GASMON_<patient>_<macTag>[-N]_<startStamp>__<endStamp>.csv
// Two sensors on the SAME patient must produce distinct names, and the
// history list must still recover both timestamps from those names.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:blood_gas_monitor/csv_recorder.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('gasmon_naming'));
  tearDown(() => dir.deleteSync(recursive: true));

  RecordingInfo infoFor(String name) {
    final f = File('${dir.path}/$name')..writeAsStringSync('x');
    return RecordingInfo.fromFile(f);
  }

  test('device-tagged name parses start/end times', () {
    final i = infoFor('GASMON_Jerry_EEF0_20260812_120000__20260812_121500.csv');
    expect(i.startTime, DateTime(2026, 8, 12, 12, 0, 0));
    expect(i.endTime, DateTime(2026, 8, 12, 12, 15, 0));
  });

  test('two sensors, same patient & second → distinct, both parse', () {
    final a = infoFor('GASMON_Jerry_EEF0_20260812_120000__20260812_121500.csv');
    final b = infoFor('GASMON_Jerry_11A2_20260812_120000__20260812_121500.csv');
    expect(a.name, isNot(b.name));
    expect(a.startTime, b.startTime);
    expect(b.endTime, DateTime(2026, 8, 12, 12, 15, 0));
  });

  test('dedupe suffix keeps timestamps parseable', () {
    final i =
        infoFor('GASMON_Jerry_EEF0-2_20260812_120000__20260812_121500.csv');
    expect(i.startTime, DateTime(2026, 8, 12, 12, 0, 0));
    expect(i.endTime, DateTime(2026, 8, 12, 12, 15, 0));
  });
}
