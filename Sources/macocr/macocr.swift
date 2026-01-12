import Foundation
import ArgumentParser
import Vision
import AppKit

@main
struct MacOCR: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A CLI tool to extract text from images using macOS Vision framework."
    )

    @Argument(help: "The path to the image file to OCR. If omitted, reads from stdin.")
    var imagePath: String?

    @Flag(name: .shortAndLong, help: "Use fast recognition level (less accurate).")
    var fast: Bool = false

    // TODO: --fix flag not working correctly - spell checker integration needs debugging
    @Flag(name: .long, help: "Use macOS spell checker to clean up the text result.")
    var fix: Bool = false

    mutating func run() throws {
        let nsImage: NSImage

        if let path = imagePath {
            let expandedPath = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)

            guard FileManager.default.fileExists(atPath: expandedPath) else {
                throw ValidationError("File does not exist at path: \(path)")
            }

            guard let img = NSImage(contentsOf: url) else {
                throw ValidationError("Could not load image at path: \(path)")
            }
            nsImage = img
        } else {
            // Check if stdin is a terminal.
            if isatty(FileHandle.standardInput.fileDescriptor) == 1 {
                // If no file path and interactive terminal, show help or error
                throw CleanExit.helpRequest()
            }
            
            // Read from stdin
            guard let data = try FileHandle.standardInput.readToEnd(),
                  let img = NSImage(data: data) else {
                throw ValidationError("Could not read valid image data from stdin.")
            }
            nsImage = img
        }

        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ValidationError("Could not convert image to CGImage.")
        }

        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        let shouldFix = self.fix

        let request = VNRecognizeTextRequest { (request, error) in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }
            
            var recognizedStrings = observations.compactMap { observation in
                // Return the top candidate
                return observation.topCandidates(1).first?.string
            }
            
            if shouldFix {
                recognizedStrings = recognizedStrings.map { MacOCR.correctText($0) }
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

    static func correctText(_ text: String) -> String {
        let checker = NSSpellChecker.shared
        var correctedText = text
        
        // We find all misspellings first
        var offset = 0
        
        var foundRanges: [NSRange] = []
        
        while true {
            let misspelledRange = checker.checkSpelling(of: correctedText, startingAt: offset)
            if misspelledRange.location == NSNotFound || misspelledRange.location >= correctedText.utf16.count {
                break
            }
            foundRanges.append(misspelledRange)
            offset = misspelledRange.location + misspelledRange.length
        }
        
        // Now apply fixes backwards
        for range in foundRanges.reversed() {
             guard let guesses = checker.guesses(forWordRange: range, in: correctedText, language: nil, inSpellDocumentWithTag: 0),
                   let topGuess = guesses.first else {
                 continue
             }
             
             if let swiftRange = Range(range, in: correctedText) {
                 correctedText.replaceSubrange(swiftRange, with: topGuess)
             }
        }
        
        return correctedText
    }
}