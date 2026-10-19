package com.margelo.nitro.qq

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.facebook.react.bridge.BaseActivityEventListener
import com.margelo.nitro.NitroModules
import com.margelo.nitro.core.Promise
import com.tencent.connect.UserInfo
import com.tencent.connect.share.QQShare
import com.tencent.connect.share.QzoneShare
import com.tencent.tauth.IUiListener
import com.tencent.tauth.Tencent
import com.tencent.tauth.UiError
import org.json.JSONObject
import java.io.File
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import kotlin.math.max

private class QQException(
  val errorCode: String,
  message: String
) : RuntimeException(message)

class HybridQQ : HybridQQSpec() {
  private val context = NitroModules.applicationContext
    ?: throw QQException("no_context", "React Native application context is unavailable")
  private val mainHandler = Handler(Looper.getMainLooper())
  private val stateLock = Any()

  private var appId: String? = null
  private var tencent: Tencent? = null
  private var loginPromise: Promise<QQLoginResult>? = null
  private var userInfoPromise: Promise<QQUserInfo>? = null
  private var sharePromise: Promise<QQShareResult>? = null
  private var loginListener: IUiListener? = null
  private var shareListener: IUiListener? = null

  init {
    context.addActivityEventListener(object : BaseActivityEventListener() {
      override fun onActivityResult(
        activity: Activity,
        requestCode: Int,
        resultCode: Int,
        data: Intent?
      ) {
        val listener = synchronized(stateLock) {
          if (requestCode == Tencent.REQUEST_LOGIN) loginListener else shareListener
        }
        if (listener != null) {
          Tencent.onActivityResultData(requestCode, resultCode, data, listener)
        }
      }
    })
  }

  override fun initialize(config: QQConfig) {
    val id = config.appId.trim()
    if (id.isEmpty()) {
      throw QQException("invalid_app_id", "QQ appId cannot be empty")
    }

    setUserAgreement(config.userAgreement)
    appId = id
    tencent = Tencent.createInstance(id, context, "${context.packageName}.qq.fileprovider")
      ?: throw QQException("initialize_failed", "Tencent.createInstance() returned null")
  }

  override fun setUserAgreement(agreed: Boolean) {
    val methods = Tencent::class.java.methods.filter { it.name == "setIsPermissionGranted" }
    val simple = methods.firstOrNull {
      it.parameterTypes.contentEquals(arrayOf(Boolean::class.javaPrimitiveType))
    }
    if (simple != null) {
      simple.invoke(null, agreed)
      return
    }

    val withModel = methods.firstOrNull { method ->
      method.parameterTypes.size == 2 &&
        method.parameterTypes[0] == Boolean::class.javaPrimitiveType &&
        method.parameterTypes[1] == String::class.java
    }
    withModel?.invoke(null, agreed, android.os.Build.MODEL)
  }

  override fun getSdkVersion(): String = BuildConfig.QQ_SDK_VERSION

  override fun isQQInstalled(): Boolean =
    tencent?.isQQInstalled(context) ?: false

  override fun isSessionValid(): Boolean =
    tencent?.isSessionValid ?: false

