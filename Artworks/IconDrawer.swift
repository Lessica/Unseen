//
//  IconDrawer.swift
//

// swiftc -parse-as-library IconDrawer.swift
// ./IconDrawer

import AppKit
import SwiftUI

let previewSize = CGSize(width: 1024, height: 1024)
let symbolWidth: CGFloat = 650
let iconCornerRadius: CGFloat = 1024 * 0.2237

struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous)
                .fill(
                LinearGradient(
                    gradient: Gradient(colors: [
                        // #9b1b3f, #ff7a59
                        .init(red: 155 / 255, green: 27 / 255, blue: 63 / 255),
                        .init(red: 255 / 255, green: 122 / 255, blue: 89 / 255),
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Image(systemName: "eyebrow")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: symbolWidth, height: symbolWidth)
                .font(.system(size: symbolWidth, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .opacity(0.9)
        }
        .frame(width: previewSize.width, height: previewSize.height, alignment: .center)
    }
}

@main
struct IconDrawer {
    @MainActor
    static func main() {
        let scriptURL = URL(fileURLWithPath: #filePath)
        let defaultOutputURL = scriptURL.deletingLastPathComponent().appendingPathComponent("AppIcon.png")
        let outputURL = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) } ?? defaultOutputURL

        let renderer = ImageRenderer(content: AppIconView())
        renderer.proposedSize = ProposedViewSize(previewSize)
        renderer.scale = 1

        guard let image = renderer.nsImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            fputs("Failed to render AppIcon.png\n", stderr)
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
