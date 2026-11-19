import Foundation
@testable import PoetryCore

/// 典籍测试样本：摘自漢リポ文本（KR3k0059、KR3k0003），个别行为覆盖边界情况而改写。
enum ClassicsFixtures {
    /// 佩文韵府：上平一东的若干韵字，另含一行两个韵字、缺字实体、跨行注文与下平十蒸的「增冰」。
    static let peiwen = """
    # -*- mode: mandoku-view; -*-
    #+TITLE: 御定佩文韻府
    #+PROPERTY: ID KR3k0059
    #+PROPERTY: JUAN 卷一之一
    <pb:KR3k0059_WYG_002-1a>¶
    　欽定四庫全書¶
    孤行在韻目之前(不應計入)¶
    御定佩文韻府卷一之一¶
    　　上平聲　　　　一東韻一¶
    東(德紅切眷方也漢書少陽在丨方丨動也從日在木中會意/也禮記大明生於丨)¶
    　韻藻南東(詩丨丨其畝/李孝先詩)自東(詩我來丨丨/又自西丨丨)小東(詩丨丨大東杼柚/其空言大小皆取)¶
    　(給於/東國)乃¶
    東(本草丨丨/夏枯草名)首陽東(詩采葑采葑/丨丨之丨)¶
    <pb:KR3k0059_WYG_002-1b>¶
    　對語(縕瑟/吹東)　(千户劍/半通東)　(殘缺/)¶
    　&KR0933;句(力障百川東/光升必自東)　(内庭秋燕玉池東半溪春水帶愁東/菊花依舊繞籬東宛似山光小閣東)¶
    同(徒紅切説文丨合也)¶
    　韻藻會同(書四海丨丨)¶
    鸝(韻㑹音義/與支韻同)　　　　緀(七稽切丨斐/文章相錯貎)¶
    &KR2997;(徂紅切籠/丨取魚器)韻藻增萬尺&KR2997;(陸龜䝉詩到頭江畔/織作中流
    丨丨丨)¶
    　　下平聲　　　十蒸韻¶
    冰(筆陵切)¶
    　韻藻增冰(禮記丨丨)層冰(楚辭丨丨峨峨)¶
    　増瀆冰(某書丨丨)¶
    """

    /// 佩文韵府目录卷：应整卷跳过。
    static let peiwenCatalog = """
    #+PROPERTY: JUAN 卷一之一目録
    　　上平聲　　　一東韻一¶
    　東　同　銅　桐¶
    """

    /// 艺文类聚卷七开头（山部上·总载山、衡山）。
    static let leiju = """
    # -*- mode: mandoku-view; -*-
    #+TITLE: 藝文類聚
    #+PROPERTY: ID KR3k0003
    #+PROPERTY: JUAN 卷第七
    <pb:KR3k0003_WYG_007-1a>¶
    欽定四庫全書¶
    　藝文類聚卷第七　　　　唐　歐陽詢　撰¶
    　山部上(總載山/衡山)　(崑崙山/廬山)¶
    　　(鍾山山/燕然)　(北芒山/羅浮山)¶
    　　總載山¶
    春秋説題辭曰山之為言宣也含澤布氣調五神也¶
    國語曰禹封九山山者土之聚也¶
    論語曰仁者樂山¶
    <pb:KR3k0003_WYG_007-1b>¶
    春秋元命苞曰山者氣之包含所以含精藏雲故觸石¶
    而出¶
    鄧徳眀南康記曰平固縣覆笥山上有笥貯玉牒記故¶
    山因笥為名焉¶
    詩晉庾闡登楚山詩曰拂駕升西嶺寓目臨浚波想望¶
    <pb:KR3k0003_WYG_007-6a>¶
    七徳耀詠此九功歌龍駟釋陽林朝服集三河迴首盻¶
    宇宙一無濟邦家¶
    晉王凝之妻謝氏詩曰峩峩東嶽髙秀極冲清天巖中¶
    閒虚宇寂漠幽以玄非工復非匠雲構發自然噐象爾¶
    何物遂令我屢遷逝將宅斯宇可以盡天年¶
    　　衡山¶
    南嶽記曰衡山者五嶽之南嶽也(其/山)其來尚矣¶
    """

    /// 艺文类聚提要卷：应整卷跳过。
    static let leijuPreface = """
    #+PROPERTY: JUAN 提要
    　　提要¶
    　　　　(臣/)等謹案藝文類聚一百卷唐歐陽詢撰¶
    """

    /// 把样本写成典籍文本目录。
    static func makeDirectory(in directory: TemporaryDirectory) throws -> URL {
        try directory.write(peiwenCatalog, to: "texts/KR3k0059_001.txt")
        try directory.write(peiwen, to: "texts/KR3k0059_002.txt")
        try directory.write(leijuPreface, to: "texts/KR3k0003_000.txt")
        try directory.write(leiju, to: "texts/KR3k0003_007.txt")
        try directory.write("无关文件", to: "texts/Readme.org")
        return directory.url.appendingPathComponent("texts", isDirectory: true)
    }

    /// 把样本放进服务数据目录的 Classics 下，模拟两部典籍都已下载（尚未导入）。
    static func placeDownloadedTexts(for service: PoetryService, in directory: TemporaryDirectory) throws {
        let texts = try makeDirectory(in: directory)
        for work in ClassicWork.allCases {
            let target = service.paths.classics.appendingPathComponent(work.rawValue).appendingPathComponent("\(work.rawValue)-master")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for file in try ClassicsIndex.textFiles(of: work, in: texts) {
                try FileManager.default.copyItem(at: file, to: target.appendingPathComponent(file.lastPathComponent))
            }
        }
    }
}
