import os
import subprocess
import re
import urllib.parse
from typing import List, Optional, Dict, Any

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

# If modifying these scopes, delete the file token.json.
SCOPES = ["https://www.googleapis.com/auth/drive.metadata.readonly", "https://www.googleapis.com/auth/drive.readonly"]

MIME_TYPE_EXTENSIONS = {
    'application/vnd.google-apps.document': '.gdoc',
    'application/vnd.google-apps.spreadsheet': '.gsheet',
    'application/vnd.google-apps.presentation': '.gslides'
}

class GoogleDrivePathGenerator:
    def __init__(self):
        self.creds = None
        self.service = None
        self.folder_names: List[str] = []

    def authenticate(self) -> None:
        """Google Drive APIの認証を行う"""
        if os.path.exists("token.json"):
            self.creds = Credentials.from_authorized_user_file("token.json", SCOPES)

        if not self.creds or not self.creds.valid:
            if self.creds and self.creds.expired and self.creds.refresh_token:
                self.creds.refresh(Request())
            else:
                flow = InstalledAppFlow.from_client_secrets_file("credentials.json", SCOPES)
                self.creds = flow.run_local_server(port=0)

            with open("token.json", "w") as token:
                token.write(self.creds.to_json())

        self.service = build("drive", "v3", credentials=self.creds)

    def _get_parent_folders(self, file_id: str) -> None:
        """親フォルダを再帰的に取得する"""
        file_metadata = self.service.files().get(
            fileId=file_id,
            fields='name, parents',
            supportsAllDrives=True
        ).execute()

        parents = file_metadata.get('parents', [])
        self.folder_names.append(file_metadata.get('name'))

        if parents:
            self._get_parent_folders(parents[0])

    @staticmethod
    def _extract_file_id_from_url(url: str) -> Optional[str]:
        """Google DriveのファイルURLからファイルIDを抽出する"""
        parsed_url = urllib.parse.urlparse(url)
        query_params = urllib.parse.parse_qs(parsed_url.query)

        if 'id' in query_params:
            return query_params['id'][0]

        for pattern in [r'/d/([a-zA-Z0-9_-]+)', r'/folders/([a-zA-Z0-9_-]+)']:
            if match := re.search(pattern, parsed_url.path):
                return match.group(1)

        return None

    @staticmethod
    def _get_clipboard_content() -> Optional[str]:
        """クリップボードの内容を取得する"""
        try:
            process = subprocess.Popen(['pbpaste'], stdout=subprocess.PIPE)
            clipboard_content, _ = process.communicate()
            return clipboard_content.decode('utf-8').strip()
        except FileNotFoundError:
            return None

    def _get_file_metadata(self, file_id: str) -> Dict[str, Any]:
        """ファイルのメタデータを取得する"""
        return self.service.files().get(
            fileId=file_id,
            fields='name, mimeType, driveId, parents',
            supportsAllDrives=True
        ).execute()

    def _get_shared_drive_name(self, drive_id: str) -> str:
        """共有ドライブの名前を取得する"""
        shared_drive_metadata = self.service.drives().get(
            driveId=drive_id,
            fields='name'
        ).execute()
        return shared_drive_metadata.get('name')

    def _get_user_email(self) -> str:
        """ユーザーのメールアドレスを取得する"""
        user = self.service.about().get(fields='user').execute().get('user')
        return user.get('emailAddress')

    def _open_file(self, file_path: str, file_name: str) -> None:
        """ファイルを開く"""
        try:
            open_command = f'open "file://{file_path}/{file_name}"'
            subprocess.run(open_command, check=True, shell=True)
            print(f"ファイルを開きました: {open_command}")
        except (FileNotFoundError) as e:
            print(f"ファイルが見つかりません: {open_command}")
        except (subprocess.CalledProcessError, OSError) as e:
            print(f"エラーが発生しました: {e}")

    def generate_path(self) -> None:
        """メイン処理"""
        try:
            self.authenticate()

            url = self._get_clipboard_content()
            if not url:
                print("クリップボードは空です。")
                return

            file_id = self._extract_file_id_from_url(url)
            if not file_id:
                print("有効なGoogle Drive URLが見つかりません。")
                return

            file_metadata = self._get_file_metadata(file_id)
            shared_drive_id = file_metadata.get('driveId')
            parents = file_metadata.get('parents', [])

            # ファイル名の処理
            mime_type = file_metadata.get('mimeType')
            ext = MIME_TYPE_EXTENSIONS.get(mime_type, '')
            file_name = file_metadata.get('name').replace("/", " ") + ext

            # 親フォルダの取得
            if parents:
                for parent_id in parents:
                    self._get_parent_folders(parent_id)

            self.folder_names.pop()

            # ドライブ名の設定
            drive_name = (
                os.path.join('Shared drives', self._get_shared_drive_name(shared_drive_id))
                if shared_drive_id
                else 'My Drive/'
            )

            # ホームディレクトリの取得
            home_directory = (
                os.environ.get('HOME') or
                os.environ.get('HOMEPATH') or
                os.environ.get('USERPROFILE')
            )

            # ファイルパスの生成
            user_email = self._get_user_email()
            file_path = os.path.join(
                '/Users',
                home_directory,
                'Library',
                'CloudStorage',
                f'GoogleDrive-{user_email}',
                drive_name,
                '/'.join(reversed(self.folder_names))
            )

            self._open_file(file_path, file_name)

        except HttpError as error:
            print(f"Google Drive APIでエラーが発生しました: {error}")

def main():
    generator = GoogleDrivePathGenerator()
    generator.generate_path()

if __name__ == "__main__":
    main()