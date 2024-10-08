import 'dart:async';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:esc_pos_bluetooth/esc_pos_bluetooth.dart';
import 'package:esc_pos_bluetooth/src/bluetooth_scan_handler.dart';
import 'package:esc_pos_bluetooth/src/print_job.dart';

class PrinterService {
  final BluetoothScanHandler _bluetoothScanHandler;
  final PrinterBluetooth _printer;
  final QueueList<PrintJob> _printQueue = QueueList<PrintJob>();
  bool defaultPrintService = false;
  int disconnectAfterMs = 10000;

  PrintJob? _currentJob;

  PrinterService(this._printer, this._bluetoothScanHandler, {this.defaultPrintService = false, this.disconnectAfterMs = 10000});

  bool get isPrinting => _currentJob != null;

  Future<void> addJob(final PrintJob job) async {
    _printQueue.add(job);
    _printNextJob();
  }

  Future<PosPrintResult> _startJob(final PrintJob? job) async {
    if (job == null || job.bytes.isEmpty) {
      return PosPrintResult.success;
    } else if (_bluetoothScanHandler.isScanning) {
      await _bluetoothScanHandler.stopScan();
    }

    Timer? timeoutTimer;
    if (job.options.timeoutMs > 0) {
      timeoutTimer = Timer(Duration(milliseconds: job.options.timeoutMs), () => throw Exception("Printing timeout"));
    }

    final writer = await _bluetoothScanHandler.connect(_printer);
    timeoutTimer?.cancel(); // stop timeout timer

    final len = job.bytes.length;
    final List<List<int>> chunks = [];
    for (int i = 0; i < len; i += job.options.chunkSizeBytes) {
      final end = (i + job.options.chunkSizeBytes < len) ? i + job.options.chunkSizeBytes : len;
      chunks.add(job.bytes.sublist(i, end));
    }

    for (int i = 0; i < chunks.length; i += 1) {
      await writer(chunks[i]);
    }

    if (job.options.queueSleepTimeMs != 0) {
      final waitTime = job.options.queueSleepTimeMs == PrintJobOptions.AUTO_SLEEP_TIME ? min(4000, max(1000, len ~/ 5.0)) : job.options.queueSleepTimeMs;
      await Future.delayed(Duration(milliseconds: waitTime));
    }

    _bluetoothScanHandler.disconnectIn(Duration(milliseconds: disconnectAfterMs)); // if no other print job is added, disconnect in 5 seconds
    return PosPrintResult.success;
  }

  Future<void> _printNextJob() async {
    print("_printNextJob: IsPrinting = $isPrinting, WaitingJob = ${_printQueue.length}");
    if (_printQueue.isNotEmpty && !isPrinting) {
      try {
        final job = _printQueue.removeFirst();
        _currentJob = job;
        try {
          await job.start(() async => _startJob(job));
          _currentJob = null;
        } catch (e) {
          print("Printing job failed: $e");
          if (job.canBeRetried) {
            _printQueue.addFirst(job);
          } else {
            job.complete(PosPrintResult.error);
            _currentJob = null;
          }
        }
      } catch (e) {
        print("Global printer service error (queue): $e");
      }

      scheduleMicrotask(() => _printNextJob());
    }
  }
}
