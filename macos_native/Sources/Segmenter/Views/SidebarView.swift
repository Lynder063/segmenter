import SwiftUI
import AppKit

public struct SidebarView: View {
    @Binding public var videoURL: URL?
    @Binding public var theIntroDBKey: String
    @Binding public var introDBKey: String
    @Binding public var tmdbKey: String
    @Binding public var searchQuery: String
    @Binding public var tmdbId: String
    @Binding public var imdbId: String
    @Binding public var mediaType: MediaType
    @Binding public var season: String
    @Binding public var episode: String
    @Binding public var drafts: [SegmentType: SegmentDraft]

    public var onOpenVideo: () -> Void
    public var onSaveKeys: () -> Void
    public var onSearchTMDB: () -> Void
    public var onLoadSegments: () -> Void
    public var onUploadAll: () -> Void
    public var onScanSeason: () -> Void
    public var onJumpToSegment: (SegmentType) -> Void
    public var onClearDraft: (SegmentType) -> Void

    public init(
        videoURL: Binding<URL?>,
        theIntroDBKey: Binding<String>,
        introDBKey: Binding<String>,
        tmdbKey: Binding<String>,
        searchQuery: Binding<String>,
        tmdbId: Binding<String>,
        imdbId: Binding<String>,
        mediaType: Binding<MediaType>,
        season: Binding<String>,
        episode: Binding<String>,
        drafts: Binding<[SegmentType: SegmentDraft]>,
        onOpenVideo: @escaping () -> Void,
        onSaveKeys: @escaping () -> Void,
        onSearchTMDB: @escaping () -> Void,
        onLoadSegments: @escaping () -> Void,
        onUploadAll: @escaping () -> Void,
        onScanSeason: @escaping () -> Void,
        onJumpToSegment: @escaping (SegmentType) -> Void,
        onClearDraft: @escaping (SegmentType) -> Void
    ) {
        self._videoURL = videoURL
        self._theIntroDBKey = theIntroDBKey
        self._introDBKey = introDBKey
        self._tmdbKey = tmdbKey
        self._searchQuery = searchQuery
        self._tmdbId = tmdbId
        self._imdbId = imdbId
        self._mediaType = mediaType
        self._season = season
        self._episode = episode
        self._drafts = drafts
        self.onOpenVideo = onOpenVideo
        self.onSaveKeys = onSaveKeys
        self.onSearchTMDB = onSearchTMDB
        self.onLoadSegments = onLoadSegments
        self.onUploadAll = onUploadAll
        self.onScanSeason = onScanSeason
        self.onJumpToSegment = onJumpToSegment
        self.onClearDraft = onClearDraft
    }


    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Section 1: Video File
                GroupBox(label: Text("Video").fontWeight(.bold)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(videoURL?.lastPathComponent ?? "No video loaded")
                            .font(.caption)
                            .foregroundColor(videoURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Button(action: onOpenVideo) {
                            Text("Open Local Video")
                                .frame(maxWidth: .infinity)
                        }

                        if tmdbKey.isEmpty {
                            Text("TMDB Key missing. Fill key to lookup.")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(6)
                }

                // Section 2: API Keys
                GroupBox(label: Text("API Keys").fontWeight(.bold)) {
                    VStack(spacing: 6) {
                        SecureField("TheIntroDB API Key", text: $theIntroDBKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        SecureField("IntroDB API Key", text: $introDBKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        SecureField("TMDB API Key", text: $tmdbKey)
                            .textFieldStyle(RoundedBorderTextFieldStyle())

                        Button(action: onSaveKeys) {
                            Text("Save Keys to Keyring")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(6)
                }

                // Section 3: Media Identification
                GroupBox(label: Text("Media Identification").fontWeight(.bold)) {
                    VStack(spacing: 8) {
                        HStack {
                            TextField("Search TMDB...", text: $searchQuery)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Button(action: onSearchTMDB) {
                                Image(systemName: "magnifyingglass")
                            }
                        }

                        TextField("TMDB ID", text: $tmdbId)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                        TextField("IMDB ID (optional)", text: $imdbId)
                            .textFieldStyle(RoundedBorderTextFieldStyle())

                        Picker("Type", selection: $mediaType) {
                            ForEach(MediaType.allCases) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())

                        if mediaType == .tv {
                            HStack {
                                TextField("Season", text: $season)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                TextField("Episode", text: $episode)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                            }
                        }

                        HStack(spacing: 8) {
                            Button(action: onLoadSegments) {
                                Text("Load Segments")
                                    .frame(maxWidth: .infinity)
                            }

                            Button(action: onUploadAll) {
                                Text("Upload All Drafts")
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.0, green: 0.48, blue: 1.0))
                        }

                        Button(action: onScanSeason) {
                            Text("Scan Season (Fingerprint)")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(6)
                }

                // Section 4: Segment Drafts
                GroupBox(label: Text("Segment Drafts").fontWeight(.bold)) {
                    VStack(spacing: 8) {
                        ForEach(SegmentType.allCases) { type in
                            HStack {
                                Circle()
                                    .fill(type.color)
                                    .frame(width: 10, height: 10)

                                Text(type.displayName)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                Spacer()

                                let draft = drafts[type] ?? .empty
                                Text(formatDraftTime(draft))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)

                                Button(action: { onJumpToSegment(type) }) {
                                    Image(systemName: "target")
                                        .font(.caption)
                                        .foregroundColor(draft.isEmpty ? .secondary : .blue)
                                }
                                .buttonStyle(.plain)
                                .disabled(draft.isEmpty)
                                .help("Jump playhead to segment start")

                                Button(action: { onClearDraft(type) }) {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .disabled(draft.isEmpty)
                                .help("Clear segment draft")
                            }

                            if type != SegmentType.allCases.last {
                                Divider()
                            }
                        }
                    }
                    .padding(6)
                }
            }
            .padding(10)
        }
        .frame(width: 320)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
    }


    private func formatDraftTime(_ draft: SegmentDraft) -> String {
        guard let start = draft.startMs, let end = draft.endMs else {
            return "-- : --"
        }
        return "\(formatMs(start)) - \(formatMs(end))"
    }

    private func formatMs(_ ms: Int) -> String {
        let sec = ms / 1000
        let m = sec / 60
        let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }
}
