//
//  IconDrawer.swift
//

// swiftc -parse-as-library IconDrawer.swift
// ./IconDrawer

import AppKit
import SwiftUI

struct IconPreset {
    let canvasSize: CGSize
    let precutCornerRadius: CGFloat?
    let defaultFileName: String

    var symbolWidth: CGFloat {
        canvasSize.width * (650 / 1024)
    }

    static let appIcon = IconPreset(
        canvasSize: CGSize(width: 1024, height: 1024),
        precutCornerRadius: 1024 * 0.2237,
        defaultFileName: "AppIcon.png"
    )

    static let projectIcon = IconPreset(
        canvasSize: CGSize(width: 240, height: 240),
        precutCornerRadius: nil,
        defaultFileName: "ProjectIcon.png"
    )
}

struct AppIconView: View {
    let preset: IconPreset

    var body: some View {
        ZStack {
            iconBackground

            Image(systemName: "eyebrow")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: preset.symbolWidth, height: preset.symbolWidth)
                .font(.system(size: preset.symbolWidth, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .opacity(0.9)
        }
        .frame(width: preset.canvasSize.width, height: preset.canvasSize.height, alignment: .center)
    }

    @ViewBuilder
    private var iconBackground: some View {
        if let cornerRadius = preset.precutCornerRadius {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(backgroundGradient)
        } else {
            Rectangle()
                .fill(backgroundGradient)
        }
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [
                // #9b1b3f, #ff7a59
                .init(red: 155 / 255, green: 27 / 255, blue: 63 / 255),
                .init(red: 255 / 255, green: 122 / 255, blue: 89 / 255),
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

@main
struct IconDrawer {
    @MainActor
    static func main() {
        let scriptURL = URL(fileURLWithPath: #filePath)
        let arguments = Array(CommandLine.arguments.dropFirst())
        let preset: IconPreset
        let outputPath: String?

        if arguments.first == "--project-icon" {
            preset = .projectIcon
            outputPath = arguments.dropFirst().first
        } else {
            preset = .appIcon
            outputPath = arguments.first
        }

        let defaultOutputURL = scriptURL.deletingLastPathComponent().appendingPathComponent(preset.defaultFileName)
        let outputURL = outputPath.map { URL(fileURLWithPath: $0) } ?? defaultOutputURL

        let renderer = ImageRenderer(content: AppIconView(preset: preset))
        renderer.proposedSize = ProposedViewSize(preset.canvasSize)
        renderer.scale = 1

        guard let image = renderer.nsImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            fputs("Failed to render \(preset.defaultFileName)\n", stderr)
            exit(1)
        }

        do {
            try pngData.write(to: outputURL)
            print(outputURL.path)
        } catch {
            fputs("Failed to write \(outputURL.path): \(error)\n", stderr)
            exit(1)
        }
    }
}
