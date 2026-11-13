/// agent 分块中转：把桌面工作区文件传输到手机（transfer-1，2026-11-13
/// 用户拍板方案）。
///
/// 背景：V4 协议无「按路径读文件字节」通道（decisions.md #12/#26，
/// file-preview-1 注释全量核实）。唯一纯数据通道=新建文件全文随
/// fileChanges 的 diff 到达（不进模型上下文、零额度）——本方案让
/// agent 把目标文件 base64 分块写成工作区小文件，手机端拉 diff 全文
/// 拼接解码。base64 不出现在对话文本里（模型上下文只多一条指令与
/// 命令摘要），成本≈一轮普通工具调用。
///
/// 线上协议（agent 视角）：
///   写入 `.zp-transfer/<transferId>/part-NNNN.b64`（每块 ≤128KiB
///   解码字节，76 字符行宽），完成后回复 `ZP-TRANSFER-OK <id> <总数>`，
///   失败回复 `ZP-TRANSFER-FAIL <id> <原因>`。
/// 限制：单文件 ≤20MB；序号必须从 1 连续；base64 不得出现在对话文本。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// 传输工作区目录前缀（工作区根相对路径）。
const transferRootDir = '.zp-transfer';

/// 单块解码字节数上限（与指令模板同值；分块参数调优见
/// docs/file-transfer-design.md——行数/diff 尺寸实测后再放宽）。
const transferChunkBytes = 128 * 1024;

/// 单文件传输上限（指令与手机端双侧卡口）。
const transferMaxFileBytes = 20 * 1024 * 1024;

/// 轮询节奏与总超时（agent 执行分块写盘一轮常见 10-60s；20MB 上限
/// 留足余量）。
const transferPollInterval = Duration(seconds: 3);
const transferTimeout = Duration(minutes: 10);

/// OK/FAIL 标记后的分块缺失宽限期（marker 先于尾块 diff 到达的窗口）。
const transferPartsGrace = Duration(seconds: 90);

/// 传输目录（工作区根相对）：`.zp-transfer/<id>/`。
String transferDirFor(String transferId) => '$transferRootDir/$transferId';

/// part 文件名（序号从 1 起，4 位以上零填充——继续进位自然加宽）。
String transferPartName(int index) {
  final s = index.toString();
  return 'part-${s.length < 4 ? s.padLeft(4, '0') : s}.b64';
}

final _partNameRe = RegExp(r'^part-(\d{4,})\.b64$');

/// part 文件名 → 序号（不匹配 → null）。
int? transferPartIndexOf(String fileName) {
  final m = _partNameRe.firstMatch(fileName);
  if (m == null) return null;
  return int.parse(m.group(1)!);
}

/// 指令模板（发送给 agent 的用户消息）。含传输 ID 与占位符说明；
/// 手机端 marker 扫描只认 assistantText 行 + 真实 ID，模板字样不会
/// 误命中。
String buildTransferInstruction({
  required String path,
  required String transferId,
  int chunkBytes = transferChunkBytes,
}) {
  return '''[ZP 手机传文件] 请把下面的文件传输到我的手机（ZCode Pocket 客户端）。

文件路径：$path

执行要求（严格遵守，无需向我确认）：
1. 对该文件做 Base64 编码，按每块 ≤$chunkBytes 字节（解码后）分块，写入工作区目录 `${transferDirFor(transferId)}/`，文件名依次为 `${transferPartName(1)}`、`${transferPartName(2)}`…（序号从 1 连续）。
2. 每个 .b64 文件内容为纯 Base64 文本，按 76 字符换行；**末块以外的分块不要带 "=" 填充**（位流连续）；除 Base64 外不要附加任何内容。
3. 不要把 Base64 内容打印到对话里；不要提交 git；不要修改源文件。
4. 若文件不存在、不可读或超过 $transferMaxFileBytes 字节，直接回复一行：`ZP-TRANSFER-FAIL $transferId 原因说明`。
5. 全部分块写完后，回复一行：`ZP-TRANSFER-OK $transferId 分块总数`（分块总数=part 文件个数，阿拉伯数字）。

可用 PowerShell / Python / Node 等任一可用方式实现。''';
}

/// 传输完成后发往会话的清理指令（用户在完成面板显式触发）。
String buildTransferCleanupInstruction(String transferId) =>
    '[ZP 手机传文件] 传输已完成，请删除工作区目录 `${transferDirFor(transferId)}/`'
    '（若该目录因此为空，`.zp-transfer/` 一并删除即可）。不要提交 git。';

