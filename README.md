# Raycast macOS Utilities

このREADMEはmacOS向けのRaycast Script Commandsです。現時点では、Google Drive for desktop上のファイルを扱う次の2機能を含みます。

| Script Command | 機能 | 認証 |
| --- | --- | --- |
| `jobcan-touch.applescript` | Slackの自分宛DMへJobcanコマンドを送信 | Keychain |
| `google-drive_active-document-link-copier_gdrivefs.sh` | 最前面で開いているGoogle DriveファイルのURLをクリップボードへコピー | 不要 |
| `google-drive-path-generator.sh` | クリップボード上のGoogle Drive URLに対応するローカル項目を開く | Google Drive API OAuth |

## インストール

1. RaycastのScript Commandsとして、このディレクトリ内の `.sh` ファイルを登録します
2. Google Drive for desktopをインストールし、対象のMy Driveまたは共有ドライブをFinderで参照できる状態にします
3. `google-drive-path-generator.sh` を使う場合は、[googleDrivePathGenerator/readme.md](googleDrivePathGenerator/readme.md) のセットアップを行います

## Jobcan touch

`jobcan-touch.applescript` は、RaycastからSlack Desktopの自分宛DMに `/jobcan_touch` を1回送るScript Commandです。Slackの送信先URLはKeychainだけから取得し、公開リポジトリには保存しません。

### 設定

1. macOSのキーチェーンアクセスで、ログインキーチェーンに一般パスワード項目を作成します。サービス名（項目名）は `my.slack.url-dm-myself`、アカウント名は `my`、パスワードには自分宛DMの `slack://channel?team=...&id=...` 形式のURLを設定します。実際のURLをシェル履歴・ソース・ログに残さないでください。
2. RaycastのScript Commandsとして `jobcan-touch.applescript` を登録します。既存の登録を切り替える際は、Raycastが実行するファイルと候補の内容が同一であることを確認します。
3. 初回の実機確認では、Slackの対象DMと空の入力欄、送信内容、送信回数を確認してから実行します。送信結果が不明な場合は自動再送しません。

Keychainの読取りに失敗した場合、値が空または形式不正の場合は、Slackを開かず、クリップボードを変更せず、送信もしません。旧環境変数からの自動取得には対応しません。旧環境変数の設定は、新方式の実機受入が成功した後に撤去します。

### 既知の制約

以前動作した単純な操作手順を基準にしており、Slackの入力欄・会話の追加アクセシビリティ探索、既存下書きの自動確認、二重起動の防止、クリップボードの復元は実装していません。実行前に対象DMと入力欄の状態を確認してください。クリップボードは `/jobcan_touch` に置き換わります。対象会話が違う、下書きが残っている等の異常を認識した場合は、実行しないでください。実送信の成功はmacOS・Raycast・Slackでの確認が必要です。

## Copy Active Document Google Drive Link

`google-drive_active-document-link-copier_gdrivefs.sh` は、最前面アプリで開いている保存済みファイルのGoogle Drive URLをコピーします。

- Excel、Word、PowerPointではアプリ固有のAppleScriptから保存パスを取得します
- その他の対応アプリでは、macOS Accessibilityの `AXDocument` 属性を利用します
- Google Drive for desktopが付与する `com.google.drivefs.item-id#S` 拡張属性から項目IDを読み取り、Google Drive URLを生成します
- `.gdoc`、`.gsheet`、`.gslides`、`.gdraw`／`.gdrawings` は各Googleエディタ用URL、それ以外はGoogle Driveの汎用URLを生成します

Raycastには、**アクセシビリティ**と、`System Events` および利用するMicrosoft Officeアプリへの**オートメーション**を許可してください。未保存ファイル、Webアプリ、ターミナル、同期場所外のローカルコピーは対象外です。

標準以外のGoogle Drive for desktop同期場所を使う場合は、Raycastの実行環境で `GOOGLE_DRIVE_ROOT` を設定してください。

## Google Drive Path Generator

`google-drive-path-generator.sh` は、クリップボードにあるGoogle DriveのファイルまたはフォルダURLから項目IDを取り出し、Google Drive APIでメタデータと親階層を取得して、ローカルの同期項目を開きます。共有ドライブにも対応します。

初回セットアップ、OAuthクライアントの準備、必要なローカルファイルは [googleDrivePathGenerator/readme.md](googleDrivePathGenerator/readme.md) を参照してください。

## 公開時の扱い

以下はローカル専用であり、Gitへ追加しません。

- `credentials.json`、`token.json`、`.env`
- `.venv/` などの仮想環境
- `.DS_Store`
- ワークスペースやアカウントに固有の設定値

旧ツールやワークスペース固有のスクリプトは、この公開リポジトリに含めません。

## 注意

- Google Drive URLの生成に使う拡張属性はGoogle Drive for desktopの内部実装に依存し、アプリ更新後の動作を保証しません
- URLの生成・ローカルファイルのオープンは共有権限を変更しません。対象を開けるかはGoogle Driveの共有設定に依存します
