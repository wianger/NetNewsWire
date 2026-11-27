//
//  RSScreen.swift
//  RSCore
//
//  Created by Maurice Parker on 4/11/19.
//  Copyright © 2019 Ranchero Software. All rights reserved.
//

#if os(macOS)
import AppKit

public final class RSScreen {

	public static var maxScreenScale: CGFloat {
		NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0
	}
}

#endif

#if os(iOS)
import UIKit

public final class RSScreen {
	nonisolated public static let maxScreenScale = CGFloat(3)
}

#endif

#if os(Windows)
import Foundation
import WinSDK

public final class RSScreen {

	/// The highest display scale among connected monitors, as macOS's backingScaleFactor.
	/// Correct only in a per-monitor DPI aware process, as WinUI apps are; otherwise 1.
	nonisolated public static var maxScreenScale: CGFloat {
		var maxDPI: UINT = 0
		withUnsafeMutablePointer(to: &maxDPI) { maxDPIPointer in
			_ = EnumDisplayMonitors(nil, nil, { monitor, _, _, context in
				var dpiX: UINT = 0
				var dpiY: UINT = 0
				if let monitor, let maxDPIPointer = UnsafeMutablePointer<UINT>(bitPattern: Int(context)), GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY) >= 0 {
					maxDPIPointer.pointee = max(maxDPIPointer.pointee, dpiX)
				}
				return true
			}, LPARAM(Int(bitPattern: maxDPIPointer)))
		}
		guard maxDPI > 0 else {
			return 2.0
		}
		return CGFloat(maxDPI) / CGFloat(USER_DEFAULT_SCREEN_DPI)
	}
}

#endif
