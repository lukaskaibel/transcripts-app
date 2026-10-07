import Accelerate
import Foundation

/// One stretch of a person's voice the app learns from: a transcript line with its embedding.
///
/// A person is the sum of all lines assigned to them, not a handful of averages. That way one wrong
/// line can be seen and left out, and a voice can change over time without losing what came before.
public struct VoiceSample: Equatable, Identifiable, Sendable {
    public enum Source: String, Sendable {
        /// The user named this voice.
        case confirmed
        /// The user's own microphone in a call: always them.
        case microphone
        /// Recognised by the app. Refines a voice the user confirmed, never defines one.
        case automatic
        /// An averaged sample from before lines had embeddings of their own.
        case legacy
    }

    public var id: String
    public var personId: String
    /// L2-normalised.
    public var embedding: [Float]
    /// Seconds of speech behind the embedding.
    public var duration: Double
    public var source: Source
    public var meetingId: String?
    public var segmentId: Int64?
    public var speakerKey: String?
    /// Where the line starts in its meeting.
    public var start: Double?
    public var date: Date?
    /// The user said not to learn from this line.
    public var ignored: Bool

    public init(
        id: String, personId: String, embedding: [Float], duration: Double, source: Source,
        meetingId: String? = nil, segmentId: Int64? = nil, speakerKey: String? = nil, start: Double? = nil, date: Date? = nil, ignored: Bool = false
    ) {
        self.id = id
        self.personId = personId
        self.embedding = VoiceMath.normalized(embedding)
        self.duration = duration
        self.source = source
        self.meetingId = meetingId
        self.segmentId = segmentId
        self.speakerKey = speakerKey
        self.start = start
        self.date = date
        self.ignored = ignored
    }

    /// Lines the user stands behind: they shape a voice; recognised ones only add to it.
    public var isAnchor: Bool { source != .automatic }

    /// Longer lines say more about a voice, up to a point.
    var weight: Float { Float(min(max(duration, 0.5), 20)) }
}

// MARK: - Clustering

/// Groups voice embeddings by similarity.
public enum VoiceClustering {
    /// Lines shorter than this are too unsteady to shape a group (two one-second lines of the same voice
    /// are often less alike than two long lines of different voices); they join the closest group afterwards.
    public static let shapingDuration: Double = 2
    /// Two groups merge while their lines are this alike on average. Lines of one voice are about 0.6–0.85
    /// alike in the app's recordings, lines of different voices 0–0.35.
    public static let mergeThreshold: Float = 0.5
    /// A short line joins a group it is this close to.
    public static let attachThreshold: Float = 0.35

    /// Average-linkage agglomerative clustering, weighted: merges the two most alike groups until no two
    /// are at least `threshold` alike. Indices per group, heaviest group first.
    public static func cluster(_ vectors: [[Float]], weights: [Float], threshold: Float) -> [[Int]] {
        let n = vectors.count
        guard n > 1 else { return n == 1 ? [[0]] : [] }
        var similarity = VoiceMath.similarityMatrix(vectors)
        var members: [[Int]] = (0..<n).map { [$0] }
        var weight = weights.map { max($0, 1e-3) }
        var active = [Bool](repeating: true, count: n)
        var best = [Int](repeating: -1, count: n)
        var bestSimilarity = [Float](repeating: -.infinity, count: n)

        func refresh(_ i: Int) {
            best[i] = -1
            bestSimilarity[i] = -.infinity
            for j in 0..<n where j != i && active[j] && similarity[i * n + j] > bestSimilarity[i] {
                bestSimilarity[i] = similarity[i * n + j]
                best[i] = j
            }
        }
        for i in 0..<n { refresh(i) }

        while true {
            var a = -1
            var top: Float = -.infinity
            for i in 0..<n where active[i] && best[i] >= 0 && bestSimilarity[i] > top {
                top = bestSimilarity[i]
                a = i
            }
            guard a >= 0, top >= threshold else { break }
            let b = best[a]
            let wa = weight[a], wb = weight[b]
            for k in 0..<n where active[k] && k != a && k != b {
                let merged = (wa * similarity[a * n + k] + wb * similarity[b * n + k]) / (wa + wb)
                similarity[a * n + k] = merged
                similarity[k * n + a] = merged
            }
            active[b] = false
            weight[a] = wa + wb
            members[a] += members[b]
            members[b] = []
            refresh(a)
            for k in 0..<n where active[k] && k != a {
                if best[k] == a || best[k] == b {
                    refresh(k)
                } else if similarity[k * n + a] > bestSimilarity[k] {
                    bestSimilarity[k] = similarity[k * n + a]
                    best[k] = a
                }
            }
        }
        return members.enumerated()
            .filter { !$0.element.isEmpty }
            .sorted { weight[$0.offset] > weight[$1.offset] }
            .map(\.element)
    }

