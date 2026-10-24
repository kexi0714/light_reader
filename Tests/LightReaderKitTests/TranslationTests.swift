import Foundation
@testable import LightReaderKit

final class TranslationTests {
    func testLineCleanupPreservesParagraphsAndCitation() {
        expectEqual(TextPreparation.normalize("The experi-\nment improves\naccuracy [12].\n\nA second paragraph."), "The experiment improves accuracy [12].\n\nA second paragraph.")
        expectEqual(TextPreparation.normalize("well-known methods"), "well-known methods")
    }
    func testEndpointNormalization() throws {
        try expectEqual(try TranslationService.modelURL("https://example.com").absoluteString, "https://example.com/v1/chat/completions")
        try expectEqual(try TranslationService.modelURL("https://example.com/v1/").path, "/v1/chat/completions")
        try expectEqual(try TranslationService.modelURL("https://example.com/api/v2/chat/completions").path, "/api/v2/chat/completions")
        try expectEqual(try TranslationService.modelURL("http://localhost:8000/v1").port, 8000)
    }
    func testRejectsInsecureRemoteAndAmbiguousURLs() {
        for url in ["http://example.com/v1", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "file:///tmp", "not a url"] {
            expectThrows(try TranslationService.modelURL(url), url)
        }
    }
    func testModelRequestContainsOnlySelectionAndExpectedSchema() throws {
        var config = TranslationConfiguration()
        config.provider = .model
        config.endpoint = "https://example.com/v1"
        config.model = "test-model"
        let request = try TranslationService.request(text: "Selected\ntext [7].", configuration: config, secret: "example-key")
        expectEqual(request.httpMethod, "POST")
        expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer example-key")
        let json = try require(JSONSerialization.jsonObject(with: require(request.httpBody)) as? [String: Any])
        let messages = try require(json["messages"] as? [[String: String]])
        expectEqual(messages.count, 2)
        expectEqual(messages[1]["content"], "Selected text [7].")
        expectEqual(json["model"] as? String, "test-model")
        expectEqual(json["stream"] as? Bool, false)
    }
    func testModelResponses() throws {
        let string = Data(#"{"choices":[{"message":{"content":"  这是译文。  "}}]}"#.utf8)
        try expectEqual(try TranslationService.parse(string, provider: .model), "这是译文。")
        let parts = Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"第一段"},{"type":"text","text":"第二段"}]}}]}"#.utf8)
        try expectEqual(try TranslationService.parse(parts, provider: .model), "第一段\n第二段")
        expectThrows(try TranslationService.parse(Data(#"{"choices":[]}"#.utf8), provider: .model))
    }
    func testBaiduOfficialSigningExample() throws {
        var config = TranslationConfiguration()
        config.provider = .baidu
        config.baiduAppID = "2015063000000001"
        let request = try TranslationService.request(text: "apple", configuration: config, secret: "12345678", salt: "1435660288")
        let body = String(data: try require(request.httpBody), encoding: .utf8)!
        expect(body.contains("sign=f89f9594663708c1605f3d736d01d2d4"))
        expect(body.contains("from=en&to=zh"))
    }
    func testBaiduFormEscapesSpecialCharacters() throws {
        var config = TranslationConfiguration()
        config.provider = .baidu
        config.baiduAppID = "demo"
        let request = try TranslationService.request(text: "a+b & c=2", configuration: config, secret: "demo", salt: "123")
        let body = String(data: try require(request.httpBody), encoding: .utf8)!
        expect(body.hasPrefix("q=a%2Bb%20%26%20c%3D2&"))
    }
    func testBaiduResponseAndServiceErrors() throws {
        let data = Data(#"{"trans_result":[{"src":"A","dst":"甲"},{"src":"B","dst":"乙"}]}"#.utf8)
        try expectEqual(try TranslationService.parse(data, provider: .baidu), "甲\n乙")
        expectThrows(try TranslationService.parse(Data(#"{"error_code":"54001","error_msg":"Invalid Sign"}"#.utf8), provider: .baidu)) { error in
            expect(error.localizedDescription.contains("签名"))
        }
    }
    func testBaiduByteLimitAndMissingConfiguration() {
        var config = TranslationConfiguration()
        expectThrows(try TranslationService.request(text: "Hello", configuration: config, secret: ""))
        config.provider = .baidu
        config.baiduAppID = "demo"
        expectThrows(try TranslationService.request(text: String(repeating: "英", count: 2000), configuration: config, secret: "demo"))
    }
    func testHTTPFailureIsActionable() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var translationConfig = TranslationConfiguration()
        translationConfig.provider = .model
        translationConfig.endpoint = "https://example.com/v1"
        translationConfig.model = "test"
        do {
            _ = try await TranslationService(session: session).translate("Hello", configuration: translationConfig, secret: "fake")
            fail("Expected failure")
        } catch { expect(error.localizedDescription.contains("401")) }
    }
}

private final class FailureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