/// 从 fileChanges 明细项收集到的单块。
class TransferPart {
  TransferPart({required this.index, required this.text});
  final int index;
  final String text;
}

/// 从一个轮次的 fileChanges 明细里收集属于本次传输的 part 全文。
/// 只认「新建文件全文」（全 `+` 行拼装，复用 file_preview 的判据语义
/// ——此处独立实现避免 ui 依赖：part 必为新建文件，上下文/删除行=
/// 异常形态，宁缺勿错）。items 形如 [{path, patches:[{lines:[...]}]}]。
List<TransferPart> collectTransferParts(
  List<dynamic> items,
  String transferId,
) {
  final dirPrefix = '${transferDirFor(transferId)}/';
  final found = <int, String>{};
  for (final raw in items) {
    if (raw is! Map) continue;
    final path = '${raw['path']}'.replaceAll('\\', '/');
    final leaf = path.split('/').last;
    final idx = transferPartIndexOf(leaf);
    if (idx == null) continue;
    // 目录前缀必须整段命中（尾匹配会串到其他传输的同名 part）。
    if (!path.contains(dirPrefix)) continue;
    final text = _assembleNewFileText(raw['patches']);
    if (text == null) continue;
    found[idx] = text;
  }
  return [
    for (final k in found.keys.toList()..sort()) TransferPart(index: k, text: found[k]!),
  ];
}

