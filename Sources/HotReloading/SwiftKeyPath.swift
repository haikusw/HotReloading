//
//  SwiftKeyPath.swift
//
//  Created by John Holdsworth on 20/03/2024.
//  Copyright © 2024 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloading/SwiftKeyPath.swift#21 $
//

import Foundation
import SwiftTrace
#if SWIFT_PACKAGE
import SwiftTraceGuts
import HotReloadingGuts
#endif

var keyPaths = [String: (offset: Int, keyPath: UnsafeRawPointer)]()
var callOffsets = [String: Int]()
var callIndexes = [String: Int]()
var lastInjectionNumber = 0

typealias KeyPathFunc = @convention(c) (UnsafeMutableRawPointer,
                                        UnsafeRawPointer) -> UnsafeRawPointer

let keyPathFuncName = "swift_getKeyPath"
var save_getKeyPath: KeyPathFunc!

@_cdecl("hookKeyPaths")
public func hookKeyPaths() {
    guard let original = dlsym(SwiftMeta.RTLD_DEFAULT, keyPathFuncName) else {
        print("⚠️ Could not find original symbol: \(keyPathFuncName)")
        return
    }
    guard let replacer = dlsym(SwiftMeta.RTLD_DEFAULT, "injection_getKeyPath") else {
        print("⚠️ Could not find replacement symbol: injection_getKeyPath")
        return
    }
    save_getKeyPath = autoBitCast(original)
    var keyPathRebinding = [rebinding(name: strdup(keyPathFuncName),
                                      replacement: replacer, replaced: nil)]
    SwiftInjection.initialRebindings += keyPathRebinding
    _ = SwiftTrace.apply(rebindings: &keyPathRebinding)
}

@_cdecl("injection_getKeyPath")
public func injection_getKeyPath(pattern: UnsafeMutableRawPointer,
                                 arguments: UnsafeRawPointer) -> UnsafeRawPointer {
    var info = Dl_info()
    for caller in Thread.callStackReturnAddresses.dropFirst() {
        guard let caller = caller.pointerValue,
              dladdr(caller, &info) != 0, let symbol = info.dli_sname,
              let callsym = SwiftMeta.demangle(symbol: symbol) else {
            continue
        }
//        print(callsym)
        if !callsym.hasSuffix(".body.getter : some") {
            break
        }
        let offset = caller-info.dli_saddr
        if let last = callOffsets[callsym] {
            if offset <= last {
                callIndexes[callsym] = 0
            }
        } else {
            callIndexes[callsym] = 0
        }
        callOffsets[callsym] = offset
        let callIndex = callIndexes[callsym, default: 0]
//        print(offset, callIndex)
        let callBase = callsym.replacingOccurrences(of: "<.*?>",
            with: "<>", options: .regularExpression) + ".keyPath#"
        func callKey(shift: Int = 0) -> String {
            return callBase+"\(callIndex+shift)"
        }
        let keyPath: UnsafeRawPointer
        if let (_, prev) = keyPaths[callKey()] {
//            if let (nextset, next) = keyPaths[callKey(shift: 1)],
//               offset == nextset {
//                print("Skipping")
//                callIndex += 1
//                prev = next
//            }
            SwiftInjection.detail("Recycling \(callKey())")
            keyPath = prev
        } else {
            keyPath = save_getKeyPath(pattern, arguments)
            keyPaths[callKey()] = (offset, keyPath)
        }
        _ = Unmanaged<AnyKeyPath>.fromOpaque(keyPath).retain()
        callIndexes[callsym] = callIndex+1
        return keyPath
    }
    return save_getKeyPath(pattern, arguments)
}
