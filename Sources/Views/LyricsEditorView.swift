import SwiftUI

public struct ResizableEditor: View {
    @Binding var text: String
    @Binding var height: CGFloat
    var minHeight: CGFloat = 70
    var maxHeight: CGFloat = 900
    var defaultHeight: CGFloat
    var dimmed: Bool = false

    @State private var dragStartHeight: CGFloat? = nil
    @State private var hovering = false

    public init(
        text: Binding<String>,
        height: Binding<CGFloat>,
        minHeight: CGFloat = 70,
        maxHeight: CGFloat = 900,
        defaultHeight: CGFloat = 160,
        dimmed: Bool = false
    ) {
        self._text = text
        self._height = height
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.defaultHeight = defaultHeight
        self.dimmed = dimmed
    }

    public var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(Theme.mono)
                .foregroundColor(Theme.fg)
                .scrollContentBackground(.hidden)
                .background(Theme.bgDark)
                .frame(height: height)
                .cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
                .opacity(dimmed ? 0.5 : 1.0)

            ZStack {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 11)
                    .contentShape(Rectangle())
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(hovering ? Theme.blue : Theme.border)
                    .frame(width: 34, height: 3)
            }
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartHeight ?? height
                        if dragStartHeight == nil { dragStartHeight = start }
                        height = min(max(start + value.translation.height, minHeight), maxHeight)
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.15)) {
                    height = defaultHeight
                }
            }
        }
    }
}

public struct LyricsEditorView: View {
    @ObservedObject var vm: StudioViewModel

    public init(vm: StudioViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "quote.bubble")
                        .foregroundColor(Theme.blue)
                    Text("LYRICS")
                        .font(Theme.smallBold)
                        .foregroundColor(Theme.comment)
                }

                if vm.isInstrumental {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.system(size: 10))
                        Text("Instrumental — lyrics disabled")
                            .font(Theme.small)
                    }
                    .foregroundColor(Theme.green)
                    Spacer()
                } else {
                    // Structure tag buttons inline on the header row
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            let tags = vm.selectedModelFamily == .yue2
                                ? ["[Intro]", "[Verse]", "[Pre-Chorus]", "[Chorus]", "[Post-Chorus]", "[Bridge]", "[Instrumental]", "[Solo]", "[Outro]"]
                                : ["[intro]", "[verse]", "[pre-chorus]", "[chorus]", "[post-chorus]", "[bridge]", "[instrumental]", "[solo]", "[outro]"]

                            ForEach(tags, id: \.self) { tag in
                                Button(tag) {
                                    vm.insertLyricsTag(tag)
                                }
                                .buttonStyle(.plain)
                                .font(Theme.small)
                                .foregroundColor(Theme.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.bgHighlight)
                                .cornerRadius(4)
                            }
                        }
                    }
                }
            }

            if vm.isInstrumental {
                Text("This track is instrumental. Toggle Instrumental off in Generation Parameters to write lyrics.")
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)
                    .padding(.vertical, 6)
            } else {
                ResizableEditor(
                    text: $vm.lyrics,
                    height: $vm.lyricsEditorHeight,
                    defaultHeight: 140,
                    dimmed: false
                )

                HStack {
                    let linesCount = vm.lyrics.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                    Text("\(linesCount) lines • \(vm.lyrics.count) chars")
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                    Spacer()

                    HStack(spacing: 4) {
                        Image(systemName: "number.circle")
                            .font(.system(size: 10))
                        Text("Total: ~\(vm.totalPromptTokens) / 4500 tokens (est)")
                            .font(Theme.mono)
                    }
                    .foregroundColor(vm.tokenColor)
                }

                if vm.totalPromptTokens > 4500 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Theme.yellow)
                            .font(Theme.small)
                        Text("Exceeds 4,500 token budget (\(vm.totalPromptTokens) tokens). Trailing lyric lines will be auto-trimmed at generation.")
                            .font(Theme.small)
                            .foregroundColor(Theme.yellow)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.bgDark)
                    .cornerRadius(4)
                }
            }
        }
        .padding(12)
        .background(Theme.bgFloat)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}
