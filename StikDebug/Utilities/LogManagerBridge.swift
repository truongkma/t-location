//
//  LogManagerBridge.swift
//  StikDebug
//
//  Created by neoarz on 3/29/25.
//

import Foundation
//objc bridge for logs
@objc class LogManagerBridge: NSObject {
    @objc static let shared = LogManagerBridge()
    
    private override init() {
        super.init()
    }
    
    @objc func addInfoLog(_ message: String) {
        LogManager.shared.addInfoLog(message)
    }
    
    @objc func addErrorLog(_ message: String) {
        LogManager.shared.addErrorLog(message)
    }
    
    @objc func addDebugLog(_ message: String) {
        LogManager.shared.addDebugLog(message)
    }
    
    @objc func addWarningLog(_ message: String) {
        LogManager.shared.addWarningLog(message)
    }
} 
