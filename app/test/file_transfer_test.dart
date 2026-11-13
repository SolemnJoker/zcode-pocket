import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transfer/file_transfer.dart';

/// agent 分块中转传输（transfer-1）：线上协议、纯函数（指令生成/分块
/// 收集/解码/marker 解析）与控制器状态机（fake 注入全路径）。

Map<String, dynamic> _partItem(
  String transferId,
  int index,
  String text, {
  bool edited = false,
  bool wrongDir = false,
}) {
  final dir = wrongDir
      ? '$transferRootDir/other-id'
      : transferDirFor(transferId);
  final lines = edited
      ? ['+${text.substring(0, 4)}', 'ctx', '+${text.substring(4)}']
      : ['+$text'];
  return {
    'path': '$dir/part-${index.toString().padLeft(4, '0')}.b64',
    'additions': lines.length,
    'deletions': 0,
    'patches': [
      {'lines': lines},
    ],
  };
}

String _b64Of(String s) => base64.encode(utf8.encode(s));

void main() {
  test('传输目录与 part 命名：4 位零填充，续位自然加宽', () {
    expect(transferDirFor('t1'), '.zp-transfer/t1');
    expect(transferPartName(1), 'part-0001.b64');
    expect(transferPartName(42), 'part-0042.b64');
    expect(transferPartName(9999), 'part-9999.b64');
    expect(transferPartName(12345), 'part-12345.b64');
    expect(transferPartIndexOf('part-0007.b64'), 7);
    expect(transferPartIndexOf('part-12345.b64'), 12345);
    expect(transferPartIndexOf('part-7.b64'), isNull);
    expect(transferPartIndexOf('other.txt'), isNull);
  });

  test('buildTransferInstruction：含路径/目录/序号起止/marker/上限', () {
    final ins = buildTransferInstruction(
      path: 'G:\\示例\\报告.docx',
      transferId: 'tx1',
    );
    expect(ins, contains(r'G:\示例\报告.docx'));
    expect(ins, contains('.zp-transfer/tx1/'));
    expect(ins, contains('part-0001.b64'));
    expect(ins, contains('part-0002.b64'));
    expect(ins, contains('ZP-TRANSFER-OK tx1'));
    expect(ins, contains('ZP-TRANSFER-FAIL tx1'));
    expect(ins, contains('$transferMaxFileBytes 字节'));
    // OK 模板占位「分块总数」非数字，不构成可自查命中的完成信号。
    expect(parseTransferOkMarker(ins, 'tx1'), isNull);
    // FAIL 模板含真实 id 会命中解析（原因「原因说明`。」）——真实防线
    // 是扫描只认 assistantText 行：用户指令行 kind=userInput 不扫描。
    expect(
      markerScanTextOfRow({'kind': 'userInput', 'text': ins}),
      isNull,
    );
  });

  test('buildTransferCleanupInstruction：指向本传输目录', () {
    final ins = buildTransferCleanupInstruction('tx9');
    expect(ins, contains('.zp-transfer/tx9/'));
  });

  test('collectTransferParts：归属目录过滤+反斜杠归一+连续排序', () {
    final items = [
      _partItem('tx1', 2, _b64Of('BB')),
      _partItem('tx1', 1, _b64Of('AA')),
      // 反斜杠路径（agent 常见输出形态）。
      {
        'path': '.zp-transfer\\tx1\\part-0003.b64',
        'patches': [
          {'lines': ['+${_b64Of('CC')}']},
        ],
      },
      // 其他传输的同名 part 不收。
      _partItem('tx2', 1, _b64Of('XX')),
      // 错目录名（other-id）不收。
      _partItem('tx1', 4, _b64Of('YY'), wrongDir: true),
      // 编辑过（含上下文行）的 part 不收（宁缺勿错）。
      _partItem('tx1', 5, _b64Of('ZZ'), edited: true),
      // 无关文件不收。
      {
        'path': 'src/main.dart',
        'patches': [
          {'lines': ['+void main() {}']},
        ],
      },
    ];
    final parts = collectTransferParts(items, 'tx1');
    expect(parts.map((p) => p.index).toList(), [1, 2, 3]);
    expect(parts[0].text, _b64Of('AA'));
    expect(parts[2].text, _b64Of('CC'));
  });

  test('decodeTransferParts：连续拼接解码；缺块/超限报错', () {
    final p1 = TransferPart(index: 1, text: _b64Of('你好，'));
    // 分块文本带换行（76 字符行宽的真实形态）→ 解码前剥除。
    final p2 = TransferPart(index: 2, text: '${_b64Of('世界！')}\n');
    final bytes = decodeTransferParts([p2, p1], 2);
    expect(utf8.decode(bytes), '你好，世界！');

    // 独立填充的分块（agent 常见实现）：各块自带 "="，剥除后按位流
    // 语义整体补齐解码——跨块切点无损。
    final padded1 = TransferPart(index: 1, text: base64.encode(utf8.encode('AB')));
    final padded2 = TransferPart(index: 2, text: base64.encode(utf8.encode('CD')));
    expect(
      utf8.decode(decodeTransferParts([padded1, padded2], 2)),
      'ABCD',
    );

    expect(
      () => decodeTransferParts([p1], 2),
      throwsStateError,
    );
    expect(() => decodeTransferParts([], 0), throwsStateError);
    // 缺中间块。
    final p3 = TransferPart(index: 3, text: _b64Of('！'));
    expect(
      () => decodeTransferParts([p1, p3], 3),
      throwsStateError,
    );
    // 超上限拒收。
    final big = TransferPart(
      index: 1,
      text: _b64Of('x' * (transferMaxFileBytes + 1)),
    );
    expect(() => decodeTransferParts([big], 1), throwsStateError);
  });

  test('marker 解析：只认真实 id；占位模板与他 id 不误命中', () {
    expect(
      parseTransferOkMarker('前文 ZP-TRANSFER-OK tx1 40 后文', 'tx1')?.totalParts,
      40,
    );
    expect(parseTransferOkMarker('ZP-TRANSFER-OK tx12 40', 'tx1'), isNull,
        reason: 'id 前缀重叠不误命中');
    expect(
      parseTransferOkMarker('ZP-TRANSFER-OK <transferId> 分块总数', 'tx1'),
      isNull,
    );
    expect(
      parseTransferFailMarker('ZP-TRANSFER-FAIL tx1：文件超过上限', 'tx1'),
      '文件超过上限',
    );
    expect(
      parseTransferFailMarker('ZP-TRANSFER-FAIL tx1', 'tx1'),
      contains('无原因说明'),
    );
    expect(parseTransferFailMarker('ZP-TRANSFER-FAIL tx2 x', 'tx1'), isNull);
  });

  test('markerScanTextOfRow：只扫 assistantText 行', () {
    expect(
      markerScanTextOfRow({'kind': 'assistantText', 'text': 'ZP-TRANSFER-OK t 1'}),
      'ZP-TRANSFER-OK t 1',
    );
    expect(markerScanTextOfRow({'kind': 'userInput', 'text': 'ZP-TRANSFER-OK t 1'}),
        isNull, reason: '用户指令行含模板字样，不参与扫描');
    expect(markerScanTextOfRow({'kind': 'toolCall'}), isNull);
    expect(markerScanTextOfRow({'kind': 'assistantText'}), isNull);
  });

  group('FileTransferController（fake 全路径）', () {
    // fetchFileChanges 闭包读取的可变 items（闭包捕获外层变量）。
    var currentItems = <Map<String, dynamic>>[];

    (FileTransferController, List<Map<String, dynamic>>, List<String>,
        List<Uint8List>) makeFixture() {
      final rows = <Map<String, dynamic>>[
        {'rowId': 1, 'kind': 'userInput', 'text': '前文'},
      ];
      final sent = <String>[];
      final decoded = <Uint8List>[];
      final c = FileTransferController(
        getRows: () async => List<Map<String, dynamic>>.of(rows),
        fetchFileChanges: (target) async => {'items': currentItems},
        sendText: (text) async => sent.add(text),
        onDecoded: (b) async => decoded.add(b),
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(seconds: 3),
        partsGrace: const Duration(milliseconds: 200),
      );
      return (c, rows, sent, decoded);
    }

    test('happy path：发指令→收块→OK 标记→解码回调→done', () async {
      final (c, rows, sent, decoded) = makeFixture();
      final run = c.start(path: 'G:/w/报告.docx', fileName: '报告.docx');
      final tid = c.id;
      expect(tid, isNotEmpty);
      // start() 首个 await 前只完成 id 生成；发送落在事件循环后。
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(sent, hasLength(1));
      expect(sent.single, contains(tid));

      // 第一轮轮询后注入：新 turnHeader + assistantText marker + 两块。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      currentItems = [
        _partItem(tid, 1, _b64Of('你好，')),
        _partItem(tid, 2, _b64Of('世界！')),
      ];
      rows.addAll([
        {
          'rowId': 3,
          'kind': 'turnHeader',
          'entityId': 'e1',
          'fileChanges': {'files': 2, 'additions': 2, 'deletions': 0},
        },
        {
          'rowId': 4,
          'kind': 'assistantText',
          'text': '完成。ZP-TRANSFER-OK $tid 2',
        },
      ]);
      await run;
      expect(c.phase, FileTransferPhase.done);
      expect(c.error, isNull);
      expect(c.totalParts, 2);
      expect(c.receivedParts, 2);
      expect(decoded, hasLength(1));
      expect(utf8.decode(decoded.single), '你好，世界！');
    });

    test('FAIL 标记 → failed（原因透传）', () async {
      final (c, rows, sent, decoded) = makeFixture();
      final run = c.start(path: 'a.txt', fileName: 'a.txt');
      final tid = c.id;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      rows.add({
        'rowId': 3,
        'kind': 'assistantText',
        'text': 'ZP-TRANSFER-FAIL $tid 文件超过 20MB',
      });
      await run;
      expect(c.phase, FileTransferPhase.failed);
      expect(c.error, contains('文件超过 20MB'));
      expect(decoded, isEmpty);
      // sent 只有一条（本轮指令）。
      expect(sent, hasLength(1));
    });

    test('无响应 → 总超时 failed', () async {
      final rows = <Map<String, dynamic>>[];
      final c = FileTransferController(
        getRows: () async => List<Map<String, dynamic>>.of(rows),
        fetchFileChanges: (target) async => {'items': const []},
        sendText: (text) async {},
        onDecoded: (b) async {},
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(milliseconds: 60),
        partsGrace: const Duration(milliseconds: 200),
      );
      await c.start(path: 'a.txt', fileName: 'a.txt');
      expect(c.phase, FileTransferPhase.failed);
      expect(c.error, contains('超时'));
    });

    test('OK 标记先到但尾块迟迟不来 → 宽限超时 failed', () async {
      final (c, rows, _, decoded) = makeFixture();
      final run = c.start(path: 'a.txt', fileName: 'a.txt');
      final tid = c.id;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // 只写 1 块但标记 2 块。
      currentItems = [_partItem(tid, 1, _b64Of('AA'))];
      rows.addAll([
        {
          'rowId': 3,
          'kind': 'turnHeader',
          'entityId': 'e1',
          'fileChanges': {'files': 1},
        },
        {
          'rowId': 4,
          'kind': 'assistantText',
          'text': 'ZP-TRANSFER-OK $tid 2',
        },
      ]);
      await run;
      expect(c.phase, FileTransferPhase.failed);
      expect(c.error, contains('分块缺失'));
      expect(c.error, contains('实收 1 块'));
      expect(decoded, isEmpty);
    });

    test('取消：等待中 cancel → 面板关闭，无失败状态', () async {
      final rows = <Map<String, dynamic>>[];
      final c = FileTransferController(
        getRows: () async => rows,
        fetchFileChanges: (target) async => {'items': const []},
        sendText: (text) async {},
        onDecoded: (b) async {},
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(seconds: 10),
      );
      final run = c.start(path: 'a.txt', fileName: 'a.txt');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      c.cancel();
      await run;
      expect(c.phase, isNot(FileTransferPhase.failed));
      expect(c.error, isNull);
    });

    test('新 turnHeader 的 files 数增长 → 重拉明细补齐尾块', () async {
      final (c, rows, _, decoded) = makeFixture();
      final run = c.start(path: 'a.bin', fileName: 'a.bin');
      final tid = c.id;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      currentItems = [_partItem(tid, 1, _b64Of('AA'))];
      rows.add({
        'rowId': 3,
        'kind': 'turnHeader',
        'entityId': 'e1',
        'fileChanges': {'files': 1},
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // agent 继续写第 2 块：header files 增长 → 重拉。
      currentItems = [
        _partItem(tid, 1, _b64Of('AA')),
        _partItem(tid, 2, _b64Of('BB')),
      ];
      rows[rows.indexWhere((r) => r['rowId'] == 3)]['fileChanges'] = {
        'files': 2,
      };
      // marker 在尾块之后到达。
      await Future<void>.delayed(const Duration(milliseconds: 30));
      rows.add({
        'rowId': 4,
        'kind': 'assistantText',
        'text': 'ZP-TRANSFER-OK $tid 2',
      });
      await run;
      expect(c.phase, FileTransferPhase.done, reason: c.error);
      expect(utf8.decode(decoded.single), 'AABB');
    });
  });
}
