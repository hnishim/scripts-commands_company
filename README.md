# Raycast macOS Utilities

このREADMEはmacOS向けのRaycast Script Commandsです。現時点では、Google Drive for desktop上のファイルを扱う次の2機能を含みます。

| Script Command | 機能 | 認証 |
| --- | --- | --- |
| `jobcan-touch.applescript` | Slack Desktopの対象conversationへJobcanのslash commandを送信 | macOS Keychain |
| `google-drive_active-document-link-copier_gdrivefs.sh` | 最前面で開いているGoogle DriveファイルのURLをクリップボードへコピー | 不要 |
| `google-drive-path-generator.sh` | クリップボード上のGoogle Drive URLに対応するローカル項目を開く | Google Drive API OAuth |

## インストール

1. RaycastのScript Commandsとして、このディレクトリ内の `.sh` ファイルを登録します
2. Google Drive for desktopをインストールし、対象のMy Driveまたは共有ドライブをFinderで参照できる状態にします
3. `google-drive-path-generator.sh` を使う場合は、[googleDrivePathGenerator/readme.md](googleDrivePathGenerator/readme.md) のセットアップを行います

## Jobcan touch

`jobcan-touch.applescript` はSlack Desktopで自分宛DMを開き、`/jobcan_touch` を送信するRaycast Script Commandです。送信先URLはmacOSのログインキーチェーンの**汎用パスワード**項目だけから取得します。URLの実値や会話識別子は公開リポジトリ、コマンド履歴、ログ、テストに記録しません。

- Service（キーチェーンアクセスの「キーチェーン項目名」）：`my.slack.url-dm-myself`
- Account（「アカウント名」）：`my`
- パスワード：対象の自分宛DMのSlack URL（`slack://channel?team=＜ワークスペース識別子＞&id=＜会話識別子＞` 形式）。実値はこの項目のパスワード欄だけに入力します。

### 登録・確認・更新・削除

1. macOSの「キーチェーンアクセス」でログインキーチェーンを選び、上記の項目名とアカウント名の汎用パスワード項目が既にないか確認します。既存項目がある場合は用途と内容の衝突を確認し、無断で上書きしません。
2. 存在しない場合は「新規パスワード項目」を作成し、上記の項目名・アカウント名・パスワードを対話的に登録します。URLを `security add-generic-password -w ...` の引数、シェル履歴、設定ファイルへ書かないでください。
3. 登録後、Terminalで次の確認コマンドを実行できます。取得値とエラー出力は破棄され、URLは表示されません。終了状態が成功でも、URL形式・送信先の正しさは後述のRaycast実機確認が必要です。

```sh
if /usr/bin/security find-generic-password -w -s my.slack.url-dm-myself -a my >/dev/null 2>&1; then
    printf '%s\n' 'Keychain項目を読み取れました'
else
    printf '%s\n' 'Keychain項目を読み取れませんでした'
fi
```

4. 更新時はキーチェーンアクセスで対象項目を開き、用途・送信先を確認してパスワード欄を編集します。削除時は同じService／Accountの項目だけを選んで削除します。いずれもURLの実値をターミナル、Git、Linearへ転記しません。

### Raycastでの受入・旧設定の撤去

1. Raycastに `jobcan-touch.applescript` を登録し、実行時にキーチェーンのアクセス許可が表示された場合は、要求元アプリと対象項目を確認した上で許可します。Terminalでの読み取り許可とRaycast経由の許可は同一ではありません。許可を拒否した場合や項目が見つからない場合は、Slackを起動・操作せず終了する設計です。
2. 旧環境変数が残っている段階でKeychainの値だけによる送信先の一致、意図した1回の `/jobcan_touch` 送信、クリップボード復元をmacOS実機で確認します。実送信を伴うため実行回数を管理してください。未登録・拒否・不正値の無副作用は、安全な検証環境または設定を退避した状態で確認してください。
3. 正常なRaycast実行を確認した**後**、旧設定を解除してRaycastを再起動します。旧設定は取得元として利用されません。

```sh
launchctl unsetenv JOBCAN_SLACK_URL
```

プロセス環境変数や別の永続化設定に `JOBCAN_SLACK_URL` が残っている場合も、ローカルで確認して撤去してください。旧設定を撤去した後にRaycastから再実行し、Keychainだけで正常動作することを確認します。macOSのAppleScriptコンパイル、Keychainの実アクセス許可、Slackの実送信はリモート環境では確認できません。

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
