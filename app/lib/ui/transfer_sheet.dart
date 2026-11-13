/// 传输进度面板 +「传到手机」入口（transfer-1 UI，2026-11-13）。
///
/// 面板持有控制器生命周期；完成即自动落盘 downloads/ 并调起系统
/// 「用其他应用打开」选择器（WPS 等出现在其中）。取消=停止等待
/// （agent 可能仍在执行分块——面板文案明示）。
library;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/app_state_scope.dart';
import '../transfer/file_transfer.dart';
import '../transfer/local_files.dart';
import '../transport/conversation.dart' show ConversationSubscription;

/// 「传到手机」入口：确认 → 传输面板。sub 为当前会话的活跃订阅
/// （行数据源）；无订阅（页面非活跃）时调用方负责拦截。
Future<void> startFileTransfer(
  BuildContext context, {
  required String sessionId,
  required String path,
  required ConversationSubscription sub,
}) async {
  final fileName = path.split(RegExp(r'[\\/]')).last;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr('传到手机？')),
      content: Text(
        tr('将向当前会话发送一条传输指令，agent 会把该文件分块传到手机'
            '（约一轮普通工具调用的额度；单文件上限 20MB）。传输完成后'
            '可用 WPS 等手机应用打开。'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(tr('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(tr('传到手机')),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => TransferSheet(
      sessionId: sessionId,
      sub: sub,
      path: path,
      fileName: fileName,
    ),
  );
}

String _humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

class TransferSheet extends StatefulWidget {
  const TransferSheet({
    super.key,
    required this.sessionId,
    required this.sub,
    required this.path,
    required this.fileName,
  });

  final String sessionId;
  final ConversationSubscription sub;
  final String path;
  final String fileName;

  @override
  State<TransferSheet> createState() => _TransferSheetState();
}

class _TransferSheetState extends State<TransferSheet> {
  FileTransferController? _controller;
  String? _savedPath;
  String? _openError;
  bool _cleanupSent = false;
  int _savedSize = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  void _start() {
    if (!mounted) return;
    final app = AppStateScope.of(context);
    _savedPath = null;
    _openError = null;
    _savedSize = 0;
    _cleanupSent = false;
    // 重试链路：旧控制器先取消再释放（无监听者时 dispose 安全）。
    _controller
      ?..cancel()
      ..dispose();
    final controller = FileTransferController(
      getRows: () async => List<Map<String, dynamic>>.of(widget.sub.state.rows),
      fetchFileChanges: (target) =>
          app.fileChanges(widget.sessionId, target: target),
      sendText: (text) async {
        await app.sendText(widget.sessionId, text);
      },
      onDecoded: _handleDecoded,
    );
    setState(() => _controller = controller);
    controller.start(path: widget.path, fileName: widget.fileName);
  }

  /// 解码完成 → 落盘 + 自动调起外部应用（失败不阻断，完成面板给
  /// 重开按钮与错误说明）。
  Future<void> _handleDecoded(Uint8List bytes) async {
    final file = await saveBytesToDownloads(
      fileName: widget.fileName,
      bytes: bytes,
    );
    _savedSize = bytes.length;
    if (!mounted) return;
    _savedPath = file.path;
    try {
      await openWithExternalApp(
        path: file.path,
        mime: mimeForFileName(widget.fileName),
      );
      if (!mounted) return;
      _openError = null;
    } catch (e) {
      if (!mounted) return;
      _openError = '$e';
    }
  }

  Future<void> _closeWhileRunning() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('取消传输？')),
        content: Text(tr('仅停止本面板的等待，agent 可能仍在执行分块；'
            '完成后可再次发起传输。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('继续等待')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('取消并关闭')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _controller?.cancel();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _reopen() async {
    final path = _savedPath;
    if (path == null || !mounted) return;
    try {
      await openWithExternalApp(
        path: path,
        mime: mimeForFileName(widget.fileName),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('打开失败：$e'))),
      );
    }
  }

  Future<void> _sendCleanup() async {
    final app = AppStateScope.of(context);
    try {
      await app.sendText(
        widget.sessionId,
        buildTransferCleanupInstruction(_controller?.id ?? ''),
      );
      if (!mounted) return;
      setState(() => _cleanupSent = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('已发送清理指令，agent 会删除临时分块')),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('清理指令发送失败：$e'))),
      );
    }
  }

  @override
  void dispose() {
    _controller
      ?..cancel()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: controller == null
            ? const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              )
            : AnimatedBuilder(
                animation: controller,
                builder: (context, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          controller.phase == FileTransferPhase.done
                              ? Icons.check_circle_outline
                              : controller.phase == FileTransferPhase.failed
                                  ? Icons.error_outline
                                  : Icons.smartphone_outlined,
                          size: 18,
                          color:
                              controller.phase == FileTransferPhase.done
                                  ? context.colors.success
                                  : controller.phase ==
                                          FileTransferPhase.failed
                                      ? context.colors.destructive
                                      : context.colors.brandAccent,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _statusText(controller),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: AppType.uiCaption,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${widget.fileName}'
                      '${controller.receivedParts > 0 ? ' · ${tr('已收')} ${controller.receivedParts}${controller.totalParts != null ? '/${controller.totalParts}' : ''} ${tr('块')}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        fontFamily: 'monospace',
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ..._body(controller),
                  ],
                ),
              ),
      ),
    );
  }

  String _statusText(FileTransferController c) => switch (c.phase) {
        FileTransferPhase.sending => tr('正在发送传输指令…'),
        FileTransferPhase.waiting => tr('等待 agent 分块传输中…'),
        FileTransferPhase.waitingTail => tr('已收到完成标记，等待尾部分块…'),
        FileTransferPhase.decoding => tr('正在保存到手机…'),
        FileTransferPhase.done => _savedPath != null
            ? tr('已保存到手机 downloads（${_humanSize(_savedSize > 0 ? _savedSize : _fileSizeOnDisk())}）')
            : tr('传输完成'),
        FileTransferPhase.failed => tr('传输失败'),
      };

  List<Widget> _body(FileTransferController c) {
    final busy = c.phase == FileTransferPhase.sending ||
        c.phase == FileTransferPhase.waiting ||
        c.phase == FileTransferPhase.waitingTail ||
        c.phase == FileTransferPhase.decoding;
    if (busy) {
      return [
        Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tr('传输期间请勿关闭本页面；连接中断会自动重试轮询。'),
                style: TextStyle(
                  fontSize: AppType.uiXs,
                  color: context.colors.foregroundSubtlest,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: _closeWhileRunning,
          child: Text(tr('取消并关闭')),
        ),
      ];
    }
    if (c.phase == FileTransferPhase.failed) {
      return [
        Text(
          c.error ?? '',
          style: TextStyle(
            fontSize: AppType.uiCaption,
            color: context.colors.destructive,
          ),
        ),
        const SizedBox(height: 10),
        // 失败时 agent 可能已写入部分分块——清理按钮在此同样提供
        //（不自动发，尊重额度）。
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _start,
                child: Text(tr('重试')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr('关闭')),
              ),
            ),
          ],
        ),
        TextButton(
          onPressed: _cleanupSent ? null : _sendCleanup,
          child: Text(_cleanupSent ? tr('已发送清理') : tr('清理临时文件')),
        ),
      ];
    }
    // done
    return [
      if (_openError != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            tr('自动打开失败：$_openError\n文件已保存，可手动重新打开。'),
            style: TextStyle(
              fontSize: AppType.uiXs,
              color: context.colors.warning,
            ),
          ),
        ),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _savedPath == null ? null : _reopen,
              child: Text(tr('用其他应用打开')),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              onPressed: _cleanupSent ? null : _sendCleanup,
              child: Text(_cleanupSent ? tr('已发送清理') : tr('清理临时文件')),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('关闭')),
      ),
    ];
  }

  /// 落盘尺寸展示兜底（controller 已持有字节长度；文件读长做兜底）。
  int _fileSizeOnDisk() {
    final path = _savedPath;
    if (path == null) return 0;
    try {
      return File(path).lengthSync();
    } catch (_) {
      return 0;
    }
  }
}
