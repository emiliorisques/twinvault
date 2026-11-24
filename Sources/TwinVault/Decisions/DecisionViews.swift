import SwiftUI

// Pestaña Decisiones (F1, MOCK). Textos en castellano para Emilio; el resto de TwinVault sigue igual.

struct DecisionsRootView: View {
    @Environment(DecisionInboxModel.self) private var model
    @State private var focusMode = false
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            MockBanner()
            if focusMode {
                DecisionFocusView(exit: { focusMode = false })
            } else {
                DecisionListView(enterFocus: { focusMode = true })
            }
        }
        .overlay(alignment: .bottom) { UndoBar().padding(.bottom, 16) }
        .toolbar {
            ToolbarItem {
                Button("Ajustes de envío", systemImage: "slider.horizontal.3") { showingSettings = true }
            }
        }
        .sheet(isPresented: $showingSettings) { DecisionSettingsView() }
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.discardHeldOnQuit()
        }
    }
}

private struct MockBanner: View {
    var body: some View {
        Text("MAQUETA · DATOS INVENTADOS · nada se conecta ni se envía")
            .font(.caption.monospaced())
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.15))
            .foregroundStyle(.orange)
            .accessibilityLabel("Maqueta con datos inventados. Nada se conecta ni se envía.")
    }
}

// MARK: Lista por urgencia

struct DecisionListView: View {
    @Environment(DecisionInboxModel.self) private var model
    let enterFocus: () -> Void
    @State private var batchOpen = false
    @State private var batchSelection: Set<UUID> = []
    @AccessibilityFocusState private var focusedCard: UUID?

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Picker("Canal", selection: $model.filter) {
                    ForEach(DecisionInboxModel.ChannelFilter.allCases) { f in
                        Text("\(f.title) · \(model.count(for: f))").tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if let bridge = model.bridge { BridgeStatusStrip(status: bridge) }
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.awaitingManualItems) { item in DecisionCardView(item: item, inFocus: false) }
                if model.pending.isEmpty {
                    AllDoneView(total: model.total)
                } else if model.grouped().isEmpty {
                    ContentUnavailableView("Nada en este canal", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("Quedan \(model.pending.count) en otros canales."))
                } else {
                    ForEach(model.grouped(), id: \.0) { urgency, list in
                        groupSection(urgency, list)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(model.decidedCount) de \(model.total) decididas hoy").font(.title3.weight(.semibold))
                ProgressView(value: Double(model.decidedCount), total: Double(max(model.total, 1)))
                    .accessibilityLabel("Decisiones de hoy")
                    .accessibilityValue("\(model.decidedCount) de \(model.total)")
            }
            Spacer()
            Button("Una a una (modo foco)", systemImage: "rectangle.center.inset.filled", action: enterFocus)
                .buttonStyle(.borderedProminent)
                .disabled(model.pending.isEmpty)
        }
    }

