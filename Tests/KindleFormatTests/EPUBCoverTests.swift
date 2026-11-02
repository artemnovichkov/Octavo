import Foundation
import Testing
@testable import KindleFormat

/// The cover lookup's two tricky halves, without needing an EPUB on disk: deciding whether
/// bytes are a picture at all, and pulling the picture out of a cover *page*.

@Test func recognisesImageBytes() {
    #expect(EPUBReader.isImage(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])))
    #expect(EPUBReader.isImage(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])))
    #expect(EPUBReader.isImage(Data("GIF89a".utf8)))
    #expect(EPUBReader.isImage(Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)))

    // The whole point: an EPUB 2 `<meta name="cover">` often points at the cover page, and
    // writing that page into cover.jpg is how a library ends up full of broken thumbnails.
    #expect(!EPUBReader.isImage(Data("<?xml version=\"1.0\"?><html><body/></html>".utf8)))
    #expect(!EPUBReader.isImage(Data()))
    #expect(!EPUBReader.isImage(Data([0xFF, 0xD8])))
}

/// `src` is located by name inside the tag. Taking the tag's first quoted value instead
/// returned the class name, and the cover silently resolved to a file called "coverimage".
@Test func findsTheImageInACoverPage() {
    let page = """
    <html><body><div class="coverpage">
      <img class="coverimage" alt="Cover" src="images/_1000265115.jpg" />
    </div></body></html>
    """
    #expect(EPUBReader.firstImageHref(inMarkup: Data(page.utf8)) == "images/_1000265115.jpg")
}

@Test func findsTheImageInAnSVGCoverPage() {
    let page = """
    <html><body><svg viewBox="0 0 600 900" preserveAspectRatio="xMidYMid meet">
      <image width="600" height="900" xlink:href="../images/cover.jpeg"/>
    </svg></body></html>
    """
    #expect(EPUBReader.firstImageHref(inMarkup: Data(page.utf8)) == "../images/cover.jpeg")
}

@Test func coverPageWithoutAnImageYieldsNothing() {
    let page = "<html><body><h1>Cover</h1></body></html>"
    #expect(EPUBReader.firstImageHref(inMarkup: Data(page.utf8)) == nil)
}

/// A fragment and percent-encoding are href spelling, not part of a zip entry name.
@Test func resolvesHrefsAgainstTheOPFFolder() {
    #expect(EPUBReader.resolve("images/cover.jpg", relativeTo: "OEBPS") == "OEBPS/images/cover.jpg")
    #expect(EPUBReader.resolve("../images/cover.jpg", relativeTo: "OEBPS/text") == "OEBPS/images/cover.jpg")
    #expect(EPUBReader.resolve("cover.xhtml#top", relativeTo: "OEBPS") == "OEBPS/cover.xhtml")
    #expect(EPUBReader.resolve("images/my%20cover.jpg", relativeTo: "") == "images/my cover.jpg")
}
