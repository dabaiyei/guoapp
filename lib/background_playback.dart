import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// iOS 投屏保活：DLNA 由电视自己拉流，本机只需保持前台进程存活。
/// 通过把 AVAudioSession 切到 playback 并播放一段静音音频，
/// 避免 App 熄屏后被系统挂起，从而中断本机的投屏流代理。
class BackgroundPlayback {
  static const _channel = MethodChannel('duanju/background');

  static bool _active = false;

  static bool get active => _active;

  static Future<void> begin() async {
    if (_active || !Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('beginPlayback');
      _active = true;
    } on PlatformException {
      _active = false;
    } on MissingPluginException {
      _active = false;
    }
  }

  static Future<void> end() async {
    if (!_active || !Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('endPlayback');
    } catch (_) {
    } finally {
      _active = false;
    }
  }
}
