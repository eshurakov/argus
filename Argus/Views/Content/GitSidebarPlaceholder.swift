// GitSidebarPlaceholder.swift
// Argus
//
// Placeholder view for the right side panel.
// Will be replaced with a full implementation in Phase 3.

import SwiftUI

struct GitSidebarPlaceholder: View {
    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary.opacity(0.5))
                .accessibilityHidden(true)
            Text("Changes")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text("Coming in Phase 3")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.6))
            Spacer()
        }
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
    }
}
