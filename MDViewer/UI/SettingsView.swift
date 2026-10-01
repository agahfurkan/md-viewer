import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.appearance) private var appearance = AppearancePreference.system.rawValue
    @AppStorage(SettingsKey.fontSize) private var fontSize = Double(ReaderStyle.defaultFontSize)
    @AppStorage(SettingsKey.fontDesign) private var fontDesign = ReaderFontDesign.system.rawValue
    @AppStorage(SettingsKey.readingWidth) private var readingWidth = ReadingWidth.standard.rawValue

    var body: some View {
        Form {
            Picker("Appearance:", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)

            Picker("Font:", selection: $fontDesign) {
                ForEach(ReaderFontDesign.allCases) { Text($0.title).tag($0.rawValue) }
            }

            LabeledContent("Text size:") {
                HStack {
                    Slider(
                        value: $fontSize,
                        in: Double(ReaderStyle.fontSizeRange.lowerBound)...Double(ReaderStyle.fontSizeRange.upperBound),
                        step: 1
                    )
                    .frame(width: 180)
                    Text("\(Int(fontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Picker("Reading width:", selection: $readingWidth) {
                ForEach(ReadingWidth.allCases) { Text($0.title).tag($0.rawValue) }
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
