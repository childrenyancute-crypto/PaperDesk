# PaperDesk

[中文使用说明](docs/usage.zh-CN.md) · [Example PDF](examples/reading-sample.pdf) · [Releases](https://github.com/childrenyancute-crypto/PaperDesk/releases) · [Beta feedback](https://github.com/childrenyancute-crypto/PaperDesk/issues/new?template=beta-feedback.yml)

PaperDesk is a macOS PDF reader for formula-heavy papers in physics and mathematics. Select passages and box equations across pages, ask about them in your AI client, and jump from a saved answer back to the relevant passage.

You can also read, annotate, keep notes, and export annotated PDFs using PaperDesk on its own. The app keeps a local copy of your papers and reading history, and preserves the original PDF.

## Install the public beta

The beta is a source release. To build it, use macOS 14 or later and an Apple toolchain with Swift 6 or later. Xcode 16 or compatible Command Line Tools provide the toolchain.

```sh
git clone https://github.com/childrenyancute-crypto/PaperDesk.git
cd PaperDesk
./scripts/package-app.sh
open dist/PaperDesk.app
```

You can move `dist/PaperDesk.app` into Applications before connecting an AI client. The app supports Chinese and English under **更多 → 界面语言** (**More → Interface language**).

## Try the example

1. Download the [example PDF](examples/reading-sample.pdf) and drag it into PaperDesk. Accept or edit the suggested project name and choose **Create project**. The PDF was made for the demo.
2. Turn on **Select formula** (框选公式). Box equation (1), `H |n> = E_n |n>`, on page 1. Go to page 2 and box equation (3), `U(t) = exp(-i H t / hbar)`. Turn off **Select formula** and highlight “For a time-independent Hamiltonian” on page 2. The **Focus** tab keeps the selections together as A, B, and C.
3. To save a PDF comment, use the annotation button beside a selection in **Focus**. To try a sourced AI answer, continue below.

### Ask about the equations

Keep PaperDesk open on the sample. In the project card at the top of **Focus**, click **Open in Terminal** (在终端打开), or **Prepare project** (准备项目) if the folder is still being set up. With a signed-in client installed, run `codex` or `opencode` in that Terminal window. PaperDesk writes a local MCP configuration for both clients in the paper's project folder.

For a client you configure manually, open **More → Connect MCP client** and copy the connection settings. Review the paper's **AI text scope** while setting up the connection. It starts at **Selection only** and can be expanded to the current page or the full paper. Restarting PaperDesk restores the default.

> Use PaperDesk selections A, B, and C. How does the operator in B act on the state in A? Where does the time-independence assumption in C enter the derivation? Save the discussion with the three selections attached.

Open the discussion in **Reading** and click one of the selection labels beneath the question to jump back to the original spot. To try numbered citations inside the answer, set **AI text scope** to **Full text** for this synthetic sample and ask the client to cite the two pages. If PaperDesk shows no connection, check that the client is running from the paper's project folder and has loaded the local MCP connection.

After trying PaperDesk, tell us which step helped or where you got stuck. A sentence is enough to start. [Share beta feedback](https://github.com/childrenyancute-crypto/PaperDesk/issues/new?template=beta-feedback.yml)

## Data and compatibility

- The library is stored in `~/Library/Application Support/PaperDesk/Library`. **More** includes annotated PDF export, Markdown and JSON exports, and a library backup.
- Your AI client can send the content it reads, including selected equation images, to its model provider. Handwritten notes have a separate sharing switch and start private.
- This beta was exercised on Apple Silicon.

## Development and license

Run `./scripts/test.sh` in Terminal for local checks. See the [Chinese usage guide](docs/usage.zh-CN.md) for exports, notes, and additional client options.

PaperDesk is available under the [MIT License](LICENSE). The bundled SwiftMath code and fonts retain their [upstream license notices](Sources/SwiftMath/mathFonts.bundle).
