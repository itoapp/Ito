import SwiftUI
import UIKit
import os
import ito_runner

struct NovelPagingReaderView: View {
    let loadedChapters: [NovelReaderView.LoadedChapter]
    let fontSize: Double
    let fontFamily: NovelFont
    let lineSpacing: Double
    let theme: NovelTheme
    let prefetchChapters: Bool
    let onLoadNextChapter: () -> Void
    @Binding var currentChapter: Novel.Chapter

    struct PagedItem {
        let chapter: Novel.Chapter
        let string: NSAttributedString
    }

    @State private var paginatedCache: [UUID: [NSAttributedString]] = [:]
    @State private var flattenedPages: [PagedItem] = []
    @State private var currentPageIndex: Int = 0
    @State private var pageSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack {
                if flattenedPages.isEmpty {
                    ProgressView("Paginating...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PageViewController(
                        pages: flattenedPages.map { $0.string },
                        currentPage: $currentPageIndex,
                        maxWidth: max(0, size.width - 32),
                        onPageChanged: { newIndex in
                            if newIndex >= 0 && newIndex < flattenedPages.count {
                                let newChap = flattenedPages[newIndex].chapter
                                if newChap.key != currentChapter.key {
                                    currentChapter = newChap
                                }

                                // Prefetch trigger
                                if prefetchChapters && newIndex >= flattenedPages.count - 3 {
                                    onLoadNextChapter()
                                }
                            }
                        }
                    )

                    // Footer Overlays (Battery & Page Counter)
                    VStack {
                        Spacer()
                        HStack {
                            BatteryIndicator(theme: theme)
                                .padding(.leading, 16)

                            Spacer()

                            Text("\(currentPageIndex + 1)/\(flattenedPages.count)")
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(theme.textColor.opacity(0.5))
                                .padding(.trailing, 16)
                        }
                        .padding(.bottom, 8)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                if pageSize == .zero && size.width > 0 {
                    pageSize = size
                    DispatchQueue.main.async { paginate(size: size) }
                }
            }
            .onChange(of: size) { newSize in
                AppLogger.ui.debug("[NovelPagingReaderView] onChange(of: size) triggered: \(String(describing: newSize))")
                if newSize != pageSize {
                    pageSize = newSize
                    paginatedCache.removeAll()
                    DispatchQueue.main.async { paginate(size: newSize) }
                }
            }
            .onChange(of: loadedChapters) { _ in
                DispatchQueue.main.async { paginate(size: pageSize) }
            }
            .onChange(of: fontSize) { newSize in
                AppLogger.ui.debug("[NovelPagingReaderView] onChange(of: fontSize) to \(newSize)")
                paginatedCache.removeAll()
                DispatchQueue.main.async { paginate(size: pageSize, overrideFontSize: newSize) }
            }
            .onChange(of: fontFamily) { newFam in
                AppLogger.ui.debug("[NovelPagingReaderView] onChange(of: fontFamily) to \(String(describing: newFam))")
                paginatedCache.removeAll()
                DispatchQueue.main.async { paginate(size: pageSize, overrideFontFamily: newFam) }
            }
            .onChange(of: lineSpacing) { newSpace in
                AppLogger.ui.debug("[NovelPagingReaderView] onChange(of: lineSpacing) to \(newSpace)")
                paginatedCache.removeAll()
                DispatchQueue.main.async { paginate(size: pageSize, overrideLineSpacing: newSpace) }
            }
            .onChange(of: theme) { newTheme in
                AppLogger.ui.debug("[NovelPagingReaderView] onChange(of: theme) to \(String(describing: newTheme))")
                paginatedCache.removeAll()
                DispatchQueue.main.async { paginate(size: pageSize, overrideTheme: newTheme) }
            }
        }
    }

    private func paginate(
        size: CGSize,
        overrideFontSize: Double? = nil,
        overrideFontFamily: NovelFont? = nil,
        overrideLineSpacing: Double? = nil,
        overrideTheme: NovelTheme? = nil
    ) {
        let currentFontSize = overrideFontSize ?? self.fontSize
        let currentFontFamily = overrideFontFamily ?? self.fontFamily
        let currentLineSpacing = overrideLineSpacing ?? self.lineSpacing
        let currentTheme = overrideTheme ?? self.theme
        AppLogger.ui.debug("[NovelPagingReaderView] Starting pagination with size: \(String(describing: size))")
        guard size.width > 0 && size.height > 0 else {
            AppLogger.ui.debug("[NovelPagingReaderView] Invalid size, aborting pagination.")
            return
        }

        let usableSize = CGSize(width: size.width - 32, height: size.height - 80)
        AppLogger.ui.debug("[NovelPagingReaderView] Usable text container size: \(String(describing: usableSize))")
        let configuration = NovelPaginationConfiguration(
            containerSize: size,
            fontSize: currentFontSize,
            fontFamily: currentFontFamily,
            lineSpacing: currentLineSpacing,
            textColor: UIColor(currentTheme.textColor)
        )

        for loadedChapter in loadedChapters {
            guard paginatedCache[loadedChapter.id] == nil else { continue }
            AppLogger.ui.debug("[NovelPagingReaderView] Paginating new chapter: \(loadedChapter.chapter.title ?? loadedChapter.chapter.key)")
            guard let pages = NovelPaginationEngine.paginate(
                chapters: [NovelPaginationChapter(
                    id: loadedChapter.id,
                    chapter: loadedChapter.chapter,
                    pages: loadedChapter.pages
                )],
                configuration: configuration
            ) else {
                return
            }
            paginatedCache[loadedChapter.id] = pages.map(\.string)
        }

        // Rebuild flattened array preserving order of loadedChapters
        var newFlattened: [PagedItem] = []
        for loadedChapter in loadedChapters {
            if let extracted = paginatedCache[loadedChapter.id] {
                for str in extracted {
                    newFlattened.append(PagedItem(chapter: loadedChapter.chapter, string: str))
                }
            }
        }

        AppLogger.ui.debug("[NovelPagingReaderView] Pagination complete. Total pages: \(newFlattened.count)")

        self.flattenedPages = newFlattened
        self.currentPageIndex = min(currentPageIndex, max(0, newFlattened.count - 1))
    }
}