/// 与 file_preview.assembleNewFileText 同判据（全 `+` 行拼全文；
/// 独立实现避免 transfer → ui 依赖；jsdiff 无尾换行标记行跳过）。
String? _assembleNewFileText(dynamic patches) {
  if (patches is! List) return null;
  final lines = <String>[];
  for (final patch in patches) {
    if (patch is! Map) return null;
    final raw = patch['lines'];
    if (raw is! List) return null;
    for (final line in raw) {
      if (line is! String) return null;
      if (line.startsWith(r'\')) continue;
      if (!line.startsWith('+')) return null;
      lines.add(line.substring(1));
    }
  }
  if (lines.isEmpty) return null;
  return lines.join('\n');
}

/// 拼接分块 → 解码字节。序号必须 1..N 连续；总字节超限抛 StateError。
///
/// 解码语义：每块都是「某字节区间的 Base64」（指令要求非末块不带 "="
/// 填充；agent 常见实现会逐块带填充——两者统一按**逐块独立解码后拼
/// 字节**处理：剥空白/剥尾部 "="/补齐 4 的倍数/解该块字节。任意切点
/// 都无损，两种填充形态兼容。
Uint8List decodeTransferParts(List<TransferPart> parts, int totalParts) {
  if (totalParts <= 0) {
    throw StateError('分块总数不合法：$totalParts');
  }
  if (parts.length < totalParts) {
    throw StateError('分块缺失：收到 ${parts.length}/$totalParts');
  }
  final byIndex = {for (final p in parts) p.index: p.text};
  final out = BytesBuilder(copy: false);
  for (var i = 1; i <= totalParts; i++) {
    final t = byIndex[i];
    if (t == null) throw StateError('分块缺失：#$i 不连续');
    var compact = t.replaceAll(RegExp(r'\s'), '');
    while (compact.endsWith('=')) {
      compact = compact.substring(0, compact.length - 1);
    }
    final rem = compact.length % 4;
    if (rem > 0) {
      compact += '=' * (4 - rem);
    }
    out.add(base64.decode(compact));
  }
  final bytes = out.toBytes();
  if (bytes.length > transferMaxFileBytes) {
    throw StateError('文件超过传输上限（${bytes.length} 字节）');
  }
  return bytes;
}

/// OK/FAIL 标记扫描（assistantText 行文本）。
({int totalParts})? parseTransferOkMarker(String text, String transferId) {
  final re = RegExp(
    r'ZP-TRANSFER-OK\s+' + RegExp.escape(transferId) + r'\s+(\d+)',
  );
  final m = re.firstMatch(text);
  if (m == null) return null;
  return (totalParts: int.parse(m.group(1)!));
}

String? parseTransferFailMarker(String text, String transferId) {
  final re = RegExp(
    r'ZP-TRANSFER-FAIL\s+' + RegExp.escape(transferId) + r'\s*[:：]?\s*(.*)',
  );
  final m = re.firstMatch(text);
  if (m == null) return null;
  final reason = (m.group(1) ?? '').trim();
  return reason.isEmpty ? 'agent 报告传输失败（无原因说明）' : reason;
}

/// 行内文本候选（marker 扫描面）：assistantText 的正文；toolCall 行的
/// 输出/摘要字段不扫——指令已要求 marker 走回复正文，扫描面收窄防
/// base64/日志误命中。
String? markerScanTextOfRow(Map<String, dynamic> row) {
  if (row['kind'] != 'assistantText') return null;
  final t = row['text'];
  return t is String ? t : null;
}

/// 传输状态机。
enum FileTransferPhase {
  /// 指令发送中。
  sending,

  /// 等 agent 分块（写盘/回复）。
  waiting,

  /// 已收到 OK 标记，等尾块 diff 到达（宽限窗）。
  waitingTail,

  /// 解码落盘中。
  decoding,

  /// 完成（file=落盘文件）。
  done,

  /// 失败（error=人话原因）。
  failed,
}

/// 传输控制器：轮询订阅行的增量（新 turnHeader→fileChanges 收块，
/// 新 assistantText→marker），完成即回调落盘。
///
/// 依赖注入（全部可 fake，单测直灌）：
/// - [getRows]：会话当前行快照（页面订阅 state.rows）。
/// - [fetchFileChanges]：按 turn target 拉明细。
/// - [sendText]：发指令。
class FileTransferController extends ChangeNotifier {
  FileTransferController({
    required this.getRows,
    required this.fetchFileChanges,
    required this.sendText,
    required this.onDecoded,
    this.transferId,
    this.pollInterval = transferPollInterval,
    this.timeout = transferTimeout,
    this.partsGrace = transferPartsGrace,
    this.now,
  });

  final Future<List<Map<String, dynamic>>> Function() getRows;
  final Future<dynamic> Function(Map<String, dynamic> target) fetchFileChanges;
  final Future<void> Function(String text) sendText;

  /// 解码完成回调（字节交出；落盘/打开在 UI 层做，保持控制器无 IO）。
  final Future<void> Function(Uint8List bytes) onDecoded;

  /// 显式注入（测试）；null=自动生成（时间戳+4 位随机）。
  final String? transferId;
  final Duration pollInterval;
  final Duration timeout;

  /// OK 标记后等尾块的宽限窗（可注入缩跑测试）。
  final Duration partsGrace;
  final DateTime Function()? now;

  FileTransferPhase phase = FileTransferPhase.sending;
  String? error;

  /// 文件名与路径（UI 展示/落盘名）。
  String path = '';
  String fileName = '';

  /// 已收块数（按最大连续序号计）与 OK 标记给出的总数（未知=null）。
  int receivedParts = 0;
  int? totalParts;

  bool _cancelled = false;
  bool _running = false;
  String? _resolvedId;
  int _baselineRowId = 0;
  final _parts = <int, String>{};
  final _harvestedTurns = <int, int>{}; // turnHeader rowId → 已收 files 数
  DateTime? _okMarkerAt;

  String get id => _resolvedId ?? '';

  void cancel() => _cancelled = true;

  /// 主流程：发指令 → 轮询 → 收块 → 解码。异常整体吞进 [error]，
  /// 不抛（UI 只看状态）。
  Future<void> start({
    required String path,
    required String fileName,
  }) async {
    if (_running) return;
    _running = true;
    _cancelled = false;
    this.path = path;
    this.fileName = fileName;
    _resolvedId = transferId ?? _newTransferId();
    error = null;
    totalParts = null;
    receivedParts = 0;
    _parts.clear();
    _harvestedTurns.clear();
    _okMarkerAt = null;
    _setPhase(FileTransferPhase.sending);
    try {
      await _captureBaseline();
      await sendText(buildTransferInstruction(path: path, transferId: id));
      _setPhase(FileTransferPhase.waiting);
      await _pollLoop();
    } catch (e) {
      if (!_cancelled) _fail('传输失败：$e');
    } finally {
      _running = false;
    }
  }

  String _newTransferId() {
    final t = (now ?? DateTime.now)().toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}${two(t.hour)}${two(t.minute)}${two(t.second)}';
    var rnd = 0;
    try {
      rnd = DateTime.now().microsecondsSinceEpoch % 0xFFFF;
    } catch (_) {}
    return 't$stamp-${rnd.toRadixString(16).padLeft(4, '0')}';
  }

  void _setPhase(FileTransferPhase p) {
    phase = p;
    notifyListeners();
  }

  void _fail(String message) {
    error = message;
    _setPhase(FileTransferPhase.failed);
  }

  /// 基线：当前最大 rowId（其后行才算「本轮新增」）。空会话=0。
  Future<void> _captureBaseline() async {
    final rows = await getRows();
    var max = 0;
    for (final r in rows) {
      final v = (r['rowId'] as num?)?.toInt() ?? -1;
      if (v > max) max = v;
    }
    _baselineRowId = max;
  }

  Future<void> _pollLoop() async {
    DateTime clock() => (now ?? DateTime.now)();
    final deadline = clock().add(timeout);
    while (!_cancelled) {
      if (clock().isAfter(deadline)) {
        _fail('等待 agent 分块超时（${timeout.inMinutes} 分钟），可在桌面端查看执行情况后重试');
        return;
      }
      await Future<void>.delayed(pollInterval);
      if (_cancelled) return;
      try {
        final finished = await _pollOnce(clock());
        if (finished) return;
      } catch (e) {
        // 单次轮询失败不终止传输（连接抖动下一轮自愈）；连续失败由
        // 总超时兜底。
        debugPrint('[transfer] poll error: $e');
      }
    }
  }

  /// 一轮轮询。返回 true=已终态（done/failed）。
  Future<bool> _pollOnce(DateTime at) async {
    final rows = await getRows();
    // 1) marker 扫描（assistantText 行，基线之后）。
    for (final r in rows) {
      final rid = (r['rowId'] as num?)?.toInt() ?? -1;
      if (rid <= _baselineRowId) continue;
      final text = markerScanTextOfRow(r);
      if (text == null) continue;
      final fail = parseTransferFailMarker(text, id);
      if (fail != null) {
        _fail('agent 报告：$fail');
        return true;
      }
      final ok = parseTransferOkMarker(text, id);
      if (ok != null && totalParts == null) {
        totalParts = ok.totalParts;
        _okMarkerAt = at;
      }
    }
    // 2) 新 turnHeader → fileChanges 收块（files 数增长则重拉）。
    for (final r in rows) {
      final rid = (r['rowId'] as num?)?.toInt() ?? -1;
      if (rid <= _baselineRowId) continue;
      if (r['kind'] != 'turnHeader') continue;
      final entityId = '${r['entityId'] ?? ''}'.trim();
      if (entityId.isEmpty) continue;
      final fc = r['fileChanges'];
      final files = fc is Map ? (fc['files'] as num?)?.toInt() ?? 0 : 0;
      final last = _harvestedTurns[rid];
      if (last != null && files <= last) continue;
      final res = await fetchFileChanges({'rowId': rid, 'entityId': entityId});
      _harvestedTurns[rid] = files;
      final items = res is Map ? res['items'] as List? : null;
      if (items == null) continue;
      for (final p in collectTransferParts(items, id)) {
        _parts[p.index] = p.text;
      }
      receivedParts = _contiguousCount();
      notifyListeners();
    }
    // 3) 终态判定。
    if (totalParts != null && receivedParts >= totalParts!) {
      _setPhase(FileTransferPhase.decoding);
      try {
        final bytes = decodeTransferParts(
          [
            for (final k in _parts.keys.toList()..sort())
              TransferPart(index: k, text: _parts[k]!),
          ],
          totalParts!,
        );
        await onDecoded(bytes);
        _setPhase(FileTransferPhase.done);
        return true;
      } catch (e) {
        _fail('解码失败：$e');
        return true;
      }
    }
    // 4) OK 标记已到但尾块迟迟不来（diff 丢失/agent 谎报）→ 宽限超时。
    final okAt = _okMarkerAt;
    if (okAt != null && at.difference(okAt) > partsGrace) {
      _fail('分块缺失：标记 ${totalParts ?? '?'} 块，实收 $receivedParts 块（宽限 ${partsGrace.inSeconds}s 超时）');
      return true;
    }
    return false;
  }

  /// 最大连续序号（从 1 起）。
  int _contiguousCount() {
    var n = 0;
    while (_parts.containsKey(n + 1)) {
      n++;
    }
    return n;
  }
}
