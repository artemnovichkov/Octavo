import Foundation
import KindleFormat

// Standalone converter for testing: octavo-convert <input> [output] [--format azw3|mobi]
let arguments = Array(CommandLine.arguments.dropFirst())

let requested: ConversionTarget? = arguments.firstIndex(of: "--format").flatMap {
    $0 + 1 < arguments.count ? ConversionTarget(rawValue: arguments[$0 + 1].lowercased()) : nil
}
if arguments.contains("--format"), requested == nil {
    print("Unknown format. Use --format azw3 or --format mobi.")
    exit(1)
}

/// The flag and its value are lifted out first so they may appear anywhere among the
/// positional arguments rather than only after them.
let positional: [String] = {
    var result: [String] = []
    var index = 0
    while index < arguments.count {
        if arguments[index] == "--format" { index += 2; continue }
        result.append(arguments[index])
        index += 1
    }
    return result
}()

guard let input = positional.first else {
    print("Usage: octavo-convert <file.epub|cbz|fb2> [output] [--format azw3|mobi]")
    exit(1)
}

let source = URL(filePath: input)
let explicitOutput = positional.count > 1 ? URL(filePath: positional[1]) : nil
// An output path that names a format wins over the flag: writing a MOBI to "out.azw3"
// because the flag was forgotten is a worse failure than being told they disagree.
let target = explicitOutput.flatMap { ConversionTarget(rawValue: $0.pathExtension.lowercased()) }
    ?? requested
    ?? .preferred
let destination = explicitOutput
    ?? source.deletingPathExtension().appendingPathExtension(target.fileExtension)

do {
    let result = try Converter.convert(source, to: destination, target: target)
    let attributes = try FileManager.default.attributesOfItem(atPath: result.path(percentEncoded: false))
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    let parsed = try MOBIReader.metadata(of: result)
    print("""
    Done: \(result.path(percentEncoded: false))
      format:  \(target.displayName)
      size:    \(size) bytes
      title:   \(parsed.title)
      authors: \(parsed.authors.joined(separator: ", "))
      cover:   \(parsed.cover.map { "\($0.count) bytes" } ?? "none")
    """)
} catch {
    print("Error: \(error.localizedDescription)")
    exit(2)
}
