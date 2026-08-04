//
//  GlobalModel.swift
//  iMonitor
//
//  Created by f.zou on 2021/5/30.
//

import Foundation

enum ViewMode: String, CaseIterable {
    case process = "Process"
    case ip = "IP"

    var displayName: String { rawValue }
}

class GlobalModel: ObservableObject {
    @Published var viewShowing: Bool = false
    @Published var controllerHaveBeenReleased: Bool = true
    @Published var isSleepDeep = false
    /// Which list the popover shows: per-process (default) or per-remote-IP.
    @Published var viewMode: ViewMode = .process
}
