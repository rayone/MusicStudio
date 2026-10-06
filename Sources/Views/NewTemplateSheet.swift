import SwiftUI

public struct NewTemplateSheet: View {
    @ObservedObject var vm: StudioViewModel
    @Binding var isPresented: Bool

    @State private var title: String = ""
    @State private var genre: String = ""
    @State private var subgenre: String = ""
    @State private var bpmText: String = ""
    @State private var selectedKey: String = "None"
    @State private var selectedScale: String = "None"
    @State private var vocal: String = "unknown"
    @State private var timeSignature: String = "4/4"
    @State private var language: String = "english"
    @State private var vocalRegister: String = ""
    @State private var moodsText: String = ""
    @State private var instrumentsText: String = ""
    @State private var tagsText: String = ""
    @State private var proTip: String = ""
    @State private var caption: String = ""

    private let keyOptions = ["None", "C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    private let scaleOptions = ["None", "major", "minor"]
    private let vocalOptions = ["unknown", "instrumental", "male", "female", "duet", "choir"]
    private let timeSigOptions = ["4/4", "3/4", "6/8", "5/4", "7/8", "12/8"]

    public init(vm: StudioViewModel, isPresented: Binding<Bool>) {
        self.vm = vm
        self._isPresented = isPresented
        _caption = State(initialValue: vm.caption)
        if let sel = vm.selectedTemplate {
            _genre = State(initialValue: sel.genre)
            _subgenre = State(initialValue: sel.subgenre)
            _vocal = State(initialValue: sel.vocal.isEmpty ? "unknown" : sel.vocal)
            if let bpm = sel.bpm {
                _bpmText = State(initialValue: "\(bpm)")
            }
            if let key = sel.key, !key.isEmpty {
                _selectedKey = State(initialValue: key)
            }
            if let scale = sel.scale, !scale.isEmpty {
                _selectedScale = State(initialValue: scale)
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Style Preset")
                        .font(Theme.bodyBold)
                        .foregroundColor(Theme.fg)
                    Text("Create and save a reusable style template to the library")
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                }
                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .font(Theme.small)
                .foregroundColor(Theme.comment)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.bgDark)
                .cornerRadius(4)

                Button(action: savePreset) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("Save Preset")
                            .font(Theme.smallBold)
                    }
                    .foregroundColor(title.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.comment : Theme.fg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(title.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.bgHighlight : Theme.blue)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
            .background(Theme.bgFloat)

            Divider().background(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Title & Genre row
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PRESET TITLE *")
                                .font(Theme.smallBold)
                                .foregroundColor(Theme.comment)
                            TextField("e.g. Cyberpunk Industrial Bass", text: $title)
                                .textFieldStyle(.plain)
                                .font(Theme.body)
                                .foregroundColor(Theme.fg)
                                .padding(6)
                                .background(Theme.bgDark)
                                .cornerRadius(4)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("GENRE")
                                .font(Theme.smallBold)
                                .foregroundColor(Theme.comment)
                            TextField("e.g. Electronic, Hip-Hop", text: $genre)
                                .textFieldStyle(.plain)
                                .font(Theme.body)
                                .foregroundColor(Theme.fg)
                                .padding(6)
                                .background(Theme.bgDark)
                                .cornerRadius(4)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("SUBGENRE")
                                .font(Theme.smallBold)
                                .foregroundColor(Theme.comment)
                            TextField("e.g. Darksynth, Boom Bap", text: $subgenre)
                                .textFieldStyle(.plain)
                                .font(Theme.body)
                                .foregroundColor(Theme.fg)
                                .padding(6)
                                .background(Theme.bgDark)
                                .cornerRadius(4)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                        }
                    }

                    // Musical attributes row
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("BPM")
                                .font(Theme.smallBold)
                                .foregroundColor(Theme.comment)
                            TextField("e.g. 140", text: $bpmText)
                                .textFieldStyle(.plain)
                                .font(Theme.mono)
                                .foregroundColor(Theme.fg)
                                .padding(6)
                                .background(Theme.bgDark)
                                .cornerRadius(4)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                                .frame(width: 80)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("KEY")
                                .font(Theme.smallBold)
                                .foregroundColor(Theme.comment)
                            Picker("", selection: $selectedKey) {
                                ForEach(keyOptions, id: \.self) { k in
                                    Text(k).tag(k)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 80)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("SCALE")
                                .font(Theme.smallBold)
                                .foregroundColor(Theme.comment)
                            Picker("", selection: $selectedScale) {
                                ForEach(scaleOptions, id: \.self) { s in
                                    Text(s).tag(s)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 90)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("VOCAL")
                                .font(Theme.smallBold)
                                .foregroundColor(Theme.comment)
                            Picker("", selection: $vocal) {
                                ForEach(vocalOptions, id: \.self) { v in
                                    Text(v).tag(v)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 110)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("TIME SIG")
                                .font(Theme.smallBold)
                                .foregroundColor(Theme.comment)
                            Picker("", selection: $timeSignature) {
                                ForEach(timeSigOptions, id: \.self) { ts in
                                    Text(ts).tag(ts)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 80)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("LANGUAGE")
                                .font(Theme.smallBold)
                                .foregroundColor(Theme.comment)
                            TextField("english", text: $language)
                                .textFieldStyle(.plain)
                                .font(Theme.body)
                                .foregroundColor(Theme.fg)
                                .padding(6)
                                .background(Theme.bgDark)
                                .cornerRadius(4)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                                .frame(width: 90)
                        }
                    }

                    // Keywords & Tags row
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("INSTRUMENTS (comma-separated)")
                                .font(Theme.smallBold)
                                .foregroundColor(Theme.comment)
                            TextField("e.g. 808 bass, analog synth, distortion guitar", text: $instrumentsText)
                                .textFieldStyle(.plain)
                                .font(Theme.body)
                                .foregroundColor(Theme.fg)
                                .padding(6)
                                .background(Theme.bgDark)
                                .cornerRadius(4)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("MOODS (comma-separated)")
                                .font(Theme.smallBold)
                                .foregroundColor(Theme.comment)
                            TextField("e.g. dark, energetic, aggressive", text: $moodsText)
                                .textFieldStyle(.plain)
                                .font(Theme.body)
                                .foregroundColor(Theme.fg)
                                .padding(6)
                                .background(Theme.bgDark)
                                .cornerRadius(4)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("TAGS (comma-separated)")
                                .font(Theme.smallBold)
                                .foregroundColor(Theme.comment)
                            TextField("e.g. cyberpunk, retro, night drive", text: $tagsText)
                                .textFieldStyle(.plain)
                                .font(Theme.body)
                                .foregroundColor(Theme.fg)
                                .padding(6)
                                .background(Theme.bgDark)
                                .cornerRadius(4)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                        }
                    }

                    // Pro Tip
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PRODUCTION TIP / NOTES")
                            .font(Theme.smallBold)
                            .foregroundColor(Theme.comment)
                        TextField("e.g. Use 30 steps with DiT guidance 1.7 for tight low end", text: $proTip)
                            .textFieldStyle(.plain)
                            .font(Theme.body)
                            .foregroundColor(Theme.fg)
                            .padding(6)
                            .background(Theme.bgDark)
                            .cornerRadius(4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 1))
                    }

                    // Caption / Style Prompt
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("STYLE PROMPT / CAPTION")
                                .font(Theme.smallBold)
                                .foregroundColor(Theme.comment)
                            Spacer()
                            Button("Copy from Studio Caption") {
                                caption = vm.caption
                            }
                            .buttonStyle(.plain)
                            .font(Theme.small)
                            .foregroundColor(Theme.blue)
                        }

                        TextEditor(text: $caption)
                            .font(Theme.monoBody)
                            .foregroundColor(Theme.fg)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Theme.bgDark)
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                            .frame(minHeight: 140, maxHeight: 240)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 680, minHeight: 520)
        .background(Theme.bgDark)
    }

    private func savePreset() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        let bpmInt = Int(bpmText.trimmingCharacters(in: .whitespacesAndNewlines))
        let keyVal = selectedKey == "None" ? nil : selectedKey
        let scaleVal = selectedScale == "None" ? nil : selectedScale

        let moods = moodsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let insts = instrumentsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        _ = vm.createTemplate(
            title: t,
            genre: genre.trimmingCharacters(in: .whitespaces),
            subgenre: subgenre.trimmingCharacters(in: .whitespaces),
            bpm: bpmInt,
            key: keyVal,
            scale: scaleVal,
            vocal: vocal,
            time_signature: timeSignature,
            vocal_register: vocalRegister.isEmpty ? nil : vocalRegister,
            language: language.trimmingCharacters(in: .whitespaces),
            pro_tip: proTip.trimmingCharacters(in: .whitespaces),
            caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
            moods: moods,
            instruments: insts,
            tags: tags
        )

        isPresented = false
    }
}
