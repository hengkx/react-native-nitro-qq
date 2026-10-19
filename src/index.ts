import { NitroModules } from 'react-native-nitro-modules'
import type {
  QQ as QQSpec,
  QQConfig,
  QQImageShareParams,
  QQLoginResult,
  QQNewsShareParams,
  QQShareResult,
  QQUserInfo,
} from './specs/QQ.nitro'

export type {
  QQConfig,
  QQImageShareParams,
  QQLoginResult,
  QQNewsShareParams,
  QQShareResult,
  QQUserInfo,
}

export const QQ = NitroModules.createHybridObject<QQSpec>('QQ')
