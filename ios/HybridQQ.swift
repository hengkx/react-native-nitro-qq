import Foundation
import NitroModules
import TencentOpenApi
import UIKit

private enum QQScene {
  static let qq = "qq"
  static let qzone = "qzone"
}

private enum QQBridgeError {
  static func make(_ code: String, _ message: String) -> NSError {
    NSError(
      domain: "react-native-nitro-qq",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: message,
        "code": code,
      ]
    )
  }
}

private final class QQBridge: NSObject, TencentSessionDelegate, QQApiInterfaceDelegate {
  static let shared = QQBridge()

  private let lock = NSLock()
  private var appId: String?
  private var universalLink: String?
  private var enableUniversalLink = false
  private var loginPromise: Promise<QQLoginResult>?
  private var userInfoPromise: Promise<QQUserInfo>?
  private var sharePromise: Promise<QQShareResult>?

  private override init() {
    super.init()
  }

  func initialize(config: QQConfig) throws {
    guard !config.appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw QQBridgeError.make("invalid_app_id", "QQ appId cannot be empty")
    }

    appId = config.appId
    universalLink = config.universalLink
    enableUniversalLink = config.enableUniversalLink
    TencentOAuth.setIsUserAgreedAuthorization(config.userAgreement)
    try setupOAuth()
  }

  func setUserAgreement(_ agreed: Bool) {
    TencentOAuth.setIsUserAgreedAuthorization(agreed)
  }

  func getSdkVersion() -> String {
    TencentOAuth.sdkVersion()
  }

  func isQQInstalled() -> Bool {
    QQApiInterface.isQQInstalled()
  }

  func isSessionValid() -> Bool {
    TencentOAuth.sharedInstance()?.isSessionValid() ?? false
  }

  func login(scopes: [String]) -> Promise<QQLoginResult> {
    do {
      try setupOAuth()
    } catch {
      return Promise.rejected(withError: error)
    }

    let promise = Promise<QQLoginResult>()
    lock.lock()
    guard loginPromise == nil else {
      lock.unlock()
      return Promise.rejected(
        withError: QQBridgeError.make("operation_in_progress", "A QQ login is already in progress")
      )
    }
    loginPromise = promise
    lock.unlock()

    let permissions = scopes.isEmpty ? ["get_user_info"] : scopes
    DispatchQueue.main.async { [weak self] in
      guard let self, let oauth = TencentOAuth.sharedInstance() else {
        self?.rejectLogin(QQBridgeError.make("not_initialized", "QQ SDK is not initialized"))
        return
      }
      if !oauth.authorize(permissions) {
        self.rejectLogin(
          QQBridgeError.make("login_start_failed", TencentOAuth.getLastErrorMsg() ?? "Unable to start QQ login")
        )
      }
    }
    return promise
  }

  func restoreSession(accessToken: String, openId: String, expiresAt: Double) throws {
    try setupOAuth()
    guard let oauth = TencentOAuth.sharedInstance() else {
      throw QQBridgeError.make("not_initialized", "QQ SDK is not initialized")
    }
    oauth.accessToken = accessToken
    oauth.openId = openId
    oauth.expirationDate = Date(timeIntervalSince1970: expiresAt / 1_000)
  }

  func logout() {
    DispatchQueue.main.async {
      TencentOAuth.sharedInstance()?.logout(self)
    }
  }

  func getUserInfo() -> Promise<QQUserInfo> {
    guard let oauth = TencentOAuth.sharedInstance(), oauth.isSessionValid() else {
      return Promise.rejected(
        withError: QQBridgeError.make("invalid_session", "QQ session is invalid; call login() first")
      )
    }

    let promise = Promise<QQUserInfo>()
    lock.lock()
    guard userInfoPromise == nil else {
      lock.unlock()
      return Promise.rejected(
        withError: QQBridgeError.make("operation_in_progress", "A QQ user-info request is already in progress")
      )
    }
    userInfoPromise = promise
    lock.unlock()

    DispatchQueue.main.async { [weak self] in
      guard oauth.getUserInfo() else {
        self?.rejectUserInfo(
          QQBridgeError.make("request_start_failed", "Unable to start QQ user-info request")
        )
        return
      }
    }
    return promise
  }

  func shareImage(params: QQImageShareParams) -> Promise<QQShareResult> {
    guard params.scene == QQScene.qq || params.scene == QQScene.qzone else {
      return Promise.rejected(
        withError: QQBridgeError.make("invalid_scene", "scene must be 'qq' or 'qzone'")
      )
    }

    let fileURL = localFileURL(params.imagePath)
    guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
      return Promise.rejected(
        withError: QQBridgeError.make("invalid_image", "Cannot read imagePath: \(params.imagePath)")
      )
    }
    guard data.count <= 5 * 1_024 * 1_024 else {
      return Promise.rejected(
        withError: QQBridgeError.make("image_too_large", "QQ images cannot exceed 5 MB")
      )
    }

    let title = params.title ?? ""
    let detail = params.description ?? ""
    let object: QQApiObject
    if params.scene == QQScene.qzone {
      guard let image = QQApiImageArrayForQZoneObject(
        imageArrayData: [data],
        title: title,
        extMap: [:]
      ) else {
        return Promise.rejected(withError: QQBridgeError.make("invalid_image", "Cannot create QZone image payload"))
      }
      object = image
    } else {
      guard let image = QQApiImageObject(
        data: data,
        previewImageData: makePreviewData(data),
        title: title,
        description: detail
      ) else {
        return Promise.rejected(withError: QQBridgeError.make("invalid_image", "Cannot create QQ image payload"))
      }
      object = image
    }
    return send(object: object, scene: params.scene)
  }

  func shareNews(params: QQNewsShareParams) -> Promise<QQShareResult> {
    guard params.scene == QQScene.qq || params.scene == QQScene.qzone else {
      return Promise.rejected(
        withError: QQBridgeError.make("invalid_scene", "scene must be 'qq' or 'qzone'")
      )
    }
    guard let url = URL(string: params.url), url.scheme != nil else {
      return Promise.rejected(withError: QQBridgeError.make("invalid_url", "Invalid share URL"))
    }

    let previewURL = params.imageUrl.flatMap(URL.init(string:))
    guard let news = QQApiNewsObject.object(
      with: url,
      title: params.title,
      description: params.description ?? "",
      previewImageURL: previewURL
    ) as? QQApiNewsObject else {
      return Promise.rejected(withError: QQBridgeError.make("invalid_payload", "Cannot create QQ news payload"))
    }
    return send(object: news, scene: params.scene)
  }

  func handleOpenURL(_ url: URL) -> Bool {
    let shareHandled = QQApiInterface.handleOpen(url, delegate: self)
    let authHandled = TencentOAuth.canHandleOpen(url) ? TencentOAuth.handleOpen(url) : false
    return shareHandled || authHandled
  }

  func handleUniversalLink(_ url: URL) -> Bool {
    let shareHandled = QQApiInterface.handleOpenUniversallink(url, delegate: self)
    let authHandled = TencentOAuth.canHandleUniversalLink(url)
      ? TencentOAuth.handleUniversalLink(url)
      : false
    return shareHandled || authHandled
  }

  private func setupOAuth() throws {
    guard TencentOAuth.isUserAgreedAuthorization() else {
      throw QQBridgeError.make(
        "user_agreement_required",
        "Call initialize({ userAgreement: true }) after the user accepts QQ's privacy terms"
      )
    }
    guard let appId else {
      throw QQBridgeError.make("not_initialized", "Call initialize() before using QQ")
    }

    let setup = {
      TencentOAuth.sharedInstance()?.setupAppId(
        appId,
        enableUniveralLink: self.enableUniversalLink,
        universalLink: self.universalLink,
        delegate: self
      )
    }
    if Thread.isMainThread {
      setup()
    } else {
      DispatchQueue.main.sync(execute: setup)
    }
  }

  private func send(object: QQApiObject, scene: String) -> Promise<QQShareResult> {
    if let universalLink {
      object.universalLink = universalLink
    }
    guard let request = SendMessageToQQReq(content: object) else {
      return Promise.rejected(withError: QQBridgeError.make("invalid_payload", "Cannot create QQ share request"))
    }

    let promise = Promise<QQShareResult>()
    lock.lock()
    guard sharePromise == nil else {
      lock.unlock()
      return Promise.rejected(
        withError: QQBridgeError.make("operation_in_progress", "A QQ share is already in progress")
      )
    }
    sharePromise = promise
    lock.unlock()

    DispatchQueue.main.async { [weak self] in
      let result = scene == QQScene.qzone
        ? QQApiInterface.sendReq(toQZone: request)
        : QQApiInterface.send(request)
      guard result.rawValue == 0 else {
        self?.rejectShare(
          QQBridgeError.make("share_start_failed", "QQ SDK rejected the share request (\(result.rawValue))")
        )
        return
      }
    }
    return promise
  }

  private func localFileURL(_ path: String) -> URL {
    if let url = URL(string: path), url.isFileURL {
      return url
    }
    return URL(fileURLWithPath: path.removingPercentEncoding ?? path)
  }

  private func makePreviewData(_ data: Data) -> Data {
    if data.count <= 1_024 * 1_024 {
      return data
    }
    guard let image = UIImage(data: data) else {
      return data
    }
    let maxSide: CGFloat = 240
    let scale = min(maxSide / image.size.width, maxSide / image.size.height, 1)
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: size)
    let preview = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    return preview.jpegData(compressionQuality: 0.75) ?? data
  }

  private func rawJSON(_ dictionary: [AnyHashable: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(dictionary),
          let data = try? JSONSerialization.data(withJSONObject: dictionary) else {
      return "{}"
    }
    return String(data: data, encoding: .utf8) ?? "{}"
  }

  private func string(_ dictionary: [AnyHashable: Any], _ key: String) -> String {
    if let value = dictionary[key] as? String { return value }
    if let value = dictionary[key] as? NSNumber { return value.stringValue }
    return ""
  }

  private func bool(_ dictionary: [AnyHashable: Any], _ key: String) -> Bool {
    let value = string(dictionary, key).lowercased()
    return value == "1" || value == "true" || value == "yes"
  }

  private func double(_ dictionary: [AnyHashable: Any], _ key: String) -> Double {
    Double(string(dictionary, key)) ?? 0
  }

  private func takeLoginPromise() -> Promise<QQLoginResult>? {
    lock.lock()
    defer { lock.unlock() }
    let promise = loginPromise
    loginPromise = nil
    return promise
  }

  private func rejectLogin(_ error: Error) {
    takeLoginPromise()?.reject(withError: error)
  }

  private func takeUserInfoPromise() -> Promise<QQUserInfo>? {
    lock.lock()
    defer { lock.unlock() }
    let promise = userInfoPromise
    userInfoPromise = nil
    return promise
  }

  private func rejectUserInfo(_ error: Error) {
    takeUserInfoPromise()?.reject(withError: error)
  }

  private func takeSharePromise() -> Promise<QQShareResult>? {
    lock.lock()
    defer { lock.unlock() }
    let promise = sharePromise
    sharePromise = nil
    return promise
  }

  private func rejectShare(_ error: Error) {
    takeSharePromise()?.reject(withError: error)
  }

  func tencentDidLogin() {
    guard let oauth = TencentOAuth.sharedInstance(),
          let accessToken = oauth.accessToken, !accessToken.isEmpty,
          let openId = oauth.openId, !openId.isEmpty else {
      rejectLogin(QQBridgeError.make("invalid_login_response", "QQ login returned no access token or openId"))
      return
    }
    takeLoginPromise()?.resolve(
      withResult: QQLoginResult(
        accessToken: accessToken,
        openId: openId,
        unionId: oauth.unionid ?? "",
        expiresAt: (oauth.expirationDate?.timeIntervalSince1970 ?? 0) * 1_000
      )
    )
  }

  func tencentDidNotLogin(_ cancelled: Bool) {
    rejectLogin(
      QQBridgeError.make(
        cancelled ? "user_cancelled" : "login_failed",
        cancelled ? "QQ login was cancelled" : (TencentOAuth.getLastErrorMsg() ?? "QQ login failed")
      )
    )
  }

  func tencentDidNotNetWork() {
    rejectLogin(QQBridgeError.make("network_error", "QQ login failed because the network is unavailable"))
  }

  func getUserInfoResponse(_ response: APIResponse!) {
    guard let response else {
      rejectUserInfo(QQBridgeError.make("invalid_response", "QQ returned an empty user-info response"))
      return
    }
    guard response.retCode == 0, let json = response.jsonResponse else {
      rejectUserInfo(
        QQBridgeError.make("user_info_failed", response.errorMsg ?? "QQ user-info request failed")
      )
      return
    }
    let serverRet = (json["ret"] as? NSNumber)?.intValue ?? Int(string(json, "ret")) ?? 0
    guard serverRet == 0 else {
      rejectUserInfo(
        QQBridgeError.make("user_info_failed", string(json, "msg").isEmpty ? "QQ user-info request failed" : string(json, "msg"))
      )
      return
    }

    takeUserInfoPromise()?.resolve(
      withResult: QQUserInfo(
        nickname: string(json, "nickname"),
        gender: string(json, "gender"),
        province: string(json, "province"),
        city: string(json, "city"),
        year: string(json, "year"),
        avatarUrl: string(json, "figureurl_qq_1"),
        avatarUrlLarge: string(json, "figureurl_qq_2"),
        isVip: bool(json, "vip"),
        level: double(json, "level"),
        raw: rawJSON(json)
      )
    )
  }

  func onReq(_ req: QQBaseReq!) {}

  func onResp(_ resp: QQBaseResp!) {
    guard let resp else {
      rejectShare(QQBridgeError.make("invalid_response", "QQ returned an empty share response"))
      return
    }
    let result = resp.result ?? ""
    let message = resp.errorDescription ?? resp.extendInfo ?? ""
    if result == "0" {
      takeSharePromise()?.resolve(withResult: QQShareResult(result: result, message: message))
    } else {
      rejectShare(
        QQBridgeError.make(
          result == "-4" ? "user_cancelled" : "share_failed",
          message.isEmpty ? "QQ share failed (\(result))" : message
        )
      )
    }
  }

  func isOnlineResponse(_ response: [AnyHashable: Any]!) {}
}

