import Foundation
import ArgumentParser
import Vision
import AppKit

@main
struct MacOCR: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A CLI tool to extract text from images using macOS Vision framework."
    )

    @Argument(help: "The path to the image file to OCR.")
    var imagePath: String

    @Flag(name: .shortAndLong, help: "Use fast recognition level (less accurate).")
    var fast: Bool = false

    mutating func run() throws {
        let expandedPath = NSString(string: imagePath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw ValidationError("File does not exist at path: \(imagePath)")
        }

        guard let image = NSImage(contentsOf: url) else {
            throw ValidationError("Could not load image at path: \(imagePath)")
        }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ValidationError("Could not convert image to CGImage.")
        }

        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        let request = VNRecognizeTextRequest { (request, error) in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }
            
            let recognizedStrings = observations.compactMap { observation in
                // Return the top candidate
                return observation.topCandidates(1).first?.string
            }
            
            print(recognizedStrings.joined(separator: "\n"))
        }

        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = true
        // Default to English if not specified, though it usually auto-detects or uses system defaults.
        // request.recognitionLanguages = ["en-US"]

        do {
            try requestHandler.perform([request])
        } catch {
            print("Error performing OCR: \(error)")
            throw ExitCode.failure
        }
    }
}