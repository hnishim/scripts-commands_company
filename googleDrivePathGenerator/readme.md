# googleDrivePathGenerator

Google DriveのファイルまたはフォルダURLから、Google Drive for desktopが同期したローカル項目を開くPythonスクリプトです。Raycastからは親ディレクトリの`google-drive-path-generator.sh`がこのスクリプトを実行します。

## 概要

クリップボードにコピーされたGoogle Drive URLから項目IDを抽出し、Google Drive APIで項目名・親階層・共有ドライブ情報を取得します。取得した情報をGoogle Drive for desktopの同期場所に対応付け、該当するローカル項目を開きます。

## 前提条件

- macOS
- Python 3.10以上
- Google Drive for desktopがインストール済みで、対象のMy Driveまたは共有ドライブをローカルで参照できること
- Google Drive APIを有効にしたGoogle Cloudプロジェクトと、デスクトップアプリ用OAuthクライアント

## セットアップ

1. Google CloudプロジェクトでGoogle Drive APIを有効にします。
2. デスクトップアプリ用OAuthクライアントを作成し、ダウンロードしたJSONをこのディレクトリの`credentials.json`として保存します。
3. 次を実行してローカル仮想環境と依存パッケージを作成します。

```bash
./setup.sh
```

`setup.sh`はPython 3.10以上を検出して`.venv`を作成し、`requirements.txt`の依存関係をインストールします。必要に応じて、使用するPythonを`PYTHON_BIN`で指定できます。

## 使い方

1. Google Drive上のファイルまたはフォルダURLをクリップボードにコピーします。
2. Raycastで`Google Drive Path Generator`を実行します。
3. 初回だけブラウザでGoogle OAuthを完了します。成功後、ローカルに`token.json`が生成されます。
4. 対応するローカル項目が開きます。

ターミナルから実行する場合は、次を使います。

```bash
.venv/bin/python googleDrivePathGenerator.py
```

## 設定ファイル

- `credentials.json`: OAuthクライアント情報。公開しません。
- `token.json`: OAuthトークン。公開しません。
- `.venv/`: ローカル仮想環境。公開しません。

## 注意事項

- Google Drive for desktopで対象が同期・ストリーミング可能である必要があります。共有ドライブでは、その共有ドライブをローカルで参照できる必要があります。
- Google Driveのショートカットファイルには対応していません。
- このスクリプトはDrive APIの読み取りスコープを使用します。ロック、共有権限変更、ファイル更新は行いません。
