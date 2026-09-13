import Foundation
import SwiftData
import SwiftUI

/// Renders the library stored on this iPhone. Opening it makes no network call;
/// only Sync and pull-to-refresh talk to the server.
struct LibraryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibrarySync.self) private var sync

    @Query private var albums: [StoredAlbum]
    @Query private var tracks: [StoredTrack]
    @Query private var records: [SyncRecord]

    @State private var confirmingFullResync = false

    var body: some View {
        List {
            Section {
                syncStatus
                Button("Sync changes") { sync.syncNow(full: false) }
                    .disabled(sync.isSyncing)
                Button("Full resync…") { confirmingFullResync = true }
                    .disabled(sync.isSyncing)
            } header: {
                Text("Sync").textCase(nil)
            } footer: {
                Text(Formatting.serverLine(settings.savedAddress) + ". Pull down to sync changes.")
            }

            Section {
                Text("\(albums.count) albums, \(tracks.count) tracks stored on this iPhone. \(downloadedCount) downloaded.")
            }

            if albums.isEmpty && tracks.isEmpty {
                Section {
                    Text("Nothing stored yet. Tap Sync changes to fetch the catalogue from the server.")
                }
            }

            ForEach(sortedAlbums) { album in
                Section {
                    LocalAlbumRow(album: album)
                    let albumTracks = sortedTracks(album.tracks)
                    if albumTracks.isEmpty {
                        Text("No tracks in this album.")
                    }
                    ForEach(albumTracks) { track in
                        LocalTrackRow(track: track)
                    }
                }
            }

            let unlisted = sortedTracks(tracks.filter { $0.album == nil })
            if !unlisted.isEmpty {
                Section {
                    ForEach(unlisted) { track in
                        LocalTrackRow(track: track)
                    }
                } header: {
                    Text("Tracks without an album").textCase(nil)
                }
            }
        }
        .navigationTitle("Library")
        .refreshable { [sync] in
            await sync.refresh()
        }
        .confirmationDialog("Full resync", isPresented: $confirmingFullResync, titleVisibility: .visible) {
            Button("Resync everything", role: .destructive) {
                sync.syncNow(full: true)
            }
        } message: {
            Text("Downloads the whole catalogue again. Albums and tracks the server no longer lists are removed from this iPhone, together with their downloaded files.")
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch sync.status {
        case .idle:
            EmptyView()
        case .syncing(let started, let since):
            LoadingRow(
                message: since.map { "Syncing changes since \($0)…" } ?? "Syncing the full catalogue…",
                since: started,
                timeout: APIClient.Timeout.library
            )
        case .succeeded(let date):
            Text("Sync succeeded at \(Formatting.time(date)).")
        case .failed(let error):
            ErrorReport(error: error)
            Text("Sync failed. Everything below is what was already stored on this iPhone.")
                .font(.caption)
        }

        if let record = records.first, let lastSyncAt = record.lastSyncAt {
            FieldRow(label: "Last successful sync", value: Formatting.dateTime(lastSyncAt))
            if let summary = record.lastSummary {
                Text(summary)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        } else {
            Text("Never synced.")
        }
    }

    private var downloadedCount: Int {
        tracks.filter { $0.downloadState == .downloaded }.count
    }

    private var sortedAlbums: [StoredAlbum] {
        albums.sorted {
            let byArtist = $0.artist.localizedStandardCompare($1.artist)
            if byArtist != .orderedSame { return byArtist == .orderedAscending }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func sortedTracks(_ list: [StoredTrack]) -> [StoredTrack] {
        list.sorted {
            switch ($0.trackNo, $1.trackNo) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending
            }
        }
    }
}

private struct LocalAlbumRow: View {
    let album: StoredAlbum

    @State private var coverProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                LocalCoverImage(album: album, side: 100, problem: $coverProblem)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(.headline)
                    Text(album.artist)
                    Text(album.year.map { String($0) } ?? "year unknown")
                        .font(.subheadline)
                    Text("\(album.tracks.count) tracks, album id \(album.serverID)")
                        .font(.caption)
                }
            }
            if let coverError = album.coverError {
                Text("Cover download failed:\n\(coverError)")
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
            if let coverProblem {
                Text(coverProblem)
                    .font(.caption2)
            }
        }
    }
}

private struct LocalTrackRow: View {
    let track: StoredTrack

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(track.trackNo.map { String($0) } ?? "–")
                .font(.body.monospacedDigit())
                .frame(minWidth: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title ?? "(no title)")
                Text(Formatting.duration(track.durationS))
                    .font(.caption)
                TrackDownloadStatus(track: track)
            }
        }
    }
}
