//
//  MainViewController+Shared.swift
//  Orbot
//
//  Created by Benjamin Erhart on 30.09.22.
//  Copyright © 2022 Guardian Project. All rights reserved.
//

import Foundation
import IPtProxy
import IPtProxyUI
import NetworkExtension
import Tor

#if os(macOS)
extension NSColor {
	class var secondaryLabel: NSColor {
		NSColor.secondaryLabelColor
	}
}
#endif

class SharedUtils: NSObject, BridgesConfDelegate, IPtProxySnowflakeClientConnectedProtocol {

#if os(macOS)
	typealias Color = NSColor
	typealias Font = NSFont
#else
	typealias Color = UIColor
	typealias Font = UIFont
#endif

	private static let centered = {
		let style = NSMutableParagraphStyle()
		style.alignment = .center

		return style
	}()


	public static var torConfUrl: URL {
		URL(string: "https://2019.www.torproject.org/docs/tor-manual.html")!
	}


	// MARK: BridgesConfDelegate

	var transport: Transport {
		get {
			Settings.transport
		}
		set {
			if Settings.transport != newValue {
				Settings.transport = newValue
				Settings.smartConnect = false
			}
		}
	}

	var customBridges: [String]? {
		get {
			Settings.customBridges
		}
		set {
			Settings.customBridges = newValue
		}
	}

	func save() {
		VpnManager.shared.configChanged()

		NotificationCenter.default.post(name: .vpnStatusChanged, object: nil)
	}


	// MARK: IPtProxySnowflakeClientConnectedProtocol

	private static var selfInstance = SharedUtils()

	func connected() {
		Settings.snowflakesHelped += 1

		NotificationCenter.default.post(name: .vpnStatusChanged, object: nil)
	}


	// MARK: Shared Methods

	static func control(startOnly: Bool) {

		// Enable, if disabled.
		if VpnManager.shared.status == .disabled {
			return VpnManager.shared.enable { success in
				if success && VpnManager.shared.status != .disabled {
					control(startOnly: startOnly)
				}
			}
		}

		if startOnly && ![VpnManager.Status.disconnected, .disconnecting].contains(VpnManager.shared.status) {
			return
		}

		switch VpnManager.shared.status {
		case .notInstalled:
			// Install first, if not installed.
			VpnManager.shared.install()

		case .evaluating, .connecting, .connected:
			VpnManager.shared.disconnect(explicit: true)

		case .disconnected, .disconnecting:
			VpnManager.shared.connect()

		default:
			break
		}
	}

	static func controlSnowflakeProxy() {
		if IPtProxyIsSnowflakeProxyRunning() {
			IPtProxyStopSnowflakeProxy()
		}
		else {
			IPtProxyStartSnowflakeProxy(1, nil, nil, nil, nil,
										FileManager.default.sfpLogFile?.truncate().path,
										false, false, selfInstance)
		}

		NotificationCenter.default.post(name: .vpnStatusChanged, object: nil)
	}

	static func smartConnectButtonLabel(buttonFontSize: CGFloat? = nil) -> NSMutableAttributedString {
		buttonTitleWithSubtitle(
			NSLocalizedString("Start", comment: ""),
			NSLocalizedString("Use Smart Connect", comment: ""),
			subtitleSize: (buttonFontSize ?? 16) * 0.5)
	}

	static func updateUi(_ notification: Notification? = nil, buttonFontSize: CGFloat? = nil) -> (
		statusIcon: String,
		buttonTitle: NSMutableAttributedString,
		statusText: NSMutableAttributedString,
		statusSubtext: String,
		sfpText: String
	) {
		let statusIcon: String
		let buttonTitle: NSMutableAttributedString
		var statusText: NSMutableAttributedString
		var statusSubtext = NSLocalizedString("Hide apps from network monitoring and get access when they are blocked.", comment: "")

		let transport = Settings.transport

		switch VpnManager.shared.status {
		case .connected:
			statusIcon = Settings.onionOnly ? .imgOrbieOnionOnly : .imgOrbieOn
			buttonTitle = NSMutableAttributedString(string: NSLocalizedString("Stop", comment: ""))

		case .evaluating, .connecting, .reasserting:
			statusIcon = .imgOrbieStarting
			buttonTitle = NSMutableAttributedString(string: NSLocalizedString("Stop", comment: ""))

		case .notInstalled, .invalid, .unknown:
			statusIcon = .imgOrbieDead
			buttonTitle = NSMutableAttributedString(string: NSLocalizedString("Install", comment: ""))

		default:
			statusIcon = .imgOrbieOff

			let subtitle: String

			if Settings.smartConnect {
				subtitle = NSLocalizedString("Use Smart Connect", comment: "")
			}
			else if transport == .none {
				subtitle = NSLocalizedString("Use Direct Connection", comment: "")
			}
			else {
				subtitle = String(format: NSLocalizedString("Use %1$@", comment: ""), transport.description)
			}

			buttonTitle = buttonTitleWithSubtitle(
				NSLocalizedString("Start", comment: ""), subtitle,
				subtitleSize: (buttonFontSize ?? 16) * 0.5)
		}

		if let error = VpnManager.shared.error {
			statusText = NSMutableAttributedString(string: error.localizedDescription,
												   attributes: [.foregroundColor: Color.systemRed])
		}
		else {
			statusText = NSMutableAttributedString(string: VpnManager.shared.status.description)

			if VpnManager.shared.isConnected {
				if notification?.name == .vpnProgress,
				   let raw = notification?.object as? Float,
				   let progress = Formatters.formatPercent(raw)
				{
					statusText.append(NSAttributedString(string: " "))
					statusText.append(NSAttributedString(string: progress))
				}

				if VpnManager.shared.status == .evaluating {
					statusSubtext = NSLocalizedString("Asking Tor Project's Circumvention Service", comment: "")
				}
				else if transport == .none {
					statusSubtext = NSLocalizedString("Use Direct Connection", comment: "")
				}
				else {
					statusSubtext = String(format: NSLocalizedString("Use %1$@", comment: ""),
										   transport.description)
				}

				if Settings.onionOnly {
					statusSubtext.append("\n")
					statusSubtext.append(NSLocalizedString("Onion-only Mode", comment: ""))
				}
				else if Settings.bypassPort != nil {
					statusSubtext.append("\n")
					statusSubtext.append(NSLocalizedString("Bypass", comment: ""))
				}
			}
		}

		let sfpText = String(
			format: IPtProxyIsSnowflakeProxyRunning() ? L10n.snowflakeProxyStarted : L10n.snowflakeProxyStopped,
			Formatters.format(Settings.snowflakesHelped))

		return (statusIcon, buttonTitle, statusText, statusSubtext, sfpText)
	}

