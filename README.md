# 诗词助手（ShiCi）

一个用于古典诗词格律创作的 macOS 应用：逐字标注平仄、检查近体诗与词谱格律、显示对/粘，并管理个人词句收藏。

<img width="823" height="733" alt="Screenshot 2026-11-17 at 12 37 36 PM" src="https://github.com/user-attachments/assets/d61a5932-01a6-40c7-ace2-178902d27939" />

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
- **语料**
  - 可一键下载并导入 [chinese-poetry](https://github.com/chinese-poetry/chinese-poetry) 的唐诗、宋词，以及 [Werneror/Poetry](https://github.com/Werneror/Poetry) 先秦至当代约 85 万首（按时代分为先秦至隋、唐五代、宋、辽金元、明、清、近现代与当代七个包），用于替换候选、前人用例、相关诗句与出处反查。
  - 不同语料包中的同一作品（全文相同，或作者相同且七成以上的句子相同）自动去重：只用优先的一份（chinese-poetry 优先），其余不参与检索、计数与统计；查看全文时可看其他版本，作者不同时注明「又作」。停用优先的语料包后，其他版本自动恢复。
  - 查看语料全文时可标注平仄与韵部。
- **典籍**
  - 《声律启蒙》《笠翁对韵》（内置）：在「韵书」中按平水韵平声韵查看各节，韵脚高亮，不属本韵的韵脚注明实际韵目；字表中标出它们用作韵脚的字。
  - 《佩文韵府》（可下载）：在「韵书」中点选一字，查看字头注、韵藻、对语、摘句；编辑时按所选位置的字数、平仄与韵部给出韵藻（选中整句时含摘句），可直接替换。
  - 《艺文类聚》（可下载）：按部、子目浏览「事」与各体诗文，可全文检索。
  - 编辑时选中一个词，可查它在《声律启蒙》《笠翁对韵》与佩文「对语」中的对仗。
- **对仗训练（Beta）**：评级规则仍在调整，结果仅供参考。
  - 对词（四字以内）、对句（五言、七言与长对）随机出题，题库取自《声律启蒙》《笠翁对韵》、佩文对语（下载后）与语料中律诗、排律的中间各联；可按来源、字数筛选。
  - 评为工、可、宽、失四级：字数不同、出对重字、末字平仄不相对为失；其余看要位平仄、五七言是否成律对，以及各字在律诗对仗联中同位相对的次数（数目、颜色、方位、干支、叠字算同类）。与原书、原诗一致时注明出处。
  - 练习记录：再次抽到答过的题时标出练过几次与上次评级，提交后列出以往作答；可只出新题或只出答过的题；记录页可筛选、删除。
  - 自由对：自己出题自己对，不记录；只填出词时列出典籍中的对与律诗常对。
  - 评分后可查看原诗全文（出自语料时）或佩文韵府中的对语（出自佩文时）；点「律诗常对」中的一项，列出律诗里这样相对的各联。
  - 好的对仗可收进收藏，标签为「对仗/对词」或「对仗/对句」。
- **读诗**
  - 读语料中的诗词（查看全文时点「读诗」，或按诗句查找），也可粘入自己的文本。
  - 圈点：圈、点、密圈（双击一句）、专名线、书名线；再按一次即取消，可撤销。颜色可在设置中选朱或墨。
  - 横排或竖排：竖排时一行一列、自右向左，圈点、专名线、书名线都在字左，平仄在字右，标点用竖排字形。
  - 批注：选中文字写评语，列在一旁；圈过的句子可一键收藏，出处自动填好。
  - 可叠加平仄、韵部，切换繁简。圈点本存在本机资料库，存有正文，语料变动不受影响。
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

提供的工具：`lookup_char`、`check_poem`、`list_forms`、`find_candidates`、`find_usages`、`search_phrases`、`add_phrase`、`tag_phrase`，以及查典籍的 `find_yunzao`（佩文韵藻）、`find_couplet`（对仗）、`search_leiju`（艺文类聚），给对仗评分的 `score_couplet` 等。佩文韵府与艺文类聚须先在 App 中下载。是否允许 agent 写入、写入的收藏是否先进收件箱，可在 App 的「设置」中调整。

## 项目结构

- `ShiCi/`：SwiftUI 应用界面。
- `PoetryCore/`：格律分析、韵书、语料索引、典籍解析与索引、用户库与 MCP 服务器（Swift Package），业务逻辑均在此并附单元测试。
- `ShiCiUITests/`：UI 测试。

用户数据（作品、收藏、设置、语料索引、典籍）保存在 `~/Library/Application Support/ShiCi`。两部典籍下载并导入后约占 170MB（文本约 67MB，索引约 100MB）。

## 数据来源与许可

本项目代码以 MIT 许可发布，见 [LICENSE](LICENSE)。内置数据来自以下项目，许可文件见 `PoetryCore/Sources/PoetryCore/Resources/Licenses/`：

| 数据 | 来源 | 许可 |
|---|---|---|
| 平水韵字表 | [rbnyng/pingshui_rhyme](https://github.com/rbnyng/pingshui_rhyme)（整理自维基文库「平水韻」） | MIT |
| 拼音（中华通韵） | [mozillazg/pinyin-data](https://github.com/mozillazg/pinyin-data) | MIT |
| 繁简字表 | [OpenCC](https://github.com/BYVoid/OpenCC) | Apache-2.0 |
| 唐诗、宋词语料（运行时下载，不随项目分发） | [chinese-poetry](https://github.com/chinese-poetry/chinese-poetry) | MIT |
| 先秦至当代语料（运行时下载，不随项目分发） | [Werneror/Poetry](https://github.com/Werneror/Poetry) | MIT |
| 声律启蒙 | [维基文库「聲律啓蒙」](https://zh.wikisource.org/wiki/聲律啓蒙) | 公有领域 |
| 笠翁对韵 | [维基文库「笠翁對韻」](https://zh.wikisource.org/wiki/笠翁對韻) | 公有领域 |
| 佩文韵府、艺文类聚（运行时下载，不随项目分发） | [漢リポ Kanseki Repository](https://github.com/kanripo)（[KR3k0059](https://github.com/kanripo/KR3k0059)、[KR3k0003](https://github.com/kanripo/KR3k0003)，四库全书文渊阁本） | CC BY-SA 4.0 |

词林正韵不是独立数据，由平水韵韵目结合今音韵母换算而来。

## 已知限制

- 平水韵数据源整理自维基文库，有漏收的字与又读（例如「伎」缺上声纸韵一读）。可在 App 中用「自定义读音」补充。
- 内置词谱每个词牌只取一种常见体式，建议对照《钦定词谱》复核。
- 佩文韵府、艺文类聚的原文无标点，条目切分按原书版式推断（如韵藻跨行、引文按行宽合并），个别条目可能切分有误；注文中的「丨」按体例还原，悬停或打开详情可看原文。缺字显示为「〓」或「□」。
- 典籍按繁简对照查字，不处理异体字：例如佩文韵府把「啼」收在「嗁」下，查「啼」查不到。
- Werneror/Poetry 把生僻字换成了「?」（另有「■」和「{訁亞}」式的部件描述），导入后一律显示为「□」，含「□」的句子不作替换候选、不计入对仗统计。其中近现代与当代作品的作者多在版权期内。全部导入后索引约 3GB（连同 chinese-poetry 实测约 3.1GB），导入共需十分钟左右；对仗训练的题库约 100 万联，占用内存约 0.7GB。
- 去重按文字比对：异体字（如「雁/鴈」）、断句不同或改动较多的异文可能认不出来；作者不同且只有部分句子相同的，视为不同作品。
- 对仗评分是近似判断：只看字数、重字、平仄与律诗中的同位字统计，不判断词性与句法，也不识别流水对；律诗中间各联并非都对仗，统计中混有少量不对仗的联。
- 繁简转换存在将「乾坤」转为「干坤」之类的问题。
