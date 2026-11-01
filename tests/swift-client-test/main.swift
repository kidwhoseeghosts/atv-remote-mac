import Foundation

@main struct T {
    static func fail(_ m: String) -> Never { print("FAIL: \(m)"); exit(1) }
    static func main() async {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("atvtest-\(getpid())")
        let client = DaemonClient(launch: .init(
            python: URL(fileURLWithPath: CommandLine.arguments[1]),
            script: URL(fileURLWithPath: CommandLine.arguments[2]),
            storage: tmp.appendingPathComponent("pyatv.conf"),
            cacheDir: tmp.appendingPathComponent("cache"), demo: true))
        client.onLog = { print("[log] \($0)") }
        do { try client.start() } catch { fail("start \(error)") }
        let collector = Task { () -> [String] in
            var names: [String] = []
            for await e in client.events {
                names.append(e.name)
                if e.name == "playing", let p = try? e.data.decode(PlayingInfo.self) { print("playing:", p.displayTitle, "|", p.displaySubtitle, p.deviceState ?? "") }
                if e.name == "state", let s = try? e.data.decode(StateEvent.self) { print("state:", s.state, s.deviceId ?? "") }
                if e.name == "artwork" { print("artwork:", e.data["path"] ?? .null) }
            }
            return names
        }
        do {
            let hello = try await client.request("hello")
            print("hello:", hello)
            let scan = try await client.request("scan", ["timeout": 1], as: ScanResult.self)
            print("devices:", scan.devices.map { "\($0.name) paired=\($0.isPaired) pending=\($0.pendingPairingProtocols) tv=\($0.isTv)" })
            guard let dev = scan.devices.first else { fail("no devices") }
            for proto in dev.pendingPairingProtocols {
                let st = try await client.request("pair_start", ["device": .string(dev.id), "protocol": .string(proto), "address": .string(dev.address)], as: PairStartResult.self)
                print("pair_start", proto, "device_provides_pin=\(st.deviceProvidesPin)")
                do { try await client.request("pair_pin", ["pin": "0000"]); fail("bad pin accepted") } catch let e as DaemonError { print("bad pin ->", e.code ?? "?") }
                _ = try await client.request("pair_start", ["device": .string(dev.id), "protocol": .string(proto)], as: PairStartResult.self)
                let fin = try await client.request("pair_pin", ["pin": "1234"], as: PairFinishResult.self)
                print("paired", proto, fin.paired, fin.device?.isPaired ?? false)
            }
            let conn = try await client.request("connect", ["device": .string(dev.id), "address": .string(dev.address), "name": .string(dev.name)], as: ConnectResult.self)
            print("connected:", conn.device?.name ?? "?")
            for k in [RemoteKey.up, .select, .playPause, .volumeUp] {
                try await client.request("key", ["key": .string(k.rawValue), "action": "tap"])
            }
            let vinfo = try await client.request("volume_diag", as: VolumeDiagInfo.self)
            print("volume_diag:", vinfo.protocols, "mrp=\(vinfo.mrpTunnel)", "methods=\(vinfo.methods?.map { $0.id } ?? [])", "advice=\(vinfo.advice ?? "-")")
            if (vinfo.methods ?? []).isEmpty { fail("volume_diag: no methods") }
            try await client.request("set_options", ["volume_method": "companion_hid", "force_mrp_tunnel": false])
            let vrun = try await client.request("volume_diag", ["run": true, "delay": 0.05], as: VolumeDiagRunResult.self, timeout: 60)
            print("volume_diag run:", vrun.results.map { "\($0.id)=\($0.ok)" })
            if vrun.results.isEmpty { fail("volume_diag run: empty") }
            let apps = try await client.request("apps", as: AppsResult.self)
            print("apps:", apps.apps.prefix(3))
            if let first = apps.apps.first { try await client.request("launch_app", ["app": .string(first.id)]) }
            try await client.request("text", ["mode": "set", "text": "hello"])
            do { try await client.request("key", ["key": "bogus"]) } catch let e as DaemonError { print("expected error:", e.code ?? "?", e.localizedDescription) }
            try await Task.sleep(nanoseconds: 800_000_000)
        } catch { fail("\(error)") }
        client.stop()
        let names = await collector.value
        print("events:", Set(names).sorted())
        print("SWIFT<->PY OK")
    }
}