    /// Groups lines of speech: long ones are clustered, short ones join the group they are closest to.
    /// Returns the groups (heaviest first) and the lines that fit none.
    public static func groups(_ vectors: [[Float]], durations: [Double], threshold: Float = mergeThreshold) -> (groups: [[Int]], unattached: [Int]) {
        let weights = durations.map { Float(min(max($0, 0.5), 20)) }
        let shaping = vectors.indices.filter { durations[$0] >= shapingDuration }
        // Without any long line, the short ones have to do.
        let core = shaping.isEmpty ? Array(vectors.indices) : shaping
        var groups = cluster(core.map { vectors[$0] }, weights: core.map { weights[$0] }, threshold: threshold)
            .map { $0.map { core[$0] } }
        let centroids = groups.map { centroid(of: $0, in: vectors, weights: weights) }
        var unattached: [Int] = []
        let coreSet = Set(core)
        for index in vectors.indices where !coreSet.contains(index) {
            let scored = centroids.enumerated().map { ($0.offset, VoiceMath.cosine(vectors[index], $0.element)) }
            if let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= attachThreshold {
                groups[best.0].append(index)
            } else {
                unattached.append(index)
            }
        }
        return (groups, unattached)
    }

    static func centroid(of indices: [Int], in vectors: [[Float]], weights: [Float]) -> [Float] {
        VoiceMath.weightedMean(indices.map { (vectors[$0], weights[$0]) }) ?? []
    }
}

// MARK: - A person's voice

/// Everything the app knows about one person's voice: their lines, grouped into voices.
///
/// Most people have one group. A second one appears when they sound different in some meetings (another
/// microphone, a cold); both count. Small groups that sound unlike the rest are strays: a line of someone
/// else that slipped in, a cough, crosstalk. They are shown, but not used to recognise anyone.
public struct VoiceProfile: Sendable {
    public struct Group: Identifiable, Sendable {
        public var id: Int
        /// Indices into the profile's samples, anchors and recognised lines.
        public var members: [Int]
        public var centroid: [Float]
        /// Seconds of confirmed speech (or the user's microphone).
        public var speech: Double
        /// Seconds of speech the app recognised by itself and added.
        public var recognizedSpeech: Double
        public var meetings: Set<String>
        public var lastHeard: Date?
        /// Used to recognise the person. The others are strays.
        public var isTrusted: Bool

        var anchorSum: [Float]
        var recognizedSums: [String: [Float]]
        /// What each meeting's confirmed lines added (weighted sums), to set a meeting aside entirely.
        var anchorSums: [String: [Float]]

        /// The voice without what one meeting's recognised lines added, to judge that meeting fairly.
        func centroid(excluding meetingId: String?) -> [Float] {
            guard let meetingId, recognizedSums[meetingId] != nil else { return centroid }
            var sum = anchorSum
            for (key, part) in recognizedSums where key != meetingId {
                sum = vDSP.add(sum, part)
            }
            return VoiceMath.normalized(sum)
        }

        /// The voice as the other meetings know it, or nil if it comes from this meeting alone.
        func centroid(without meetingId: String) -> [Float]? {
            guard anchorSums[meetingId] != nil || recognizedSums[meetingId] != nil else { return centroid }
            var sum = [Float](repeating: 0, count: anchorSum.count)
            var any = false
            for (key, part) in anchorSums where key != meetingId {
                sum = vDSP.add(sum, part)
                any = true
            }
            guard any else { return nil }
            for (key, part) in recognizedSums where key != meetingId { sum = vDSP.add(sum, part) }
            return VoiceMath.normalized(sum)
        }
    }

    public let personId: String
    public let samples: [VoiceSample]
    public let groups: [Group]
    /// Lines that fit none of the person's voices.
    public let strays: [Int]
    /// Lines the user excluded.
    public let ignored: [Int]

    /// At most this many confirmed lines shape a voice, the newest ones.
    static let maximumAnchors = 600
    /// Recognised lines count half as much as confirmed ones.
    static let recognizedWeight: Float = 0.5
    /// A recognised line joins a voice it is this alike to; otherwise it is a stray.
    static let recognizedAttach: Float = 0.45