final class HybridQQ: HybridQQSpec {
  func initialize(config: QQConfig) throws {
    try QQBridge.shared.initialize(config: config)
  }

  func setUserAgreement(agreed: Bool) throws {
    QQBridge.shared.setUserAgreement(agreed)
  }

  func getSdkVersion() throws -> String {
    QQBridge.shared.getSdkVersion()
  }

  func isQQInstalled() throws -> Bool {
    QQBridge.shared.isQQInstalled()
  }

  func isSessionValid() throws -> Bool {
    QQBridge.shared.isSessionValid()
  }

  func login(scopes: [String]) throws -> Promise<QQLoginResult> {
    QQBridge.shared.login(scopes: scopes)
  }

  func restoreSession(accessToken: String, openId: String, expiresAt: Double) throws {
    try QQBridge.shared.restoreSession(accessToken: accessToken, openId: openId, expiresAt: expiresAt)
  }

  func logout() throws {
    QQBridge.shared.logout()
  }

  func getUserInfo() throws -> Promise<QQUserInfo> {
    QQBridge.shared.getUserInfo()
  }

  func shareImage(params: QQImageShareParams) throws -> Promise<QQShareResult> {
    QQBridge.shared.shareImage(params: params)
  }

  func shareNews(params: QQNewsShareParams) throws -> Promise<QQShareResult> {
    QQBridge.shared.shareNews(params: params)
  }

  func handleOpenURL(url: String) throws -> Bool {
    guard let url = URL(string: url) else { return false }
    return QQBridge.shared.handleOpenURL(url)
  }

  func handleUniversalLink(url: String) throws -> Bool {
    guard let url = URL(string: url) else { return false }
    return QQBridge.shared.handleUniversalLink(url)
  }
}

@objc(NitroQQApplicationDelegate)
public final class QQApplicationDelegate: NSObject {
  @objc(handleOpenURL:)
  public static func handleOpenURL(_ url: URL) -> Bool {
    QQBridge.shared.handleOpenURL(url)
  }

  @objc(handleUniversalLink:)
  public static func handleUniversalLink(_ url: URL) -> Bool {
    QQBridge.shared.handleUniversalLink(url)
  }
}
