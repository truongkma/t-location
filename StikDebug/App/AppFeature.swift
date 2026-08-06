//
//  AppFeature.swift
//  StikDebug
//

import SwiftUI

enum AppFeature: String, CaseIterable, Identifiable {
    case home
    case scripts
    case tools
    case location
    case settings

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .home:
            return "Apps"
        case .scripts:
            return "Scripts"
        case .tools:
            return "Tools"
        case .location:
            return "Location"
        case .settings:
            return "Settings"
        }
    }

    var detail: String {
        switch self {
        case .home:
            return "Manage installed apps"
        case .scripts:
            return "Manage and run JS scripts"
        case .tools:
            return "Access additional tools"
        case .location:
            return "Simulate GPS location"
        case .settings:
            return "Configure StikDebug"
        }
    }

    var toolTitle: String {
        switch self {
        case .location:
            return "Location Simulation"
        default:
            return title
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            return "square.grid.2x2"
        case .scripts:
            return "scroll"
        case .tools:
            return "wrench.and.screwdriver"
        case .location:
            return "location"
        case .settings:
            return "gearshape.fill"
        }
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .home:
            HomeView()
        case .scripts:
            ScriptListView()
        case .tools:
            ToolsView()
        case .location:
            LocationSimulationView()
        case .settings:
            SettingsView()
        }
    }
}

extension AppFeature {
    static let mainTabs: [AppFeature] = [.home, .tools, .settings]
    static let toolList: [AppFeature] = [.scripts, .location]
}
