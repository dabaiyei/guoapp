import 'dart:async';

import 'package:flutter/material.dart';

import 'cast_controller.dart';
import 'core_bridge.dart';
import 'models.dart';

/// 投屏控制页：进入后手机变遥控器，电视独立播放，手机可熄屏。
class CastControlScreen extends StatefulWidget {
  const CastControlScreen({
    super.key,
    required this.controller,
    required this.detail,
    required this.index,
    required this.repository,
    required this.onEpisode,
    required this.onQuality,
    required this.onDevice,
  });
  final CastController controller;
  final DramaDetail detail;
  final int index;
  final AppRepository repository;
  final Future<void> Function(int index) onEpisode;
  final Future<void> Function(int quality) onQuality;
  final Future<void> Function(CastDevice device) onDevice;
  @override
  State<CastControlScreen> createState() => _CastControlScreenState();
}

class _CastControlScreenState extends State<CastControlScreen> {
  Timer? _ticker;
  double? _dragValue;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _index = widget.index;
    _ticker = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(widget.controller.refreshStatus());
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Episode get _episode => widget.detail.episodes[_index];

  String _qualityLabel(int quality) =>
      quality > 0 ? '${quality}P' : '自动';

  Future<void> _switchEpisode(int next) async {
    if (next < 0 || next >= widget.detail.episodes.length) return;
    setState(() => _index = next);
    await widget.onEpisode(next);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final status = widget.controller.status;
        if (!status.active) {
          return Scaffold(
            appBar: AppBar(title: const Text('投屏')),
            body: const Center(child: Text('投屏已结束')),
          );
        }
        final duration = status.duration;
        final position = _dragValue != null
            ? Duration(seconds: _dragValue!.round())
            : status.position;
        final total = duration.inSeconds > 0 ? duration.inSeconds : 1;
        final value = position.inSeconds.toDouble().clamp(0.0, total.toDouble());
        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            elevation: 0,
            title: const Text('投屏中'),
            actions: [
              IconButton(
                tooltip: '停止投屏',
                onPressed: () async {
                  await widget.controller.stop();
                  if (context.mounted) Navigator.of(context).maybePop();
                },
                icon: const Icon(Icons.stop_circle_outlined),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        _CastHero(
                          drama: widget.detail.drama,
                          repository: widget.repository,
                          device: status.device,
                        ),
                        const SizedBox(height: 24),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 28),
                          child: Text(
                            '${widget.detail.drama.title} · 第 ${_episode.number} 集',
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.cast_connected_rounded,
                              size: 15,
                              color: Colors.white70,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '正在 ${status.device} 播放'
                              '${widget.controller.status.playing ? '' : ' · 已暂停'}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),
                        _CastProgress(
                          value: value,
                          total: total,
                          position: position,
                          duration: duration,
                          onChanged: (next) =>
                              setState(() => _dragValue = next),
                          onChangeEnd: (next) async {
                            setState(() => _dragValue = null);
                            await widget.controller.seek(
                              Duration(seconds: next.round()),
                            );
                          },
                        ),
                        const SizedBox(height: 12),
                        _CastTransport(
                          playing: status.playing,
                          busy: widget.controller.busy,
                          onPrevious: _index > 0
                              ? () => _switchEpisode(_index - 1)
                              : null,
                          onNext: _index + 1 < widget.detail.episodes.length
                              ? () => _switchEpisode(_index + 1)
                              : null,
                          onRewind: () => widget.controller.seek(
                            Duration(
                              seconds: (position.inSeconds - 15)
                                  .clamp(0, total)
                                  .round(),
                            ),
                          ),
                          onForward: () => widget.controller.seek(
                            Duration(
                              seconds: (position.inSeconds + 15)
                                  .clamp(0, total)
                                  .round(),
                            ),
                          ),
                          onToggle: status.playing
                              ? widget.controller.pause
                              : widget.controller.resume,
                        ),
                      ],
                    ),
                  ),
                ),
                _CastBottomBar(
                  status: status,
                  qualityLabel: _qualityLabel(status.quality),
                  onQuality: _pickQuality,
                  onVolume: status.supportsVolume ? _pickVolume : null,
                  onEpisodes: _pickEpisode,
                  onDevice: _switchDevice,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickQuality() async {
    final status = widget.controller.status;
    final options = status.qualities.isEmpty ? [status.quality] : status.qualities;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final quality in options)
              ListTile(
                title: Text(
                  _qualityLabel(quality),
                  style: const TextStyle(color: Colors.white),
                ),
                trailing: quality == status.quality
                    ? const Icon(Icons.check_rounded, color: Color(0xFFFF765F))
                    : null,
                onTap: () => Navigator.of(context).pop(quality),
              ),
          ],
        ),
      ),
    );
    if (picked != null && picked != status.quality) {
      await widget.onQuality(picked);
    }
  }

  Future<void> _pickVolume() async {
    var volume = widget.controller.status.volume.toDouble();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              children: [
                const Icon(Icons.volume_down_rounded, color: Colors.white),
                Expanded(
                  child: Slider(
                    value: volume.clamp(0, 100),
                    max: 100,
                    divisions: 100,
                    onChanged: (next) {
                      setSheet(() => volume = next);
                      widget.controller.setVolume(next.round());
                    },
                  ),
                ),
                const Icon(Icons.volume_up_rounded, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickEpisode() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .6,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '选择剧集',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 72,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: 1.6,
                      ),
                  itemCount: widget.detail.episodes.length,
                  itemBuilder: (context, index) {
                    final active = index == _index;
                    return InkWell(
                      onTap: () => Navigator.of(context).pop(index),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: active
                              ? const Color(0xFFFF765F)
                              : Colors.white12,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${widget.detail.episodes[index].number}',
                          style: TextStyle(
                            color: active ? Colors.white : Colors.white70,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && picked != _index) {
      await _switchEpisode(picked);
    }
  }

  Future<void> _switchDevice() async {
    final device = await showCastDevicePicker(context, widget.controller);
    if (device == null || !mounted) return;
    await widget.onDevice(device);
  }
}

class _CastHero extends StatelessWidget {
  const _CastHero({
    required this.drama,
    required this.repository,
    required this.device,
  });
  final Drama drama;
  final AppRepository repository;
  final String device;
  @override
  Widget build(BuildContext context) => Stack(
    alignment: Alignment.center,
    children: [
      SizedBox(
        height: 200,
        width: double.infinity,
        child: Opacity(
          opacity: .28,
          child: drama.cover.isEmpty
              ? const ColoredBox(color: Color(0xFF201d2a))
              : Image.network(
                  drama.cover,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const ColoredBox(color: Color(0xFF201d2a)),
                ),
        ),
      ),
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(
              color: Color(0x22FFFFFF),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.cast_connected_rounded,
              color: Colors.white,
              size: 34,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            device.isEmpty ? '电视' : device,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ],
  );
}

class _CastProgress extends StatelessWidget {
  const _CastProgress({
    required this.value,
    required this.total,
    required this.position,
    required this.duration,
    required this.onChanged,
    required this.onChangeEnd,
  });
  final double value;
  final int total;
  final Duration position;
  final Duration duration;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: const Color(0xFFFF765F),
            inactiveTrackColor: Colors.white24,
            thumbColor: Colors.white,
          ),
          child: Slider(
            value: value.clamp(0, total.toDouble()),
            max: total.toDouble(),
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_time(position), style: _timeStyle),
              Text(_time(duration), style: _timeStyle),
            ],
          ),
        ),
      ],
    ),
  );

  static const _timeStyle = TextStyle(color: Colors.white54, fontSize: 12);

  static String _time(Duration value) {
    final seconds = value.inSeconds.clamp(0, 359999);
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}

