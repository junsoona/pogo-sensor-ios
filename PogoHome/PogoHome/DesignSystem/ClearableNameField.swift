import SwiftUI

/// A single-line name field for the room and sensor editors: `placeholder` shows in the
/// system's gray placeholder style whenever `text` is empty (a suggested/default name, not
/// a label), and an `xmark.circle.fill` clear button sits at the trailing edge only while
/// there is text to clear. The field takes all remaining width and truncates; the button
/// keeps its own fixed width, so the two never overlap at any Dynamic Type size.
struct ClearableNameField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    /// Data (a suggested or product name), shown verbatim.
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            TextField(title, text: $text, prompt: Text(placeholder))
                .frame(maxWidth: .infinity, alignment: .leading)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        // A concrete gray, not `.secondary`: inside a borderless Button the
                        // hierarchical `.secondary` style derives from the button's accent tint
                        // and renders light blue. `secondaryLabel` adapts to light/dark mode.
                        .foregroundStyle(Color(.secondaryLabel))
                        // A comfortable tap target without growing the Form row.
                        .frame(minWidth: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                // Borderless keeps the tap on the button alone instead of the whole Form row.
                .buttonStyle(.borderless)
                .fixedSize()
                .accessibilityLabel("이름 지우기")
            }
        }
    }
}

#Preview {
    @Previewable @State var roomName = ""
    @Previewable @State var sensorName = "창가 센서"
    Form {
        ClearableNameField(title: "방 이름", text: $roomName, placeholder: "거실 2")
        ClearableNameField(title: "기기 이름", text: $sensorName, placeholder: "PMS5003 미세먼지 센서")
    }
}
