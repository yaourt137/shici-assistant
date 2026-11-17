import Foundation
import Testing
@testable import PoetryCore

@Suite("搜韵链接")
struct SouYunLinkTests {
    @Test("平水韵与词林正韵的查字网址")
    func urls() {
        #expect(SouYunLink.url(for: "看", book: .pingshui)?.absoluteString == "https://sou-yun.cn/QR.aspx?ct=&c=%E7%9C%8B")
        #expect(SouYunLink.url(for: "看", book: .cilin)?.absoluteString == "https://sou-yun.cn/QR.aspx?c=%E7%9C%8B&ci=*")
    }

    @Test("繁体字与扩展区汉字按原样编码")
    func encoding() {
        #expect(SouYunLink.url(for: "聽", book: .pingshui)?.absoluteString == "https://sou-yun.cn/QR.aspx?ct=&c=%E8%81%BD")
        #expect(SouYunLink.url(for: "𠀀", book: .cilin)?.absoluteString == "https://sou-yun.cn/QR.aspx?c=%F0%A0%80%80&ci=*")
    }

    @Test("非汉字与不支持的韵书不生成链接")
    func unsupported() {
        for character: Character in ["a", "，", " ", "1"] {
            #expect(SouYunLink.url(for: character, book: .pingshui) == nil)
        }
        #expect(SouYunLink.url(for: "看", book: .tongyun) == nil)
        #expect(SouYunLink.supportedBooks == [.pingshui, .cilin])
    }
}
