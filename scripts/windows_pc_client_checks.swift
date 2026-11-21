import Foundation
import ControllerCore

@MainActor final class PCCheckTransport: BridgeTransporting {
    var onReady:(()->Void)?; var onMessage:((Data)->Void)?; var onFailure:((String)->Void)?
    var sent:[WindowsPCPacket]=[], closed:[WindowsPCPacket]=[]
    var token=UUID().uuidString
    func open(host:String,port:UInt16) { onReady?() }
    func send(_ data:Data) { sent.append(try! WindowsPCCodec.decode(data)) }
    func close(afterSending data:Data?) { if let data { closed.append(try! WindowsPCCodec.decode(data)) } }
    func reply(_ packet:WindowsPCPacket) { onMessage?(try! WindowsPCCodec.encode(packet)) }
    func arm() { let hello=sent.last!; token=UUID().uuidString; reply(.init(kind:.ready,session:hello.session,token:token)); ack() }
    func ack() { let state=sent.last!; reply(.init(kind:.ack,session:state.session,sequence:state.sequence,token:token)) }
}
@MainActor final class PCCheckClock { var now=100.0 }
@main struct WindowsPCClientChecks {
    @MainActor static func main() throws {
        var checks=0
        func check(_ value:@autoclosure()->Bool,_ label:String) { guard value() else { fatalError(label) }; checks += 1 }
        let suite="PCChecks.\(UUID())"
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(BridgeTriggerMode.usbButtons.rawValue,forKey:"bridge.triggerMode")
        let link=PCCheckTransport(), clock=PCCheckClock()
        let model=ControllerViewModel(defaults:defaults,transport:link,clock:{clock.now},automaticTimer:false)
        model.setBridgeProtocol(.windowsPC); model.host="127.0.0.1"
        model.updateInput(.init(buttons:[.guide,.share]),epoch:model.inputEpoch)
        check(model.state.buttons == [.guide,.share] && model.controlsEnabled,"Practice keeps Guide and Share even when PC is the saved route")
        model.setMode(.bridge);model.connect()
        check(model.portText=="42734" && !model.controlsEnabled,"PC selects its port and waits for neutral handshake")
        link.arm();check(model.isReady && model.allowsDesktopControls && model.allowsTriggerControls,"PC enables desktop and pressure after neutral ACK")
        let held=BridgeOutputState(gamepad:.init(buttons:[.a,.guide,.share],leftStick:.init(x:0.4),rightStick:.init(y:0.8)),leftTrigger:0.35,rightTrigger:0.75)
        let desktop=PracticeOutputState(heldKeys:[.w,.leftControl],heldMouseButtons:[.right],pointerOffset:.init(dx:4.5,dy:-2),scrollOffset:40)
        model.updateOutput(held,desktop:desktop,epoch:model.inputEpoch)
        check(link.sent.last?.output?.gamepad.buttons == [.a],"Unsupported Guide and Share do not reach PC")
        check(link.sent.last?.output?.leftTrigger==0.35 && link.sent.last?.output?.rightTrigger==0.75,"PC preserves partial trigger pressure")
        check(link.sent.last?.output?.keys==["LCTRL","W"] && link.sent.last?.output?.mouse==["RIGHT"],"PC keyboard and mouse retain ownership")
        check(link.sent.last?.output?.pointer==[4.5,-2] && link.sent.last?.output?.scroll==40,"PC cumulative movement reaches wire")
        let oldEpoch=model.inputEpoch, oldSession=link.sent.last!.session
        model.cancelQueuedInput(reason:"Profile changed")
        check(model.connectionRequested && !model.isReady && link.closed.last?.kind == .stop,"Profile changes stop old queued input but preserve intent")
        check(link.sent.last?.session != oldSession,"Profile changes establish a new PC session")
        link.arm();model.updateOutput(held,desktop:desktop,epoch:oldEpoch)
        check(link.sent.last?.output == .neutral,"Stale touches cannot restore old input after page changes")
        model.updateOutput(held,desktop:desktop,epoch:model.inputEpoch);link.ack()
        clock.now += 0.5;model.tick()
        check(!model.isReady && model.outputState.isNeutral && link.closed.last?.kind == .stop,"Missed ACK clears all PC output and closes")
        clock.now += 1;model.tick();link.arm()
        check(link.sent.last?.output == .neutral && model.isReady,"Retry begins neutral, never replays a prior hold")
        model.setForeground(false);check(!model.controlsEnabled && link.closed.last?.kind == .stop,"Background sends PC Stop")
        model.setForeground(true);link.arm();model.stop()
        let count=link.sent.count;clock.now += 10;model.tick()
        check(!model.connectionRequested && link.sent.count==count,"Explicit Disconnect does not reconnect while app remains open")

        let key=ProfileControl(name:"Key and trigger",payload:"W,LT:0.5"),move=ProfileControl(kind:.leftStick),camera=ProfileControl(payload:"CAMERA_FOLLOW")
        let controls=[key,move,camera], positions=controls.map { ProfilePlacement(id:$0.id,position:.init(x:0.5,y:0.5)) }
        let profile=try ControllerProfile(name:"PC checks",controls:controls,portrait:positions,landscape:positions)
        let bytes=try ControllerProfileLibraryCodec.encode(.init(activeProfileID:profile.id,profiles:[profile]))
        defaults.set(bytes,forKey:ProfileControllerViewModel.libraryKey)
        let profileLink=PCCheckTransport()
        let profileModel=ProfileControllerViewModel(defaults:defaults,transport:profileLink,clock:{clock.now},automaticTimer:false)
        check(profileModel.bridgeTriggerMode == .usbButtons,"Restoring PC preserves the separate Pico USB-trigger preference")
        profileModel.setForeground(true);profileModel.setMode(.bridge);profileModel.connect();profileLink.arm()
        func input(_ event:ProfileInputEvent) { _=profileModel.handleInput(event,epoch:profileModel.inputEpoch);profileLink.ack() }
        input(.begin(contact:1,control:key.id,position:.zero))
        check(profileLink.sent.last?.output?.keys==["W"] && profileLink.sent.last?.output?.leftTrigger==0.5,"Actual profile engine sends desktop+analog output")
        input(.end(contact:1))
        check(profileLink.sent.last?.output?.keys==[] && profileLink.sent.last?.output?.leftTrigger==0,"Actual engine releases both owners")
        profileModel.setCameraFollowEnabled(true)
        input(.begin(contact:2,control:move.id,position:.init(x:1)))
        clock.now += 0.21;profileModel.tickInput();profileLink.ack();clock.now += 0.18;profileModel.tickInput();profileLink.ack()
        check((profileLink.sent.last?.output?.gamepad.rightStick.x ?? 0)>0,"Camera Follow generated by iOS reaches PC right stick")
        profileModel.releaseAll();profileLink.arm()
        check(profileModel.practiceState == .neutral && profileModel.connectionRequested,"Profile Release all clears held keys/camera and preserves connection")
        check(defaults.data(forKey:ProfileControllerViewModel.libraryKey)==bytes,"PC transport never rewrites saved layouts")
        profileModel.stop()
        print("PASS: \(checks) Windows PC actual-model checks; no Windows native output performed.")
    }
}
