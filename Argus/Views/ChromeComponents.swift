// ChromeComponents.swift
// Argus
//
// Shared empty, error, and unavailable message treatment for content
// surfaces, plus the compact count badge used in chrome.

import SwiftUI

struct CountBadge: View {
    let count: Int
    var prominent: Bool = false
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        Text("\(count)")
            .font(
                .system(
                    size: appSettings.presentationMetrics.textSize(forBaseSize: 11),
                    weight: .semibold,
                    design: .monospaced
                )
            )
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                Capsule()
                    .fill(Color.primary.opacity(prominent ? 0.11 : 0.07))
            }
    }
}

struct SurfaceMessageView: View {
    let systemImage: String
    let title: String
    var tint: Color?
    var path: String?
    var detail: String?
    var warning: String?
    var actionTitle: String?
    var actionHelp: String?
    var actionAccessibilityValue: String = ""
    var actionDisabled: Bool = false
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(tint ?? Color.secondary.opacity(0.5))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            if let path {
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            if let warning {
                Text(warning)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(actionDisabled)
                    .help(actionHelp ?? "")
                    .accessibilityValue(actionAccessibilityValue)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
