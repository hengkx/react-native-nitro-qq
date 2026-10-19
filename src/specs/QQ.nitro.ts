import type { HybridObject } from 'react-native-nitro-modules'

export type QQConfig = {
  appId: string
  universalLink?: string
  enableUniversalLink: boolean
  userAgreement: boolean
}

export type QQLoginResult = {
  accessToken: string
  openId: string
  unionId: string
  expiresAt: number
}

export type QQUserInfo = {
  nickname: string
  gender: string
  province: string
  city: string
  year: string
  avatarUrl: string
  avatarUrlLarge: string
  isVip: boolean
  level: number
  raw: string
}

export type QQImageShareParams = {
  imagePath: string
  title?: string
  description?: string
  scene: string
}

export type QQNewsShareParams = {
  url: string
  title: string
  description?: string
  imageUrl?: string
  scene: string
}

export type QQShareResult = {
  result: string
  message: string
}

export interface QQ
  extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  initialize(config: QQConfig): void
  setUserAgreement(agreed: boolean): void
  getSdkVersion(): string
  isQQInstalled(): boolean
  isSessionValid(): boolean
  login(scopes: string[]): Promise<QQLoginResult>
  restoreSession(accessToken: string, openId: string, expiresAt: number): void
  logout(): void
  getUserInfo(): Promise<QQUserInfo>
  shareImage(params: QQImageShareParams): Promise<QQShareResult>
  shareNews(params: QQNewsShareParams): Promise<QQShareResult>
  handleOpenURL(url: string): boolean
  handleUniversalLink(url: string): boolean
}
