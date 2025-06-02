//
//  PacketTunnelProvider.swift
//  TunnelProv
//
//  Created by Stephen on 06/01/2025.
//
//  Inspired by Stossy & StosVPN
//

import NetworkExtension
import Darwin

class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let deviceIP = options?["TunnelDeviceIP"] as? String ?? "10.7.0.0"
        let fakeIP = options?["TunnelFakeIP"] as? String ?? "10.7.0.1"
        
        let toNetwork: (String) -> UInt32 = { address in
            var addr = in_addr()
            inet_pton(AF_INET, address, &addr)
            return addr.s_addr.bigEndian
        }
        let deviceNet = toNetwork(deviceIP), fakeNet = toNetwork(fakeIP)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: deviceIP)
        let ipv4 = NEIPv4Settings(addresses: [deviceIP], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: deviceIP, subnetMask: "255.255.255.0")]
        ipv4.excludedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { error in
            guard error == nil else { return completionHandler(error) }
            
            func process() {
                self.packetFlow.readPackets { packets, protocols in
                    var modified = packets
                    for i in modified.indices where protocols[i].int32Value == AF_INET && modified[i].count >= 20 {
                        modified[i].withUnsafeMutableBytes { buffer in
                            let ptr = buffer.baseAddress!.assumingMemoryBound(to: UInt32.self)
                            let src = ptr[3], dst = ptr[4]
                            ptr[3] = src == deviceNet ? fakeNet : dst
                            ptr[4] = dst == fakeNet ? deviceNet : src
                        }
                    }
                    self.packetFlow.writePackets(modified, withProtocols: protocols)
                    process()
                }
            }
            process()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
