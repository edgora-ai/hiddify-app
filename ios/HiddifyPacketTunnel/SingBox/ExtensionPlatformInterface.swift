//
//  ExtensionPlatformInterface.swift
//  SingBoxPacketTunnel
//
//  Created by GFWFighter on 7/25/1402 AP.
//

import Foundation
import HiddifyCore
import Network
import NetworkExtension
import UIKit
import UserNotifications

public class ExtensionPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {
    
    
    private var tunnel: ExtensionProvider
    private var networkSettings: NEPacketTunnelNetworkSettings?

    init(_ tunnel: ExtensionProvider) {
        self.tunnel = tunnel
    }

    public func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        NSLog("H?A1")
        try runBlocking { [self] in
            try await openTun0(options, ret0_)
        }
    }

    private func openTun0(_ options: LibboxTunOptionsProtocol?, _ ret0_: UnsafeMutablePointer<Int32>?) async throws {
        guard let options else {
            throw NSError(domain: "ExtensionPlatformInterface", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Nil options")])
        }
        guard let ret0_ else {
            throw NSError(domain: "ExtensionPlatformInterface", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Nil return pointer")])
        }

//        let prefs = tunnel.overridePreferences ?? ExtensionProvider.OverridePreferences()
        let autoRouteUseSubRangesByDefault = true//prefs.autoRouteUseSubRangesByDefault // await SharedPreferences.autoRouteUseSubRangesByDefault.get()
        let excludeAPNs = false//prefs.excludeAPNsRoute //await SharedPreferences.excludeAPNsRoute.get()
        let excludeDefaultRoute = false// prefs.excludeDefaultRoute
        let systemProxyEnabled = false//prefs.systemProxyEnabled

        
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "::1")
        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            if options.getDNSMode()?.value != LibboxDNSModeDisabled {
                let dnsServerIterator: LibboxStringIteratorProtocol
                do {
                    // The Swift importer throws for a nil Objective-C result.
                    dnsServerIterator = try options.getDNSServerAddress()
                } catch {
                    throw NSError(domain: "ExtensionPlatformInterface", code: Int(EINVAL), userInfo: [
                        NSLocalizedDescriptionKey: "Could not read DNS server addresses for enabled DNS",
                        NSUnderlyingErrorKey: error,
                    ])
                }
                var dnsServers: [String] = []
                while dnsServerIterator.hasNext() {
                    dnsServers.append(dnsServerIterator.next())
                }
                guard !dnsServers.isEmpty, !dnsServers.contains(where: { $0.isEmpty }) else {
                    throw platformError(EINVAL, "DNS is enabled, but no valid DNS server addresses were returned")
                }
                let dnsSettings = NEDNSSettings(servers: dnsServers)
                dnsSettings.matchDomains = [""]
                dnsSettings.matchDomainsNoSearch = true
                settings.dnsSettings = dnsSettings
            }
            
            var ipv4Address: [String] = []
            var ipv4Mask: [String] = []
            let ipv4AddressIterator = options.getInet4Address()!
            while ipv4AddressIterator.hasNext() {
                let ipv4Prefix = ipv4AddressIterator.next()!
                ipv4Address.append(ipv4Prefix.address())
                ipv4Mask.append(ipv4Prefix.mask())
            }
            let ipv4Settings = NEIPv4Settings(addresses: ipv4Address, subnetMasks: ipv4Mask)
            var ipv4Routes: [NEIPv4Route] = []
            var ipv4ExcludeRoutes: [NEIPv4Route] = []

            let inet4RouteAddressIterator = options.getInet4RouteAddress()!
            if inet4RouteAddressIterator.hasNext() {
                while inet4RouteAddressIterator.hasNext() {
                    let ipv4RoutePrefix = inet4RouteAddressIterator.next()!
                    ipv4Routes.append(NEIPv4Route(destinationAddress: ipv4RoutePrefix.address(), subnetMask: ipv4RoutePrefix.mask()))
                }
            } else if autoRouteUseSubRangesByDefault {
                ipv4Routes.append(NEIPv4Route(destinationAddress: "1.0.0.0", subnetMask: "255.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "2.0.0.0", subnetMask: "254.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "4.0.0.0", subnetMask: "252.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "8.0.0.0", subnetMask: "248.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "16.0.0.0", subnetMask: "240.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "32.0.0.0", subnetMask: "224.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "64.0.0.0", subnetMask: "192.0.0.0"))
                ipv4Routes.append(NEIPv4Route(destinationAddress: "128.0.0.0", subnetMask: "128.0.0.0"))
                ipv4Routes.append(NEIPv4Route.default())
            } else {
                ipv4Routes.append(NEIPv4Route.default())
            }

            let inet4RouteExcludeAddressIterator = options.getInet4RouteExcludeAddress()!
            while inet4RouteExcludeAddressIterator.hasNext() {
                let ipv4RoutePrefix = inet4RouteExcludeAddressIterator.next()!
                ipv4ExcludeRoutes.append(NEIPv4Route(destinationAddress: ipv4RoutePrefix.address(), subnetMask: ipv4RoutePrefix.mask()))
            }
            if excludeDefaultRoute, !ipv4Routes.isEmpty {
                if !ipv4ExcludeRoutes.contains(where: { it in
                    it.destinationAddress == "0.0.0.0" && it.destinationSubnetMask == "255.255.255.254"
                }) {
                    ipv4ExcludeRoutes.append(NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "255.255.255.254"))
                }
            }
            if excludeAPNs, !ipv4Routes.isEmpty {
                if !ipv4ExcludeRoutes.contains(where: { it in
                    it.destinationAddress == "17.0.0.0" && it.destinationSubnetMask == "255.0.0.0"
                }) {
                    ipv4ExcludeRoutes.append(NEIPv4Route(destinationAddress: "17.0.0.0", subnetMask: "255.0.0.0"))
                }
           }
            ipv4Settings.includedRoutes = ipv4Routes
            ipv4Settings.excludedRoutes = ipv4ExcludeRoutes
            settings.ipv4Settings = ipv4Settings

            var ipv6Address: [String] = []
            var ipv6Prefixes: [NSNumber] = []
            let ipv6AddressIterator = options.getInet6Address()!
            while ipv6AddressIterator.hasNext() {
                let ipv6Prefix = ipv6AddressIterator.next()!
                ipv6Address.append(ipv6Prefix.address())
                ipv6Prefixes.append(NSNumber(value: ipv6Prefix.prefix()))
            }
            let ipv6Settings = NEIPv6Settings(addresses: ipv6Address, networkPrefixLengths: ipv6Prefixes)
            var ipv6Routes: [NEIPv6Route] = []
            var ipv6ExcludeRoutes: [NEIPv6Route] = []

            let inet6RouteAddressIterator = options.getInet6RouteAddress()!
            if inet6RouteAddressIterator.hasNext() {
                while inet6RouteAddressIterator.hasNext() {
                    let ipv6RoutePrefix = inet6RouteAddressIterator.next()!
                    ipv6Routes.append(NEIPv6Route(destinationAddress: ipv6RoutePrefix.address(), networkPrefixLength: NSNumber(value: ipv6RoutePrefix.prefix())))
                }
            } else if autoRouteUseSubRangesByDefault {
                ipv6Routes.append(NEIPv6Route(destinationAddress: "100::", networkPrefixLength: 8))
                ipv6Routes.append(NEIPv6Route(destinationAddress: "200::", networkPrefixLength: 7))
                ipv6Routes.append(NEIPv6Route(destinationAddress: "400::", networkPrefixLength: 6))
                ipv6Routes.append(NEIPv6Route(destinationAddress: "800::", networkPrefixLength: 5))
                ipv6Routes.append(NEIPv6Route(destinationAddress: "1000::", networkPrefixLength: 4))
                ipv6Routes.append(NEIPv6Route(destinationAddress: "2000::", networkPrefixLength: 3))
                ipv6Routes.append(NEIPv6Route(destinationAddress: "4000::", networkPrefixLength: 2))
                ipv6Routes.append(NEIPv6Route(destinationAddress: "8000::", networkPrefixLength: 1))
                ipv6Routes.append(NEIPv6Route.default())
            } else {
                ipv6Routes.append(NEIPv6Route.default())
            }

            let inet6RouteExcludeAddressIterator = options.getInet6RouteExcludeAddress()!
            while inet6RouteExcludeAddressIterator.hasNext() {
                let ipv6RoutePrefix = inet6RouteExcludeAddressIterator.next()!
                ipv6ExcludeRoutes.append(NEIPv6Route(destinationAddress: ipv6RoutePrefix.address(), networkPrefixLength: NSNumber(value: ipv6RoutePrefix.prefix())))
            }
            if excludeDefaultRoute, !ipv6Routes.isEmpty {
                if !ipv6ExcludeRoutes.contains(where: { it in
                    it.destinationAddress == "::" && it.destinationNetworkPrefixLength == 127
                }) {
                    ipv6ExcludeRoutes.append(NEIPv6Route(destinationAddress: "::", networkPrefixLength: 127))
                }
            }
            ipv6Settings.includedRoutes = ipv6Routes
            ipv6Settings.excludedRoutes = ipv6ExcludeRoutes
            settings.ipv6Settings = ipv6Settings
        }

        if options.isHTTPProxyEnabled() {
            let proxySettings = NEProxySettings()
            let proxyServer = NEProxyServer(address: options.getHTTPProxyServer(), port: Int(options.getHTTPProxyServerPort()))
            proxySettings.httpServer = proxyServer
            proxySettings.httpsServer = proxyServer
            if systemProxyEnabled {
                proxySettings.httpEnabled = true
                proxySettings.httpsEnabled = true
            }

            var bypassDomains: [String] = []
            let bypassDomainIterator = options.getHTTPProxyBypassDomain()!
            while bypassDomainIterator.hasNext() {
                bypassDomains.append(bypassDomainIterator.next())
            }

            if excludeAPNs {
                if !bypassDomains.contains(where: { it in
                    it == "push.apple.com"
                }) {
                    bypassDomains.append("push.apple.com")
                }
            }

            if !bypassDomains.isEmpty {
                proxySettings.exceptionList = bypassDomains
            }

            var matchDomains: [String] = []

            let matchDomainIterator = options.getHTTPProxyMatchDomain()!

            while matchDomainIterator.hasNext() {
                matchDomains.append(matchDomainIterator.next())
            }

            if !matchDomains.isEmpty {
                proxySettings.matchDomains = matchDomains
            }
            settings.proxySettings = proxySettings
        }

        networkSettings = settings
        try await tunnel.setTunnelNetworkSettings(settings)

        if let tunFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = tunFd
            return
        }

        let tunFdFromLoop = LibboxGetTunnelFileDescriptor()
        if tunFdFromLoop != -1 {
            ret0_.pointee = tunFdFromLoop
        } else {
            throw NSError(domain: "missing file descriptor", code: 0)
        }
    }

    public func usePlatformAutoDetectControl() -> Bool {
        false
    }
    public func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        #if os(macOS)
            if Variant.useSystemExtension {
                guard let sourceAddress, let destinationAddress else {
                    throw NSError(domain: "findConnectionOwner", code: 0, userInfo: [
                        NSLocalizedDescriptionKey: "Missing source or destination address",
                    ])
                }
                let owner = try RootHelperClient.shared.findConnectionOwner(
                    ipProtocol: ipProtocol,
                    sourceAddress: sourceAddress,
                    sourcePort: sourcePort,
                    destinationAddress: destinationAddress,
                    destinationPort: destinationPort
                )
                let result = LibboxConnectionOwner()
                result.userId = owner.userId
                result.userName = owner.userName
                result.processPath = owner.processPath
                return result
            }
        #endif
        throw NSError(domain: "ExtensionPlatformInterface", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Not implemented")])
    }

    public func useProcFS() -> Bool {
        false
    }

    public func writeLog(_ message: String?) {
        guard let message else {
            return
        }
        tunnel.writeMessage(message)
    }

    private let interfaceMonitorLock = NSLock()
    private var defaultInterfaceMonitor: DefaultInterfaceMonitorState?
    private var ownedInterfaceNames: Set<String> = []

    public func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else {
            throw platformError(EINVAL, "Missing default interface listener")
        }
        let state = DefaultInterfaceMonitorState(listener)
        state.monitor.pathUpdateHandler = { [weak self, weak state] path in
            guard let state else {
                return
            }
            self?.onUpdateDefaultInterface(state, path)
        }
        interfaceMonitorLock.lock()
        guard defaultInterfaceMonitor == nil else {
            interfaceMonitorLock.unlock()
            throw platformError(EALREADY, "Default interface monitor is already started")
        }
        defaultInterfaceMonitor = state
        state.monitor.start(queue: state.queue)
        interfaceMonitorLock.unlock()

        _ = state.initialUpdate.wait(timeout: .now() + 5)
        interfaceMonitorLock.lock()
        let isCurrent = defaultInterfaceMonitor === state
        let initialized = state.initialized
        if isCurrent && !initialized {
            defaultInterfaceMonitor = nil
        }
        interfaceMonitorLock.unlock()
        guard isCurrent else {
            throw platformError(ECANCELED, "Default interface monitor start was canceled")
        }
        guard initialized else {
            state.monitor.cancel()
            throw platformError(ETIMEDOUT, "Timed out waiting for the initial network path")
        }
    }

    private func onUpdateDefaultInterface(_ state: DefaultInterfaceMonitorState, _ updatedPath: Network.NWPath? = nil) {
        interfaceMonitorLock.lock()
        guard defaultInterfaceMonitor === state else {
            interfaceMonitorLock.unlock()
            return
        }
        if let updatedPath {
            state.path = updatedPath
        }
        guard let path = state.path else {
            interfaceMonitorLock.unlock()
            return
        }
        let ownedNames = ownedInterfaceNames
        interfaceMonitorLock.unlock()

        if path.status != .unsatisfied,
           let defaultInterface = path.availableInterfaces.first(where: { !ownedNames.contains($0.name) }) {
            state.listener.updateDefaultInterface(defaultInterface.name, interfaceIndex: Int32(defaultInterface.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
        } else {
            state.listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
        }

        interfaceMonitorLock.lock()
        let signalInitialUpdate = defaultInterfaceMonitor === state && !state.initialized
        if signalInitialUpdate {
            state.initialized = true
        }
        interfaceMonitorLock.unlock()
        if signalInitialUpdate {
            state.initialUpdate.signal()
        }
    }

    public func registerMyInterface(_ name: String?) {
        guard let name, !name.isEmpty else {
            return
        }
        interfaceMonitorLock.lock()
        let inserted = ownedInterfaceNames.insert(name).inserted
        let state = defaultInterfaceMonitor
        interfaceMonitorLock.unlock()
        if inserted, let state {
            // Go may register while holding its own interface lock; never call it back inline.
            state.queue.async { [weak self, weak state] in
                guard let state else {
                    return
                }
                self?.onUpdateDefaultInterface(state)
            }
        }
    }

    public func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
        stopDefaultInterfaceMonitor()
    }

    private func stopDefaultInterfaceMonitor(clearOwnedInterfaces: Bool = false) {
        interfaceMonitorLock.lock()
        let state = defaultInterfaceMonitor
        defaultInterfaceMonitor = nil
        if clearOwnedInterfaces {
            ownedInterfaceNames.removeAll()
        }
        interfaceMonitorLock.unlock()
        state?.monitor.cancel()
        state?.initialUpdate.signal()
    }

    public func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        interfaceMonitorLock.lock()
        let state = defaultInterfaceMonitor
        let path = state?.path ?? state?.monitor.currentPath
        let ownedNames = ownedInterfaceNames
        interfaceMonitorLock.unlock()
        guard let path else {
            throw platformError(ENXIO, "Default interface monitor is not started")
        }
        if path.status == .unsatisfied {
            return networkInterfaceArray([])
        }
        var interfaces: [LibboxNetworkInterface] = []
        for it in path.availableInterfaces where !ownedNames.contains(it.name) {
            let interface = LibboxNetworkInterface()
            interface.name = it.name
            interface.index = Int32(it.index)
            switch it.type {
            case .wifi:
                interface.type = LibboxInterfaceTypeWIFI
            case .cellular:
                interface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet:
                interface.type = LibboxInterfaceTypeEthernet
            default:
                interface.type = LibboxInterfaceTypeOther
            }
            interfaces.append(interface)
        }
        return networkInterfaceArray(interfaces)
    }

    private let neighborMonitorLock = NSLock()
    private var neighborMonitor: NeighborMonitorState?

    public func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {
        guard let listener else {
            throw platformError(EINVAL, "Missing neighbor listener")
        }
        let state = NeighborMonitorState(listener)
        neighborMonitorLock.lock()
        guard neighborMonitor == nil else {
            neighborMonitorLock.unlock()
            throw platformError(EALREADY, "Neighbor monitor is already started or starting")
        }
        neighborMonitor = state
        neighborMonitorLock.unlock()

        // The helper calls the relay synchronously before returning its subscription.
        var subscriptionError: NSError?
        let subscription = LibboxSubscribeNeighborTable(state.relay, &subscriptionError)
        neighborMonitorLock.lock()
        let isCurrent = neighborMonitor === state
        if isCurrent {
            if subscriptionError == nil, let subscription {
                state.subscription = subscription
            } else {
                neighborMonitor = nil
            }
        }
        neighborMonitorLock.unlock()
        guard isCurrent, subscriptionError == nil, subscription != nil else {
            state.relay.invalidate()
            subscription?.close()
            if !isCurrent {
                throw platformError(ECANCELED, "Neighbor monitor start was canceled")
            }
            if let subscriptionError {
                throw subscriptionError
            }
            throw platformError(EIO, "Neighbor monitor returned no subscription")
        }
    }

    public func closeNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {
        stopNeighborMonitor()
    }

    private func stopNeighborMonitor() {
        neighborMonitorLock.lock()
        let state = neighborMonitor
        neighborMonitor = nil
        let subscription = state?.subscription
        state?.subscription = nil
        neighborMonitorLock.unlock()
        state?.relay.invalidate()
        subscription?.close()
    }

    class networkInterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var iterator: IndexingIterator<[LibboxNetworkInterface]>
        init(_ array: [LibboxNetworkInterface]) {
            iterator = array.makeIterator()
        }

        private var nextValue: LibboxNetworkInterface?

        func hasNext() -> Bool {
            nextValue = iterator.next()
            return nextValue != nil
        }

        func next() -> LibboxNetworkInterface? {
            nextValue
        }
    }

    public func underNetworkExtension() -> Bool {
        true
    }

    public func includeAllNetworks() -> Bool {
        #if os(tvOS)
            return false
        #else
            return false
//            return tunnel.overridePreferences?.includeAllNetworks ?? false
        #endif
    }

    public func clearDNSCache() {
        guard let networkSettings else {
            return
        }
        runBlocking {
            self.tunnel.reasserting = true
            defer { self.tunnel.reasserting = false }
            await withCheckedContinuation { continuation in
                self.tunnel.setTunnelNetworkSettings(nil) { _ in
                    continuation.resume()
                }
            }
            await withCheckedContinuation { continuation in
                self.tunnel.setTunnelNetworkSettings(networkSettings) { _ in
                    continuation.resume()
                }
            }
        }
    }

    public func readWIFIState() -> LibboxWIFIState? {
//        #if os(iOS)
//            let network = runBlocking {
//                await NEHotspotNetwork.fetchCurrent()
//            }
//            guard let network else {
//                return nil
//            }
//            return LibboxWIFIState(network.ssid, wifiBSSID: network.bssid)!
//        #elseif os(macOS)
//            if Variant.useSystemExtension {
//                return UserServiceClient.shared.readWIFIState()
//            }
//            guard let interface = CWWiFiClient.shared().interface() else {
//                return nil
//            }
//            guard let ssid = interface.ssid() else {
//                return nil
//            }
//            guard let bssid = interface.bssid() else {
//                return nil
//            }
//            return LibboxWIFIState(ssid, wifiBSSID: bssid)!
//        #else
            return nil
//        #endif
    }

    public func readWIFISSID() -> String? {
//        #if os(iOS)
//            return runBlocking {
//                await NEHotspotNetwork.fetchCurrent()?.ssid
//            }
//        #elseif os(macOS)
//            return CWWiFiClient.shared().interface()?.ssid()
//        #else
            return nil
//        #endif
    }

