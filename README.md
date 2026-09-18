# Raycast macOS Utilities

このREADMEはmacOS向けのRaycast Script Commandsです。現時点では、Google Drive for desktop上のファイルを扱う次の2機能を含みます。

| Script Command | 機能 | 認証 |
| --- | --- | --- |
| `jobcan-touch.applescript` | Slack Desktopの対象conversationへJobcanのslash commandを送信 | `JOBCAN_SLACK_URL` |
| `google-drive_active-document-link-copier_gdrivefs.sh` | 最前面で開いているGoogle DriveファイルのURLをクリップボードへコピー | 不要 |
| `google-drive-path-generator.sh` | クリップボード上のGoogle Drive URLに対応するローカル項目を開く | Google Drive API OAuth |

## インストール

1. RaycastのScript Commandsとして、このディレクトリ内の `.sh` ファイルを登録します
2. Google Drive for desktopをインストールし、対象のMy Driveまたは共有ドライブをFinderで参照できる状態にします
3. `google-drive-path-generator.sh` を使う場合は、[googleDrivePathGenerator/readme.md](googleDrivePathGenerator/readme.md) のセットアップを行います

## Jobcan touch

`jobcan-touch.applescript` はSlack Desktopを開き、対象conversationへ `/jobcan_touch` を送信するRaycast Script Commandです。Slackのworkspace／conversation固有値は公開repositoryへ保存せず、Raycastの実行環境で `JOBCAN_SLACK_URL` として設定してください。

設定値は次の形式に限定されます。`YOUR_WORKSPACE_ID` と `YOUR_CONVERSATION_ID` は、実際の値をローカルの実行環境だけに設定します。

```sh
launchctl setenv JOBCAN_SLACK_URL 'slack://channel?team=YOUR_WORKSPACE_ID&id=YOUR_CONVERSATION_ID'
```

1. RaycastのScript Commandsとして `jobcan-touch.applescript` を登録します
2. Terminalで上記の `launchctl setenv` を実行し、Raycastが利用するユーザー環境へ `JOBCAN_SLACK_URL` を設定します。設定ファイルや値そのものはGitへ追加しません
3. Raycastを終了して再起動します。起動済みのRaycastプロセスには、後から設定した環境変数は反映されません
4. Raycastから実行し、Slack Desktopの対象conversationで `/jobcan_touch` が送信されることを確認します

`launchctl setenv` は現在のユーザーセッションのlaunchd環境へ設定します。設定を解除する場合は、Terminalで `launchctl unsetenv JOBCAN_SLACK_URL` を実行してからRaycastを再起動してください。

`JOBCAN_SLACK_URL` が未設定または形式不正の場合は、Slackをactivateせず、clipboardを変更せず送信せずに終了します。Raycastの実登録artifactとの対応、および実Slack／Jobcan経路は、候補ごとにmacOS上で確認してください。

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
