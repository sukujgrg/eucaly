import AppKit
import XCTest
@testable import eucaly

@MainActor
final class AltViewSettingsTests: XCTestCase {
    private func makeService() -> (AltViewService, RecordingAltViewSender) {
        let name = "AltViewSettingsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let sender = RecordingAltViewSender()
        let service = AltViewService(defaults: defaults, pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender })
        return (service, sender)
    }

    func testReturnInPairingFieldConnectsOnlyOnce() throws {
        let (service, sender) = makeService()
        let controller = AltViewSettingsController(service: service)
        controller.discoveryEnabled = false
        controller.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 560, height: 440))
        defer { window.close() }
        controller.hostField.stringValue = "receiver.local"
        XCTAssertTrue(window.makeFirstResponder(controller.codeField))
        let editor = try XCTUnwrap(controller.codeField.currentEditor() as? NSTextView)
        editor.insertText("ABCD2345", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(controller.codeField.stringValue, "ABCD2345")

        let returnKey = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        XCTAssertTrue(window.performKeyEquivalent(with: returnKey))
        let connectionID = try XCTUnwrap(sender.connectionID)
        XCTAssertTrue(service.isConnecting)
        XCTAssertFalse(controller.connectButton.isEnabled)
        XCTAssertEqual(service.destination?.host, "receiver.local")
        XCTAssertTrue(sender.submissions.isEmpty)
        XCTAssertEqual(sender.takes, 0)

        _ = window.performKeyEquivalent(with: returnKey)
        XCTAssertEqual(sender.connectionID, connectionID, "Return must not restart an in-progress connection")
    }

    func testNativeSettingsKeepsSavedManualAddressAndConnectionWhenClosed() async {
        let (service, sender) = makeService()
        service.connect(to: .manual(host: "receiver.local", port: "49722")!, code: "ABCD2345")
        let controller = AltViewSettingsController(service: service)
        controller.discoveryEnabled = false
        controller.loadViewIfNeeded()
        controller.viewWillAppear()
        XCTAssertEqual(controller.receiverPicker.selectedItem?.title, "Manual address")
        XCTAssertEqual(controller.hostField.stringValue, "receiver.local")
        XCTAssertEqual(controller.portField.stringValue, "49722")
        XCTAssertTrue(controller.hostField.isEnabled)
        XCTAssertEqual(controller.disconnectButton.title, "Cancel")
        controller.viewWillDisappear()
        XCTAssertTrue(service.hasConnection, "Closing Settings must not cancel connect-only setup")
        service.receive(sender.connectedStatus)
        await settle()
        XCTAssertEqual(controller.disconnectButton.title, "Disconnect")
        XCTAssertFalse(controller.connectButton.isEnabled)
        XCTAssertTrue(sender.submissions.isEmpty)
        XCTAssertEqual(sender.takes, 0)
        controller.hostField.stringValue = "other.local"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.hostField))
        XCTAssertFalse(service.hasConnection, "Destination edits cancel the previous connection")
    }

    func testTemplateMenuUsesIDsRetainsMissingChoiceAndDoesNotPublish() async throws {
        let (service, sender) = makeService()
        service.connect(to: .init(name: "Saved receiver", host: nil, port: nil, serviceType: AltViewProtocol.serviceType, domain: "local."), code: "ABCD2345")
        let controller = AltViewSettingsController(service: service)
        controller.discoveryEnabled = false
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.receiverPicker.selectedItem?.title, "Saved receiver")
        XCTAssertFalse(controller.hostField.isEnabled)
        XCTAssertFalse(controller.templatePicker.isEnabled)
        var status = sender.connectedStatus
        let future = AltViewContentTemplate(rawValue: "future.v3")
        status.templateCapabilities = .init(templates: [.init(id: .lyrics, name: "Same name"), .init(id: future, name: "Same name")], policy: .sender)
        service.receive(status)
        await settle()
        XCTAssertEqual(controller.templatePicker.itemTitles, ["Receiver’s layout", "Same name", "Same name"])
        XCTAssertEqual(controller.templatePicker.selectedItem?.representedObject as? String, "lyrics")
        controller.templatePicker.selectItem(at: 2)
        controller.templatePicker.sendAction(try XCTUnwrap(controller.templatePicker.action), to: controller)
        XCTAssertEqual(service.selectedTemplate, future)
        let item = try XCTUnwrap(controller.templatePicker.item(at: 2))
        status.templateCapabilities.policy = .custom
        service.receive(status)
        await settle()
        XCTAssertTrue(controller.templatePicker.item(at: 2) === item, "Policy/acknowledgement refresh must not rebuild the open menu")
        XCTAssertTrue(controller.statusLabel.stringValue.contains("overrides"))
        status.templateCapabilities = .init(templates: [], policy: .sender)
        service.receive(status)
        await settle()
        XCTAssertEqual(controller.templatePicker.selectedItem?.title, "future.v3 · Unavailable")
        XCTAssertEqual(controller.templatePicker.selectedItem?.isEnabled, false)
        XCTAssertTrue(controller.templateHint.stringValue.contains("unavailable"))
        XCTAssertTrue(sender.submissions.isEmpty)
        XCTAssertEqual(sender.takes, 0)
        service.disconnect()
        await settle()
        XCTAssertFalse(controller.templatePicker.isEnabled)
        XCTAssertEqual(service.selectedTemplate, future)
    }

    func testConnectedSettingsLayoutFitsAndKeepsAddressEditable() async throws {
        let (service, sender) = makeService()
        service.connect(to: .manual(host: "receiver.local", port: "49721")!, code: "ABCD2345")
        var status = sender.connectedStatus
        status.templateCapabilities = .init(templates: [.init(id: .lyrics, name: "Lyrics"), .init(id: .scripture, name: "Scripture")], policy: .custom)
        status.message = "Connected — ready to take output"
        service.receive(status)
        let controller = AltViewSettingsController(service: service)
        controller.discoveryEnabled = false
        controller.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        // Installing a controller adopts its fitting size. Test the actual
        // Settings content size supplied by SwiftUI after installation.
        window.setContentSize(NSSize(width: 560, height: 440))
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        await settle()
        controller.view.layoutSubtreeIfNeeded()
        for control in [controller.receiverPicker, controller.hostField, controller.portField,
                        controller.codeField, controller.connectButton, controller.disconnectButton,
                        controller.templatePicker, controller.templateHint, controller.statusLabel] {
            let frame = controller.view.convert(control.bounds, from: control)
            XCTAssertGreaterThan(frame.height, 10)
            XCTAssertTrue(controller.view.bounds.contains(frame), "Control must fit inside Settings: \(control)")
        }
        XCTAssertGreaterThan(controller.hostField.frame.width, 200)
        XCTAssertEqual(controller.portField.frame.width, 70, accuracy: 1)
        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let image = NSImage(size: controller.view.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "AltView Settings — connected with receiver override"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(25)) }
}
