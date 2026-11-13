/// 手机本地落盘与外部应用打开（transfer-1 基建，2026-11-13 用户需求
/// 「产物传到手机用 WPS 等打开」）。
///
/// 落盘位置：应用私有文档目录下的 `downloads/`（无存储权限诉求；
/// FileProvider 按次授予读 URI，外部应用经 ACTION_VIEW 打开）。.mime
/// 表为本地最小集（覆盖 office/pdf/压缩包/图片/文本），未收录扩展回退
/// `application/octet-stream`（系统仍会给出可处理字节的应用选择器）。
///
/// 平台通道：companion/fileopener（MainActivity.kt 注册）——方法
/// `openWithExternal(path, mime)`。测试缝：宿主测试无插件注册，
/// MissingPluginException 抛 [UnsupportedError] 人话化。
library;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 传输产物落盘目录名（应用私有 documents 下一级）。
const downloadsDirName = 'downloads';

/// 原生通道名与方法（MainActivity.kt companion/fileopener 对位）。
const fileOpenerChannelName = 'companion/fileopener';
const fileOpenerMethodName = 'openWithExternal';

final _fileOpenerChannel = MethodChannel(fileOpenerChannelName);

/// 常见扩展 → MIME（本地最小表；未收录回退 octet-stream）。
const _mimeByExt = <String, String>{
  '.doc': 'application/msword',
  '.docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx':
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.xlsm': 'application/vnd.ms-excel.sheet.macroenabled.12',
  '.csv': 'text/csv',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.pdf': 'application/pdf',
  '.zip': 'application/zip',
  '.7z': 'application/x-7z-compressed',
  '.rar': 'application/vnd.rar',
  '.gz': 'application/gzip',
  '.tar': 'application/x-tar',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.bmp': 'image/bmp',
  '.svg': 'image/svg+xml',
  '.txt': 'text/plain',
  '.md': 'text/markdown',
  '.json': 'application/json',
  '.xml': 'application/xml',
  '.html': 'text/html',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.mp4': 'video/mp4',
  '.mov': 'video/quicktime',
};

/// 文件名 → MIME（大小写不敏感；无扩展/未收录 → octet-stream）。
String mimeForFileName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot + 1 >= name.length) return 'application/octet-stream';
  return _mimeByExt[name.substring(dot).toLowerCase()] ??
      'application/octet-stream';
}

/// 落盘文件名净化：剥路径分隔符与控制字符、去首尾空白/点、限长
/// 120（文件系统安全线），空结果回退 'file'——源文件名来自 agent
/// 写盘路径/产物标题，不可信直拼。
String sanitizeFileName(String name) {
  var s = name.replaceAll(RegExp(r'[\\/:\u0000-\u001f]'), '_').trim();
  while (s.startsWith('.')) {
    s = s.substring(1);
  }
  if (s.length > 120) {
    final dot = s.lastIndexOf('.');
    // 保扩展名截断（无扩展名或截点太靠前则硬截）。
    if (dot > 0 && s.length - dot <= 16) {
      s = s.substring(0, 120 - (s.length - dot)) + s.substring(dot);
    } else {
      s = s.substring(0, 120);
    }
  }
  return s.isEmpty ? 'file' : s;
}

/// downloads 目录（懒创建；路径=`<documents>/downloads`）。
Future<Directory> downloadsDir() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(
    '${docs.path}${Platform.pathSeparator}$downloadsDirName',
  );
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  return dir;
}

/// 字节落盘到 downloads（同名覆盖——传输重试语义；返回实际文件）。
/// 主 isolate 直写（≤32MB 一次性 addAll 已在调用方缓冲，磁盘 IO 毫秒级）。
Future<File> saveBytesToDownloads({
  required String fileName,
  required List<int> bytes,
}) async {
  final dir = await downloadsDir();
  final file = File(
    '${dir.path}${Platform.pathSeparator}${sanitizeFileName(fileName)}',
  );
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

/// 外部应用打开失败的人话异常（PlatformException 透传 code/message）。
class FileOpenException implements Exception {
  FileOpenException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 经系统选择器用外部应用打开文件（WPS/Office/浏览器等）。
/// 文件必须位于 FileProvider 覆盖域内（见 android file_paths.xml：
/// files 目录全树，含 path_provider documents=files/app_flutter）。
Future<void> openWithExternalApp({
  required String path,
  String? mime,
}) async {
  try {
    await _fileOpenerChannel.invokeMethod(fileOpenerMethodName, {
      'path': path,
      'mime': mime ?? mimeForFileName(path),
    });
  } on MissingPluginException {
    throw UnsupportedError('当前平台不支持外部应用打开（原生通道未注册）');
  } on PlatformException catch (e) {
    throw FileOpenException('${e.code}: ${e.message ?? e.details ?? '未知错误'}');
  }
}