  override fun login(scopes: Array<String>): Promise<QQLoginResult> {
    val sdk = requireTencent()
    val activity = currentActivity()
      ?: return Promise.rejected(QQException("no_activity", "QQ login requires a foreground Activity"))

    val promise = Promise<QQLoginResult>()
    synchronized(stateLock) {
      if (loginPromise != null || sharePromise != null) {
        return Promise.rejected(
          QQException("operation_in_progress", "Another QQ login or share operation is already in progress")
        )
      }
      loginPromise = promise
    }

    val listener = object : IUiListener {
      override fun onComplete(response: Any?) {
        val json = response as? JSONObject
        if (json == null) {
          rejectLogin(QQException("invalid_login_response", "QQ returned an invalid login response"))
          return
        }

        val accessToken = json.optString("access_token")
        val openId = json.optString("openid")
        val expiresIn = json.optLong("expires_in", 0)
        if (accessToken.isEmpty() || openId.isEmpty()) {
          rejectLogin(QQException("invalid_login_response", "QQ login returned no access token or openId"))
          return
        }

        sdk.setAccessToken(accessToken, expiresIn.toString())
        sdk.openId = openId
        resolveLogin(
          QQLoginResult(
            accessToken = accessToken,
            openId = openId,
            unionId = json.optString("unionid"),
            expiresAt = System.currentTimeMillis().toDouble() + expiresIn * 1_000.0
          )
        )
      }

      override fun onError(error: UiError) {
        rejectLogin(
          QQException(
            "login_failed_${error.errorCode}",
            error.errorMessage ?: error.errorDetail ?: "QQ login failed"
          )
        )
      }

      override fun onCancel() {
        rejectLogin(QQException("user_cancelled", "QQ login was cancelled"))
      }

      override fun onWarning(code: Int) = Unit
    }
    synchronized(stateLock) { loginListener = listener }

    val scope = scopes.filter { it.isNotBlank() }.ifEmpty { listOf("get_user_info") }.joinToString(",")
    mainHandler.post {
      try {
        sdk.login(activity, scope, listener)
      } catch (error: Throwable) {
        rejectLogin(error)
      }
    }
    return promise
  }

  override fun restoreSession(accessToken: String, openId: String, expiresAt: Double) {
    val sdk = requireTencent()
    val expiresIn = max(0, ((expiresAt - System.currentTimeMillis()) / 1_000).toLong())
    sdk.setAccessToken(accessToken, expiresIn.toString())
    sdk.openId = openId
  }

  override fun logout() {
    tencent?.logout(context)
  }

  override fun getUserInfo(): Promise<QQUserInfo> {
    val sdk = requireTencent()
    if (!sdk.isSessionValid) {
      return Promise.rejected(
        QQException("invalid_session", "QQ session is invalid; call login() first")
      )
    }

    val promise = Promise<QQUserInfo>()
    synchronized(stateLock) {
      if (userInfoPromise != null) {
        return Promise.rejected(
          QQException("operation_in_progress", "A QQ user-info request is already in progress")
        )
      }
      userInfoPromise = promise
    }

    val listener = object : IUiListener {
      override fun onComplete(response: Any?) {
        val json = response as? JSONObject
        if (json == null) {
          rejectUserInfo(QQException("invalid_response", "QQ returned an invalid user-info response"))
          return
        }
        val ret = json.optInt("ret", 0)
        if (ret != 0) {
          rejectUserInfo(
            QQException("user_info_failed_$ret", json.optString("msg", "QQ user-info request failed"))
          )
          return
        }

        resolveUserInfo(
          QQUserInfo(
            nickname = json.optString("nickname"),
            gender = json.optString("gender"),
            province = json.optString("province"),
            city = json.optString("city"),
            year = json.optString("year"),
            avatarUrl = json.optString("figureurl_qq_1"),
            avatarUrlLarge = json.optString("figureurl_qq_2"),
            isVip = json.optString("vip") == "1" || json.optBoolean("vip"),
            level = json.optDouble("level", 0.0),
            raw = json.toString()
          )
        )
      }

      override fun onError(error: UiError) {
        rejectUserInfo(
          QQException(
            "user_info_failed_${error.errorCode}",
            error.errorMessage ?: error.errorDetail ?: "QQ user-info request failed"
          )
        )
      }

      override fun onCancel() {
        rejectUserInfo(QQException("user_cancelled", "QQ user-info request was cancelled"))
      }

      override fun onWarning(code: Int) = Unit
    }

    mainHandler.post {
      try {
        UserInfo(context, sdk.qqToken).getUserInfo(listener)
      } catch (error: Throwable) {
        rejectUserInfo(error)
      }
    }
    return promise
  }