// MARK: - UIPageViewController Wrapper

struct PageViewController: UIViewControllerRepresentable {
    let pages: [NSAttributedString]
    @Binding var currentPage: Int
    let maxWidth: CGFloat
    let onPageChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: nil
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear

        if let firstVC = context.coordinator.makePageContentVC(index: 0) {
            pvc.setViewControllers([firstVC], direction: .forward, animated: false)
        }

        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        let oldPages = coordinator.parent.pages

        AppLogger.ui.debug("[PageViewController] updateUIViewController called. oldPages count: \(oldPages.count), new pages count: \(pages.count)")

        // Update the coordinator's reference to the latest data
        coordinator.parent = self

        // Check if pages content actually changed (not just a re-render)
        let contentChanged = oldPages.count != pages.count ||
            zip(oldPages, pages).contains(where: { $0.0 !== $0.1 })

        if contentChanged {
            AppLogger.ui.debug("[PageViewController] Content changed, refreshing. Setting vc for index \(currentPage)")
            let targetIndex = min(currentPage, max(0, pages.count - 1))
            if let vc = coordinator.makePageContentVC(index: targetIndex) {
                pvc.setViewControllers([vc], direction: .forward, animated: false)
            } else {
                AppLogger.ui.debug("[PageViewController] Failed to create VC for index \(targetIndex)")
            }
        } else {
            AppLogger.ui.debug("[PageViewController] Content did not change.")
        }
    }

    class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageViewController

        init(_ parent: PageViewController) {
            self.parent = parent
        }

        func makePageContentVC(index: Int) -> PageContentViewController? {
            guard index >= 0 && index < parent.pages.count else { return nil }
            let vc = PageContentViewController()
            vc.index = index
            vc.attributedString = parent.pages[index]
            vc.maxWidth = parent.maxWidth
            AppLogger.ui.debug("[PageViewController Coordinator] Created VC for index \(index) with string length \(vc.attributedString?.length ?? 0)")
            return vc
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? PageContentViewController else { return nil }
            return makePageContentVC(index: vc.index - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let vc = viewController as? PageContentViewController else { return nil }
            return makePageContentVC(index: vc.index + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            if completed,
               let vc = pageViewController.viewControllers?.first as? PageContentViewController {
                parent.currentPage = vc.index
                parent.onPageChanged(vc.index)
            }
        }
    }
}

class PageContentViewController: UIViewController {
    var index: Int = 0
    var attributedString: NSAttributedString?
    var maxWidth: CGFloat = 0

    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        AppLogger.ui.debug("[PageContentViewController] viewDidLoad for index \(self.index)")
        view.backgroundColor = .clear

        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])

        textView.attributedText = attributedString
        AppLogger.ui.debug("[PageContentViewController] set attributedText for index \(self.index)")

        // Disable UITextView's built-in double tap to remove selection conflicts,
        // users can still long-press to select text.
        for recognizer in textView.gestureRecognizers ?? [] {
            if let tapRecognizer = recognizer as? UITapGestureRecognizer, tapRecognizer.numberOfTapsRequired == 2 {
                tapRecognizer.isEnabled = false
            }
        }
    }
}

// MARK: - Battery Indicator

struct BatteryIndicator: View {
    let theme: NovelTheme
    @State private var level: Float = -1.0
    @State private var state: UIDevice.BatteryState = .unknown

    var body: some View {
        Group {
            if level >= 0 {
                HStack(spacing: 4) {
                    Image(systemName: batteryIcon)
                        .font(.system(size: 10, weight: .regular))
                    Text("\(Int(level * 100))%")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                }
                .foregroundColor(theme.textColor.opacity(0.5))
            }
        }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            level = UIDevice.current.batteryLevel
            state = UIDevice.current.batteryState
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            level = UIDevice.current.batteryLevel
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            state = UIDevice.current.batteryState
        }
    }

    private var batteryIcon: String {
        if state == .charging || state == .full {
            return "battery.100.bolt"
        }
        if level > 0.85 { return "battery.100" }
        if level > 0.60 { return "battery.75" }
        if level > 0.35 { return "battery.50" }
        if level > 0.10 { return "battery.25" }
        return "battery.0"
    }
}
