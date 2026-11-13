# 产物传输与预览设计（preview-kind-1 / transfer-1）

> 2026-11-13 · 用户需求：「在 app 中查看工作的产物（markdown/html/图片/
> word/excel 等）；word/excel 传输到手机用 WPS 等应用打开。」
> 决策摘要见 `docs/decisions.md` #26/#27。本文是完整设计与调优指南。

## 1. 背景与硬约束

ZCode Pocket 是纯客户端（仓库不含桌面端代码），走官方 Web 远控通道
（relay + V4 协议）。协议层三条硬事实（`zcode-protocol-v4` V4_METHODS
全量核实，`docs/protocol-notes.md`）：

1. **没有「按路径读文件字节」的方法**——桌面端只按会话投递：
   - 新建文件的全文随 `conversationFileChangesV4` 的 diff 到达
     （纯数据：不进模型上下文、零额度）；
   - 工作流产物有专用字节通道 `conversationWorkflowRunArtifactReadV4`
     （≤512KiB/块）；
   - 会话附件双向（`attachmentPut`/`attachmentRead`），但创建方只有
     手机客户端——桌面端 agent 无法创建附件 ref。
2. relay 凭据不能出手机（附件 round-trip 方案需要 PC 端脚本持有
   凭据，死结）。
3. 工具输出在桌面端有 ~32KiB 截断——「让 agent 在对话里直接输出
   base64」对 >20KB 的文件不可行。

## 2. 方案对比（为什么选 agent 分块中转）

| 方案 | 额度 | 可靠性 | 人在 PC 前的要求 | 结论 |
| --- | --- | --- | --- | --- |
| A. agent 把文件 base64 分块写工作区小文件（本方案） | ≈一轮普通工具调用 | 高（手机端校验连续性+超时+诚实失败） | 不需要（agent 代执行） | **采用** |
| B. 对话内直接输出 base64 | 高（工具输出截断 ~32KiB，大文件必死） | 低 | 不需要 | 否 |
| C. PC 端脚本经 relay 上传附件 | 零 | 高 | **需要人在 PC 前**（且凭据无法安全获取） | 否 |
| D. agent 转 HTML 复用网页预览 | ≈一轮 | 中（保真损失） | 不需要 | 未做（可后续叠加） |

## 3. 线上协议（transfer-1）

**指令**（手机端 `buildTransferInstruction` 生成，作为用户消息发送）：

- 目标文件按 base64 编码，每块 ≤131072 字节（解码后），写入工作区
  `.zp-transfer/<transferId>/part-NNNN.b64`（4 位以上零填充、从 1 连续）；
- 76 字符行宽；**非末块不带 `=` 填充**（解码端两种形态都兼容，见 §5）；
- 不打印 base64、不提交 git、不改源文件；
- 文件不存在/不可读/超 20MB → 回复 `ZP-TRANSFER-FAIL <id> <原因>`；
- 完成回复 `ZP-TRANSFER-OK <id> <分块总数>`。

**传输 ID**：`t<yyyyMMddHHmmss>-<4 位hex>`，防并发/重试串扰。

**手机端状态机**（`app/lib/transfer/file_transfer.dart`
`FileTransferController`，依赖全部注入可测）：

```
sending ──► waiting ──► (marker OK 且块齐) ──► decoding ──► done
                │  ▲                                │
                │  └── 每 3s 轮询：新 turnHeader →   │
                │      fileChanges 收块（files 数    │
                │      增长即重拉）                  │
                ├── marker FAIL ──► failed（原因透传）
                ├── 总超时（10min）──► failed
                └── OK 后 90s 宽限内块不齐 ──► failed（分块缺失）
```

- 轮询数据源=当前会话订阅的行快照（`ConversationSubscription.state.rows`）；
  marker 只扫 `assistantText` 行且 rowId>基线——**用户指令行里的模板
  字样永不误命中**；
- 分块按序号连续性校验（`part-0001..N` 缺任何一块不进解码）；
- 解码：逐块剥空白/剥尾部 `=`/补齐 4 倍数/独立解码后拼字节（对「流式
  无填充」与「逐块带填充」两种 agent 实现形态都正确，任意切点无损）；
