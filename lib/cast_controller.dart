import 'dart:async';

import 'package:flutter/widgets.dart';

import 'background_playback.dart';
import 'core_bridge.dart';
import 'local_store.dart';

class CastDevice {
  const CastDevice({
    required this.id,
    required this.name,
    required this.model,
  });
  final String id;
  final String name;
  final String model;

  factory CastDevice.fromJson(Map<String, dynamic> row) => CastDevice(
    id: (row['id'] ?? '').toString(),
    name: (row['name'] ?? '').toString(),
    model: (row['model'] ?? '').toString(),
  );
}

class CastStatus {
  const CastStatus({
    this.active = false,
    this.deviceId = '',
    this.device = '',
    this.title = '',
    this.state = '',
    this.positionMs = 0,
    this.durationMs = 0,
  });
  final bool active;
  final String deviceId;
  final String device;
  final String title;
  final String state;
  final int positionMs;
  final int durationMs;

  factory CastStatus.fromJson(Map<String, dynamic> row) => CastStatus(
    active: row['active'] == true,
    deviceId: (row['deviceId'] ?? '').toString(),
    device: (row['device'] ?? '').toString(),
    title: (row['title'] ?? '').toString(),
    state: (row['state'] ?? '').toString(),
    positionMs: (row['positionMs'] as num?)?.toInt() ?? 0,
    durationMs: (row['durationMs'] as num?)?.toInt() ?? 0,
  );

  bool get playing => state == 'PLAYING';
}

/// DLNA / UPnP 投屏：电视直接拉流播放，手机可以熄屏。
class CastController extends ChangeNotifier {
  CastController(this.repository, this.store) {
    store.addListener(_storeChanged);
  }

  static CastController? current;

  final AppRepository repository;
  final LocalStore store;

  List<CastDevice> _devices = const [];
  bool _scanning = false;
  bool _busy = false;
  bool _disposed = false;
  String _error = '';
  String _manualHost = '';
  CastStatus _status = const CastStatus();
  CastDevice? _selected;

  List<CastDevice> get devices => List.unmodifiable(_devices);
  bool get scanning => _scanning;
  bool get busy => _busy;
  String get error => _error;
  String get manualHost => _manualHost;
  CastStatus get status => _status;
  bool get active => _status.active;
  CastDevice? get selected => _selected;

  void _storeChanged() {
    if (_disposed) return;
  }

  void setManualHost(String value) {
    _manualHost = value.trim();
    notifyListeners();
  }

  void select(CastDevice device) {
    _selected = device;
    notifyListeners();
  }

  Future<Map<String, dynamic>> _call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) {
    if (store.locked) throw AppFailure('请先解锁当前用户');
    return repository.cast(command, {...payload, if (_manualHost.isNotEmpty) 'host': _manualHost});
  }

  Future<void> scan() async {
    if (_scanning) return;
    _scanning = true;
    _error = '';
    notifyListeners();
    try {
      final result = await _call('discover');
      final rows = (result['devices'] as List? ?? const []);
      _devices = [
        for (final row in rows)
          if (row is Map) CastDevice.fromJson(row.cast<String, dynamic>()),
      ];
      if (_selected != null &&
          !_devices.any((device) => device.id == _selected!.id)) {
        _selected = null;
      }
      _selected ??= _devices.length == 1 ? _devices.first : null;
    } catch (failure) {
      _error = failure is AppFailure ? failure.message : '$failure';
    } finally {
      _scanning = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> start({
    required CastDevice device,
    required String session,
    required String title,
    int positionMs = 0,
  }) async {
    if (_busy) return;
    _busy = true;
    _error = '';
    notifyListeners();
    try {
      _selected = device;
      _status = CastStatus.fromJson(
        await _call('start', {
          'device': device.id,
          'session': session,
          'title': title,
          'targetMs': positionMs,
        }),
      );
      await BackgroundPlayback.begin();
    } catch (failure) {
      _error = failure is AppFailure ? failure.message : '$failure';
      rethrow;
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> refreshStatus() async {
    if (!_status.active) return;
    try {
      _status = CastStatus.fromJson(await _call('status'));
      if (!_disposed) notifyListeners();
    } catch (_) {}
  }

  Future<void> _transport(String command) async {
    try {
      _status = CastStatus.fromJson(await _call(command));
      if (!_disposed) notifyListeners();
    } catch (failure) {
      _error = failure is AppFailure ? failure.message : '$failure';
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> pause() => _transport('pause');
  Future<void> resume() => _transport('resume');

  Future<void> seek(Duration position) async {
    try {
      _status = CastStatus.fromJson(
        await _call('seek', {'targetMs': position.inMilliseconds}),
      );
      if (!_disposed) notifyListeners();
    } catch (failure) {
      _error = failure is AppFailure ? failure.message : '$failure';
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> setVolume(int volume) async {
    try {
      await _call('volume', {'volume': volume.clamp(0, 100)});
    } catch (failure) {
      _error = failure is AppFailure ? failure.message : '$failure';
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> stop() async {
    try {
      await _call('stop');
    } catch (_) {
    } finally {
      await BackgroundPlayback.end();
      _status = const CastStatus();
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (_status.active) unawaited(BackgroundPlayback.end());
    store.removeListener(_storeChanged);
    super.dispose();
  }
}
