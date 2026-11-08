import SwiftUI
import QuietCalendarCore

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch vm.screen {
                case .onboarding:
                    onboarding
                case .note:
                    noteScreen
                case .confirm:
                    confirmScreen
                case .schedule:
                    scheduleScreen
                case .deleteReview:
                    // The delete review UI lives in the capture panel
                    // (CaptureContentView). This legacy popover only gets
                    // here if a delete flow was left open; show the note
                    // field so the user can retry from here.
                    noteScreen
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 340, height: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { vm.prepareForPopoverOpen() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { vm.prepareForPopoverOpen() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("QuikCal")
                .font(.system(.headline, design: .rounded))
            Spacer()
            if vm.screen != .onboarding {
                Button {
                    vm.openOnboarding()
                } label: {
                    Image(systemName: "calendar.badge.checkmark")
                }
                .buttonStyle(.plain)
                .help(vm.selectedCalendarTitle)
                .accessibilityLabel("Calendar settings")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Onboarding

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a calendar")
                .font(.subheadline.weight(.semibold))
            Text("QuikCal only writes when you press Add, and only into a writable calendar macOS already exposes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch vm.accessPhase {
            case .granted, .writeOnly:
                // 2026-11-07 owner correction: write-only is connected —
                // the writable list is the default calendar under that
                // grant. The UI never demands full access just to show it.
                if vm.accessPhase == .writeOnly {
                    Text("Connected — events go to your default calendar. Full Access additionally enables browsing calendars and voice delete.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if vm.calendarChoices.isEmpty {
                    Text("No writable calendars were found.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(vm.calendarChoices) { choice in
                                Button {
                                    vm.selectCalendar(choice)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(choice.title).font(.callout.weight(.medium))
                                            if !choice.sourceTitle.isEmpty {
                                                Text(choice.sourceTitle)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        if vm.selectionState.choice?.id == choice.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.secondary.opacity(0.08))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            case .denied:
                Text("Calendar access is denied or restricted. Enable it in System Settings → Privacy & Security → Calendars, then return here.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .notDetermined, .unknown:
                Button("Allow Calendar Access") {
                    vm.requestCalendarAccess()
                }
                .buttonStyle(.borderedProminent)
                Text("Access is requested only when you click this button.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if case .missing = vm.selectionState {
                Text("Your previously chosen calendar is missing or no longer writable. Pick another.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let status = vm.statusMessage {
                Text(status).font(.caption).foregroundStyle(.red)
            }

            Spacer(minLength: 0)
            if case .valid = vm.selectionState {
                Button("Continue") { vm.screen = .note }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
    }

    // MARK: - Note

    private var noteScreen: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if vm.inputText.isEmpty {
                    Text("Type anything to add to your calendar")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $vm.inputText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: vm.inputText) { _, _ in
                        vm.inputChanged()
                    }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
            )

            if let clarification = vm.clarification {
                Text(clarification)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = vm.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = vm.parseNote, vm.clarification == nil {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let speechMessage = vm.speech.message {
                Text(speechMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    vm.speech.toggle()
                } label: {
                    Image(systemName: micSymbol)
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(vm.speech.state == .recording ? .red : .primary)
                .disabled(vm.isParsing || vm.isSaving)
                .accessibilityLabel(vm.speech.state == .recording ? "Stop dictation" : "Dictate on device")
                .help("On-device speech only — no cloud fallback")

                Spacer()

                Button {
                    vm.submitNote()
                } label: {
                    if vm.isParsing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Parse")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canParseNote)
                .help(vm.speechPhase == .active ? "Stop dictation before parsing" : "Parse note")
            }
        }
        .padding(14)
    }

    private var micSymbol: String {
        switch vm.speech.state {
        case .recording, .finishing: return "stop.circle.fill"
        case .requesting: return "mic.badge.ellipsis"
        case .idle: return "mic"
        }
    }

    // MARK: - Confirm

    private var confirmScreen: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Confirm before adding")
                .font(.subheadline.weight(.semibold))

            TextField("Title", text: $vm.draftTitle)
                .textFieldStyle(.roundedBorder)
            DatePicker("Starts", selection: $vm.draftStart)
            DatePicker("Ends", selection: $vm.draftEnd)
            TextField("Location", text: $vm.draftLocation)
                .textFieldStyle(.roundedBorder)

            if vm.draftEnd <= vm.draftStart {
                Text("End must be after start.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let note = vm.parseNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = vm.statusMessage {
                Text(status).font(.caption).foregroundStyle(.red)
            }
            if let googleBlock = vm.googleAddBlockMessage {
                Text(googleBlock)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Back") { vm.cancelConfirmation() }
                    .disabled(vm.isSaving)
                Spacer()
                Button {
                    vm.addConfirmedEvent()
                } label: {
                    if vm.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(vm.duplicateAddArmed ? "Add copy" : "Add")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canAddDraft)
                .help(vm.googleAddBlockMessage
                    ?? (vm.duplicateAddArmed
                        ? "Creates another identical event on purpose"
                        : "Add to the selected calendar"))
            }
        }
        .padding(14)
    }

    // MARK: - Schedule

    private var scheduleScreen: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { vm.shiftScheduleDay(-1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous day")

                Text(vm.scheduleDay, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)

                Button { vm.shiftScheduleDay(1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next day")
            }

            Text(vm.selectedCalendarTitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let status = vm.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if vm.scheduleItems.isEmpty {
                        Text("No events on this day in the selected calendar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    } else {
                        ForEach(vm.scheduleItems) { item in
                            scheduleRow(item)
                        }
                    }
                }
            }

            Button("New entry") { vm.startNewEntry() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
        .padding(14)
        .onAppear { vm.reloadScheduleIfPossible() }
    }

    private func scheduleRow(_ item: ScheduleItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Text(timeRange(item))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let location = item.location, !location.isEmpty {
                Text(location)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func timeRange(_ item: ScheduleItem) -> String {
        if item.isAllDay { return "All day" }
        let start = item.start.formatted(date: .omitted, time: .shortened)
        let end = item.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }
}
