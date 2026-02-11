//
//  Toast.swift
//  Collectly
//
//  Created by Eric Chandonnet on 2026-01-15.
//
import SwiftUI
import UIKit

// MARK: - Toast Model

struct Toast: Identifiable, Equatable {
    enum Style {
        case success, info, error
    }

    let id = UUID()
    let style: Style
    let title: String
    let systemImage: String?
    let duration: TimeInterval

    init(style: Style, title: String, systemImage: String? = nil, duration: TimeInterval = 2.0) {
        self.style = style
        self.title = title
        self.systemImage = systemImage
        self.duration = duration
    }
}

// MARK: - Toast View

private struct ToastView: View {
    let toast: Toast

    private var accentColor: Color {
        switch toast.style {
        case .success: return .green
        case .info: return .blue
        case .error: return .red
        }
    }

    private var backgroundOpacity: Double {
        switch toast.style {
        case .success: return 0.22
        case .info: return 0.18
        case .error: return 0.22
        }
    }

    var body: some View {
        HStack(spacing: 10) {

            if let sf = toast.systemImage {
                Image(systemName: sf)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accentColor)
            }

            Text(toast.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule().fill(accentColor.opacity(backgroundOpacity))
                )
        )
        .overlay(
            Capsule().stroke(accentColor.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - ViewModifier

struct ToastModifier: ViewModifier {
    @Binding var toast: Toast?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast {
                    ToastView(toast: toast)
                        .padding(.top, 10)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()

                            DispatchQueue.main.asyncAfter(deadline: .now() + toast.duration) {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                    self.toast = nil
                                }
                            }
                        }
                        .zIndex(999)
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: toast)
    }
}

extension View {
    func toast(_ toast: Binding<Toast?>) -> some View {
        self.modifier(ToastModifier(toast: toast))
    }
}

// MARK: - Haptics helpers

enum Haptic {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

