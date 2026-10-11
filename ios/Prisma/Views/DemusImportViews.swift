import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Choosing the file

/// The file types the picker offers.
///
/// The first is the type this app declares for the `.playlist` extension in its
/// Info.plist. The second is every file there is: iOS only recognises the first
/// when the file's provider agrees about what a `.playlist` is, and a file saved
/// from Demus into Files, iCloud Drive or a third-party provider may come back
/// typed as plain data. A wrong file costs nothing — the server says what is wrong
/// with it and nothing is imported.
enum DemusFile {
    static let typeIdentifier = "com.brighina.prisma.demus-playlist"

    static var pickerTypes: [UTType] {
        [UTType(importedAs: typeIdentifier), .data]
    }
}

/// "Importa da Demus", in Libreria → Playlist, under Nuova playlist: opens the file
/// picker and hands what was picked to `DemusImporter`. The preview that follows is
/// `RootView`'s sheet, the same one a file opened from another app gets.
struct DemusImportButton: View {
    @Environment(DemusImporter.self) private var importer
    @Environment(\.prismaInk) private var ink

    @State private var picking = false

    var body: some View {
        Button {
            picking = true
        } label: {
            Label("Importa da Demus", systemImage: "square.and.arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ink.accentText)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .prismaRow()
        .fileImporter(isPresented: $picking, allowedContentTypes: DemusFile.pickerTypes) { result in
            switch result {
            case .success(let url):
                importer.open(url)
            case .failure(let error):
                importer.pickFailed(error)
            }
        }
    }
}

// MARK: - Preview and confirmation

/// The sheet between a Demus file and its import: the server reading it, then what
/// it holds set against what this phone already has, then Importa or Annulla.
///
/// Nothing is written while it is up. It follows the plain system styling of the
/// sheets it sits beside (`DestinationSheet`, `AddFavouritesToPlaylistSheet`), and
/// reads the store in exactly one place, at the top of its body.
struct DemusImportSheet: View {
    @Environment(DemusImporter.self) private var importer

    @Query private var favourites: [FavouriteTrack]
    @Query private var tracks: [StoredTrack]
    @Query(sort: \Playlist.sortPosition) private var playlists: [Playlist]
    @Query private var entries: [PlaylistEntry]

    /// The answer to "update the playlist that is there, or make a new one". nil
    /// until it is given, and Importa waits for it.
    @State private var choice: DemusImporter.PlaylistChoice?

    var body: some View {
        // The one place this sheet reads the store.
        let pending = importer.pending
        let preview = pending.map {
            Projection.demusPreview(
                $0.playlist, favourites: favourites, tracks: tracks,
                playlists: playlists, entries: entries
            )
        }
        let space = preview.flatMap { DemusSpace(preview: $0, available: pending?.availableBytes) }
        let decided = preview.flatMap { decision(for: $0) }

        NavigationStack {
            List {
                switch importer.phase {
                case .idle:
                    EmptyView()
                case .parsing(let fileName):
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Lettura di “\(fileName)” sul server…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(minHeight: 44)
                    } footer: {
                        Text("Il server legge soltanto il file: finché non tocchi Importa non cambia nulla, né qui né lì.")
                    }
                case .failed(let error):
                    Section {
                        ProblemBlock(error: error)
                    } footer: {
                        Text("Non è stato importato nulla.")
                    }
                case .preview:
                    if let preview {
                        content(preview, space: space)
                    }
                }
            }
            .navigationTitle("Importa da Demus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasFailed ? "Chiudi" : "Annulla") { importer.cancel() }
                }
                // Only once there is something to import: a file still being read,
                // or one that could not be, offers nothing to confirm.
                if preview != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(space?.isEnough == false ? "Importa comunque" : "Importa") {
                            if let decided {
                                importer.confirm(decided)
                            }
                        }
                        .disabled(decided == nil)
                    }
                }
            }
        }
    }

    /// There is nothing left to cancel, only a message to close.
    private var hasFailed: Bool {
        if case .failed = importer.phase { return true }
        return false
    }

    /// What Importa would do about the playlist, or nil while it cannot be pressed:
    /// the file has no tracks, or a playlist of that name exists and the question
    /// has not been answered. An answer given about another playlist is not one.
    private func decision(for preview: DemusPreviewData) -> DemusImporter.PlaylistChoice? {
        guard preview.trackCount > 0 else { return nil }
        guard let existing = preview.existing else { return .createNew }
        switch choice {
        case .createNew?:
            return .createNew
        case .update(let id)? where id == existing.id:
            return .update(id)
        default:
            return nil
        }
    }

    @ViewBuilder
    private func content(_ preview: DemusPreviewData, space: DemusSpace?) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Formatting.trackCount(preview.songCount) + " · " + preview.totalDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

            if preview.trackCount == 0 {
                Text("Il file non contiene nessun brano, quindi non c'è niente da importare.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FieldRow(label: "Già nei preferiti", value: Self.share(preview.alreadyFavourite, of: preview.trackCount))
                FieldRow(label: "Già sul telefono", value: Self.share(preview.onPhone, of: preview.trackCount))
                FieldRow(label: "Da scaricare", value: Self.toDownload(preview.toDownload))
                if let space {
                    if space.isEnough {
                        FieldRow(label: "Spazio sul telefono", value: space.summary)
                    } else {
                        ProblemBlock(space.warning(tracks: preview.toDownload))
                    }
                }
                if preview.repeated > 0 {
                    Text(Self.repeated(preview.repeated))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        if preview.trackCount > 0, let existing = preview.existing {
            Section {
                option(
                    .update(existing.id),
                    symbol: "text.badge.plus",
                    title: "Aggiorna quella che c'è",
                    explanation: Self.updateExplanation(existing)
                )
                option(
                    .createNew,
                    symbol: "plus.rectangle.on.rectangle",
                    title: "Crea una nuova playlist",
                    explanation: "Nasce una seconda playlist con lo stesso nome e tutti i brani del file, nel loro ordine. Quella che c'è resta com'è."
                )
            } header: {
                Text("Esiste già una playlist “\(preview.name)”").textCase(nil)
            } footer: {
                if existing.sameNameCount > 1 {
                    Text("Ci sono \(existing.sameNameCount) playlist con questo nome: l'aggiornamento va nella prima dell'elenco in Libreria.")
                }
            }
        }

        if preview.trackCount > 0 {
            Section {
                EmptyView()
            } footer: {
                Text("I brani entrano nella playlist e nei preferiti subito. Quelli che non sono ancora sul telefono vengono scaricati sul server e poi sul telefono (Entrambi), uno alla volta: possono volerci ore, e l'avanzamento è nella scheda Download. Non parte nessuna riproduzione.")
            }
        }
    }

    /// One of the two answers, in the shape of a `DestinationSheet` choice, with a
    /// mark on the one chosen.
    private func option(
        _ value: DemusImporter.PlaylistChoice,
        symbol: String,
        title: String,
        explanation: String
    ) -> some View {
        let isChosen = choice == value
        return Button {
            choice = value
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .frame(width: 26)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    // MARK: Words

    /// "12 di 53", "Nessuno", "Tutti e 53".
    private static func share(_ count: Int, of total: Int) -> String {
        if count == 0 { return "Nessuno" }
        if count == total { return total == 1 ? "Sì" : "Tutti e \(total)" }
        return "\(count) di \(total)"
    }

    private static func toDownload(_ count: Int) -> String {
        if count == 0 { return "Niente: sono già tutti sul telefono" }
        return Formatting.trackCount(count) + ", sul server e sul telefono"
    }

    private static func repeated(_ count: Int) -> String {
        count == 1
            ? "Un brano compare due volte nel file: nella playlist entra una volta sola."
            : "\(count) voci del file ripetono un brano già elencato: nella playlist ogni brano entra una volta sola."
    }

    private static func updateExplanation(_ existing: DemusExistingPlaylist) -> String {
        switch existing.missingCount {
        case 0:
            return "Contiene già tutti i brani del file, quindi resta com'è. I brani vengono comunque messi nei preferiti e scaricati."
        case 1:
            return "Aggiunge in fondo l'unico brano del file che non contiene ancora."
        default:
            return "Aggiunge in fondo, nell'ordine del file, i \(existing.missingCount) brani che non contiene ancora."
        }
    }
}

/// The free-space check of the preview: what the tracks still to download are
/// estimated to need, against what the phone has.
///
/// The need is `DemusEstimate` for those tracks, plus what the device downloads
/// already queued will take, plus the reserve `DownloadManager` keeps free for
/// every download. The space is the same figure a single download is checked
/// against: the volume's capacity for important usage.
///
/// nil when there is nothing to download, or when iOS would not say how much is
/// free — in which case the preview claims nothing about space.
struct DemusSpace: Equatable {
    let needed: Int64
    let available: Int64

    init?(preview: DemusPreviewData, available: Int64?) {
        guard preview.toDownload > 0, let available else { return nil }
        self.needed = preview.estimatedBytes + preview.queuedBytes + Int64(DownloadManager.reserveBytes)
        self.available = available
    }

    var isEnough: Bool { available >= needed }

    var summary: String {
        "Servono circa \(Self.size(needed)); liberi \(Self.size(available))"
    }

    func warning(tracks: Int) -> String {
        "Lo spazio sul telefono potrebbe non bastare: per scaricare \(tracks == 1 ? "questo brano" : "questi \(tracks) brani") servono circa \(Self.size(needed)) e ne restano \(Self.size(available)). Libera spazio prima di importare; altrimenti i download che non ci stanno non riusciranno, e la loro riga dirà perché."
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Progress in Download

/// Words for the line of an import in the Downloads tab.
enum ImportText {
    /// "Importazione «Sad»: 12 di 53", and ", 3 non riusciti" once some have failed.
    static func headline(_ data: ImportProgressData) -> String {
        var text = "Importazione «\(data.name)»: \(data.done) di \(data.total)"
        if data.failed > 0 {
            text += data.failed == 1 ? ", 1 non riuscito" : ", \(data.failed) non riusciti"
        }
        return text
    }

    /// The second line: why nothing seems to move, or what is left to do. nil while
    /// the import is simply under way.
    static func detail(_ data: ImportProgressData, queueResumesAt: Date?) -> String? {
        if data.isFinished {
            let missing = data.failed == 1
                ? "un brano non è arrivato"
                : "\(data.failed) brani non sono arrivati"
            return "L'importazione è finita, ma \(missing) sul telefono. Restano nella playlist e nei preferiti; quelli elencati qui sotto in Non riuscito dicono perché, e hanno Riprova."
        }
        if let queueResumesAt {
            return "YouTube ha chiesto di rallentare, quindi il server ha messo in pausa i download: riprendono alle \(queueResumesAt.formatted(date: .omitted, time: .shortened)). Non serve fare nulla, i brani in coda non sono persi."
        }
        return nil
    }
}

/// One import, at the top of the Downloads tab: "Importazione «Sad»: 12 di 53".
///
/// It stays while tracks are still arriving, says so in words when the server's
/// queue is resting, and ends in one of two ways. Every track on the phone: it
/// simply goes. Some not: it stays as "50 di 53, 3 non riusciti" until closed, so
/// a failure is neither counted as done nor left to keep the line running.
struct ImportProgressLine: View {
    let data: ImportProgressData

    @Environment(AcquisitionCoordinator.self) private var acquisitions
    @Environment(DemusImporter.self) private var importer
    @Environment(\.prismaInk) private var ink

    var body: some View {
        let resumesAt = queueResumesAt
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                icon(resting: resumesAt != nil)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ImportText.headline(data))
                        // The count changes under the eye; its digits keep their width.
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = ImportText.detail(data, queueResumesAt: resumesAt) {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .padding(.bottom, data.isFinished ? 0 : 12)
            .accessibilityElement(children: .combine)

            if data.isFinished {
                DismissLink { importer.forget([data.id]) }
                    .padding(.leading, 34)
            }
        }
    }

    /// When the server's queue starts again, if that is what this import is waiting
    /// for: it has tracks in the queue, and the server has said it is resting.
    private var queueResumesAt: Date? {
        guard !data.isFinished, data.waitingOnServer > 0,
              let until = acquisitions.serverCooldownUntil, until > Date() else { return nil }
        return until
    }

    @ViewBuilder
    private func icon(resting: Bool) -> some View {
        if data.isFinished {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(ink.favourite)
        } else if resting {
            Image(systemName: "clock")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ink.secondary)
        } else {
            ProgressRing(fraction: Double(data.done) / Double(max(1, data.total)), color: ink.accent, side: 18)
        }
    }
}
