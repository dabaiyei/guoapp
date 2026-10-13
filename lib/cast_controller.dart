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
    this.quality = 0,
    this.qualities = const [],
    this.supportsVolume = false,
    this.volume = 0,
    this.ended = false,
  });
  final bool active;
  final String deviceId;
  final String device;
  final String title;
  final String state;
  final int positionMs;
  final int durationMs;
  final int quality;
  final List<int> qualities;
  final bool supportsVolume;
  final int volume;
  final bool ended;

  factory CastStatus.fromJson(Map<String, dynamic> row) => CastStatus(
    active: row['active'] == true,
    deviceId: (row['deviceId'] ?? '').toString(),
    device: (row['device'] ?? '').toString(),
    title: (row['title'] ?? '').toString(),
    state: (row['state'] ?? '').toString(),
    positionMs: (row['positionMs'] as num?)?.toInt() ?? 0,
    durationMs: (row['durationMs'] as num?)?.toInt() ?? 0,
    quality: (row['quality'] as num?)?.toInt() ?? 0,
    qualities: [
      for (final value in (row['qualities'] as List? ?? const []))
        if (value is num) value.toInt(),
    ],
    supportsVolume: row['supportsVolume'] == true,
    volume: (row['volume'] as num?)?.toInt() ?? 0,
    ended: row['ended'] == true,
  );

  bool get playing => state == 'PLAYING';
  bool get paused => state == 'PAUSED_PLAYBACK';
  Duration get position => Duration(milliseconds: positionMs);
  Duration get duration => Duration(milliseconds: durationMs);

  Map<String, dynamic> toJson() => {
    'active': active,
    'deviceId': deviceId,
    'device': device,
    'title': title,
    'state': state,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'quality': quality,
    'qualities': qualities,
    'supportsVolume': supportsVolume,
    'volume': volume,
    'ended': ended,
  };

  CastStatus copyWith({int? positionMs, int? durationMs, int? volume}) =>
      CastStatus(
        active: active,
        deviceId: deviceId,
        device: device,
        title: title,
        state: state,
        positionMs: positionMs ?? this.positionMs,
        durationMs: durationMs ?? this.durationMs,
        quality: quality,
        qualities: qualities,
        supportsVolume: supportsVolume,
        volume: volume ?? this.volume,
        ended: ended,
      );
}