    public init(personId: String, samples: [VoiceSample]) {
        self.personId = personId
        self.samples = samples
        ignored = samples.indices.filter { samples[$0].ignored }
        var anchors = samples.indices.filter { samples[$0].isAnchor && !samples[$0].ignored }
        if anchors.count > Self.maximumAnchors {
            anchors = Array(anchors.sorted { (samples[$0].date ?? .distantPast) > (samples[$1].date ?? .distantPast) }.prefix(Self.maximumAnchors))
        }
        let vectors = anchors.map { samples[$0].embedding }
        let (indexGroups, unattached) = VoiceClustering.groups(vectors, durations: anchors.map { samples[$0].duration })
        var strays = unattached.map { anchors[$0] }

        var groups: [Group] = indexGroups.enumerated().map { number, members in
            let indices = members.map { anchors[$0] }
            var sum = [Float](repeating: 0, count: vectors.first?.count ?? 0)
            var byMeeting: [String: [Float]] = [:]
            for index in indices {
                let part = vDSP.multiply(samples[index].weight, samples[index].embedding)
                sum = vDSP.add(sum, part)
                let key = samples[index].meetingId ?? samples[index].id
                byMeeting[key] = vDSP.add(byMeeting[key] ?? [Float](repeating: 0, count: part.count), part)
            }
            return Group(
                id: number, members: indices, centroid: VoiceMath.normalized(sum),
                speech: indices.reduce(0) { $0 + samples[$1].duration }, recognizedSpeech: 0,
                meetings: Set(indices.compactMap { samples[$0].meetingId }),
                lastHeard: indices.compactMap { samples[$0].date }.max(), isTrusted: false,
                anchorSum: sum, recognizedSums: [:], anchorSums: byMeeting
            )
        }
        // The biggest voice always counts; others once they are more than a few stray lines: a real share of
        // the person's speech, or heard again and again across meetings.
        let total = groups.reduce(0) { $0 + $1.speech }
        for index in groups.indices {
            let group = groups[index]
            // A single long line is no voice of its own: it may be someone the diarizer put in with them.
            groups[index].isTrusted = index == 0 || (group.members.count >= 3 && (
                group.speech >= max(20, total * 0.1)
                || (group.meetings.count >= 2 && group.members.count >= 4 && group.speech >= 15)
            ))
        }

        // Recognised lines only join a voice that is already there.
        let trusted = groups.indices.filter { groups[$0].isTrusted }
        for index in samples.indices where samples[index].source == .automatic && !samples[index].ignored {
            let sample = samples[index]
            let scored = trusted.map { ($0, VoiceMath.cosine(sample.embedding, groups[$0].centroid)) }
            guard sample.duration >= 1, let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= Self.recognizedAttach else {
                strays.append(index)
                continue
            }
            let key = sample.meetingId ?? sample.id
            var part = groups[best.0].recognizedSums[key] ?? [Float](repeating: 0, count: sample.embedding.count)
            part = vDSP.add(part, vDSP.multiply(sample.weight * Self.recognizedWeight, sample.embedding))
            groups[best.0].recognizedSums[key] = part
            groups[best.0].members.append(index)
            groups[best.0].recognizedSpeech += sample.duration
            if let meetingId = sample.meetingId { groups[best.0].meetings.insert(meetingId) }
            if let date = sample.date { groups[best.0].lastHeard = max(groups[best.0].lastHeard ?? date, date) }
        }
        // However much was recognised, what the user confirmed keeps two thirds of the say: a few wrong
        // automatic names can't pull a voice towards someone else.
        for index in groups.indices where !groups[index].recognizedSums.isEmpty {
            let group = groups[index]
            let anchorWeight = group.members.filter { samples[$0].isAnchor }.reduce(Float(0)) { $0 + samples[$1].weight }
            let recognizedWeight = group.members.filter { !samples[$0].isAnchor }.reduce(Float(0)) { $0 + samples[$1].weight * Self.recognizedWeight }
            let scale = recognizedWeight > anchorWeight / 2 ? anchorWeight / 2 / recognizedWeight : 1
            if scale < 1 { groups[index].recognizedSums = group.recognizedSums.mapValues { vDSP.multiply(scale, $0) } }
            var sum = groups[index].anchorSum
            for part in groups[index].recognizedSums.values { sum = vDSP.add(sum, part) }
            groups[index].centroid = VoiceMath.normalized(sum)
        }
        self.groups = groups
        self.strays = strays
    }

    public var hasVoice: Bool { groups.contains(where: \.isTrusted) }

    /// Meetings the person's recognised voice comes from.
    public var meetingCount: Int {
        Set(groups.filter(\.isTrusted).flatMap(\.meetings)).count
    }

