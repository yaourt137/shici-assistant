import PoetryCore
import SwiftUI

/// 在默认浏览器中打开搜韵，查该字的平水韵、词林正韵归部。可放在面板行内，也可放进右键菜单。
struct SouYunButtons: View {
    @Environment(\.openURL) private var openURL
    let character: Character

    var body: some View {
        ForEach(SouYunLink.supportedBooks) { book in
            if let url = SouYunLink.url(for: character, book: book) {
                Button("搜韵·\(book.displayName)") { openURL(url) }
                    .help("在浏览器中打开搜韵，查「\(character)」的\(book.displayName)归部")
                    .accessibilityIdentifier("souyun-\(book.rawValue)")
            }
        }
    }
}