class _CastTransport extends StatelessWidget {
  const _CastTransport({
    required this.playing,
    required this.busy,
    required this.onPrevious,
    required this.onNext,
    required this.onRewind,
    required this.onForward,
    required this.onToggle,
  });
  final bool playing;
  final bool busy;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onRewind;
  final VoidCallback onForward;
  final VoidCallback onToggle;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _CastButton(
          icon: Icons.skip_previous_rounded,
          tooltip: '上一集',
          onPressed: onPrevious,
        ),
        _CastButton(
          icon: Icons.replay_10_rounded,
          tooltip: '快退 15 秒',
          onPressed: onRewind,
        ),
        _CastButton(
          icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          tooltip: playing ? '暂停' : '继续',
          size: 46,
          onPressed: busy ? null : onToggle,
        ),
        _CastButton(
          icon: Icons.forward_10_rounded,
          tooltip: '快进 15 秒',
          onPressed: onForward,
        ),
        _CastButton(
          icon: Icons.skip_next_rounded,
          tooltip: '下一集',
          onPressed: onNext,
        ),
      ],
    ),
  );
}

class _CastButton extends StatelessWidget {
  const _CastButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 30,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    iconSize: size,
    color: Colors.white,
    disabledColor: Colors.white24,
    icon: Icon(icon),
  );
}

class _CastBottomBar extends StatelessWidget {
  const _CastBottomBar({
    required this.status,
    required this.qualityLabel,
    required this.onQuality,
    required this.onVolume,
    required this.onEpisodes,
    required this.onDevice,
  });
  final CastStatus status;
  final String qualityLabel;
  final VoidCallback onQuality;
  final VoidCallback? onVolume;
  final VoidCallback onEpisodes;
  final VoidCallback onDevice;
  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: Colors.white12)),
    ),
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _CastBarItem(
          icon: Icons.high_quality_rounded,
          label: qualityLabel,
          onTap: onQuality,
        ),
        _CastBarItem(
          icon: Icons.grid_view_rounded,
          label: '选集',
          onTap: onEpisodes,
        ),
        _CastBarItem(
          icon: Icons.volume_up_rounded,
          label: status.supportsVolume ? '音量' : '不支持',
          onTap: onVolume,
        ),
        _CastBarItem(
          icon: Icons.tv_rounded,
          label: '换设备',
          onTap: onDevice,
        ),
      ],
    ),
  );
}

class _CastBarItem extends StatelessWidget {
  const _CastBarItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Expanded(
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: onTap == null ? Colors.white24 : Colors.white, size: 20),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: onTap == null ? Colors.white24 : Colors.white70,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 供播放器与投屏页共用的设备选择弹窗，返回选中的电视。
Future<CastDevice?> showCastDevicePicker(
  BuildContext context,
  CastController controller,
) async {
  await controller.scan();
  if (!context.mounted) return null;
  return showModalBottomSheet<CastDevice>(
    context: context,
    backgroundColor: const Color(0xFF1C1C1E),
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .5,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '选择投屏设备',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
              Expanded(
                child: controller.devices.isEmpty
                    ? Center(
                        child: Text(
                          controller.scanning ? '正在搜索…' : '没有发现设备',
                          style: const TextStyle(color: Colors.white54),
                        ),
                      )
                    : ListView(
                        children: [
                          for (final device in controller.devices)
                            ListTile(
                              leading: const Icon(
                                Icons.tv_rounded,
                                color: Colors.white70,
                              ),
                              title: Text(
                                device.name,
                                style: const TextStyle(color: Colors.white),
                              ),
                              onTap: () =>
                                  Navigator.of(context).pop(device),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
