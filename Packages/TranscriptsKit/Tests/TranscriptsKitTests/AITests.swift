import Foundation
import Testing
@testable import TranscriptsKit

/// Answers HTTP requests from a closure, so the providers can be tested without the network.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            request.httpBody = data
        }
        Self.requests.append(request)
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static func body(of request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }
}

private let summaryJSON = """
{"title":"Release-Planung","overview":"Das Release wird verschoben.","decisions":["Release am 14."],"actionItems":[{"text":"PDF-Export fixen","owner":"Lukas","due":"Mittwoch"},{"text":"Mail an Kunden","owner":"","due":""}],"openQuestions":[],"speakerNames":[{"speaker":"Sprecher 4","name":"Jonas","evidence":"Gute Idee, Jonas."}]}
"""

@Suite(.serialized) struct ProviderTests {
    @Test func anthropicSendsStructuredOutputAndFallbacks() async throws {
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { _ in
            (200, MockURLProtocol.json(["stop_reason": "end_turn", "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": summaryJSON]]]))
        }
        let provider = AnthropicProvider(apiKey: "sk-ant-test", session: MockURLProtocol.session())
        let text = try await provider.complete(LLMRequest(system: "sys", prompt: "hi", schema: Summarizer.summarySchema), model: "claude-opus-5-5")
        #expect(text == summaryJSON)
        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let body = MockURLProtocol.body(of: request)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["thinking"] == nil)
        let config = try #require(body["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "medium")
        #expect((config["format"] as? [String: Any])?["type"] as? String == "json_schema")
    }

    @Test func anthropicOlderModelsGetNoEffortOrFallback() async throws {
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { _ in (200, MockURLProtocol.json(["stop_reason": "end_turn", "content": [["type": "text", "text": "{}"]]])) }
        let provider = AnthropicProvider(apiKey: "k", session: MockURLProtocol.session())
        _ = try await provider.complete(LLMRequest(system: "s", prompt: "p"), model: "claude-haiku-4-5")
        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        let body = MockURLProtocol.body(of: request)
        #expect(body["output_config"] == nil)
        #expect(body["fallbacks"] == nil)
    }

    @Test func anthropicRefusalAndTruncationBecomeErrors() async throws {
        let provider = AnthropicProvider(apiKey: "k", session: MockURLProtocol.session())
        MockURLProtocol.handler = { _ in (200, MockURLProtocol.json(["stop_reason": "refusal", "stop_details": ["category": "cyber"], "content": []])) }
        await #expect(throws: LLMError.refused("cyber")) {
            try await provider.complete(LLMRequest(system: "s", prompt: "p"), model: "claude-opus-5-5")
        }
        MockURLProtocol.handler = { _ in (200, MockURLProtocol.json(["stop_reason": "max_tokens", "content": [["type": "text", "text": "{"]]])) }
        await #expect(throws: LLMError.truncated) {
            try await provider.complete(LLMRequest(system: "s", prompt: "p"), model: "claude-opus-5-5")
        }
    }

    @Test func badKeyIsReported() async throws {
        MockURLProtocol.handler = { _ in (401, MockURLProtocol.json(["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]])) }
        let provider = AnthropicProvider(apiKey: "wrong", session: MockURLProtocol.session())
        await #expect(throws: LLMError.invalidKey(.anthropic)) { try await provider.models() }
    }

    @Test func anthropicModelListPutsTheDefaultFirst() async throws {
        MockURLProtocol.handler = { _ in
            (200, MockURLProtocol.json(["data": [
                ["id": "claude-fable-5-1", "display_name": "Claude Fable 5.1"],
                ["id": "claude-opus-5-5", "display_name": "Claude Opus 5.5"],
                ["id": "claude-sonnet-5-5", "display_name": "Claude Sonnet 5.5"],
            ]]))
        }
        let models = try await AnthropicProvider(apiKey: "k", session: MockURLProtocol.session()).models()
        #expect(models.first?.id == "claude-opus-5-5")
        #expect(models.count == 3)
    }

    @Test func openAIFallsBackWhenStructuredOutputIsRejected() async throws {
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            let body = MockURLProtocol.body(of: request)
            if (body["response_format"] as? [String: Any])?["type"] as? String == "json_schema" {
                return (400, MockURLProtocol.json(["error": ["message": "response_format json_schema is not supported with this model"]]))
            }
            return (200, MockURLProtocol.json(["choices": [["finish_reason": "stop", "message": ["content": summaryJSON]]]]))
        }
        let text = try await OpenAIProvider(apiKey: "sk-test", session: MockURLProtocol.session())
            .complete(LLMRequest(system: "s", prompt: "p", schema: Summarizer.summarySchema), model: "gpt-x")
        #expect(text == summaryJSON)
        #expect(MockURLProtocol.requests.count == 2)
        #expect(MockURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }

    @Test func openAIModelsAreFilteredAndOrdered() async throws {
        MockURLProtocol.handler = { _ in
            (200, MockURLProtocol.json(["data": ["gpt-4o-mini", "gpt-5-mini", "gpt-5", "text-embedding-3-small", "gpt-5-2025-08-07", "whisper-1", "gpt-4o-realtime-preview", "o3"].map { ["id": $0] }]))
        }
        let ids = try await OpenAIProvider(apiKey: "k", session: MockURLProtocol.session()).models().map(\.id)
        #expect(ids.first == "gpt-5")
        #expect(!ids.contains("whisper-1"))
        #expect(!ids.contains("text-embedding-3-small"))
        #expect(!ids.contains("gpt-4o-realtime-preview"))
        #expect(ids.firstIndex(of: "gpt-5") ?? 9 < ids.firstIndex(of: "gpt-5-mini") ?? 0)
    }

    @Test func geminiCallsGenerateContentAndSkipsThoughts() async throws {
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { _ in
            (200, MockURLProtocol.json(["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "thinking…", "thought": true], ["text": summaryJSON]]]]]]))
        }
        let text = try await GeminiProvider(apiKey: "AIza-test", session: MockURLProtocol.session())
            .complete(LLMRequest(system: "s", prompt: "p", schema: Summarizer.summarySchema), model: "gemini-3-flash")
        #expect(text == summaryJSON)
        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-test")
    }

    @Test func ollamaStripsThinkingAndSendsTheSchema() async throws {
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { _ in
            (200, MockURLProtocol.json(["done": true, "done_reason": "stop", "message": ["role": "assistant", "content": "<think>hmm</think>\n" + summaryJSON]]))
        }
        let text = try await OllamaProvider(session: MockURLProtocol.session())
            .complete(LLMRequest(system: "s", prompt: "p", schema: Summarizer.summarySchema), model: "qwen3:8b")
        #expect(text == summaryJSON)
        let body = MockURLProtocol.body(of: try #require(MockURLProtocol.requests.first))
        #expect(body["stream"] as? Bool == false)
        #expect(body["think"] as? Bool == false)
        #expect(body["format"] is [String: Any])
        #expect(MockURLProtocol.requests.first?.url?.absoluteString == "http://localhost:11434/api/chat")
    }
}

extension ProviderTests {
    @Test func ollamaRetriesWithoutThinkSwitchWhenUnsupported() async throws {
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { request in
            if MockURLProtocol.body(of: request)["think"] != nil {
                return (400, MockURLProtocol.json(["error": "\"llama3\" does not support thinking"]))
            }
            return (200, MockURLProtocol.json(["done": true, "message": ["content": "{}"]]))
        }
        let text = try await OllamaProvider(session: MockURLProtocol.session()).complete(LLMRequest(system: "s", prompt: "p"), model: "llama3")
        #expect(text == "{}")
        #expect(MockURLProtocol.requests.count == 2)
    }
}

@Suite struct SummaryParsingTests {
    @Test func parsesAFullSummary() throws {
        let outcome = try Summarizer.parse(summaryJSON)
        #expect(outcome.title == "Release-Planung")
        #expect(outcome.decisions == ["Release am 14."])
        #expect(outcome.actionItems.count == 2)
        #expect(outcome.actionItems[0].owner == "Lukas")
        #expect(outcome.actionItems[1].owner == nil)
        #expect(outcome.actionItems[1].due == nil)
        #expect(outcome.speakerNames == [SpeakerNameHint(speakerLabel: "Sprecher 4", name: "Jonas", evidence: "Gute Idee, Jonas.")])
    }

    @Test func toleratesFencesProseAndBracesInStrings() throws {
        let messy = "Hier ist die Zusammenfassung:\n```json\n{\"overview\":\"Ein {kleiner} Test\",\"decisions\":[],\"actionItems\":[\"Nur Text\"],\"openQuestions\":[]}\n```\nViel Erfolg!"
        let outcome = try Summarizer.parse(messy)
        #expect(outcome.overview == "Ein {kleiner} Test")
        #expect(outcome.actionItems.first?.text == "Nur Text")
    }

    @Test func missingOverviewIsAnError() {
        #expect(throws: LLMError.self) { try Summarizer.parse("{\"decisions\":[]}") }
        #expect(throws: LLMError.self) { try Summarizer.parse("Sorry, I can't help.") }
    }

    @Test func longTranscriptsAreSplitAtLines() {
        let text = (1...100).map { "[00:\($0)] Anna: Satz Nummer \($0) mit etwas Inhalt." }.joined(separator: "\n")
        let chunks = Summarizer.chunks(text, size: 500)
        #expect(chunks.count > 5)
        #expect(chunks.allSatisfy { $0.count <= 500 })
        #expect(chunks.joined(separator: "\n") == text)
    }

    @Test func transcriptUsesNamesAndTheUser() {
        let meeting = Meeting(id: "m", title: "T")
        let detail = MeetingDetail(
            meeting: meeting,
            segments: [Segment(meetingId: "m", speakerKey: "me", channel: .microphone, start: 3, end: 4, text: "Hallo."), Segment(meetingId: "m", speakerKey: "S1", channel: .system, start: 65, end: 66, text: "Hi.")],
            speakers: [MeetingSpeaker(meetingId: "m", key: "S1", label: "Sprecher 1", personId: "a")],
            people: ["a": Person(id: "a", name: "Anna Berger")],
            summary: nil, actionItems: [], markers: []
        )
        #expect(Summarizer.transcriptText(detail, myName: "Lukas") == "[00:03] Lukas: Hallo.\n[01:05] Anna Berger: Hi.")
    }
}
