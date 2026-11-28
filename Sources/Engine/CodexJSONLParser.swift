import Foundation

/// Incremental, zero-lag C-streamed JSONL parser for OpenAI Codex CLI session logs
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`). Read-only, ~2 MB peak RAM.
public enum CodexJSONLParser {
    private struct CodexLineDTO: Decodable {
        struct PayloadDTO: Decodable {
            struct InfoDTO: Decodable {
                struct TokenUsageDTO: Decodable {
                    let input_tokens: Int64?
                    let cached_input_tokens: Int64?
                    let output_tokens: Int64?
                    let reasoning_output_tokens: Int64?
                    let total_tokens: Int64?
                }
                let last_token_usage: TokenUsageDTO?
                let total_token_usage: TokenUsageDTO?
            }
            let type: String?
            let id: String?
            let cwd: String?
            let model: String?
            let info: InfoDTO?
        }
        let timestamp: String?
        let type: String?
        let payload: PayloadDTO?
    }

    private static let needleTokenCount: [UInt8] = Array("\"token_count\"".utf8)
    private static let needleSessionMeta: [UInt8] = Array("\"session_meta\"".utf8)
    private static let needleTurnContext: [UInt8] = Array("\"turn_context\"".utf8)

    public static func parseIncremental(
        fileURL: URL,
        existingCursor: FileCursor?
    ) -> (records: [UsageRecord], cursor: FileCursor)? {
        let path = fileURL.path
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }

        let fileSize = Int64(st.st_size)
        let inode = Int64(st.st_ino)
        let mtimeNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        let mtime = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))

        var startOffset: Int64 = 0
        if let cur = existingCursor {
            if cur.inode == inode && cur.byteOffset == fileSize && cur.mtimeNs == mtimeNs {
                return nil
            }
            if cur.inode == inode && cur.byteOffset <= fileSize {
                startOffset = cur.byteOffset
            }
        }

        guard let fp = fopen(path, "rb") else { return nil }
        defer { fclose(fp) }

        let decoder = JSONDecoder()
        var sessionId = fileURL.deletingPathExtension().lastPathComponent
        var project = "general"
        var currentModel = "gpt-5-codex"

        // If resuming mid-file, quickly scan up to startOffset with C memmem prefilter
        // so session_meta or turn_context model updates past 16 KB are never dropped.
        if startOffset > 0 {
            var headerBuf: UnsafeMutablePointer<CChar>?
            var headerCap: Int = 0
            defer { if let headerBuf { free(headerBuf) } }
            var scanned: Int64 = 0
            while scanned < startOffset {
                let len = getline(&headerBuf, &headerCap, fp)
                if len <= 0 { break }
                scanned += Int64(len)
                guard let buf = headerBuf else { break }
                let hasMeta = needleSessionMeta.withUnsafeBytes { memmem(buf, len, $0.baseAddress, $0.count) != nil }
                let hasTurn = needleTurnContext.withUnsafeBytes { memmem(buf, len, $0.baseAddress, $0.count) != nil }
                guard hasMeta || hasTurn else { continue }
                let data = Data(bytesNoCopy: buf, count: len, deallocator: .none)
                if let dto = try? decoder.decode(CodexLineDTO.self, from: data) {
                    if dto.type == "session_meta" {
                        if let id = dto.payload?.id, !id.isEmpty { sessionId = id }
                        if let cwd = dto.payload?.cwd, let p = ProjectNormalizer.fromDirectoryPath(cwd) { project = p }
                    } else if dto.type == "turn_context", let m = dto.payload?.model, !m.isEmpty {
                        currentModel = m
                    }
                }
            }
            guard fseeko(fp, off_t(startOffset), SEEK_SET) == 0 else { return nil }
        }

        var records: [UsageRecord] = []
        var consumedOffset = startOffset
        var lineBuf: UnsafeMutablePointer<CChar>?
        var lineCap: Int = 0
        defer { if let lineBuf { free(lineBuf) } }

        while true {
            let readLen = getline(&lineBuf, &lineCap, fp)
            if readLen <= 0 { break }
            guard let buf = lineBuf else { break }
            guard buf[readLen - 1] == 0x0A else { break }
            consumedOffset += Int64(readLen)

            let hasMeta = needleSessionMeta.withUnsafeBytes { memmem(buf, readLen, $0.baseAddress, $0.count) != nil }
            let hasTurn = needleTurnContext.withUnsafeBytes { memmem(buf, readLen, $0.baseAddress, $0.count) != nil }
            let hasTok = needleTokenCount.withUnsafeBytes { memmem(buf, readLen, $0.baseAddress, $0.count) != nil }
            guard hasMeta || hasTurn || hasTok else { continue }

            let lineData = Data(bytesNoCopy: buf, count: readLen, deallocator: .none)
            guard let dto = try? decoder.decode(CodexLineDTO.self, from: lineData) else { continue }

            if dto.type == "session_meta" {
                if let id = dto.payload?.id, !id.isEmpty { sessionId = id }
                if let cwd = dto.payload?.cwd, let p = ProjectNormalizer.fromDirectoryPath(cwd) { project = p }
                continue
            }
            if dto.type == "turn_context" {
                if let m = dto.payload?.model, !m.isEmpty { currentModel = m }
                continue
            }
            guard dto.type == "event_msg",
                  dto.payload?.type == "token_count",
                  let lastUsage = dto.payload?.info?.last_token_usage else { continue }

            let rawInput = lastUsage.input_tokens ?? 0
            let cachedIn = min(rawInput, max(0, lastUsage.cached_input_tokens ?? 0))
            let uncachedIn = max(0, rawInput - cachedIn)
            let outTok = max(0, lastUsage.output_tokens ?? 0)
            guard uncachedIn > 0 || cachedIn > 0 || outTok > 0 else { continue }

            let tsStr = dto.timestamp ?? ""
            let ts = (!tsStr.isEmpty ? LocalDateFormatting.parseISO8601(tsStr) : nil) ?? mtime
            let (day, hour) = LocalDateFormatting.dayAndHour(from: ts)
            let dedupeKey: String
            if let totalTokens = dto.payload?.info?.total_token_usage?.total_tokens {
                dedupeKey = "codex:\(sessionId):total:\(totalTokens)"
            } else {
                dedupeKey = "codex:\(sessionId):\(tsStr):\(rawInput + outTok)"
            }

            let pricing = PricingCatalog.pricing(for: currentModel)
            let (cost, saved) = pricing.computeCost(
                input: uncachedIn,
                output: outTok,
                cacheRead: cachedIn,
                cacheCreate: 0
            )

            records.append(UsageRecord(
                dedupeKey: dedupeKey,
                day: day,
                hour: hour,
                provider: ProviderKind.codex.rawValue,
                source: "codex-cli",
                model: pricing.canonicalName,
                project: project,
                sessionId: "codex:\(sessionId)",
                inputTokens: uncachedIn,
                outputTokens: outTok,
                cacheReadTokens: cachedIn,
                cacheCreateTokens: 0,
                costUSD: cost,
                cacheSavedUSD: saved,
                isEstimated: pricing.isEstimated
            ))
        }

        let newCursor = FileCursor(
            path: path,
            inode: inode,
            byteOffset: consumedOffset,
            lastStepIdx: -1,
            lastGenIdx: -1,
            mtimeNs: mtimeNs
        )
        return (records, newCursor)
    }
}
