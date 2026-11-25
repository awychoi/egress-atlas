import Foundation

/// HOST parser, scope, attribution, dnsmasq, nettop and synthetic-monitor checks
/// shared by `--host-test` and `--self-test`. Non-exiting: callers read the
/// returned report.
enum HostChecks {
    struct SyntheticSummary {
        let apps: Int
        let endpoints: Int
        let rx: UInt64
    }

    struct Report {
        let failures: [String]
        let synthetic: SyntheticSummary?
    }

    static func run() -> Report {
        var failed: [String] = []
        let fixture = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs
        tcp4  2552737      0  192.168.1.108.62104    172.66.0.218.443       ESTABLISHED      9280774         1774 2552492  131072             curl:21720  00102 00000008 0000000000039086 00000081 04000900      2      0 000000
        tcp4       0      0  192.168.1.108.49301    17.57.147.6.5223       ESTABLISHED       192864       269503  131072  131072             apsd:393  00182 00020000 0000000000002024 00180081 04080900      2      0 000000
        tcp6       0      0  fe80::1418:1c0a:.55836 fe80::cdf:fb53:5.49395 ESTABLISHED        12288         4343  131072  131376         rapportd:671  00102 00000004 000000000001f7e7 20080083 01000800      3      0 000004
        udp4       0      0  192.168.1.108.63685    172.64.152.29.443                       9102         7945 1048576   29040   Brave Browser He:1472  00102 00000000 0000000000036c16 00000000 04200900      1      0 000002
        tcp4       0      0  *.7000                 *.*                    LISTEN                 0            0  131072  131072             launchd:1  00100 00000006 000000000001f0fa 00000001 00000800      1      0 000000
        """
        let rows = HostTrafficParser.parse(fixture)
        if rows.count != 4 { failed.append("parser row count \(rows.count)") }
        if let curl = rows.first(where: { $0.pid == 21720 }) {
            if curl.rxBytes != 9_280_774 || curl.txBytes != 1_774 { failed.append("curl bytes") }
            if curl.remotePort != 443 { failed.append("curl port") }
            if curl.proto != "tcp4" { failed.append("curl proto") }
        } else {
            failed.append("curl missing")
        }
        if let brave = rows.first(where: { $0.remotePort == 443 && $0.proto == "udp4" }) {
            if brave.remoteAddress != "172.64.152.29" { failed.append("udp host") }
            if brave.rxBytes != 9_102 || brave.txBytes != 7_945 { failed.append("udp bytes") }
        } else {
            failed.append("udp row missing")
        }
        if !rows.contains(where: { $0.proto == "tcp6" && $0.remotePort == 49395 }) {
            failed.append("ipv6 row missing")
        }
        if rows.contains(where: { $0.pid == 1 }) { failed.append("listener not skipped") }
        if HostScope.classify("192.168.1.4") != .lan { failed.append("scope lan") }
        if HostScope.classify("8.8.8.8") != .internet { failed.append("scope internet") }
        if HostScope.classify("127.0.0.1") != .loopback { failed.append("scope loopback") }
        if HostScope.classify("100.101.102.103") != .vpn { failed.append("scope vpn") }

        let attributor = HostDomainAttributor()
        attributor.resolveHost = { _ in ["93.184.216.34"] }
        attributor.record(domain: "example.com", at: Date())
        Thread.sleep(forTimeInterval: 0.8)
        if let match = attributor.match(host: "93.184.216.34", port: 443, at: Date()) {
            if match.confidence != .temporal || match.domain != "example.com" {
                failed.append("domain resolved \(match.confidence) \(match.domain)")
            }
        } else {
            failed.append("domain exact missing")
        }
        if attributor.match(host: "203.0.113.9", port: 9999, at: Date()) != nil {
            failed.append("unmatched ip")
        }

        let nowStamp = Date().timeIntervalSince1970
        let logLines: [PiHoleLogLine] = [
            PiHoleLogLine(timestamp: nowStamp - 1.0, message: "query[A] example.com from 192.168.1.108"),
            PiHoleLogLine(timestamp: nowStamp - 0.9, message: "cached example.com is 93.184.216.34"),
            PiHoleLogLine(timestamp: nowStamp - 0.8, message: "query[A] www.apple.com from 192.168.1.108"),
            PiHoleLogLine(timestamp: nowStamp - 0.7, message: "reply www.apple.com is <CNAME>"),
            PiHoleLogLine(timestamp: nowStamp - 0.6, message: "reply e6858.dscb.akamaiedge.net is 17.253.144.10"),
            PiHoleLogLine(timestamp: nowStamp - 0.5, message: "query[A] other.com from 10.0.0.9"),
            PiHoleLogLine(timestamp: nowStamp - 0.4, message: "cached other.com is 1.2.3.4"),
            PiHoleLogLine(timestamp: nowStamp - 0.3, message: "reply www.apple.com is 17.253.144.10"),
        ]
        var logParser = HostDnsmasqParser()
        let observations = logParser.ingest(logLines, localClients: ["192.168.1.108"])
        if observations.count != 2 { failed.append("dnsmasq observations \(observations.count)") }
        if !observations.contains(where: { $0.ip == "93.184.216.34" && $0.domain == "example.com" }) {
            failed.append("dnsmasq exact")
        }
        if !observations.contains(where: { $0.domain == "www.apple.com" && $0.ip == "17.253.144.10" }) {
            failed.append("dnsmasq cname")
        }
        if observations.contains(where: { $0.domain == "other.com" }) {
            failed.append("dnsmasq other client leaked")
        }
        attributor.recordAnswer(domain: "example.com", ip: "93.184.216.34", at: Date())
        if attributor.match(host: "93.184.216.34", port: 443, at: Date())?.confidence != .exact {
            failed.append("attributor log exact")
        }
        attributor.recordAnswer(domain: "www.example.com", ip: "93.184.216.34", at: Date())
        if attributor.match(host: "93.184.216.34", port: 443, at: Date())?.confidence != .temporal {
            failed.append("attributor ambiguity")
        }

        let nettopFixture = """
        time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
        12:00:00.000001,Brave Browser.42,,,500,100,0,0,0,,,,,,,,,,,,
        12:00:00.000002,tcp4 192.168.1.108:50000<->93.184.216.34:443,en0,Established,500,100,0,0,0,,,,,,,,,,,,
        12:00:00.000003,tcp4 *:443<->*:*,en0,Listen,,,,,,,,,,,,,,,,,,,,
        12:00:00.000004,trustd.7,,,20,30,0,0,0,,,,,,,,,,,,
        12:00:00.000005,tcp6 fe80::1418:1c0a:e074:ad98%en0.55836<->2606:4700:4700::1111.443,en0,Established,20,30,0,0,0,,,,,,,,,,,,
        """
        let nettopSamples = HostNettopParser.parse(nettopFixture)
        if nettopSamples.count != 2 { failed.append("nettop parse count \(nettopSamples.count)") }
        if nettopSamples.first?.pid != 42 || nettopSamples.first?.remoteAddress != "93.184.216.34"
            || nettopSamples.first?.remotePort != 443 {
            failed.append("nettop ipv4 parse")
        }
        if nettopSamples.last?.pid != 7 || nettopSamples.last?.remoteAddress != "2606:4700:4700::1111"
            || nettopSamples.last?.remotePort != 443 {
            failed.append("nettop ipv6 parse")
        }

        let monitor = HostTrafficMonitor()
        let t0 = Date()
        let first = HostSocketSample(proto: "tcp4", localAddress: "192.168.1.108",
                                     localPort: 50000, remoteAddress: "93.184.216.34",
                                     remotePort: 443, pid: 999999,
                                     rxBytes: 100, txBytes: 50)
        monitor.debugIngest([first], at: t0, dt: 1, baseline: true)
        let second = HostSocketSample(proto: "tcp4", localAddress: "192.168.1.108",
                                      localPort: 50000, remoteAddress: "93.184.216.34",
                                      remotePort: 443, pid: 999999,
                                      rxBytes: 1_000, txBytes: 200)
        monitor.debugIngest([second], at: t0.addingTimeInterval(1), dt: 1)
        let synthetic = monitor.snapshot
        if synthetic.apps.count != 1 { failed.append("monitor app count \(synthetic.apps.count)") }
        if synthetic.apps.first?.rxTotal != 900 { failed.append("monitor rx total \(String(describing: synthetic.apps.first?.rxTotal))") }
        if synthetic.apps.first?.txTotal != 150 { failed.append("monitor tx total") }
        if synthetic.endpoints.count != 1 { failed.append("monitor endpoint count") }
        if synthetic.transfers.first?.bytesIn != 900 { failed.append("monitor transfer") }

        let summary = SyntheticSummary(apps: synthetic.apps.count,
                                       endpoints: synthetic.endpoints.count,
                                       rx: synthetic.apps.first?.rxTotal ?? 0)

        return Report(failures: failed, synthetic: summary)
    }
}
