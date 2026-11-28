//
//  Blocks.swift
//  RSCore
//
//  Created by Brent Simmons on 11/29/19.
//  Copyright © 2019 Ranchero Software, LLC. All rights reserved.
//

import Foundation

public typealias VoidBlock = @Sendable () -> Void
public typealias VoidCompletionBlock = VoidBlock

#if os(macOS) || os(iOS) || os(Windows)
public typealias ImageResultBlock = @MainActor (RSImage?) -> Void
#endif
