import CryptoKit
import Foundation
import XCTest
@testable import TwinVault

@MainActor
final class DecisionInboxTests: XCTestCase {
    private func makeModel(items: [DecisionItem]? = nil, bridge: BridgeStatus = FakeBridgeStatusReader.sample())
        -> (DecisionInboxModel, FakeDecisionServer, FakeBridgeApprovalSink, FakeExternalActions) {
        let server = FakeDecisionServer(items: items)
        let status = FakeBridgeStatusReader(status: bridge)
        let sink = FakeBridgeApprovalSink(statusReader: status)
        let external = FakeExternalActions()
        let model = DecisionInboxModel(
            server: server, verifier: Ed25519ProposalVerifier(publicKey: server.publicKey),
            bridgeReader: status, bridgeSink: sink, threads: FakeThreadPreviewProvider(), external: external,
            timersEnabled: false)
        return (model, server, sink, external)
    }

    private func item(_ model: DecisionInboxModel, _ n: Int) -> DecisionItem {
        model.items.first { $0.itemId == UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", n))! }!
    }

    func testFakeInboxLoadsAllSignedItems() async {
        let (model, _, _, _) = makeModel()
        await model.load()
        XCTAssertEqual(model.items.count, 9)
        XCTAssertEqual(model.discardedCount, 0)
        XCTAssertNotNil(model.bridge)
    }

    func testTamperedUnsignedOrLooserItemsAreDiscarded() async {
        let (model, server, _, _) = makeModel()
        let base = FakeInboxData.items(now: Date())[0]
        // 1) Cambia el texto después de firmar: no coincide la huella.
        var tampered = FakeDecisionServer.signed(base, key: .init())
        tampered.itemId = UUID(); tampered.what.body = "Otro texto"
        // 2) Firmada con otra clave.
        var foreign = FakeDecisionServer.signed(base, key: .init())
        foreign.itemId = UUID()
        // 3) Un WhatsApp que el servidor deja aprobar desde la web, aunque esté bien firmado: se descarta.
        var looser = base
        looser.itemId = UUID(); looser.approveWhere = .macOrWeb
        await server.inject(tampered)
        await server.inject(foreign)
        await server.inject(await server.signedWithOwnKey(looser))
        await model.load()
        XCTAssertEqual(model.items.count, 9)
        XCTAssertEqual(model.discardedCount, 3)
        XCTAssertEqual(DecisionItemValidator.structuralProblems(looser, now: Date()).contains(.whatsappSendMustBeApprovedOnMac), true)
    }

    func testGroupsByUrgencyTodayFirst() async {
        let (model, _, _, _) = makeModel()
        await model.load()
        let groups = model.grouped().map(\.0)
        XCTAssertEqual(groups, [.today, .thisWeek, .later])
        XCTAssertEqual(model.grouped().first?.1.count, 2)
    }

    func testNothingLeavesTheAppDuringUndoWindow() async {
        let (model, server, sink, _) = makeModel()
        await model.load()
        model.approve(item(model, 1))
        model.approve(item(model, 2))
        XCTAssertEqual(model.held.count, 2)
        let requests = await server.requests
        let submitted = await sink.submitted
        XCTAssertTrue(requests.isEmpty, "Durante el margen no se manda nada a Core")
        XCTAssertTrue(submitted.isEmpty, "Durante el margen no se manda nada al puente")
        XCTAssertEqual(model.decidedCount, 2)
    }

    func testUndoReturnsTheCardAndSendsNothing() async {
        let (model, server, sink, _) = makeModel()
        await model.load()
        let wa = item(model, 1)
        model.approve(wa)
        model.undoLast()
        await model.commitAll()
        XCTAssertTrue(model.pending.contains { $0.itemId == wa.itemId })
        let requests = await server.requests
        let submitted = await sink.submitted
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(submitted.isEmpty)
    }

    func testWhatsAppGoesToBridgeAndNoTextReachesCore() async {
        let (model, server, sink, _) = makeModel()
        await model.load()
        let wa = item(model, 1)
        model.setText(wa.what.body + " Gracias.", for: wa)
        model.approve(wa)
        await model.commitAll()
        let submitted = await sink.submitted
        let requests = await server.requests
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(submitted.first?.body, wa.what.body + " Gracias.")
        XCTAssertEqual(requests.first?.action, .editApprove)
        XCTAssertNil(requests.first?.editedBody, "El texto de WhatsApp no va a Core")
        XCTAssertEqual(requests.first?.editedSha256, wa.payloadSha256(withBody: wa.what.body + " Gracias."))
        XCTAssertEqual(requests.first?.decidedWhere, "mac")
    }

    func testEditedEmailCarriesItsText() async {
        let (model, server, sink, _) = makeModel()
        await model.load()
        let mail = item(model, 2)
        model.setText("Hola Sergio, ¿el martes a las 10?", for: mail)
        model.approve(mail)
        await model.commitAll()
        let requests = await server.requests
        let submitted = await sink.submitted
        XCTAssertEqual(requests.first?.editedBody, "Hola Sergio, ¿el martes a las 10?")
        XCTAssertTrue(submitted.isEmpty, "El correo no pasa por el puente")
    }

    func testLiveCheckBlocksLinksInPhaseOne() async {
        let (model, server, _, _) = makeModel()
        await model.load()
        let wa = item(model, 1)
        model.setText("Mira www.ejemplo.com", for: wa)
        XCTAssertNotNil(model.problem(for: wa))
        model.approve(wa)
        XCTAssertTrue(model.held.isEmpty)
        await model.commitAll()
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testDailyCapBlocksWhatsApp() async {
        var full = FakeBridgeStatusReader.sample()
        full.sentToday = full.dailyCap
        let (model, _, _, _) = makeModel(bridge: full)
        await model.load()
        XCTAssertEqual(model.problem(for: item(model, 1)), "Has llegado al tope de hoy: no puede salir.")
    }

    func testBatchRefusesSendsAndAcceptsSimilarLinks() async {
        let (model, server, _, _) = makeModel()
        await model.load()
        let links = (6...9).map { item(model, $0).itemId }
        XCTAssertFalse(model.approveBatch(links + [item(model, 1).itemId]), "Un envío nunca va en lote")
        XCTAssertFalse(model.approveBatch([item(model, 3).itemId, item(model, 5).itemId]), "Sin la misma regla no hay lote")
        XCTAssertTrue(model.approveBatch(links))
        await model.commitAll()
        let requests = await server.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(Set(requests.compactMap(\.batchRef)).count, 1)
    }

    func testLaterReasonsMapToRejectOrSnooze() async {
        let (model, server, _, _) = makeModel()
        await model.load()
        model.later(item(model, 3), reason: .masAdelante)
        model.later(item(model, 5), reason: .yaHecho)
        model.later(item(model, 2), reason: .otro, note: "  ")
        XCTAssertEqual(model.held.count, 2, "«Otro» sin nota no se acepta")
        await model.commitAll()
        let requests = await server.requests
        XCTAssertEqual(requests.map(\.action), [.snooze, .reject])
        XCTAssertNotNil(requests.first?.snoozedUntil)
        XCTAssertEqual(requests.last?.reason, .yaHecho)
    }

    func testLinkedInIsCopiedAndOnlyRecordedAfterConfirmation() async {
        let (model, server, sink, external) = makeModel()
        await model.load()
        let li = item(model, 4)
        model.approve(li)
        XCTAssertEqual(external.copied, [li.what.body])
        XCTAssertTrue(model.awaitingManualSend.contains(li.itemId))
        await model.commitAll()
        var requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
        model.confirmManualSend(li, sent: true)
        await model.commitAll()
        requests = await server.requests
        let submitted = await sink.submitted
        XCTAssertEqual(requests.map(\.action), [.approve])
        XCTAssertTrue(submitted.isEmpty)
    }

    func testServerRefusesSecondDecision() async throws {
        let server = FakeDecisionServer()
        let first = try await server.fetchInbox()[1]
        let request = DecisionRequest(itemId: first.itemId, action: .approve, payloadSha256Seen: first.payloadSha256,
                                      decidedAt: Date(), decidedWhere: "mac")
        _ = try await server.decide(request)
        do {
            _ = try await server.decide(request)
            XCTFail("Debía rechazar la segunda decisión")
        } catch let error as DecisionServerError {
            XCTAssertEqual(error, .alreadyDecided)
        }
    }

    func testQuitDuringUndoWindowDiscardsTheDecision() async {
        let (model, server, _, _) = makeModel()
        await model.load()
        model.approve(item(model, 2))
        model.discardHeldOnQuit()
        await model.commitAll()
        let requests = await server.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(model.pending.count, 9)
    }

    func testBusinessDaysSkipWeekend() {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 27; c.hour = 10 // viernes
        let friday = Calendar.current.date(from: c)!
        let result = DecisionInboxModel.addingBusinessDays(3, to: friday)
        XCTAssertEqual(Calendar.current.component(.day, from: result), 2) // miércoles 2 dic
    }

    // MARK: Ejemplos del contrato (Documentation/Contracts/Examples)

    private func example(_ name: String) throws -> DecisionItem {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Documentation/Contracts/Examples/\(name)")
        return try DecisionJSON.decoder().decode(DecisionItem.self, from: Data(contentsOf: url))
    }

    func testValidContractExamplesPassStructuralChecks() throws {
        let reference = ISO8601DateFormatter().date(from: "2026-11-24T09:00:00Z")!
        for name in ["decision-item-v1.send-whatsapp.valid.json", "decision-item-v1.attach-meeting.valid.json",
                     "decision-item-v1.link-meeting.valid.json"] {
            let item = try example(name)
            XCTAssertEqual(DecisionItemValidator.structuralProblems(item, now: reference), [], name)
        }
    }

    func testInvalidContractExampleIsRejected() throws {
        let reference = ISO8601DateFormatter().date(from: "2026-11-24T09:00:00Z")!
        let item = try example("decision-item-v1.send-whatsapp-web.invalid.json")
        let problems = DecisionItemValidator.structuralProblems(item, now: reference)
        XCTAssertTrue(problems.contains(.whatsappSendMustBeApprovedOnMac))
        XCTAssertTrue(problems.contains(.batchNotAllowedForSend))
    }

    func testEncodingRoundTripKeepsSnakeCaseKeys() throws {
        let item = FakeInboxData.items(now: Date())[0]
        let data = try DecisionJSON.encoder().encode(item)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"summary_line\""))
        XCTAssertTrue(text.contains("\"payload_sha256\""))
        let decoded = try DecisionJSON.decoder().decode(DecisionItem.self, from: data)
        XCTAssertEqual(decoded.itemId, item.itemId)
    }
}

extension FakeDecisionServer {
    /// Para pruebas: firma con la clave del propio servidor falso (simula un servidor que firma algo indebido).
    func signedWithOwnKey(_ item: DecisionItem) -> DecisionItem { Self.signed(item, key: signingKeyForTests) }
}
