import Foundation
import CryptoKit

public struct BaiduTranslationEngine: SubtitleTranslationEngine {
    public static let endpoint = URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!
    public let appID: String
    public let secret: String
    public let timeout: TimeInterval
    var configuration: URLSessionConfiguration = .ephemeral
    public init(appID: String, secret: String, timeout: TimeInterval = 3) {
        self.appID = appID; self.secret = secret; self.timeout = timeout
    }
    static func languageCode(_ language: SubtitleLanguage) -> String {
        switch language {
        case .automatic: return "auto"
        case .simplifiedChinese: return "zh"
        case .traditionalChinese: return "cht"
        case .english: return "en"
        case .japanese: return "jp"
        }
    }
    // Baidu requires MD5 of the original UTF-8 text, before form encoding.
    static func signature(appID: String, text: String, salt: String, secret: String) -> String {
        Insecure.MD5.hash(data: Data((appID + text + salt + secret).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func makeRequest(_ input: TranslationInput, salt: String) throws -> URLRequest {
        guard !appID.isEmpty, !secret.isEmpty else { throw TranslationFailure("请填写百度翻译 APP ID 并保存密钥。") }
        let parameters = [
            "q": input.text, "from": Self.languageCode(input.source), "to": Self.languageCode(input.target),
            "appid": appID, "salt": salt,
            "sign": Self.signature(appID: appID, text: input.text, salt: salt, secret: secret)
        ]
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = parameters.sorted { $0.key < $1.key }.map {
            $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: safe) ?? "")
        }.joined(separator: "&")
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = max(0.1, timeout)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return request
    }
    public func translate(_ input: TranslationInput) async throws -> String {
        if let direct = input.directResult { return direct }
        let request = try makeRequest(input, salt: UUID().uuidString)
        let config = configuration
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = max(0.1, timeout)
        let session = URLSession(configuration: config, delegate: NoBaiduRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranslationFailure("百度翻译连接失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。")
        }
        let payload = try JSONDecoder().decode(Response.self, from: data)
        if let code = payload.error_code, code != "52000" { throw TranslationFailure(Self.errorMessage(code)) }
        let text = payload.trans_result?.map(\.dst).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw TranslationFailure("百度翻译未返回有效译文。") }
        return input.target.normalizeChinese(text)
    }
    private struct Response: Decodable {
        let error_code: String?
        let trans_result: [Entry]?
        struct Entry: Decodable { let dst: String }
    }
    static func errorMessage(_ code: String) -> String {
        switch code {
        case "52001", "52002": return "百度翻译服务超时或暂不可用（\(code)），已跳过本句。"
        case "52003", "54001": return "百度翻译鉴权失败（\(code)），请结束翻译后检查 APP ID 和密钥。"
        case "54003": return "百度翻译请求过于频繁（54003），请增大请求间隔。"
        case "54004": return "百度翻译账户余额不足（54004），请检查账户。"
        case "54005": return "百度翻译长文本请求过于频繁（54005），请缩小字幕区域或增大间隔。"
        case "58000": return "百度翻译 IP 限制（58000），请检查控制台配置。"
        case "58001": return "百度翻译不支持当前语言方向（58001）。"
        case "58002", "90107": return "百度翻译服务尚未开通或认证未完成（\(code)）。"
        default: return "百度翻译失败（\(code)），请检查服务配置。"
        }
    }
}

private final class NoBaiduRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
