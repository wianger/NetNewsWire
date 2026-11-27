//
//  CoreAPI.swift
//  NetNewsWireCore
//
//  The C ABI exported to the Windows app. It is deliberately tiny: one request entry
//  point carrying a method name and JSON params, one event callback, and lifecycle
//  calls. Every feature goes through `nnw_request`, so adding one never changes the
//  ABI or the P/Invoke declarations. The methods are in CoreService.
//
//  Threading: call everything on the UI thread, which owns the Swift main queue
//  (see MainQueueBridge.swift). Callbacks run there too.
//
//  Memory: strings passed in are copied before the call returns. Every `char *`
//  passed to a callback or returned belongs to the caller, who frees it with
//  `nnw_string_free`.
//

import Foundation
import CoreService

/// `callback(context, json)`.
public typealias NNWCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?) -> Void

@c(nnw_core_version)
public func coreVersion() -> UnsafeMutablePointer<CChar>? {
	makeCString(CoreService.version)
}

@c(nnw_string_free)
public func stringFree(_ string: UnsafeMutablePointer<CChar>?) {
	string?.deallocate()
}

@c(nnw_is_main_thread)
public func isMainThread() -> Bool {
	Thread.isMainThread
}

/// Starts the core: opens the accounts and begins calling `eventCallback(eventContext, json)`
/// with `CoreEvent` JSON. Returns false if called twice or off the main thread.
@c(nnw_core_start)
public func coreStart(_ eventContext: UnsafeMutableRawPointer?, _ eventCallback: NNWCallback?) -> Bool {
	guard Thread.isMainThread, let eventCallback else {
		return false
	}
	let events = CallbackBox(context: eventContext, callback: eventCallback)
	return MainActor.assumeIsolated {
		guard CoreHost.service == nil else {
			return false
		}
		let service = CoreService { event in
			events.call(CoreService.eventJSON(event))
		}
		// The themes that ship with the app are in Themes next to the exe (see the csproj).
		if let executable = CommandLine.arguments.first {
			service.appThemesFolder = URL(filePath: executable).deletingLastPathComponent().appending(path: "Themes", directoryHint: .isDirectory)
		}
		CoreHost.service = service
		service.start()
		return true
	}
}

/// Runs `method` with `paramsJSON` (a JSON object, or null for none), then calls
/// `callback(context, responseJSON)` exactly once with `{"result": …}` or `{"error": …}`.
@c(nnw_request)
public func request(_ method: UnsafePointer<CChar>?, _ paramsJSON: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?, _ callback: NNWCallback?) {
	guard let callback else {
		return
	}
	let reply = CallbackBox(context: context, callback: callback)
	let methodName = method.map { String(cString: $0) } ?? ""
	let params = paramsJSON.map { Data(String(cString: $0).utf8) }

	Task { @MainActor in
		guard let service = CoreHost.service else {
			reply.call(#"{"error":{"code":"notStarted","message":"Call nnw_core_start first."}}"#)
			return
		}
		let response = await service.handle(method: methodName, params: params)
		reply.call(String(decoding: response, as: UTF8.self))
	}
}

// MARK: - Private

@MainActor private enum CoreHost {
	static var service: CoreService?
}

/// The host's context pointer and callback. The host keeps the context alive until called back.
private struct CallbackBox: @unchecked Sendable {
	let context: UnsafeMutableRawPointer?
	let callback: NNWCallback

	func call(_ json: String) {
		callback(context, makeCString(json))
	}
}

func makeCString(_ string: String) -> UnsafeMutablePointer<CChar>? {
	let utf8 = Array(string.utf8CString)
	let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
	buffer.initialize(from: utf8, count: utf8.count)
	return buffer
}
