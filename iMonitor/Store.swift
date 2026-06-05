//
//  Store.swift
//  iMonitor
//
//  Created by f.zou on 2021/5/23.
//

import SwiftUI

enum SharedStore {
    static let listViewModel = ListViewModel()
    static let statusDataModel = StatusDataModel()
    static let systemDataModel = SystemDataModel()
    static let globalModel = GlobalModel()
    static let themeModel = ThemeModel()
}

extension View {
    func withGlobalEnvironmentObjects() -> some View {
        environmentObject(SharedStore.listViewModel)
        .environmentObject(SharedStore.statusDataModel)
        .environmentObject(SharedStore.systemDataModel)
        .environmentObject(SharedStore.globalModel)
        .environmentObject(SharedStore.themeModel)
    }
}
