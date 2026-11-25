# PaperDesk

[English quick start](../README.md) · [下载示例 PDF](../examples/reading-sample.pdf) · [提交试用反馈](https://github.com/childrenyancute-crypto/PaperDesk/issues/new?template=beta-feedback.yml)

PaperDesk 是为理论物理和数学文献准备的 Mac 阅读器。你可以把几页里的公式放进同一个问题，回看保存的回答时点出处跳回原文。PDF 阅读、批注、笔记和导出都能单独使用。

## 安装早期测试版

当前通过源码构建。需要 macOS 14 或更新版本，以及 Swift 6 或更新版本（可通过 Xcode 16 或兼容的 Command Line Tools 安装）。

```sh
git clone https://github.com/childrenyancute-crypto/PaperDesk.git
cd PaperDesk
./scripts/package-app.sh
open dist/PaperDesk.app
```

如需放进 Finder 的「应用程序」，可在配置 AI 连接前移动 `dist/PaperDesk.app`。

## 用示例做一次跨页问答

1. 把[合成示例 PDF](../examples/reading-sample.pdf)拖入 PaperDesk。确认或修改建议名称并点「创建项目」。打开「框选公式」，在第 1 页框选式 (1) 作为 A，在第 2 页框选式 (3) 作为 B。退出公式框选后，划选第 2 页的 “For a time-independent Hamiltonian” 作为 C。
2. 保持 PaperDesk 打开。在「焦点」上方的项目卡点击「在终端打开」。项目文件夹还未准备时，点击「准备项目」。如果已安装并登录 Codex 或 OpenCode，在这个终端运行 `codex` 或 `opencode`。PaperDesk 会给这个文件夹生成连接配置。其他支持本机 MCP 的客户端可从「更多 → 连接 MCP 客户端」复制配置。
3. 在客户端提问。回答归档后，打开「阅读」里的这一条记录，点问题下方的选区标签回到 PDF。

> 请用 PaperDesk 的 A、B、C 三个选区，解释 B 里的演化算符作用在 A 的本征态上得到什么。推导在哪一步用到了 C 的哈密顿量不随时间变化的假设？请把这次问答保存到 PaperDesk，并附上这三个选区。

如果想试回答里的编号出处，可把这份合成示例的「AI 正文读取范围」调为「全文」，请客户端在答复中引用两页的相关段落。

如果暂时不接 AI，也可以点「焦点」中任一选区旁的批注按钮，写一条批注，然后通过「更多 → 导出批注 PDF」带走。

试完后欢迎留一句话，说说哪一步帮到了你，或者你在哪一步卡住。安装没成功也可以提交。[提交试用反馈](https://github.com/childrenyancute-crypto/PaperDesk/issues/new?template=beta-feedback.yml)

## 阅读、批注与笔记

1. 打开 PaperDesk，拖入 PDF，或点「导入 PDF」。
2. 在「焦点」里选中一条选区，点该条目的批注按钮，输入内容后写入 PDF。在「阅读」页签可以查看已归档的问答。
3. 在 PDF 里划选文字，或打开工具栏的「框选公式」后拖出矩形。「焦点」按 A、B、C 显示选区。点击一项可回到原文，点批注图标为它添加批注，点 × 移除。翻页后可以继续往同一组里加。
4. 可以接入 AI 客户端发问，例如「从 A 到 B 时，在哪一步用了 C 的条件？」客户端可读取本轮选区，把完整问答和出处写回「阅读」。
5. AI 提炼的笔记和原文摘录会出现在「阅读」里的「待审核」。确认前可以修改笔记，或删减、重排摘录的原句。「焦点」上方的项目卡点「笔记」可浏览和编辑这篇文献的全部笔记。

讨论和笔记会在本机排版行内和独立的 LaTeX 公式，保存与导出时保留原始文本。公式由内置的 SwiftMath 排版，只支持受限的 LaTeX 子集：行内 `$...$`，独立公式 `$$...$$`、`\[...\]` 或 equation 环境；可用环境为 matrix、pmatrix、bmatrix、Bmatrix、vmatrix、Vmatrix、cases、aligned、split、eqalign、gather、displaylines、eqnarray。`\label`、`\tag`、`\newcommand`、`\operatorname`、`\overset`、`\ce`、`\hspace` 等命令以及公式内的中文或 emoji 不会渲染。MCP 提供了 `check_latex` 工具：发送或归档前把完整答复交给它检查，会返回将要渲染的规范形式，并指出仍不支持的写法。

在「更多」菜单的「界面语言」中可在中文和 English 之间切换整套界面。

在「更多 → 文献信息」中编辑标签、阅读状态和 BibTeX。可以从 Zotero 的 `.bib` 导出文件里挑一条引用，也可手动粘贴并复制已存条目。在「更多」中还能导出批注 PDF、阅读记录 JSON、Markdown 或备份资料库。

手动批注在「焦点」里逐条添加，用黄色。高亮和评论保存在资料库里的阅读用 PDF 中，可以从「更多」在 Finder 中找到这份文件，用其他 PDF 阅读器查看。导入前的文件和资料库里的原始版本会保留。拖动右侧栏左边的分隔线可以调整宽度。

阅读目标和笔记入口都在「焦点」上方的项目卡里。拖动 PDF 导入时会弹出项目名创建框，默认使用论文文件的标题；创建后卡片标题显示这个项目名。项目文件夹里会维护 `reading-goal.md` 和 `notes.md` 两份 Markdown 镜像，便于直接查看；SQLite 仍是权威数据，AI 客户端通过 MCP 写入（`set_reading_goal`、`submit_note_draft` 等），不要让它直接改这两个文件。未开启「允许 AI 读取手写笔记」时，手写笔记不会写入镜像。

## 接入 MCP 客户端

通过「连接 MCP 客户端」复制本机连接设置，可选择跟随当前论文，或固定绑定一篇论文。提问时保持 PaperDesk 开着。客户端可以按关键词查找这篇论文的旧讨论和已确认笔记。手写笔记通过独立开关分享，手动问答可逐条分享。每条 AI 记录会记录客户端来源。右栏的项目卡可在终端中打开单篇论文的项目文件夹，直接启动 opencode 等命令行客户端；「复制项目路径」可把同一文件夹地址贴到其他客户端里创建项目。项目准备会同时写入 Codex 的 `.codex/config.toml` 和 OpenCode 的 `opencode.json`（已存在时只合并 `mcp.paperdesk` 条目）。

回答引用原文时，客户端会先用 `cite_passage` 为每处原文建立一个编号，正文里以 `⟦1⟧` 这样的上标标出，保存讨论时一并归档。点开「阅读」里的某条回答，「出处」角标为青色圆圈数字，正文用浅色底加下划线标出这条回答的全部引用。切换到另一条回答后，上一组的标注自动消失。引用不会占用 A、B、C 选区，也不受清空选区影响。写进 PDF 的批注由用户在「焦点」里逐条手动添加。

阅读区右下角的提问气泡可以把问题发给本机的 Codex、OpenCode 或其他已注册的 MCP 客户端；气泡和输入框都可以拖动，并限制在正文预览区域内。展开一条阅读记录会让它成为续问目标，此时提问直接续接该对话；没有活跃对话时，选择栏只列出**当前论文已通过 MCP 连接**的客户端。翻页或隐藏右栏时续问目标仍然有效。浮层显示发送目标，并在发送时固定当前页和选区。旧记录首次续接时可能需要填写外部客户端的会话编号。回答保存到阅读记录，提问失败时可从浮层找回草稿。

客户端续写同一会话时，向 `save_discussion` 提供这篇论文上一条已归档回答的 `message_id` 作为 `previous_discussion_id`。连接重启后，PaperDesk 也能把续问归入原来的会话。

项目与具体论文和 PDF 版本绑定。每次发问固定一份阅读状态，后续翻页或取消选区只影响新问题。默认仅共享已固定的选区，可在「更多」或连接窗口里把当前文献的正文读取范围改为「当前页」或「全文」。重新启动 PaperDesk 后恢复默认范围。所选 AI 客户端可能把读取的文字、公式截图和问题发送给它的模型服务。手写笔记有独立的分享开关，默认不分享。PDF、选区截图和阅读记录保存在 `~/Library/Application Support/PaperDesk/Library`，可通过「备份资料库」备份。论文项目文件夹位于 `~/Documents/PaperDesk/Codex Projects`。

右栏项目卡右上角的圆点表示 MCP 连接状态：绿色实心表示有客户端连接，灰色空心表示未连接。点击圆点查看连接的程序、版本、项目文件夹和本地 MCP 服务状态；没有连接时显示「暂无 MCP 连接」。「最近项目访问」显示上次经该论文专属连接收到请求的时间。

## 开发

- `scripts/package-app.sh` 构建本机应用。
- `scripts/test.sh` 运行本地验证。部分命令行沙箱禁止本机进程通信，可在 Mac 的终端中直接运行。
- 新增外部客户端：实现 `QuestionClientAdapter` 并在 `QuestionClientRegistry.adapters` 注册一个条目；状态点和发送列表会自动出现该客户端。
- [早期实施方案](implementation-plan.md)。
