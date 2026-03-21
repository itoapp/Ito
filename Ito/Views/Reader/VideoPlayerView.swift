import AVKit
import SwiftUI
import ito_runner

struct VideoPlayerView: View {
    let runner: ItoRunner
    let pluginId: String
    let anime: Anime
    let episode: Anime.Episode

    @State private var videos: [Anime.Video] = []
    @State private var isLoaded = false
    @State private var errorMessage: String?

    @State private var selectedVideo: Anime.Video?
    @State private var selectedAudioTrack: Anime.AudioTrack?
    @State private var selectedSubtitle: Anime.Subtitle?

    @State private var player: AVPlayer?

    @State private var showQualitySelector = false
    @State private var showAudioSelector = false
    @State private var showSubtitleSelector = false

    @State private var showCustomControls = true

    // Custom Subtitle State
    @State private var parsedSubtitles: [(start: Double, end: Double, text: String)] = []
    @State private var currentSubtitleText: String?

    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !isLoaded && errorMessage == nil {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                    Text("Extracting Video Streams...")
                        .foregroundColor(.white)
                }
            } else if let error = errorMessage {
                VStack(spacing: 24) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.yellow)
                    Text("Error Loading Video")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text(error)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button("Close") {
                        dismiss()
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.2))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            } else if let player = player, let video = selectedVideo {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .overlay(
                        VStack {
                            Spacer()
                            if let subText = currentSubtitleText {
                                Text(subText)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Color.black.opacity(0.75))
                                    .cornerRadius(8)
                                    .padding(.bottom, 60)
                            }
                        }
                    )
                    .overlay(
                        VStack {
                            HStack {
                                // We MUST keep our custom back button, because the native iOS 16/17 AVPlayer full-screen dismiss 
                                // often fails to trigger the SwiftUI `@Environment(\.dismiss)` when not presented via a standard sheet.
                                Button(action: {
                                    player.pause()
                                    dismiss()
                                }) {
                                    Image(systemName: "chevron.left.circle.fill")
                                        .font(.system(size: 30))
                                        .foregroundColor(.white)
                                        .padding()
                                        .background(Circle().fill(Color.black.opacity(0.01))) // increase tap area
                                }

                                Spacer()

                                if let tracks = video.audioTracks, tracks.count > 1 {
                                    Button(action: { showAudioSelector = true }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "speaker.wave.2")
                                            Text(selectedAudioTrack?.language ?? "Audio")
                                        }
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.black.opacity(0.6))
                                        .foregroundColor(.white)
                                        .cornerRadius(6)
                                    }
                                }

                                if let subs = video.subtitles, !subs.isEmpty {
                                    Button(action: { showSubtitleSelector = true }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "captions.bubble")
                                            Text(selectedSubtitle?.language ?? "Subtitles")
                                        }
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.black.opacity(0.6))
                                        .foregroundColor(selectedSubtitle != nil ? .blue : .white)
                                        .cornerRadius(6)
                                    }
                                }

                                if videos.count > 1 {
                                    Button(action: {
                                        print("🎬 [DEBUG] Quality selector tapped. videos count: \(videos.count)")
                                        showQualitySelector = true
                                    }) {
                                        Text(video.quality)
                                            .font(.caption)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Color.black.opacity(0.6))
                                            .foregroundColor(.white)
                                            .cornerRadius(6)
                                    }
                                }
                            }
                            .padding()
                            // Keep it near the top but below the AVPlayer's native controls if possible,
                            // or just aligned to top-right.
                            Spacer()
                        }
                    )
            } else {
                Text("No playable streams found.")
                    .foregroundColor(.white)
            }
        }
        .confirmationDialog("Select Quality", isPresented: $showQualitySelector) {
            ForEach(Array(videos.enumerated()), id: \.offset) { _, vid in
                Button(vid.quality) {
                    print("🎬 [DEBUG] Selected new quality: \(vid.quality)")
                    self.selectedVideo = vid
                    self.setupPlayer(for: vid)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Select Audio Track", isPresented: $showAudioSelector) {
            if let tracks = selectedVideo?.audioTracks {
                ForEach(Array(tracks.enumerated()), id: \.offset) { _, track in
                    Button(track.language) {
                        self.selectedAudioTrack = track
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Select Subtitles", isPresented: $showSubtitleSelector) {
            Button("Off") {
                self.selectedSubtitle = nil
                self.parsedSubtitles = []
                self.currentSubtitleText = nil
            }
            if let subs = selectedVideo?.subtitles {
                ForEach(Array(subs.enumerated()), id: \.offset) { _, sub in
                    let type = sub.isHardsub ? "(Hardsub)" : "(Softsub)"
                    Button("\(sub.language) \(type)") {
                        self.selectedSubtitle = sub
                        Task { await loadSubtitleFile(sub) }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            await loadVideoStreams()
        }
        .onDisappear {
            player?.pause()
        }
    }

    private func loadVideoStreams() async {
        guard !isLoaded else { return }

        // Record history right away so it shows up even if it fails to load
        let episodeTitleStr = episode.title ?? episode.key
        HistoryManager.shared.addAnime(anime, episodeTitle: episodeTitleStr, pluginId: pluginId)

        do {
            print("🎬 [DEBUG] Fetching video list for episode: \(episode.key)")
            let fetchedVideos = try await runner.getVideoList(anime: anime, episode: episode)

            await MainActor.run {
                self.videos = fetchedVideos
                if let first = fetchedVideos.first {
                    print("🎬 [DEBUG] Selected video URL: \(first.url)")
                    self.selectedVideo = first
                    self.selectedAudioTrack = first.audioTracks?.first
                    self.selectedSubtitle =
                        first.subtitles?.first(where: { !$0.isHardsub }) ?? first.subtitles?.first

                    self.setupPlayer(for: first)
                } else {
                    print("🎬 [DEBUG] Video list returned empty!")
                }
                self.isLoaded = true
            }
        } catch {
            print("🎬 [DEBUG] Error fetching video list: \(error)")
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoaded = true
            }
        }
    }

    private func setupPlayer(for video: Anime.Video) {
        guard let url = URL(string: video.url) else {
            print("🎬 [DEBUG] Invalid URL string: \(video.url)")
            return
        }

        var options: [String: Any] = [:]

        if let headers = video.headers, !headers.isEmpty {
            print("🎬 [DEBUG] Injecting AVPlayer Headers from plugin: \(headers)")
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers

            Task {
                await diagnoseStreamBlocked(url: url, headers: headers)
            }
        }

        let asset = AVURLAsset(url: url, options: options)
        let playerItem = AVPlayerItem(asset: asset)

        if self.player == nil {
            self.player = AVPlayer(playerItem: playerItem)

            // Setup periodic time observer for custom subtitles
            self.player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { time in
                Task { @MainActor in
                    self.updateSubtitles(for: time.seconds)
                }
            }
        } else {
            self.player?.replaceCurrentItem(with: playerItem)
        }

        self.player?.play()

        // If we have selected a subtitle, load it
        if let sub = self.selectedSubtitle {
            Task {
                await loadSubtitleFile(sub)
            }
        }
    }

    /// Bypasses AVPlayer's black box to see exactly what the server is returning
    private func diagnoseStreamBlocked(url: URL, headers: [String: String]) async {
        print("🕵️‍♂️ [DEBUG-NET] Running diagnostic fetch on: \(url.absoluteString)")
        var request = URLRequest(url: url)

        // Apply the exact same headers
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                print("🕵️‍♂️ [DEBUG-NET] HTTP Status Code: \(httpResponse.statusCode)")
            }

            if let responseString = String(data: data, encoding: .utf8) {
                print("🕵️‍♂️ [DEBUG-NET] First 500 chars of response payload:")
                print(String(responseString.prefix(500)))
            } else {
                print("🕵️‍♂️ [DEBUG-NET] Could not decode response payload as UTF-8 string. Byte count: \(data.count)")
            }
        } catch {
            print("🕵️‍♂️ [DEBUG-NET] Diagnostic fetch failed completely: \(error.localizedDescription)")
        }
    }

    private func loadSubtitleFile(_ subtitle: Anime.Subtitle) async {
        guard let url = URL(string: subtitle.url) else { return }
        print("🎬 [DEBUG-SUB] Downloading VTT: \(url)")

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                print("🎬 [DEBUG-SUB] HTTP Status for VTT: \(httpResponse.statusCode)")
            }
            if let vttString = String(data: data, encoding: .utf8) {
                print("🎬 [DEBUG-SUB] VTT downloaded, first 200 chars: \(String(vttString.prefix(200)))")
                let parsed = Self.parseVTT(vttString)
                await MainActor.run {
                    self.parsedSubtitles = parsed
                    print("🎬 [DEBUG-SUB] Successfully parsed \(parsed.count) subtitle blocks.")
                    if let first = parsed.first {
                        print("🎬 [DEBUG-SUB] First Subtitle Block: Start: \(first.start), End: \(first.end), Text: \(first.text)")
                    }
                }
            } else {
                print("🎬 [DEBUG-SUB] Failed to decode VTT data as UTF-8.")
            }
        } catch {
            print("🎬 [DEBUG-SUB] Failed to load VTT: \(error)")
        }
    }

    @State private var hasTrackedProgress = false

    private func updateSubtitles(for currentTime: Double) {
        // Track Progress
        if !hasTrackedProgress, let duration = player?.currentItem?.duration.seconds, duration > 0 {
            if currentTime / duration >= 0.8 {
                hasTrackedProgress = true

                // Mark as watched locally immediately
                Task { @MainActor in
                    ReadProgressManager.shared.markAsWatched(animeId: anime.key, episodeId: episode.key, episodeNum: episode.episode)
                }

                Task {
                    if let episodeFloat = episode.episode {
                        await TrackerManager.shared.updateProgress(localId: anime.key, progress: Int(episodeFloat))
                    } else {
                        let titleOrFallback = episode.title ?? episode.key
                        let words = titleOrFallback.components(separatedBy: .whitespacesAndNewlines)
                        if let numberWord = words.first(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) {
                            let numbersOnly = numberWord.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                            if let episodeNum = Int(numbersOnly) {
                                await TrackerManager.shared.updateProgress(localId: anime.key, progress: episodeNum)
                            }
                        }
                    }
                }
            }
        }

        if let current = parsedSubtitles.first(where: { currentTime >= $0.start && currentTime <= $0.end }) {
            if self.currentSubtitleText != current.text {
                print("🎬 [DEBUG-SUB-TIME] MATCH @ \(currentTime)s: '\(current.text)'")
                self.currentSubtitleText = current.text
            }
        } else {
            if self.currentSubtitleText != nil {
                print("🎬 [DEBUG-SUB-TIME] CLEAR @ \(currentTime)s")
                self.currentSubtitleText = nil
            }
        }
    }
}

extension VideoPlayerView {
    static func parseVTT(_ vtt: String) -> [(start: Double, end: Double, text: String)] {
        var results: [(start: Double, end: Double, text: String)] = []
        // Clean out all \r characters before splitting by \n
        let cleanVtt = vtt.replacingOccurrences(of: "\r", with: "")
        let lines = cleanVtt.components(separatedBy: "\n")

        var currentStart: Double = 0
        var currentEnd: Double = 0
        var currentText = ""
        var isReadingText = false

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // "WEBVTT" header or other metadata can be safely ignored until we find a timestamp
            if trimmed.contains("-->") {
                // If we were already reading text and hit another timestamp without a blank line,
                // save the previous one.
                if isReadingText {
                    let cleanedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleanedText.isEmpty {
                        results.append((start: currentStart, end: currentEnd, text: cleanedText))
                    }
                    currentText = ""
                }

                let parts = trimmed.components(separatedBy: "-->")
                if parts.count == 2 {
                    // Extract just the time string, ignoring extra VTT positioning metadata (like 'line:20%')
                    let startStr = parts[0].trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).first ?? ""
                    let endStr = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).first ?? ""

                    currentStart = Self.parseVTTTime(startStr)
                    currentEnd = Self.parseVTTTime(endStr)
                    isReadingText = true

                    if results.count < 3 {
                        print("🎬 [DEBUG-SUB] Parsed timestamp line \(index): start='\(startStr)' (\(currentStart)s), end='\(endStr)' (\(currentEnd)s)")
                    }
                }
            } else if trimmed.isEmpty {
                // A blank line signifies the end of a subtitle block
                if isReadingText {
                    let cleanedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleanedText.isEmpty {
                        results.append((start: currentStart, end: currentEnd, text: cleanedText))
                    }
                    currentText = ""
                    isReadingText = false
                }
            } else if isReadingText {
                // Strip simple HTML tags like <i>, <b>
                let stripped = trimmed.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
                if !currentText.isEmpty {
                    currentText += "\n" + stripped
                } else {
                    currentText = stripped
                }
            }
        }

        // Append last block if EOF reached without newline
        if isReadingText {
            let cleanedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanedText.isEmpty {
                results.append((start: currentStart, end: currentEnd, text: cleanedText))
            }
        }

        return results
    }

    static func parseVTTTime(_ timeStr: String) -> Double {
        // Formats: "00:01:23.450" or "01:23.450" or "00:01:23,450"
        let parts = timeStr.components(separatedBy: ":")
        var seconds: Double = 0

        if parts.count == 3 {
            seconds += (Double(parts[0]) ?? 0) * 3600
            seconds += (Double(parts[1]) ?? 0) * 60
            seconds += Double(parts[2].replacingOccurrences(of: ",", with: ".")) ?? 0
        } else if parts.count == 2 {
            seconds += (Double(parts[0]) ?? 0) * 60
            seconds += Double(parts[1].replacingOccurrences(of: ",", with: ".")) ?? 0
        }
        return seconds
    }
}