    /// Seconds of speech behind the voice, confirmed and recognised.
    public var speech: Double {
        groups.filter(\.isTrusted).reduce(0) { $0 + $1.speech + $1.recognizedSpeech }
    }

    /// How alike an embedding is to the closest of the person's voices, without what `meetingId` added itself.
    public func similarity(to embedding: [Float], excludingMeeting meetingId: String? = nil) -> Float? {
        groups.filter(\.isTrusted).map { VoiceMath.cosine(embedding, $0.centroid(excluding: meetingId)) }.max()
    }

    /// How alike an embedding is to the person's voice as the other meetings know it: for showing whom
    /// a voice of `meetingId` sounds like, without the meeting answering for itself.
    public func similarity(to embedding: [Float], without meetingId: String) -> Float? {
        groups.filter(\.isTrusted).compactMap { $0.centroid(without: meetingId) }.map { VoiceMath.cosine(embedding, $0) }.max()
    }

    /// Two strong voices under one name that sound clearly different: perhaps two people.
    public var possibleSplit: (Int, Int)? {
        let strong = groups.filter { $0.isTrusted && $0.speech >= 30 && $0.members.count >= 5 }
        var worst: (Int, Int, Float)?
        for (i, a) in strong.enumerated() {
            for b in strong.dropFirst(i + 1) {
                let similarity = VoiceMath.cosine(a.centroid, b.centroid)
                if similarity < Self.splitThreshold, similarity < (worst?.2 ?? .infinity) { worst = (a.id, b.id, similarity) }
            }
        }
        return worst.map { ($0.0, $0.1) }
    }

    /// Below this, two voices of one person are probably two people. The same person across meetings is
    /// 0.8–0.9 alike in the app's recordings, different people at most about 0.5.
    static let splitThreshold: Float = 0.55
}

// MARK: - Everyone

/// A known person's voice compared with an unknown one.
public struct VoiceMatch: Equatable, Sendable {
    public var personId: String
    public var similarity: Float
    /// How many meetings the person's voice comes from; more make a match more trustworthy.
    public var meetings: Int
}

/// Compares voices against everyone the app has heard before.
public struct VoiceLibrary: Sendable {
    public private(set) var profiles: [String: VoiceProfile]

    public init(samples: [VoiceSample] = []) {
        profiles = Dictionary(grouping: samples, by: \.personId).reduce(into: [:]) { result, entry in
            result[entry.key] = VoiceProfile(personId: entry.key, samples: entry.value)
        }
    }

    /// Each vector a confirmed ten-second sample from a meeting of its own (tests and previews).
    public init(voices: [String: [[Float]]]) {
        var samples: [VoiceSample] = []
        for (personId, vectors) in voices {
            for (index, vector) in vectors.enumerated() {
                samples.append(VoiceSample(id: "\(personId)-\(index)", personId: personId, embedding: vector, duration: 10, source: .confirmed, meetingId: "\(personId)-\(index)"))
            }
        }
        self.init(samples: samples)
    }

    public var isEmpty: Bool { !profiles.values.contains(where: \.hasVoice) }

    /// Learns a voice right away (a name given while recording), until the library is loaded again.
    public mutating func add(_ embedding: [Float], to personId: String, duration: Double = 10, meetingId: String? = nil) {
        let existing = profiles[personId]?.samples ?? []
        let sample = VoiceSample(id: UUID().uuidString, personId: personId, embedding: embedding, duration: duration, source: .confirmed, meetingId: meetingId, date: Date())
        profiles[personId] = VoiceProfile(personId: personId, samples: existing + [sample])
    }

    /// Everyone ranked by similarity, best first.
    ///
    /// A person's score is the similarity to the closest of their voices; strays play no part. People in
    /// `boosted` (the invitees of the calendar event) get a small head start. `excludingMeeting` leaves out
    /// what that meeting's recognised lines added, so a meeting is never judged by itself.
    public func rank(_ embedding: [Float], boosted: Set<String> = [], excluding: Set<String> = [], excludingMeeting: String? = nil) -> [VoiceMatch] {
        profiles.values.compactMap { profile -> VoiceMatch? in
            guard !excluding.contains(profile.personId), var score = profile.similarity(to: embedding, excludingMeeting: excludingMeeting) else { return nil }
            // The score may then exceed 1, which only matters for the order.
            if boosted.contains(profile.personId) { score += 0.04 }
            return VoiceMatch(personId: profile.personId, similarity: score, meetings: max(profile.meetingCount, 1))
        }
        .sorted { $0.similarity > $1.similarity }
    }