  override fun shareImage(params: QQImageShareParams): Promise<QQShareResult> {
    val activity = currentActivity()
      ?: return Promise.rejected(QQException("no_activity", "QQ sharing requires a foreground Activity"))
    if (!isValidScene(params.scene)) {
      return Promise.rejected(QQException("invalid_scene", "scene must be 'qq' or 'qzone'"))
    }

    val promise = reserveShare()
    if (promise == null) {
      return Promise.rejected(
        QQException("operation_in_progress", "Another QQ login or share operation is already in progress")
      )
    }

    Thread {
      try {
        val imagePath = resolveLocalImage(params.imagePath)
        mainHandler.post {
          val bundle = Bundle().apply {
            if (params.scene == SCENE_QZONE) {
              // 3.5.19 的 QzoneShare 未公开 TARGET_URL/TITLE/SUMMARY 常量，QZone 直接复用 QQ 的 Bundle 键。
              putInt(QzoneShare.SHARE_TO_QZONE_KEY_TYPE, QzoneShare.SHARE_TO_QZONE_TYPE_IMAGE)
              putStringArrayList(QQShare.SHARE_TO_QQ_IMAGE_URL, arrayListOf(imagePath))
              putString(QQShare.SHARE_TO_QQ_TITLE, params.title ?: "")
              putString(QQShare.SHARE_TO_QQ_SUMMARY, params.description ?: "")
            } else {
              putInt(QQShare.SHARE_TO_QQ_KEY_TYPE, QQShare.SHARE_TO_QQ_TYPE_IMAGE)
              putString(QQShare.SHARE_TO_QQ_IMAGE_LOCAL_URL, imagePath)
              putString(QQShare.SHARE_TO_QQ_TITLE, params.title ?: "")
              putString(QQShare.SHARE_TO_QQ_SUMMARY, params.description ?: "")
            }
          }
          startShare(activity, bundle, params.scene)
        }
      } catch (error: Throwable) {
        mainHandler.post { rejectShare(error) }
      }
    }.start()
    return promise
  }

  override fun shareNews(params: QQNewsShareParams): Promise<QQShareResult> {
    val activity = currentActivity()
      ?: return Promise.rejected(QQException("no_activity", "QQ sharing requires a foreground Activity"))
    if (!isValidScene(params.scene)) {
      return Promise.rejected(QQException("invalid_scene", "scene must be 'qq' or 'qzone'"))
    }
    if (!params.url.startsWith("http://") && !params.url.startsWith("https://")) {
      return Promise.rejected(QQException("invalid_url", "Share URL must use http or https"))
    }

    val promise = reserveShare()
    if (promise == null) {
      return Promise.rejected(
        QQException("operation_in_progress", "Another QQ login or share operation is already in progress")
      )
    }

    val bundle = Bundle().apply {
      if (params.scene == SCENE_QZONE) {
        // QZone 图文分享复用 QQ 的 Bundle 键（3.5.19 的 QzoneShare 未公开这些常量）。
        putInt(QzoneShare.SHARE_TO_QZONE_KEY_TYPE, QzoneShare.SHARE_TO_QZONE_TYPE_IMAGE_TEXT)
        putString(QQShare.SHARE_TO_QQ_TARGET_URL, params.url)
        putString(QQShare.SHARE_TO_QQ_TITLE, params.title)
        putString(QQShare.SHARE_TO_QQ_SUMMARY, params.description ?: "")
        params.imageUrl?.let {
          putStringArrayList(QQShare.SHARE_TO_QQ_IMAGE_URL, arrayListOf(it))
        }
      } else {
        putInt(QQShare.SHARE_TO_QQ_KEY_TYPE, QQShare.SHARE_TO_QQ_TYPE_DEFAULT)
        putString(QQShare.SHARE_TO_QQ_TARGET_URL, params.url)
        putString(QQShare.SHARE_TO_QQ_TITLE, params.title)
        putString(QQShare.SHARE_TO_QQ_SUMMARY, params.description ?: "")
        params.imageUrl?.let { putString(QQShare.SHARE_TO_QQ_IMAGE_URL, it) }
      }
    }
    mainHandler.post { startShare(activity, bundle, params.scene) }
    return promise
  }

  override fun handleOpenURL(url: String): Boolean = false

  override fun handleUniversalLink(url: String): Boolean = false

