import SwiftUI
import UIKit
import os
import ito_runner

struct NovelPagingReaderView: View {
    let pages: [Page]
    let fontSize: Double
    let fontFamily: NovelFont
    let lineSpacing: Double
    let theme: NovelTheme
    let chapterTitle: String

    @State private var textContainers: [NSTextContainer] = []
    @State private var textStorage: NSTextStorage?
    @State private var layoutManager: NSLayoutManager?

    @State private var currentPageIndex: Int = 0
    @State private var pageSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack {
                if textContainers.isEmpty {
                    ProgressView("Paginating...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TabView(selection: $currentPageIndex) {
                        ForEach(0..<textContainers.count, id: \.self) { index in
                            if layoutManager != nil && textStorage != nil {
                                let container = textContainers[index]
                                let usableSize = CGSize(width: size.width - 32, height: size.height - 80)

                                PagingTextPageView(layoutManager: layoutManager!, textContainer: container)
                                    .frame(width: usableSize.width, height: usableSize.height, alignment: .top)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 20)
                                    .tag(index)
                            }
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            }
            .onChange(of: size) { newSize in
                if newSize != pageSize {
                    pageSize = newSize
                    paginate(size: newSize)
                }
            }
            .onAppear {
                if pageSize == .zero && size.width > 0 {
                    pageSize = size
                    DispatchQueue.main.async {
                        paginate(size: size)
                    }
                }
            }
            // Trigger repagination when font settings change
            .onChange(of: fontSize) { _ in repaginate() }
            .onChange(of: fontFamily) { _ in repaginate() }
            .onChange(of: lineSpacing) { _ in repaginate() }
            .onChange(of: theme) { _ in repaginate() }
        }
    }

    private func repaginate() {
        textContainers = []
        DispatchQueue.main.async {
            paginate(size: pageSize)
        }
    }

    private func paginate(size: CGSize) {
        AppLogger.ui.debug("[NovelPagingReaderView] Starting pagination with size: \(String(describing: size))")
        guard size.width > 0 && size.height > 0 else {
            AppLogger.ui.debug("[NovelPagingReaderView] Invalid size, aborting pagination.")
            return
        }

        let fullString = NSMutableAttributedString()

        // Setup Fonts
        let titleFont: UIFont
        let bodyFont: UIFont

        switch fontFamily {
        case .serif:
            titleFont = UIFont(name: "TimesNewRomanPS-BoldMT", size: CGFloat(fontSize) + 6) ?? .boldSystemFont(ofSize: CGFloat(fontSize) + 6)
            bodyFont = UIFont(name: "TimesNewRomanPSMT", size: CGFloat(fontSize)) ?? .systemFont(ofSize: CGFloat(fontSize))
        case .monospaced:
            titleFont = UIFont(name: "Menlo-Bold", size: CGFloat(fontSize) + 6) ?? .boldSystemFont(ofSize: CGFloat(fontSize) + 6)
            bodyFont = UIFont(name: "Menlo", size: CGFloat(fontSize)) ?? .systemFont(ofSize: CGFloat(fontSize))
        default:
            titleFont = .boldSystemFont(ofSize: CGFloat(fontSize) + 6)
            bodyFont = .systemFont(ofSize: CGFloat(fontSize))
        }

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: UIColor(theme.textColor)
        ]
        fullString.append(NSAttributedString(string: chapterTitle + "\n\n", attributes: titleAttrs))

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = CGFloat(lineSpacing)

        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: UIColor(theme.textColor),
            .paragraphStyle: paragraphStyle
        ]

        for page in pages {
            if case .text(let text) = page.content {
                fullString.append(NSAttributedString(string: text + "\n\n", attributes: bodyAttrs))
            }
        }

        let storage = NSTextStorage(attributedString: fullString)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)

        // Subtract horizontal padding (16 * 2) and top padding (20) and some bottom margin (60)
        let usableSize = CGSize(width: size.width - 32, height: size.height - 80)
        AppLogger.ui.debug("[NovelPagingReaderView] Usable text container size: \(String(describing: usableSize))")

        var containers: [NSTextContainer] = []
        var glyphRange = NSRange(location: 0, length: 0)

        AppLogger.ui.debug("[NovelPagingReaderView] Beginning layout loop. Total string length: \(fullString.length)")

        repeat {
            let container = NSTextContainer(size: usableSize)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            containers.append(container)

            glyphRange = manager.glyphRange(for: container)

            // Safety break
            if containers.count > 1000 {
                AppLogger.ui.debug("[NovelPagingReaderView] SAFETY BREAK: Exceeded 1000 containers!")
                break
            }
            if glyphRange.length == 0 {
                AppLogger.ui.debug("[NovelPagingReaderView] BREAK: Glyph range length is 0 at container \(containers.count)")
                break
            }
        } while NSMaxRange(glyphRange) < manager.numberOfGlyphs

        AppLogger.ui.debug("[NovelPagingReaderView] Pagination complete. Total pages: \(containers.count), Total glyphs laid out: \(manager.numberOfGlyphs)")

        self.textStorage = storage
        self.layoutManager = manager
        self.textContainers = containers
        self.currentPageIndex = 0
    }
}

struct PagingTextPageView: UIViewRepresentable {
    let layoutManager: NSLayoutManager
    let textContainer: NSTextContainer

    func makeUIView(context: Context) -> PageRenderView {
        let view = PageRenderView(layoutManager: layoutManager, textContainer: textContainer)
        AppLogger.ui.debug("[PagingTextPageView] Created view for container with size: \(String(describing: textContainer.size))")
        return view
    }

    func updateUIView(_ uiView: PageRenderView, context: Context) {
        uiView.setNeedsDisplay()
    }
}

class PageRenderView: UIView {
    let layoutManager: NSLayoutManager
    let textContainer: NSTextContainer

    init(layoutManager: NSLayoutManager, textContainer: NSTextContainer) {
        self.layoutManager = layoutManager
        self.textContainer = textContainer
        super.init(frame: .zero)
        self.backgroundColor = .clear
        self.isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        AppLogger.ui.debug("[PageRenderView] Drawing glyph range: \(String(describing: glyphRange)) in rect: \(String(describing: rect))")
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
    }
}