    /// Whom a voice of `meetingId` sounds like, judged only by what the other meetings taught the app.
    public func rank(_ embedding: [Float], excluding: Set<String> = [], without meetingId: String) -> [VoiceMatch] {
        profiles.values.compactMap { profile -> VoiceMatch? in
            guard !excluding.contains(profile.personId), let score = profile.similarity(to: embedding, without: meetingId) else { return nil }
            return VoiceMatch(personId: profile.personId, similarity: score, meetings: max(profile.meetingCount, 1))
        }
        .sorted { $0.similarity > $1.similarity }
    }

    /// Whom a voice may be when no one is clear: everyone about as close as the best match (within 0.12)
    /// and not far below a suggestion, at most three, most likely first. Better to name two or three
    /// people than none or the wrong one.
    public static func candidates(_ matches: [VoiceMatch], thresholds: VoiceThresholds, rejected: [String] = []) -> [String] {
        let open = matches.filter { !rejected.contains($0.personId) }
        guard let best = open.first else { return [] }
        let floor = max(thresholds.suggestion - 0.1, best.similarity - 0.12)
        return Array(open.filter { $0.similarity >= floor }.prefix(3).map(\.personId))
    }

    /// How much an embedding sounds like one particular person.
    public func similarity(_ embedding: [Float], to personId: String) -> Float? {
        profiles[personId]?.similarity(to: embedding)
    }
}

// MARK: - Picture

extension VoiceMath {
    /// Cosine similarities of all pairs, row-major n × n.
    static func similarityMatrix(_ vectors: [[Float]]) -> [Float] {
        let n = vectors.count
        guard let d = vectors.first?.count, d > 0, n > 0 else { return [] }
        var flat = [Float](repeating: 0, count: n * d)
        for (i, vector) in vectors.enumerated() where vector.count == d {
            let unit = normalized(vector)
            flat.replaceSubrange(i * d..<(i + 1) * d, with: unit)
        }
        var transposed = [Float](repeating: 0, count: n * d)
        vDSP_mtrans(flat, 1, &transposed, 1, vDSP_Length(d), vDSP_Length(n))
        var result = [Float](repeating: 0, count: n * n)
        vDSP_mmul(flat, 1, transposed, 1, &result, 1, vDSP_Length(n), vDSP_Length(n), vDSP_Length(d))
        return result
    }

    /// The two directions in which the embeddings differ most (principal components), for drawing them
    /// on a plane. The directions come from the vectors at `fitting` (all when nil), so a few outliers can't
    /// squeeze everything else into a dot; coordinates are scaled so those fill -1...1, and the rest is kept
    /// inside that.
    public static func projection(_ vectors: [[Float]], fitting: [Int]? = nil) -> [(x: Float, y: Float)] {
        let n = vectors.count
        guard n > 0, let d = vectors.first?.count, d > 0 else { return [] }
        guard n > 2 else { return n == 1 ? [(0, 0)] : [(-0.5, 0), (0.5, 0)] }
        let basis = (fitting?.count ?? 0) >= 3 ? fitting! : Array(vectors.indices)
        var mean = [Float](repeating: 0, count: d)
        for index in basis where vectors[index].count == d { mean = vDSP.add(mean, vectors[index]) }
        mean = vDSP.divide(mean, Float(basis.count))
        let all = vectors.map { $0.count == d ? vDSP.subtract($0, mean) : [Float](repeating: 0, count: d) }
        let centered = basis.map { all[$0] }
        func component(orthogonalTo previous: [Float]?) -> [Float] {
            var v = (0..<d).map { Float(sin(Double($0) * 12.9898 + 4.1414)) }
            for _ in 0..<60 {
                var next = [Float](repeating: 0, count: d)
                for row in centered {
                    let dot = vDSP.dot(row, v)
                    next = vDSP.add(next, vDSP.multiply(dot, row))
                }
                if let previous {
                    let overlap = vDSP.dot(next, previous)
                    next = vDSP.subtract(next, vDSP.multiply(overlap, previous))
                }
                let norm = sqrt(vDSP.sumOfSquares(next))
                guard norm > 1e-9 else { break }
                v = vDSP.divide(next, norm)
            }
            return v
        }
        let first = component(orthogonalTo: nil)
        let second = component(orthogonalTo: first)
        let points = all.map { (x: vDSP.dot($0, first), y: vDSP.dot($0, second)) }
        let spread = basis.map { max(abs(points[$0].x), abs(points[$0].y)) }.sorted()
        let scale = max(spread[min(spread.count - 1, Int(Double(spread.count) * 0.95))], 1e-6)
        return points.map { (x: max(-1, min(1, $0.x / scale)), y: max(-1, min(1, $0.y / scale))) }
    }
}
