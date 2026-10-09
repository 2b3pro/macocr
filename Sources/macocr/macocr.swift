import Foundation
import ArgumentParser
import Vision
import AppKit
import CoreGraphics
import PDFKit

enum OCRInput {
    case image(NSImage)
    case pdf(PDFDocument)
}

@main
struct MacOCR: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macocr",
        abstract: "A CLI tool to extract text from images and PDFs using macOS Vision framework.",
        version: "0.2.0"
    )

    // Pages are rendered at this resolution, with the longest side capped to bound memory.
    static let pdfRenderDPI: CGFloat = 300
    static let pdfMaxPixelDimension: CGFloat = 8000

    @Argument(help: "The path to an image or PDF file. If omitted, reads image or PDF data from stdin.")
    var inputPath: String?

    @Flag(name: .shortAndLong, help: "Use fast recognition level (less accurate).")
    var fast: Bool = false

    @Flag(name: .shortAndLong, help: "OCR an image from the clipboard.")
    var clipboard: Bool = false

    @Flag(name: .shortAndLong, help: "Capture the screen and OCR the captured image.")
    var screen: Bool = false

    @Option(name: [.customShort("R"), .long], help: "Capture rectangle as x,y,width,height (requires --screen).")
    var rect: String?

    @Option(name: .long, help: "Save the captured screen image as PNG, JPEG, or TIFF (requires --screen).")
    var saveImage: String?

    @Option(name: .shortAndLong, help: "Recognition language identifier, such as en-US.")
    var language: String?

    @Flag(name: .long, help: "List supported recognition languages and exit.")
    var listLanguages: Bool = false

    @Flag(name: .long, help: "Copy recognized text to the clipboard instead of printing it.")
    var copy: Bool = false

    @Option(name: .shortAndLong, help: "PDF pages to OCR, such as 1-3,7 or 5- (default: all pages).")
    var pages: String?

    @Flag(name: .long, help: "For PDFs, use a page's embedded text layer when it has one, and OCR only pages without one.")
    var textLayer: Bool = false

    // TODO: --fix flag not working correctly - spell checker integration needs debugging
    @Flag(name: .long, help: "Use macOS spell checker to clean up the text result.")
    var fix: Bool = false

    @Flag(name: .long, help: "Clean up recognized text with Apple's on-device language model (macOS 26.4+ with Apple Intelligence). Slower; any part whose cleanup drops or changes content keeps its original text.")
    var cleanup: Bool = false

    mutating func run() async throws {
        if listLanguages {
            let recognitionLevel: VNRequestTextRecognitionLevel = fast ? .fast : .accurate
            let languages = try VNRecognizeTextRequest.supportedRecognitionLanguages(
                for: recognitionLevel,
                revision: VNRecognizeTextRequest.currentRevision
            )
            print(languages.sorted().joined(separator: "\n"))
            return
        }

        let selectedInputCount = [clipboard, screen, inputPath != nil].filter { $0 }.count
        guard selectedInputCount <= 1 else {
            throw ValidationError("Specify only one input: an image or PDF path, --clipboard, or --screen.")
        }
        guard rect == nil || screen else {
            throw ValidationError("--rect requires --screen.")
        }
        guard saveImage == nil || screen else {
            throw ValidationError("--save-image requires --screen.")
        }
        let usesPDFOptions = pages != nil || textLayer
        guard !usesPDFOptions || !(screen || clipboard) else {
            throw ValidationError("--pages and --text-layer require a PDF input.")
        }

        // Check the model before doing any OCR work.
        let cleanText = cleanup ? try MacOCR.makeCleaner() : nil

        let input: OCRInput

        if screen {
            let nsImage = try MacOCR.captureScreen(rect: rect)
            if let saveImage {
                try MacOCR.save(nsImage, to: saveImage)
            }
            input = .image(nsImage)
        } else if clipboard {
            guard let img = NSImage(pasteboard: .general) else {
                throw ValidationError("The clipboard does not contain a valid image.")
            }
            input = .image(img)
        } else if let path = inputPath {
            let expandedPath = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)

            guard FileManager.default.fileExists(atPath: expandedPath) else {
                throw ValidationError("File does not exist at path: \(path)")
            }

            if MacOCR.isPDF(fileAt: url) {
                input = .pdf(try MacOCR.openPDF(PDFDocument(url: url), source: path))
            } else {
                guard let img = NSImage(contentsOf: url) else {
                    throw ValidationError("Could not load image at path: \(path)")
                }
                input = .image(img)
            }
        } else {
            // Check if stdin is a terminal.
            if isatty(FileHandle.standardInput.fileDescriptor) == 1 {
                // If no file path and interactive terminal, show help or error
                throw CleanExit.helpRequest()
            }

            // Read from stdin
            guard let data = try FileHandle.standardInput.readToEnd() else {
                throw ValidationError("Could not read valid image or PDF data from stdin.")
            }
            if MacOCR.isPDF(data) {
                input = .pdf(try MacOCR.openPDF(PDFDocument(data: data), source: "stdin"))
            } else {
                guard let img = NSImage(data: data) else {
                    throw ValidationError("Could not read valid image or PDF data from stdin.")
                }
                input = .image(img)
            }
        }

        switch input {
        case .image(let nsImage):
            guard !usesPDFOptions else {
                throw ValidationError("--pages and --text-layer require a PDF input.")
            }
            guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ValidationError("Could not convert image to CGImage.")
            }
            var text = try recognizeText(in: cgImage)
            if let cleanText {
                text = await cleanText(text, "the image")
            }
            try deliver(text)

        case .pdf(let document):
            // Pages are separated by a form feed, as pdftotext does.
            let pageNumbers = try MacOCR.parsePages(pages, pageCount: document.pageCount)
            var pageTexts: [String] = []
            for (index, pageNumber) in pageNumbers.enumerated() {
                var text = try autoreleasepool { try self.text(ofPage: pageNumber, in: document) }
                if let cleanText {
                    text = await cleanText(text, "page \(pageNumber)")
                }
                if copy {
                    pageTexts.append(text)
                } else {
                    // Stream each page as it finishes so long documents show progress.
                    print((index > 0 ? "\u{0C}" : "") + text)
                    fflush(stdout)
                }
            }
            if copy {
                try deliver(pageTexts.joined(separator: "\n\u{0C}"))
            }
        }
    }

    func text(ofPage pageNumber: Int, in document: PDFDocument) throws -> String {
        guard let page = document.page(at: pageNumber - 1) else {
            throw ValidationError("Could not read page \(pageNumber) of the PDF.")
        }
        if textLayer,
           let embedded = page.string,
           !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return embedded
        }
        do {
            return try recognizeText(in: MacOCR.render(page))
        } catch let error as ValidationError {
            throw ValidationError("Page \(pageNumber): \(error.message)")
        }
    }

    func recognizeText(in cgImage: CGImage) throws -> String {
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()

        request.revision = VNRecognizeTextRequest.currentRevision
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = true
        if let language {
            request.recognitionLanguages = [language]
        }

        do {
            try requestHandler.perform([request])
        } catch {
            throw ValidationError("Error performing OCR: \(error.localizedDescription)")
        }

        guard let observations = request.results else {
            throw ValidationError("OCR completed without a readable result.")
        }

        var recognizedStrings = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        if fix {
            recognizedStrings = recognizedStrings.map { MacOCR.correctText($0) }
        }

        return recognizedStrings.joined(separator: "\n")
    }

    func deliver(_ recognizedText: String) throws {
        if copy {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(recognizedText, forType: .string) else {
                throw ValidationError("Could not copy recognized text to the clipboard.")
            }
        } else {
            print(recognizedText)
        }
    }

    // The PDF spec allows the header anywhere in the first 1024 bytes.
    static func isPDF(_ data: Data) -> Bool {
        data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    static func isPDF(fileAt url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        return isPDF(handle.readData(ofLength: 1024))
    }

    static func openPDF(_ document: PDFDocument?, source: String) throws -> PDFDocument {
        guard let document else {
            throw ValidationError("Could not read PDF from \(source).")
        }
        // Documents with only an owner password open with an empty user password.
        if document.isLocked && !document.unlock(withPassword: "") {
            throw ValidationError("The PDF from \(source) is password-protected.")
        }
        guard document.pageCount > 0 else {
            throw ValidationError("The PDF from \(source) has no pages.")
        }
        return document
    }

    /// Parses a 1-based page list such as "1-3,7,10-" into sorted, unique page numbers.
    static func parsePages(_ spec: String?, pageCount: Int) throws -> [Int] {
        guard let spec else {
            return Array(1...pageCount)
        }

        var selected = Set<Int>()
        for part in spec.split(separator: ",") {
            let bounds = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = Int(bounds[0]) else {
                throw ValidationError("--pages must look like 1-3,7 or 5-; could not read '\(part)'.")
            }
            let last: Int
            if bounds.count == 1 {
                last = first
            } else if bounds[1].isEmpty {
                last = pageCount
            } else if let end = Int(bounds[1]) {
                last = end
            } else {
                throw ValidationError("--pages must look like 1-3,7 or 5-; could not read '\(part)'.")
            }
            guard first >= 1, first <= pageCount, last <= pageCount else {
                throw ValidationError("--pages '\(part)' is out of range; the PDF has \(pageCount) page(s).")
            }
            guard first <= last else {
                throw ValidationError("--pages '\(part)' is a reversed range.")
            }
            selected.formUnion(first...last)
        }

        guard !selected.isEmpty else {
            throw ValidationError("--pages must name at least one page.")
        }
        return selected.sorted()
    }

    /// Renders a PDF page onto an opaque white bitmap. Vision reads transparent
    /// pixels as black, so drawing without a background hides black text.
    static func render(_ page: PDFPage) throws -> CGImage {
        let bounds = page.bounds(for: .cropBox)
        let isSideways = (page.rotation / 90) % 2 != 0
        let pointWidth = isSideways ? bounds.height : bounds.width
        let pointHeight = isSideways ? bounds.width : bounds.height
        let scale = min(pdfRenderDPI / 72, pdfMaxPixelDimension / max(pointWidth, pointHeight))
        let width = Int((pointWidth * scale).rounded())
        let height = Int((pointHeight * scale).rounded())

        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            throw ValidationError("Could not create a bitmap to render the PDF page.")
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)

        guard let image = context.makeImage() else {
            throw ValidationError("Could not render the PDF page.")
        }
        return image
    }

    static func captureScreen(rect: String?) throws -> NSImage {
        let captureRect: CGRect
        if let rect {
            captureRect = try parseCaptureRect(rect)
        } else {
            captureRect = .infinite
        }

        guard let cgImage = CGWindowListCreateImage(
            captureRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            throw ValidationError(
                "Could not capture the screen. Grant Screen Recording permission in System Settings."
            )
        }

        return NSImage(cgImage: cgImage, size: .zero)
    }

    static func parseCaptureRect(_ value: String) throws -> CGRect {
        let components = value.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 4,
              let x = Double(components[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(components[1].trimmingCharacters(in: .whitespaces)),
              let width = Double(components[2].trimmingCharacters(in: .whitespaces)),
              let height = Double(components[3].trimmingCharacters(in: .whitespaces)),
              [x, y, width, height].allSatisfy({ $0.isFinite }),
              width > 0,
              height > 0 else {
            throw ValidationError("--rect must be x,y,width,height with positive width and height.")
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func save(_ image: NSImage, to path: String) throws {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        let fileType: NSBitmapImageRep.FileType
        let properties: [NSBitmapImageRep.PropertyKey: Any]

        switch url.pathExtension.lowercased() {
        case "png":
            fileType = .png
            properties = [:]
        case "jpg", "jpeg":
            fileType = .jpeg
            properties = [.compressionFactor: 0.9]
        case "tif", "tiff":
            fileType = .tiff
            properties = [:]
        default:
            throw ValidationError("--save-image path must end in .png, .jpg, .jpeg, .tif, or .tiff.")
        }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(
                using: fileType,
                properties: properties
              ) else {
            throw ValidationError("Could not encode the captured image.")
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ValidationError("Could not save captured image to \(path): \(error.localizedDescription)")
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