- 完成：落盘 `<documents>/downloads/<原文件名>`（应用私有，无存储权限）→
  `companion/fileopener` 原生通道 → FileProvider 按次读授权 +
  `ACTION_VIEW` 系统选择器（WPS 等出现在其中）→ 自动调起；
- 清理：完成面板显式按钮发清理指令（agent 删除 `.zp-transfer/<id>/`），
  不自动发（尊重额度）。

## 4. 预览扩展（preview-kind-1）

`file_preview.dart` 新增档位路由 `openGeneratedFilePreview`：
html（WebView，file-preview-1 原有）→ markdown（flutter_markdown_plus，
样式与对话消息同源）→ 文本（等宽+复制全文）→ none（已知二进制）。
判定纯函数 `filePreviewKindFor`；二进制误入文本页由 NUL 嗅探兜底拒绝。
工作流产物同路由（markdown 产物进渲染页，不再纯文本）；产物二进制档
直接走 `workflowRunArtifactRead`（64 块/32MiB）落盘+打开，**无需 agent**。
可发现性：文件变更卡片里可预览行显示眼睛角标，二进制行显示「传到手机」
按钮——此前预览藏在默认折叠的卡片内（维护者本人都找不到过）。

## 5. 分块参数与调优指南

| 参数 | 现值 | 依据 |
| --- | --- | --- |
| 单块解码字节 | 128KiB（≈1751 行 × 76 字符） | 单文件 diff 行数上限未实测，保守起步 |
| 单文件上限 | 20MB（指令+解码双侧卡口） | word/excel 常见体量；5MB ≈ 40 块 |
| 轮询间隔 / 总超时 | 3s / 10min | agent 写盘一轮常见 10–60s |
| OK 后宽限 | 90s | 尾块 diff 可能晚于 marker 到达 |
| 产物字节上限 | 32MiB（64 块） | 图片档维持 16MiB 预览上限 |

**真机实测后若要放宽**：桌面端对单文件 diff 的行数/字节上限未知。
放宽步骤：先对一个 5MB 文件实测 128KiB 分块（40 块全达即安全）；再以
256KiB/块实测；若 `conversationFileChangesV4` 对单 turn 的 items 总量
有隐性上限，表现为「块收不齐+无 FAIL」——此时应减小分块或分多条指令
分批传输。改 `transferChunkBytes` 常量即可（指令模板自动跟随）。

## 6. 失败路径与安全边界

- **诚实失败**：FAIL 标记（原因透传）/超时/分块缺失/解码失败/落盘失败
  都在面板给出人话+重试（新 transferId）。
- **取消语义**：面板取消只停等待，agent 可能仍在执行——文案明示；
  重试无害（新目录）。
- **安全**：文件存应用私有目录；FileProvider 只按次授予读 URI
  （`exported=false`，覆盖域=files 目录树）；无存储权限；base64 不进
  模型上下文；清理指令只删本次传输目录。
- **污染**：临时分块写在工作区 `.zp-transfer/` 下，完成后经清理指令
  删除；中断的传输可让 agent 手动清（目录名带传输 ID 可定位）。

## 7. 实现索引

- `app/lib/transfer/file_transfer.dart` — 指令生成/收集/解码/marker/控制器
- `app/lib/transfer/local_files.dart` — 落盘/mime/外部打开（Dart 侧）
- `app/lib/ui/transfer_sheet.dart` — 传输面板与入口
- `app/lib/ui/file_preview.dart` — 档位路由 + Markdown/文本预览页
- `app/lib/ui/workflow_runs_page.dart` — 产物二进制落盘打开/图片外开
- `app/lib/ui/conversation_file_summary_card.dart` — 行内角标与传输入口
- `MainActivity.kt`（companion/fileopener）+ `AndroidManifest.xml`
  FileProvider + `res/xml/file_paths.xml`
- 测试：`app/test/file_transfer_test.dart`、`app/test/file_preview_test.dart`