//    public func serviceStop() throws {
//        tunnel.stopService()
//    }

    public func serviceReload() throws {
        try runBlocking { [self] in
            try await tunnel.reloadService()
        }
    }

    public func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        guard let networkSettings else {
            return status
        }
        guard let proxySettings = networkSettings.proxySettings else {
            return status
        }
        if proxySettings.httpServer == nil {
            return status
        }
        status.available = true
        status.enabled = proxySettings.httpEnabled
        return status
    }

    public func setSystemProxyEnabled(_ isEnabled: Bool) throws {
        guard let networkSettings else {
            return
        }
        guard let proxySettings = networkSettings.proxySettings else {
            return
        }
        if proxySettings.httpServer == nil {
            return
        }
        if proxySettings.httpEnabled == isEnabled {
            return
        }
        proxySettings.httpEnabled = isEnabled
        proxySettings.httpsEnabled = isEnabled
        networkSettings.proxySettings = proxySettings
        try runBlocking {
            try await self.tunnel.setTunnelNetworkSettings(networkSettings)
        }
    }

    public func writeDebugMessage(_ message: String?) {
        guard let message else {
            return
        }
//        tunnel.writeMessage(message)
    }

    func reset() {
        networkSettings = nil
        stopDefaultInterfaceMonitor(clearOwnedInterfaces: true)
        stopNeighborMonitor()
    }

    public func send(_ notification: LibboxNotification?) throws {
        guard let notification, !notification.identifier.isEmpty else {
            throw platformError(EINVAL, "Missing notification or notification identifier")
        }
        #if !os(tvOS)
            #if os(macOS)
                if Variant.useSystemExtension {
                    try UserServiceClient.shared.sendNotification(notification)
                    return
                }
            #endif
            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.subtitle = notification.subtitle
            content.body = notification.body
            if !notification.openURL.isEmpty {
                content.userInfo["OPEN_URL"] = notification.openURL
                content.categoryIdentifier = "OPEN_URL"
            }
            content.interruptionLevel = .active
            let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
            try runBlocking {
                let settings = await center.notificationSettings()
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    break
                #if os(iOS)
                case .ephemeral:
                    break
                #endif
                default:
                    throw self.platformError(EACCES, "Notifications are not authorized for this app")
                }
                try await center.add(request)
            }
        #else
            throw unsupported("Notifications")
        #endif
    }

    public func cancelNotification(_ identifier: String?, typeID _: Int32) throws {
        guard let identifier, !identifier.isEmpty else {
            throw platformError(EINVAL, "Missing notification identifier")
        }
        #if !os(tvOS)
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        #else
            throw unsupported("Notifications")
        #endif
    }

    public func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? {
        nil
    }

    public func systemCertificates() -> (any LibboxStringIteratorProtocol)? {
        nil
    }

    public func usePlatformShell() -> Bool {
        false
    }

    public func checkPlatformShell() throws {
        throw unsupported("Platform shell")
    }

    public func openShellSession(_ user: LibboxPlatformUser?, command: String?, environ: LibboxStringIteratorProtocol?, term: String?, rows: Int32, cols: Int32) throws -> LibboxShellSessionProtocol {
        throw unsupported("Shell sessions")
    }

    public func lookupUser(_ username: String?) throws -> LibboxPlatformUser {
        throw unsupported("System user lookup")
    }

    public func lookupSFTPServer() throws -> LibboxStringBox {
        throw unsupported("SFTP server lookup")
    }

    public func readSystemSSHHostKey() throws -> LibboxStringBox {
        throw unsupported("System SSH host keys")
    }

    public func tailscaleHostname() -> String {
        ""
    }

    public func usePlatformBridge() -> Bool {
        false
    }

    public func createBridge(_ options: LibboxBridgeOptions?) throws -> LibboxBridgeSessionProtocol {
        throw unsupported("Platform bridges")
    }

    public func usePlatformAutoRedirect() -> Bool {
        false
    }

    public func createAutoRedirect(_ options: Data?, handler: LibboxAutoRedirectHandlerProtocol?) throws -> LibboxAutoRedirectSessionProtocol {
        throw unsupported("Platform auto-redirect")
    }

    private func unsupported(_ operation: String) -> NSError {
        platformError(ENOTSUP, "\(operation) is not supported by this iOS extension")
    }

    private func platformError(_ code: Int32, _ description: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: description])
    }

    public func autoDetectControl(_: Int32) throws {}

}

