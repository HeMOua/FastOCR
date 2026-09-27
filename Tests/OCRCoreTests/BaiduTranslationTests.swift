import XCTest
@testable import OCRCore

final class BaiduTranslationTests: XCTestCase {
    func testOfficialSigningExample() {
        XCTAssertEqual(BaiduTranslationEngine.signature(appID: "2015063000000001", text: "apple", salt: "1435660288", secret: "12345678"),
                       "f89f9594663708c1605f3d736d01d2d4")
    }
    func testRawUnicodeSignedBeforeEncodingAndLanguageMapping() throws {
        let engine = BaiduTranslationEngine(appID: "test-app", secret: "secret")
        let input = TranslationInput(text: "日本語 + & = ?\n第二行", source: .japanese, target: .traditionalChinese)
        let request = try engine.makeRequest(input, salt: "123")
        let fields = decodeForm(try XCTUnwrap(request.httpBody))
        XCTAssertEqual(request.url, BaiduTranslationEngine.endpoint)
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(fields["q"], input.text)
        XCTAssertEqual(fields["from"], "jp")
        XCTAssertEqual(fields["to"], "cht")
        XCTAssertEqual(fields["sign"], BaiduTranslationEngine.signature(appID: "test-app", text: input.text, salt: "123", secret: "secret"))
        XCTAssertNil(fields["secret"])
        XCTAssertNil(fields["model"])
        XCTAssertNil(fields["messages"])
        XCTAssertEqual(BaiduTranslationEngine.languageCode(.simplifiedChinese), "zh")
        XCTAssertEqual(BaiduTranslationEngine.languageCode(.english), "en")
    }
    private func engine(appID: String = "success") -> BaiduTranslationEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BaiduStub.self]
        var engine = BaiduTranslationEngine(appID: appID, secret: "fake-test-secret")
        engine.configuration = config
        return engine
    }
    func testBaiduMultiLineResponseAndTraditionalConversionWithoutNetwork() async throws {
        let result = try await engine().translate(.init(text: "See you tomorrow", source: .english, target: .traditionalChinese))
        XCTAssertEqual(result, "我們明天見\n一起學習")
    }
    func testHTTPAndProviderErrorsAreActionableWithoutExposingBody() async {
        for (appID, expected) in [("httpfail", "503"), ("authfail", "APP ID"), ("ratefail", "请求间隔")] {
            do {
                _ = try await engine(appID: appID).translate(.init(text: "Hello", source: .english, target: .japanese))
                XCTFail("Expected failure")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("private-response"))
            }
        }
    }
    func testChineseConversionDoesNotRequireCredentialsOrNetwork() async throws {
        let result = try await BaiduTranslationEngine(appID: "", secret: "").translate(.init(text: "学习", source: .simplifiedChinese, target: .traditionalChinese))
        XCTAssertEqual(result, "學習")
    }
}

private func decodeForm(_ data: Data) -> [String: String] {
    Dictionary(uniqueKeysWithValues: String(decoding: data, as: UTF8.self).split(separator: "&").map {
        let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(pair[0]), String(pair[1]).removingPercentEncoding!)
    })
}
private final class BaiduStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let fields = decodeForm(data)
        XCTAssertEqual(request.url, BaiduTranslationEngine.endpoint)
        XCTAssertEqual(fields["sign"], BaiduTranslationEngine.signature(appID: fields["appid"]!, text: fields["q"]!, salt: fields["salt"]!, secret: "fake-test-secret"))
        let appID = fields["appid"]
        let body: String
        switch appID {
        case "authfail": body = #"{"error_code":"54001","error_msg":"private-response"}"#
        case "ratefail": body = #"{"error_code":"54003","error_msg":"private-response"}"#
        default: body = #"{"trans_result":[{"dst":"我们明天见"},{"dst":"一起学习"}]}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: appID == "httpfail" ? 503 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
