import Foundation
import MikserCore

// mikserctl — posts one control command to the running Mikser app and prints its JSON reply.
let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first, !cmd.isEmpty else {
    print("usage: mikserctl ping | set <app> <0…1> | mute <app> | unmute <app> | reset | stats | dump | quit")
    print("       mikserctl output list | output set <device name> | login on|off|status | popover open|close")
    exit(2)
}
var info: [String: Any] = ["cmd": cmd, "args": Array(argv.dropFirst())]

let replyURL = ControlChannel.replyURL
func modificationDate() -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: replyURL.path))?[.modificationDate] as? Date
}
let before = modificationDate()
var replied = false
let observer = DistributedNotificationCenter.default().addObserver(
    forName: ControlChannel.replyName, object: nil, queue: .main) { _ in replied = true }

DistributedNotificationCenter.default().postNotificationName(ControlChannel.controlName, object: nil, userInfo: info, deliverImmediately: true)

let deadline = Date().addingTimeInterval(4)
while Date() < deadline, !replied {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    if let now = modificationDate(), now != before { replied = true }
}
DistributedNotificationCenter.default().removeObserver(observer)

guard replied, let data = try? Data(contentsOf: replyURL), let text = String(data: data, encoding: .utf8) else {
    print("{\"ok\": false, \"message\": \"no reply from Mikser within 4 s (is it running?)\"}")
    exit(1)
}
print(text)
if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["ok"] as? Bool == false { exit(1) }
