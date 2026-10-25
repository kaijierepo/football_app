# football_flutter_app

竞彩足球 APP：泊松预测、任九、历史战绩、方案与多模型推荐。后端见
[football_poisson](https://github.com/kaijierepo/football_poisson)。

## 首次安装

1. 从 [Releases](https://github.com/kaijierepo/football_app/releases/latest) 下载最新 APK 安装。
2. 打开 APP → 设置 → 填服务器地址 `http://45.205.20.212:8000` 和 API Token
   （服务端 `data/config.json` 的 `api_token`）。

## 自动更新

- 每次 `pubspec.yaml` 的 `version` 变化并推送到 `main`，GitHub Actions 会构建
  release APK 并发布为 `v<版本>-<build号>` 的 Release（例如 `v1.0.2-3`）。
- APP 启动时静默检查最新 Release，设置页也可手动「检查更新」；发现更高
  `versionCode` 时点击「下载并安装」，由系统安装器覆盖升级。
- **升级的前提是签名一致**：CI 使用仓库 Secrets 中的同一份 keystore
  （`ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` /
  `ANDROID_KEY_PASSWORD`）。请勿更换，否则已装用户必须卸载重装。

## 本地开发

```bash
flutter pub get
flutter run                  # 调试
flutter build apk --release  # 本地打包（无 android/key.properties 时用 debug 签名）
```

## 发版流程

1. 修改 `pubspec.yaml`：`version: 1.0.2+3`（`+` 后的 build 号必须递增）。
2. 提交并推送到 `main`。
3. Actions 构建完成后，手机打开 APP → 设置 → 检查更新 → 下载并安装。
