<img width="823" height="733" alt="Screenshot 2026-11-17 at 12 37 36 PM" src="https://github.com/user-attachments/assets/d61a5932-01a6-40c7-ace2-178902d27939" />


# 诗词助手（ShiCi）

一个用于古典诗词格律创作的 macOS 应用：逐字标注平仄、检查近体诗与词谱格律、显示对/粘，并管理个人词句收藏。

## 功能

- **格律分析**
  - 逐字标注平仄，支持平水韵、词林正韵、中华通韵三套韵书。
  - 近体诗（五七言绝句、律诗）：检查平仄、粘对、押韵、孤平、三平尾、拗救、特拗；可手动指定起收（平起平收、仄起仄收等）。
  - 词：按内置词谱逐字检查平仄与押韵（含换韵）。
  - 律句律对：标出每句的律句类型、每联是否律对、联间是否相粘，用于长庆体、梅村体等律化歌行。
  - 句末字韵部显示。
- **多音字与读音**
  - 为多音字按位置指定读音（声调 + 韵部），格律与押韵判断随之改变。
  - 为韵书漏收的字补充平水韵读音（自定义读音），词林正韵随之换算。
  - 一键在浏览器中打开搜韵，查平水韵、词林正韵归部。
- **语料**
  - 可一键下载并导入 [chinese-poetry](https://github.com/chinese-poetry/chinese-poetry) 的唐诗、宋词，用于替换候选、前人用例、相关诗句与出处反查。
  - 查看语料全文时可标注平仄与韵部。
- **收藏**：词句收藏、标签、智能收藏夹、收件箱。
- **MCP**：附带 `shici-mcp` 服务器，供 Claude Code 等 agent 查字、检查格律、检索与收藏词句。

## 下载

在 [Releases](../../releases) 下载 `ShiCi.zip`，解压后得到 `ShiCi.app`。

应用仅做了本地临时签名，未经 Apple 公证。首次打开时系统会阻止运行，请在 Finder 中右键点击 `ShiCi.app`，选择「打开」；或在「系统设置 → 隐私与安全性」中允许打开。

## 运行要求

- macOS 26 或更高版本
- 从源码编译需要 Xcode 26（Swift 6.2）

## 从源码编译

```sh
# 编译 App（产物在 build/Build/Products/Release/ShiCi.app）
xcodebuild -project ShiCi.xcodeproj -scheme ShiCi -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build build

# 运行单元测试
cd PoetryCore && swift test
```

也可以直接用 Xcode 打开 `ShiCi.xcodeproj` 运行。

## MCP 服务器

```sh
cd PoetryCore && swift build -c release
claude mcp add shici -- "$(pwd)/.build/release/shici-mcp"
```

提供的工具：`lookup_char`、`check_poem`、`list_forms`、`find_candidates`、`find_usages`、`search_phrases`、`add_phrase`、`tag_phrase` 等。是否允许 agent 写入、写入的收藏是否先进收件箱，可在 App 的「设置」中调整。

## 项目结构

- `ShiCi/`：SwiftUI 应用界面。
- `PoetryCore/`：格律分析、韵书、语料索引、用户库与 MCP 服务器（Swift Package），业务逻辑均在此并附单元测试。
- `ShiCiUITests/`：UI 测试。

用户数据（作品、收藏、设置、语料索引）保存在 `~/Library/Application Support/ShiCi`。

## 数据来源与许可

本项目代码以 MIT 许可发布，见 [LICENSE](LICENSE)。内置数据来自以下项目，许可文件见 `PoetryCore/Sources/PoetryCore/Resources/Licenses/`：

| 数据 | 来源 | 许可 |
|---|---|---|
| 平水韵字表 | [rbnyng/pingshui_rhyme](https://github.com/rbnyng/pingshui_rhyme)（整理自维基文库「平水韻」） | MIT |
| 拼音（中华通韵） | [mozillazg/pinyin-data](https://github.com/mozillazg/pinyin-data) | MIT |
| 繁简字表 | [OpenCC](https://github.com/BYVoid/OpenCC) | Apache-2.0 |
| 唐诗、宋词语料（运行时下载，不随项目分发） | [chinese-poetry](https://github.com/chinese-poetry/chinese-poetry) | MIT |

词林正韵不是独立数据，由平水韵韵目结合今音韵母换算而来。

## 已知限制

- 平水韵数据源整理自维基文库，有漏收的字与又读（例如「伎」缺上声纸韵一读）。可在 App 中用「自定义读音」补充。
- 内置词谱每个词牌只取一种常见体式，建议对照《钦定词谱》复核。
- 搜韵链接的网址格式并非搜韵公开接口，搜韵改版后可能失效。
