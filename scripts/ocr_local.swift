#!/usr/bin/env swift

// Local OCR helper for commencement-page images.
//
// Build from the repository root on macOS:
//   swiftc scripts/ocr_local.swift -o ocr_local
//
// The compiled `ocr_local` binary is intentionally gitignored. The Issuu
// harvester invokes it once per downloaded page image and stores the resulting
// text only in scratch space.

import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: ocr_local <image-path>\n".utf8))
    exit(64)
}

let fileURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard
    let image = NSImage(contentsOf: fileURL),
    let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("ocr_local: cannot load image: \(fileURL.path)\n".utf8))
    exit(66)
}

var recognizedLines: [String] = []
var recognitionError: Error?

let request = VNRecognizeTextRequest { request, error in
    recognitionError = error
    guard let observations = request.results as? [VNRecognizedTextObservation] else {
        return
    }
    recognizedLines = observations.compactMap { $0.topCandidates(1).first?.string }
}
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true

do {
    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
} catch {
    recognitionError = error
}

if let error = recognitionError {
    FileHandle.standardError.write(Data("ocr_local: OCR failed: \(error)\n".utf8))
    exit(1)
}

print(recognizedLines.joined(separator: "\n"))
