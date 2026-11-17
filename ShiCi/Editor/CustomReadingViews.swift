import PoetryCore
import SwiftUI

/// 按声部分组选择平水韵韵目。
struct PingshuiGroupMenu: View {
    @Environment(AppModel.self) private var model
    let title: String
    /// 不可选的韵目（如该字已收录者）。
    let excluded: Set<Int>
    let onSelect: (Int) -> Void

    var body: some View {
        Menu(title) {
            ForEach(PingshuiSection.allCases, id: \.self) { section in
                Menu(section.displayName) {
                    ForEach(model.dictionary.groups.filter { $0.section == section }) { group in
                        Button(group.displayName) { onSelect(group.id) }
                            .disabled(excluded.contains(group.id))
                    }
                }
            }
        }
        .accessibilityIdentifier("pingshuiGroupMenu")
    }
}

/// 「字音」页中某字的自定义读音：列出已补充的读音（可删除），并可再补充。
struct CustomReadingRows: View {
    @Environment(AppModel.self) private var model
    let character: Character

    private var readings: [CustomReading] {
        let simplified = model.dictionary.converter.simplified(character)
        return model.customReadings.filter { model.dictionary.converter.simplified($0.character) == simplified }
    }

    var body: some View {
        ForEach(readings) { reading in
            HStack {
                Text("自定义").foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                Text(model.dictionary.groups.indices.contains(reading.groupID)
                     ? model.dictionary.groups[reading.groupID].displayName : "未知韵目")
                Spacer()
                Button {
                    model.removeCustomReading(reading)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("删除这条自定义读音")
            }
        }
        PingshuiGroupMenu(title: "补充平水韵读音…", excluded: Set(model.dictionary.pingshuiGroupIDs(of: character))) { groupID in
            model.addCustomReading(String(character), groupID: groupID)
        }
        .fixedSize()
        .help("韵书漏收的又读可在此补充；词林正韵随之换算，中华通韵不受影响")
    }
}