private final class DefaultInterfaceMonitorState {
    let monitor = NWPathMonitor()
    // A fresh queue per start also permits a Go callback to close and restart the monitor.
    let queue = DispatchQueue(label: "ExtensionPlatformInterface.defaultInterface")
    let listener: LibboxInterfaceUpdateListenerProtocol
    let initialUpdate = DispatchSemaphore(value: 0)
    var path: Network.NWPath?
    var initialized = false

    init(_ listener: LibboxInterfaceUpdateListenerProtocol) {
        self.listener = listener
    }
}

private final class NeighborMonitorState {
    let relay: NeighborUpdateRelay
    var subscription: LibboxNeighborSubscription?

    init(_ listener: LibboxNeighborUpdateListenerProtocol) {
        relay = NeighborUpdateRelay(listener)
    }
}

private final class NeighborUpdateRelay: NSObject, LibboxNeighborUpdateListenerProtocol {
    private let lock = NSLock()
    private var listener: LibboxNeighborUpdateListenerProtocol?

    init(_ listener: LibboxNeighborUpdateListenerProtocol) {
        self.listener = listener
    }

    func invalidate() {
        lock.lock()
        listener = nil
        lock.unlock()
    }

    func updateNeighborTable(_ entries: LibboxNeighborEntryIteratorProtocol?) {
        lock.lock()
        let listener = self.listener
        lock.unlock()
        // Forward the Go iterator synchronously; an already active callback may finish after close.
        listener?.updateNeighborTable(entries)
    }
}