    @ViewBuilder
    private func groupSection(_ urgency: DecisionInboxModel.Urgency, _ list: [DecisionItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(urgency.title.uppercased())  \(list.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(urgency == .today ? .orange : .secondary)
                .accessibilityAddTraits(.isHeader)
            let batches = model.batchGroups(in: list)
            ForEach(batches, id: \.key) { group in batchBox(group.items) }
            let batched = batchOpen ? Set(batches.flatMap { $0.items.map(\.itemId) }) : []
            ForEach(list.filter { !batched.contains($0.itemId) }) { item in
                DecisionCardView(item: item, inFocus: false)
                    .accessibilityFocused($focusedCard, equals: item.itemId)
            }
        }
    }

    private func batchBox(_ group: [DecisionItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(group.count) parecidas").bold()
                Text("· misma regla (\(group.first?.origin.ref ?? ""))").foregroundStyle(.secondary)
                Spacer()
                Button(batchOpen ? "Ocultar" : "Revisar y aprobar juntas") {
                    batchOpen.toggle()
                    if batchOpen { batchSelection = Set(group.map(\.itemId)) }
                }
            }
            if batchOpen {
                ForEach(group) { item in
                    Toggle(isOn: Binding(
                        get: { batchSelection.contains(item.itemId) },
                        set: { on in if on { batchSelection.insert(item.itemId) } else { batchSelection.remove(item.itemId) } }
                    )) {
                        Text("\(item.what.linkFrom ?? item.what.title) → \(item.what.linkTo ?? item.what.body)")
                    }
                    .toggleStyle(.checkbox)
                }
                HStack {
                    let n = group.filter { batchSelection.contains($0.itemId) }.count
                    Button(n == group.count ? "Aprobar las \(n)" : "Aprobar las \(n) marcadas") {
                        if model.approveBatch(Array(batchSelection)) { batchOpen = false }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(n < 2)
                    Text("Solo para enlazar y subir a la ficha. Los envíos van siempre de uno en uno.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4])))
    }
}

private struct AllDoneView: View {
    let total: Int
    var body: some View {
        ContentUnavailableView("Todo al día", systemImage: "checkmark.circle",
                               description: Text("Has decidido las \(total) de hoy. Lo nuevo aparecerá aquí."))
    }
}

extension DecisionInboxModel {
    var awaitingManualItems: [DecisionItem] { items.filter { awaitingManualSend.contains($0.itemId) } }
}

// MARK: Tarjeta

struct DecisionCardView: View {
    @Environment(DecisionInboxModel.self) private var model
    let item: DecisionItem
    let inFocus: Bool
    var editorFocus: FocusState<Bool>.Binding?
    @State private var showingLater = false
    @State private var otherNote = ""
    @State private var drawer: Drawer?
    @State private var thread: ThreadPreview?

    enum Drawer { case details, thread }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ChannelBadge(channel: item.channel)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.summaryLine).font(inFocus ? .title3.weight(.medium) : .headline)
                        .accessibilityAddTraits(.isHeader)
                    (Text("Recomendación: ").bold().foregroundStyle(.green) + Text(item.recommendation))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(model.exitsLabel(item)).font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        if !model.awaitingManualSend.contains(item.itemId) {
                            Text(model.expiryLabel(item)).font(.caption).foregroundStyle(.orange)
                        }
                        if item.approveWhere == .mac { Text("Solo se aprueba en este Mac").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            content.padding(.leading, 44)
            HStack(spacing: 16) {
                disclosure("Ver detalles", .details)
                if item.threadPreview != .none {
                    disclosure(item.threadPreview == .approvedSummary ? "Ver resumen del hilo" : "Ver último hilo", .thread)
                }
            }
            .padding(.leading, 44)
            if let drawer { drawerView(drawer).padding(.leading, 44) }
            footer.padding(.leading, 44)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        if item.type == .link {
            HStack {
                Text(item.what.linkFrom ?? "").padding(4).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                Image(systemName: "arrow.right").accessibilityLabel("con")
                Text(item.what.linkTo ?? "").padding(4).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
            .font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let subject = item.what.emailSubject { Text("Asunto: \(subject)").font(.caption).foregroundStyle(.secondary) }
                editor
                hint
                if let quote = item.what.quote { Text(quote).italic().foregroundStyle(.secondary).font(.callout) }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        let binding = Binding(get: { model.text(for: item) }, set: { model.setText($0, for: item) })
        let base = TextEditor(text: binding)
            .font(.body)
            .frame(minHeight: 60, maxHeight: 160)
            .padding(6)
            .scrollContentBackground(.hidden)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(item.type == .send ? "Texto que se enviará. Puedes cambiarlo." : "Texto que se guardará. Puedes cambiarlo.")
            .disabled(model.awaitingManualSend.contains(item.itemId))
        if let editorFocus { base.focused(editorFocus) } else { base }
    }

    @ViewBuilder
    private var hint: some View {
        if let problem = model.problem(for: item) {
            Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        } else if model.isEdited(item) {
            HStack {
                Text(item.type == .send ? "Has cambiado el texto: se enviará tu versión." : "Has cambiado el texto: se guardará tu versión.")
                Button("Volver al texto propuesto") { model.restoreText(for: item) }.buttonStyle(.link)
            }
            .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Puedes cambiar el texto aquí mismo.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func disclosure(_ title: String, _ kind: Drawer) -> some View {
        Button {
            drawer = drawer == kind ? nil : kind
            if kind == .thread, thread == nil { Task { thread = await model.threads.preview(for: item) } }
        } label: {
            Label(title, systemImage: drawer == kind ? "chevron.down" : "chevron.right").font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(drawer == kind ? .primary : .secondary)
        .accessibilityValue(drawer == kind ? "abierto" : "cerrado")
    }

    @ViewBuilder
    private func drawerView(_ kind: Drawer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch kind {
            case .details:
                LabeledContent("Origen", value: "\(item.origin.kind == .rule ? "Regla" : "Agente") · \(item.origin.ref) · creada en \(item.origin.createdBySource == .local ? "tu Mac" : "Company OS")")
                LabeledContent("Por qué", value: item.why)
                LabeledContent("Comprobado") {
                    VStack(alignment: .leading) {
                        ForEach(item.checks, id: \.name) { c in
                            Label(c.name, systemImage: c.ok ? "checkmark" : "xmark").foregroundStyle(c.ok ? .green : .red)
                        }
                    }
                }
            case .thread:
                if let thread {
                    ForEach(thread.messages) { m in
                        VStack(alignment: m.fromMe ? .trailing : .leading, spacing: 1) {
                            Text(m.text)
                            Text("\(m.fromMe ? "Tú" : "La otra persona") · \(m.when)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(m.fromMe ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity, alignment: m.fromMe ? .trailing : .leading)
                    }
                    if let summary = thread.summary { Text(summary) }
                    if let open = thread.openLabel { Button(open) { model.setNotice("En la app real se abre fuera (MOCK).") } }
                    Text(thread.privacyNote).font(.caption2).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var footer: some View {
        if model.awaitingManualSend.contains(item.itemId) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Texto copiado. Pégalo en LinkedIn, envíalo y confirma.").font(.callout)
                HStack {
                    Button("Lo he enviado") { model.confirmManualSend(item, sent: true) }.buttonStyle(.borderedProminent)
                    Button("No lo envié") { model.confirmManualSend(item, sent: false) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(model.primaryLabel(for: item)) { model.approve(item) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.problem(for: item) != nil)
                    Button("Ahora no") { showingLater.toggle(); model.laterRequestedFor = nil }
                        .controlSize(.large)
                        .accessibilityValue(showingLater ? "motivos abiertos" : "")
                }
                if showingLater || model.laterRequestedFor == item.itemId { laterChips }
            }
        }
    }

    private var laterChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("¿Por qué? Un clic y queda decidido.").font(.caption).foregroundStyle(.secondary)
            FlowRow(spacing: 6) {
                ForEach(LaterReason.allCases) { reason in
                    Button(reason.label) {
                        if reason == .otro { showOther = true }
                        else { model.later(item, reason: reason); showingLater = false }
                    }
                    .buttonStyle(.bordered)
                }
            }
            if showOther {
                HStack {
                    TextField("Escribe el motivo y pulsa Intro", text: $otherNote)
                        .onSubmit { saveOther() }
                    Button("Guardar", action: saveOther)
                }
            }
        }
    }

    @State private var showOther = false
    private func saveOther() {
        model.later(item, reason: .otro, note: otherNote)
        if !otherNote.trimmingCharacters(in: .whitespaces).isEmpty { showingLater = false; showOther = false }
    }
}


struct ChannelBadge: View {
    let channel: DecisionChannel
    var body: some View {
        let (label, color): (String, Color) = switch channel {
        case .whatsapp: ("WA", Color(red: 0.12, green: 0.43, blue: 0.28))
        case .linkedin: ("in", Color(red: 0.17, green: 0.37, blue: 0.59))
        case .email: ("@", Color(red: 0.42, green: 0.32, blue: 0.64))
        case .meeting: ("◉", Color(red: 0.54, green: 0.32, blue: 0.13))
        case .core: ("OS", Color.gray)
        }
        Text(label).font(.caption.monospaced().bold()).foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(color, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(DecisionInboxModel.ChannelFilter(rawValue: channel.rawValue)?.title ?? "Company OS")
    }
}

/// Fila que salta de línea (para los motivos de «Ahora no»).
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: Modo foco

struct DecisionFocusView: View {
    @Environment(DecisionInboxModel.self) private var model
    let exit: () -> Void
    @FocusState private var containerFocused: Bool
    @FocusState private var editorFocused: Bool

    var body: some View {
        let current = model.focusQueue.first
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(model.decidedCount) de \(model.total) decididas hoy").font(.title3.weight(.semibold))
                    ProgressView(value: Double(model.decidedCount), total: Double(max(model.total, 1)))
                        .accessibilityLabel("Decisiones de hoy")
                }
                Spacer()
                Button("Salir del modo foco", action: exit).keyboardShortcut(.cancelAction)
            }
            Text("A aprobar · E editar · N ahora no · S saltar · Z deshacer · Esc salir")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Atajos: A aprobar, E editar el texto, N ahora no, S saltar, Z deshacer, Escape salir.")
            if let current {
                Text("\(model.urgency(of: current).title) · \(DecisionInboxModel.ChannelFilter(rawValue: current.channel.rawValue)?.title ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                DecisionCardView(item: current, inFocus: true, editorFocus: $editorFocused)
                    .id(current.itemId)
            } else {
                AllDoneView(total: model.total)
                Button("Volver a la bandeja", action: exit).buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($containerFocused)
        .onAppear { containerFocused = true }
        .onChange(of: current?.itemId) { containerFocused = true }
        .onKeyPress(characters: .letters, phases: .down) { press in
            // Solo cuando el foco está en el contenedor: al escribir en el texto, las letras son texto.
            guard !editorFocused else { return .ignored }
            guard let current else { return .ignored }
            switch press.characters.lowercased() {
            case "a":
                if model.problem(for: current) == nil { model.approve(current) }
                return .handled
            case "e":
                editorFocused = true; return .handled
            case "n":
                model.laterRequestedFor = current.itemId; return .handled
            case "s":
                model.skip(current.itemId); return .handled
            case "z":
                model.undoLast(); return .handled
            default:
                return .ignored
            }
        }
    }
}

// MARK: Deshacer

struct UndoBar: View {
    @Environment(DecisionInboxModel.self) private var model

    var body: some View {
        if let last = model.lastHeld {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let secs = max(0, Int(last.deadline.timeIntervalSince(context.date).rounded(.up)))
                HStack(spacing: 12) {
                    Text(last.message)
                    Text("· \(secs) s").monospacedDigit().foregroundStyle(.secondary).accessibilityHidden(true)
                    if model.held.count > 1 { Text("· solo puedes deshacer la última").foregroundStyle(.secondary) }
                    Button("Deshacer") { model.undoLast() }
                        .keyboardShortcut("z", modifiers: [.command])
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 6)
            }
            .accessibilityElement(children: .contain)
            .onAppear {
                AccessibilityNotification.Announcement("\(last.message). Tienes \(model.undoSeconds) segundos para deshacer.").post()
            }
            .id(last.id)
        }
    }
}

// MARK: Puente y ajustes

struct BridgeStatusStrip: View {
    let status: BridgeStatus
    var body: some View {
        HStack(spacing: 14) {
            Label(status.sessionWorking ? "WhatsApp conectado" : "WhatsApp sin conexión",
                  systemImage: status.sessionWorking ? "checkmark.circle" : "exclamationmark.triangle")
            Text(status.phase.plainName)
            Text("Quedan \(status.leftToday) de \(status.dailyCap) hoy")
            Text("\(status.markedChats) chats profesionales")
            if status.brakeOn { Text("Envíos parados por precaución").foregroundStyle(.red) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

struct DecisionSettingsView: View {
    @Environment(DecisionInboxModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Al decidir") {
                Picker("Margen para deshacer", selection: $model.undoSeconds) {
                    Text("5 segundos").tag(5); Text("10 segundos").tag(10); Text("20 segundos").tag(20)
                }
                Text("Durante el margen no sale nada. Al acabar, sale tal como lo decidiste.").font(.caption).foregroundStyle(.secondary)
            }
            Section("WhatsApp (lo controla el puente; aquí solo se lee)") {
                if let b = model.bridge {
                    LabeledContent("Fase", value: b.phase.plainName)
                    LabeledContent("Envíos al día / a la semana", value: "\(b.dailyCap) / \(b.weeklyCap)")
                    LabeledContent("Hoy", value: "\(b.sentToday) enviados · quedan \(b.leftToday)")
                    LabeledContent("Al mismo chat", value: "1 al día")
                    LabeledContent("Franjas", value: "L–V 9:30–13:30 y 15:30–19:00 (Madrid)")
                    LabeledContent("Sin envíos", value: "8 dic, 24 dic – 6 ene")
                    LabeledContent("Enlaces", value: b.phase.allowedLinks == 0 ? "ninguno" : "como mucho \(b.phase.allowedLinks)")
                    LabeledContent("Siguiente franja", value: b.nextWindow)
                } else {
                    Text("Sin datos del puente.")
                }
                Text("Subir de fase se hace en el puente, contigo delante, de una en una. Bajar también se hace allí en F1.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Desde dónde sale cada cosa") {
                LabeledContent("WhatsApp", value: "Desde tu WhatsApp, a través de este Mac. Solo se aprueba aquí.")
                LabeledContent("Correo", value: "Desde tu buzón, enviado por Company OS.")
                LabeledContent("LinkedIn", value: "Lo envías tú: la app copia el texto y abre el perfil.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 520)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Hecho") { dismiss() } } }
    }
}