	static func getCircuits(_ completed: @escaping (_ text: String) -> Void) {
		VpnManager.shared.getCircuits { circuits, error in
			let circuits = TorCircuit.filter(circuits)

			var text = ""

			var i = 1

			for c in circuits {
				text += "Circuit \(c.circuitId ?? String(i))\n"

				var j = 1

				for n in c.nodes ?? [] {
					var country = n.localizedCountryName ?? n.countryCode ?? ""

					if !country.isEmpty {
						country = " (\(country))"
					}

					text += "\(j): \(n.nickName ?? n.fingerprint ?? n.ipv4Address ?? n.ipv6Address ?? "unknown node")\(country)\n"

					j += 1
				}

				text += "\n"

				i += 1
			}

			completed(text)
		}
	}

	static func clearTorCache() {
		let fm = FileManager.default

		guard let torDir = fm.torDir,
			  let enumerator = fm.enumerator(at: torDir, includingPropertiesForKeys: [.isDirectoryKey])
		else {
			return
		}

		for case let file as URL in enumerator {
			if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false {
				if file == fm.torAuthDir {
					enumerator.skipDescendants()
				}

				continue
			}

			do {
				try fm.removeItem(at: file)

				print("File deleted: \(file.path)")
			}
			catch {
				print("File could not be deleted: \(file.path)")
			}
		}
	}


#if DEBUG
	static func addScreenshotDummies() {
		guard Config.screenshotMode, let authDir = FileManager.default.torAuthDir else {
			return
		}

		do {
			try "6gk626a5xm3gdyrbezfhiptzegvvc62c3k6y3xbelglgtgqtbai5liqd:descriptor:x25519:EJOYJMYKNS6TYTQ2RSPZYBSBR3RUZA5ZKARKLF6HXVXHTIV76UCQ"
				.write(to: authDir.appendingPathComponent("6gk626a5xm3gdyrbezfhiptzegvvc62c3k6y3xbelglgtgqtbai5liqd.auth_private"),
					   atomically: true, encoding: .utf8)

			try "jtb2cwibhkok4f2xejfqbsjb2xcrwwcdj77bjvhofongraxvumudyoid:descriptor:x25519:KC2VJ5JLZ5QLAUUZYMRO4R3JSOYM3TBKXDUMAS3D5BEI5IPYUI4A"
				.write(to: authDir.appendingPathComponent("jtb2cwibhkok4f2xejfqbsjb2xcrwwcdj77bjvhofongraxvumudyoid.auth_private"),
					   atomically: true, encoding: .utf8)

			try "pqozr7dey5yellqfwzjppv4q25zbzbwligib7o7g5s6bvrltvy3lfdid:descriptor:x25519:ZHXT5IO2OMJKH3HKPDYDNNXXIPJCXR5EG6MGLQNC56GAF2C75I5A"
				.write(to: authDir.appendingPathComponent("pqozr7dey5yellqfwzjppv4q25zbzbwligib7o7g5s6bvrltvy3lfdid.auth_private"),
					   atomically: true, encoding: .utf8)
		}
		catch {
			print(error)
		}
	}
#endif


	// MARK: Private Methods

	private static func buttonTitleWithSubtitle(_ title: String, _ subtitle: String, subtitleSize: CGFloat) -> NSMutableAttributedString {
		let label = NSMutableAttributedString(string: String(format: "%@\n", title),
											  attributes: [.paragraphStyle: centered])

		label.append(NSAttributedString(string: subtitle,
										attributes: [.paragraphStyle: centered,
													 .font: Font.systemFont(ofSize: subtitleSize)]))

		return label
	}
}