/// DLNA / UPnP 投屏：电视直接拉流播放，手机可以熄屏。
class CastController extends ChangeNotifier with WidgetsBindingObserver {
  CastController(this.repository, this.store) {
    store.addListener(_storeChanged);
    WidgetsBinding.instance.addObserver(this);
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
  Timer? _poll;
  bool _polling = false;
  bool _ended = false;
  int _episode = 0;
  Duration _lastPosition = Duration.zero;
  DateTime _seekedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 电视播完当前集时回调，由播放页决定是否自动续播。
  Future<void> Function()? onEnded;

  List<CastDevice> get devices => List.unmodifiable(_devices);
  bool get scanning => _scanning;
  bool get busy => _busy;
  String get error => _error;
  String get manualHost => _manualHost;
  CastStatus get status => _status;
  bool get active => _status.active;
  CastDevice? get selected => _selected;

  /// 投屏中的剧集下标，切换集数后随之更新，是控制页与本机播放共用的唯一来源。
  int get episode => _episode;

  /// 电视最后的播放位置。即使投屏已停止也可读，用于退出投屏时把进度带回本机。
  Duration get lastPosition =>
      _status.active ? _status.position : _lastPosition;

  void _storeChanged() {
    if (_disposed) return;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 熄屏期间定时器会被系统暂停，回到前台立即对一次时间，避免进度显示停在旧值。
    if (state == AppLifecycleState.resumed && _status.active) {
      unawaited(refreshStatus());
    }
  }

  /// 启动统一的状态轮询：控制器自己持有，页面打开或关闭都不影响进度同步。
  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(refreshStatus());
    });
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
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
    int quality = 0,
    int? episode,
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
          'quality': quality,
        }),
      );
      if (episode != null) _episode = episode;
      await BackgroundPlayback.begin();
      await _refreshVolume();
      _ended = false;
      _startPolling();
    } catch (failure) {
      _error = failure is AppFailure ? failure.message : '$failure';
      rethrow;
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 投屏中切换到同一集的其他清晰度。
  /// 返回 true 表示原生已就地切换（保留了进度），false 表示需要上层重新解析线路再投。
  Future<bool> switchQuality(int quality) async {
    if (_busy) return true;
    _busy = true;
    _error = '';
    try {
      _status = CastStatus.fromJson(
        await _call('quality', {'quality': quality}),
      );
      return true;
    } catch (failure) {
      _error = failure is AppFailure ? failure.message : '$failure';
      return false;
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> refreshStatus() async {
    if (!_status.active || _polling || _disposed) return;
    _polling = true;
    try {
      final next = CastStatus.fromJson(await _call('status'));
      if (_disposed) return;
      if (!next.active) {
        _stopPolling();
        _status = const CastStatus();
        notifyListeners();
        return;
      }
      // 音量以本地为准（电视不支持写入时不应被轮询覆盖）。
      var merged = CastStatus.fromJson({
        ...next.toJson(),
        'volume': _status.volume,
      });
      // seek 后的短时间内，电视仍可能回报旧位置，此时保留本地目标位置。
      final settle = DateTime.now().difference(_seekedAt);
      if (settle < const Duration(seconds: 4) &&
          (merged.positionMs - _status.positionMs).abs() > 5000) {
        merged = merged.copyWith(positionMs: _status.positionMs);
      }
      _status = merged;
      if (merged.positionMs > 0) {
        _lastPosition = Duration(milliseconds: merged.positionMs);
      }
      notifyListeners();
      if (next.ended && !_ended) {
        _ended = true;
        await onEnded?.call();
      } else if (!next.ended) {
        _ended = false;
      }
    } catch (_) {
    } finally {
      _polling = false;
    }
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

  /// 跳到指定位置。先本地乐观更新进度条，避免电视处理 seek 期间跳动。
  Future<void> seek(Duration position) async {
    final clamped = position.isNegative ? Duration.zero : position;
    final duration = _status.duration;
    final target = duration > Duration.zero && clamped > duration
        ? duration
        : clamped;
    _status = _status.copyWith(positionMs: target.inMilliseconds);
    _seekedAt = DateTime.now();
    if (!_disposed) notifyListeners();
    try {
      final next = CastStatus.fromJson(
        await _call('seek', {'targetMs': target.inMilliseconds}),
      );
      _status = CastStatus.fromJson({
        ...next.toJson(),
        // 电视常在收到 seek 后仍回报旧位置，这里保留目标位置，由轮询在宽限期后纠正。
        'positionMs': target.inMilliseconds,
        'volume': _status.volume,
      });
      if (!_disposed) notifyListeners();
    } catch (failure) {
      _error = failure is AppFailure ? failure.message : '$failure';
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _refreshVolume() async {
    if (!_status.supportsVolume) return;
    try {
      final result = await _call('volume');
      final value = (result['volume'] as num?)?.toInt();
      if (value != null && !_disposed) {
        _status = _status.copyWith(volume: value);
      }
    } catch (_) {}
  }

  Future<void> setVolume(int volume) async {
    final value = volume.clamp(0, 100);
    _status = _status.copyWith(volume: value);
    if (!_disposed) notifyListeners();
    try {
      await _call('volume', {'volume': value, 'hasVolume': true});
    } catch (failure) {
      _error = failure is AppFailure ? failure.message : '$failure';
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> stop() async {
    _stopPolling();
    _ended = false;
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
    _stopPolling();
    WidgetsBinding.instance.removeObserver(this);
    if (_status.active) unawaited(BackgroundPlayback.end());
    store.removeListener(_storeChanged);
    super.dispose();
  }
}
