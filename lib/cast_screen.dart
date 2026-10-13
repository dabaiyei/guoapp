import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'cast_controller.dart';

Future<T?> _castPanel<T>(
  BuildContext context,
  Widget child, {
  double maxHeight = 620,
}) {
  final size = MediaQuery.sizeOf(context);
  final height = min(size.height * .88, maxHeight);
  if (size.width >= 800) {
    return showDialog<T>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: 620, height: height, child: child),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) => SizedBox(height: height, child: child),
  );
}

/// 选择电视并把当前播放投上去。返回 true 表示投屏已开始。
Future<bool> showCastPanel(
  BuildContext context,
  CastController controller, {
  required String title,
  required String Function() session,
  required Duration Function() position,
  required Future<void> Function() onCasting,
}) async {
  final started = await _castPanel<bool>(
    context,
    _CastPanel(
      controller: controller,
      title: title,
      session: session,
      position: position,
      onCasting: onCasting,
    ),
  );
  return started == true;
}

class _CastPanel extends StatefulWidget {
  const _CastPanel({
    required this.controller,
    required this.title,
    required this.session,
    required this.position,
    required this.onCasting,
  });
  final CastController controller;
  final String title;
  final String Function() session;
  final Duration Function() position;
  final Future<void> Function() onCasting;
  @override
  State<_CastPanel> createState() => _CastPanelState();
}

class _CastPanelState extends State<_CastPanel> {
  final _manual = TextEditingController();

  @override
  void initState() {
    super.initState();
    _manual.text = widget.controller.manualHost;
    unawaited(widget.controller.scan());
  }

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  Future<void> _connect(CastDevice device) async {
    final session = widget.session();
    if (session.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前内容暂不支持投屏')));
      return;
    }
    try {
      await widget.controller.start(
        device: device,
        session: session,
        title: widget.title,
        positionMs: widget.position().inMilliseconds,
      );
      await widget.onCasting();
      if (mounted) Navigator.of(context).pop(true);
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$failure')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
            child: Row(
              children: [
                const Icon(Icons.cast_rounded, size: 22),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    '投屏到电视',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: '重新搜索',
                  onPressed: controller.scanning
                      ? null
                      : () => controller.scan(deep: true),
                  icon: controller.scanning
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
          if (controller.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      controller.error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Expanded(
            child: controller.devices.isEmpty
                ? Center(
                    child: Text(
                      controller.scanning ? '正在搜索电视…' : '没有发现设备',
                      style: TextStyle(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: controller.devices.length,
                    itemBuilder: (context, index) {
                      final device = controller.devices[index];
                      final busy = controller.busy;
                      return ListTile(
                        leading: const Icon(Icons.tv_rounded),
                        title: Text(device.name),
                        subtitle: device.model.isEmpty
                            ? null
                            : Text(device.model),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        enabled: !busy,
                        onTap: busy ? null : () => _connect(device),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manual,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '电视 IP（搜索不到时手填）',
                      hintText: '例如 192.168.1.8',
                    ),
                    onChanged: controller.setManualHost,
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonal(
                  onPressed: controller.scanning
                      ? null
                      : () => controller.scan(deep: true),
                  child: const Text('连接'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 投屏进行中的悬浮控制条。
class CastBanner extends StatelessWidget {
  const CastBanner({super.key, required this.controller, this.onStop});
  final CastController controller;
  final Future<void> Function()? onStop;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      if (!controller.active) return const SizedBox.shrink();
      final status = controller.status;
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              const Icon(Icons.cast_connected_rounded, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '正在投屏到 ${status.device}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              IconButton(
                tooltip: status.playing ? '暂停' : '继续',
                iconSize: 20,
                constraints: const BoxConstraints.tightFor(
                  width: 34,
                  height: 34,
                ),
                padding: EdgeInsets.zero,
                onPressed: status.playing
                    ? controller.pause
                    : controller.resume,
                icon: Icon(
                  status.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
              IconButton(
                tooltip: '停止投屏',
                iconSize: 20,
                constraints: const BoxConstraints.tightFor(
                  width: 34,
                  height: 34,
                ),
                padding: EdgeInsets.zero,
                onPressed: () async {
                  await controller.stop();
                  await onStop?.call();
                },
                icon: const Icon(Icons.stop_circle_outlined),
              ),
            ],
          ),
        ),
      );
    },
  );
}