  private fun requireTencent(): Tencent =
    tencent ?: throw QQException("not_initialized", "Call initialize() before using QQ")

  private fun currentActivity(): Activity? = context.currentActivity

  private fun isValidScene(scene: String): Boolean =
    scene == SCENE_QQ || scene == SCENE_QZONE

  private fun reserveShare(): Promise<QQShareResult>? {
    val promise = Promise<QQShareResult>()
    synchronized(stateLock) {
      if (sharePromise != null || loginPromise != null) return null
      sharePromise = promise
    }
    return promise
  }

  private fun startShare(activity: Activity, bundle: Bundle, scene: String) {
    val sdk = try {
      requireTencent()
    } catch (error: Throwable) {
      rejectShare(error)
      return
    }

    val listener = object : IUiListener {
      override fun onComplete(response: Any?) {
        val json = response as? JSONObject
        resolveShare(
          QQShareResult(
            result = json?.optString("ret", "0") ?: "0",
            message = json?.optString("msg", "") ?: ""
          )
        )
      }

      override fun onError(error: UiError) {
        rejectShare(
          QQException(
            "share_failed_${error.errorCode}",
            error.errorMessage ?: error.errorDetail ?: "QQ share failed"
          )
        )
      }

      override fun onCancel() {
        rejectShare(QQException("user_cancelled", "QQ share was cancelled"))
      }

      override fun onWarning(code: Int) = Unit
    }
    synchronized(stateLock) { shareListener = listener }

    try {
      if (scene == SCENE_QZONE) {
        sdk.shareToQzone(activity, bundle, listener)
      } else {
        sdk.shareToQQ(activity, bundle, listener)
      }
    } catch (error: Throwable) {
      rejectShare(error)
    }
  }

  private fun resolveLocalImage(value: String): String {
    val uri = Uri.parse(value)
    if (uri.scheme == "content") {
      val input = context.contentResolver.openInputStream(uri)
        ?: throw QQException("invalid_image", "Cannot open content URI: $value")
      val extension = context.contentResolver.getType(uri)?.substringAfterLast('/') ?: "jpg"
      val output = File.createTempFile("nitro-qq-share-", ".$extension", context.cacheDir)
      input.use { source -> output.outputStream().use { target -> source.copyTo(target) } }
      return output.absolutePath
    }
    if (uri.scheme == "file") {
      return uri.path ?: throw QQException("invalid_image", "Invalid file URI: $value")
    }
    return URLDecoder.decode(value, StandardCharsets.UTF_8.name()).also { path ->
      if (!File(path).isFile) {
        throw QQException("invalid_image", "Image file does not exist: $path")
      }
    }
  }

  private fun resolveLogin(result: QQLoginResult) {
    val promise = synchronized(stateLock) {
      val pending = loginPromise
      loginPromise = null
      loginListener = null
      pending
    }
    promise?.resolve(result)
  }

  private fun rejectLogin(error: Throwable) {
    val promise = synchronized(stateLock) {
      val pending = loginPromise
      loginPromise = null
      loginListener = null
      pending
    }
    promise?.reject(error)
  }

  private fun resolveUserInfo(result: QQUserInfo) {
    val promise = synchronized(stateLock) {
      val pending = userInfoPromise
      userInfoPromise = null
      pending
    }
    promise?.resolve(result)
  }

  private fun rejectUserInfo(error: Throwable) {
    val promise = synchronized(stateLock) {
      val pending = userInfoPromise
      userInfoPromise = null
      pending
    }
    promise?.reject(error)
  }

  private fun resolveShare(result: QQShareResult) {
    val promise = synchronized(stateLock) {
      val pending = sharePromise
      sharePromise = null
      shareListener = null
      pending
    }
    promise?.resolve(result)
  }

  private fun rejectShare(error: Throwable) {
    val promise = synchronized(stateLock) {
      val pending = sharePromise
      sharePromise = null
      shareListener = null
      pending
    }
    promise?.reject(error)
  }

  companion object {
    private const val SCENE_QQ = "qq"
    private const val SCENE_QZONE = "qzone"
  }
}
