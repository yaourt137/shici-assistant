import Foundation

/// 搜韵（sou-yun.cn）单字查韵链接。网址格式并非公开接口，系实测所得，搜韵改版时可能失效。
public enum SouYunLink {
    /// 目前支持的韵书（中华通韵的网址格式尚未确认）。
    public static let supportedBooks: [RhymeBook] = [.pingshui, .cilin]

    /// 非汉字或不支持的韵书返回 nil。字按原样发送（简繁体搜韵均可识别）。
    public static func url(for character: Character, book: RhymeBook) -> URL? {
        guard TextSegmenter.isHan(character) else { return nil }
        let text = String(character)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "sou-yun.cn"
        components.path = "/QR.aspx"
        switch book {
        case .pingshui:
            components.queryItems = [URLQueryItem(name: "ct", value: ""), URLQueryItem(name: "c", value: text)]
        case .cilin:
            components.queryItems = [URLQueryItem(name: "c", value: text), URLQueryItem(name: "ci", value: "*")]
        case .tongyun:
            return nil
        }
        return components.url
    }
}
