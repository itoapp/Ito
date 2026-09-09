import UIKit
import ito_runner

struct NovelPaginationChapter {
    let id: UUID
    let chapter: Novel.Chapter
    let pages: [Page]
}

struct NovelPaginationConfiguration {
    let containerSize: CGSize
    let fontSize: Double
    let fontFamily: NovelFont
    let lineSpacing: Double
    let textColor: UIColor
}

struct NovelPaginationPage {
    let chapterID: UUID
    let chapter: Novel.Chapter
    let string: NSAttributedString
}

@MainActor
enum NovelPaginationEngine {
    static func paginate(
        chapters: [NovelPaginationChapter],
        configuration: NovelPaginationConfiguration
    ) -> [NovelPaginationPage]? {
        guard configuration.containerSize.width > 0,
              configuration.containerSize.height > 0 else {
            return nil
        }

        let usableSize = CGSize(
            width: configuration.containerSize.width - 32,
            height: configuration.containerSize.height - 80
        )
        let fonts = fonts(
            family: configuration.fontFamily,
            size: configuration.fontSize
        )
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: fonts.title,
            .foregroundColor: configuration.textColor
        ]
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = configuration.lineSpacing
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: fonts.body,
            .foregroundColor: configuration.textColor,
            .paragraphStyle: paragraphStyle
        ]

        return chapters.flatMap { chapter in
            paginate(
                chapter: chapter,
                usableSize: usableSize,
                titleAttributes: titleAttributes,
                bodyAttributes: bodyAttributes
            )
        }
    }

    static func formattedTitle(for chapter: Novel.Chapter) -> String {
        if let number = chapter.chapter {
            if let title = chapter.title, !title.isEmpty {
                return "Chapter \(number.formatted()) - \(title)"
            }
            return "Chapter \(number.formatted())"
        }
        return chapter.title ?? "Unknown Chapter"
    }

    private static func paginate(
        chapter: NovelPaginationChapter,
        usableSize: CGSize,
        titleAttributes: [NSAttributedString.Key: Any],
        bodyAttributes: [NSAttributedString.Key: Any]
    ) -> [NovelPaginationPage] {
        let fullString = NSMutableAttributedString()
        fullString.append(
            NSAttributedString(
                string: formattedTitle(for: chapter.chapter) + "\n\n",
                attributes: titleAttributes
            )
        )
        for page in chapter.pages {
            if case .text(let text) = page.content {
                fullString.append(
                    NSAttributedString(
                        string: text + "\n\n",
                        attributes: bodyAttributes
                    )
                )
            }
        }

        let storage = NSTextStorage(attributedString: fullString)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        var containers: [NSTextContainer] = []
        var glyphRange = NSRange(location: 0, length: 0)

        repeat {
            let container = NSTextContainer(size: usableSize)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            containers.append(container)
            glyphRange = manager.glyphRange(for: container)
            if containers.count > 1000 || glyphRange.length == 0 {
                break
            }
        } while NSMaxRange(glyphRange) < manager.numberOfGlyphs

        return containers.compactMap { container in
            let glyphRange = manager.glyphRange(for: container)
            let characterRange = manager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            guard characterRange.length > 0 else { return nil }
            return NovelPaginationPage(
                chapterID: chapter.id,
                chapter: chapter.chapter,
                string: storage.attributedSubstring(from: characterRange)
            )
        }
    }

    private static func fonts(
        family: NovelFont,
        size: Double
    ) -> (title: UIFont, body: UIFont) {
        (
            family.uiFont(size: CGFloat(size) + 6, isBold: true),
            family.uiFont(size: CGFloat(size))
        )
    }
}
