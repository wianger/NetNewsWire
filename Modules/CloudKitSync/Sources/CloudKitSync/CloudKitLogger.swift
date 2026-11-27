//
//  CloudKitLogger.swift
//  RSCore
//
//  Created by Brent Simmons on 10/2/25.
//

import Foundation
import RSCore
#if canImport(os)
import os
#endif

public let cloudKitLogger = Logger(subsystem: Logger.nnwSubsystem, category: "CloudKit")
