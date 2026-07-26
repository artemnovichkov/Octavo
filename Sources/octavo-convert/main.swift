import Foundation
import KindleFormat

// Standalone converter for testing: octavo-convert <input> [output]
let arguments = Array(CommandLine.arguments.dropFirst())
guard let input = arguments.first else {
    print("Usage: octavo-convert <file.epub|cbz|fb2> [output.mobi]")
    exit(1)
}

let source = URL(filePath: input)
let destination = arguments.count > 1
    ? URL(filePath: arguments[1])
    : source.deletingPathExtension().appendingPathExtension("mobi")

do {
    let result = try Converter.convert(source, to: destination)
    let attributes = try FileManager.default.attributesOfItem(atPath: result.path(percentEncoded: false))
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    let parsed = try MOBIReader.metadata(of: result)
    print("""
    Done: \(result.path(percentEncoded: false))
      size:    \(size) bytes
      title:   \(parsed.title)
      authors: \(parsed.authors.joined(separator: ", "))
      cover:   \(parsed.cover.map { "\($0.count) bytes" } ?? "none")
    """)
} catch {
    print("Error: \(error.localizedDescription)")
    exit(2)
}
