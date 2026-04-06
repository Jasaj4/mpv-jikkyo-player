# mpv-jikkyo-player

テレビ録画TSファイルを元にニコニコ実況コメントを取得し、ASS字幕として表示するツール。

mpvプレイヤー向け。CLI単体でも使用可能。MacOS / Linux / Windows 対応。
<img width="1072" height="652" alt="Image" src="https://github.com/user-attachments/assets/f5b5557c-fc26-45d9-bd95-291941b59759" />
## 機能

- TSストリームからEIT/TOT/チャンネル情報を直接パースし、ニコニコ実況APIからコメントを自動取得
- コメントをニコニコ風弾幕ASS字幕に変換（スクロール・固定・色・サイズ対応）
- ARIB STD-B24字幕（地デジ字幕）の抽出・弾幕ASSとのマージ
- 字幕トラックの個別追加（弾幕のみ / 字幕のみ / 弾幕+字幕）で表示切り替え可能
- 動画と同名の `.xml` ファイルがあれば自動読み込み
- 録画途中で止まったりしているファイルも正確な録画終了位置を特定

## セットアップ

### 依存

- **lua** (5.1+ or LuaJIT) — CLI用 （任意、mpv再生のみなら不要）
- **mpv** — 再生・字幕表示（任意、CLIのみなら不要）
- **node** >= 18 — ARIB字幕抽出に必要（任意）

### インストール

mpvの `scripts/` ディレクトリに直接cloneする:

#### MacOS / Linux

```sh
git clone https://github.com/jasaj4/mpv-jikkyo-player.git ~/.config/mpv/scripts/jikkyo-player
cd ~/.config/mpv/scripts/jikkyo-player
make install
```

#### Windows

```powershell
git clone https://github.com/jasaj4/mpv-jikkyo-player.git "$env:APPDATA\mpv\scripts\jikkyo-player"
cd "$env:APPDATA\mpv\scripts\jikkyo-player"
.\install.ps1
```

ARIB字幕なしでインストールする場合:

```sh
# MacOS / Linux
make install NO_ARIB=1

# Windows
.\install.ps1 -NoArib
```

### アンインストール

jikkyo-player ディレクトリを削除するだけで完了:

```sh
# MacOS / Linux
rm -rf ~/.config/mpv/scripts/jikkyo-player

# Windows
Remove-Item -Recurse -Force "$env:APPDATA\mpv\scripts\jikkyo-player"
```

## 使い方

### mpv

TSファイルを再生すると自動的にコメントを取得・表示する。

1. TSストリームからチャンネル・時間情報を抽出
2. ニコニコ実況APIからコメントXMLを取得
3. ASS字幕に変換してmpvに読み込み

#### 字幕トラック

ロード完了後、以下の3つの字幕トラックが追加される:

| トラック名 | 内容 |
| --------- | ---- |
| **字幕** | ARIB字幕のみ |
| **弾幕** | 弾幕コメントのみ |
| **弾幕+字幕** | 弾幕とARIB字幕をマージ |

弾幕はAPIレスポンス後すぐにロードされ、ARIB字幕は抽出完了後に追加される。両方揃った時点でマージトラックが作られ、`default_track` の設定に従って自動的に切り替わる。

`n` キーで jikkyo-player の字幕トラックを順番に切り替えられる:

```
弾幕 → 字幕 → 弾幕+字幕 → off → 弾幕 → ...
```

（利用可能なトラックのみ表示される。例えばARIB字幕がない場合は「字幕」はスキップされる）

キーを変更するには `input.conf`（MacOS/Linux: `~/.config/mpv/input.conf`、Windows: `%APPDATA%\mpv\input.conf`）に設定する:

```
# 例: k キーで弾幕トラック切り替え
k script-binding cycle-danmaku-track
```

再生中のTSと同じフォルダもしくは`danmaku_search_dirs`で指定したフォルダに同名のxmlファイルはないかを探し、ある場合はapiコールスキップ

### CLI

```
Usage: jikkyo-player <ts_file> [options]

Options:
  -o, --output <path>    ass出力先 (default: stdout)
  --no-arib              ARIB字幕抽出をスキップ
  --arib-script <path>   arib-ts2ass.js のパス
  --info                 TSストリーム情報のみ表示 (JSON)
  --fetch-only           XML取得のみ (ASS変換しない)
```

例:

```sh
# MacOS / Linux
cd ~/.config/mpv/scripts/jikkyo-player

# Windows
cd "$env:APPDATA\mpv\scripts\jikkyo-player"

./bin/jikkyo-player recording.ts -o danmaku.ass
```

## 設定

設定をカスタマイズするには `script-opts/jikkyo-player.conf` を手動で作成する:

```sh
# MacOS / Linux
touch ~/.config/mpv/script-opts/jikkyo-player.conf

# Windows
New-Item -ItemType File -Force "$env:APPDATA\mpv\script-opts\jikkyo-player.conf"
```

必要な項目のみ記述すればよい。例:

```ini
scroll_duration=10.0
font_name=Noto Sans CJK JP
lane_count=15
```

### 設定一覧

| 設定 | デフォルト | 説明 |
|------|-----------|------|
| `play_res_x` | `1920` | ASS仮想解像度X |
| `play_res_y` | `1080` | ASS仮想解像度Y |
| `scroll_duration` | `7.0` | スクロール速度（画面横断秒数） |
| `fixed_duration` | `5.0` | 固定コメント表示秒数 |
| `font_name` | `Hiragino Sans W5` | ASSフォント名（Windowsでは `Yu Gothic` 等に変更推奨） |
| `font_outline` | `1.0` | アウトライン太さ |
| `font_size` | `0` | フォントサイズ（`0` = `lane_count`から自動計算） |
| `lane_count` | `20` | スクロールレーン数 |
| `lane_margin` | `4` | レーン間の余白ピクセル |
| `scroll_area_ratio` | `0.75` | スクロール領域（画面高さの割合） |
| `recording_offset` | `7` | 録画開始オフセット秒（EIT/TOTなし時のみ） |
| `danmaku_offset` | `0` | 弾幕タイミング調整秒（常に適用） |
| `default_track` | `both` | デフォルト表示トラック（`both` / `danmaku` / `arib`） |
| `danmaku_search_dirs` | *(空)* | 弾幕XMLの検索フォルダ（MacOS/Linux: コロン区切り、Windows: セミコロン区切り） |

#### 弾幕XMLの検索パス

デフォルトでは動画と同じフォルダにある同名の `.xml` ファイルを自動読み込みする。

弾幕XMLを別フォルダで一括管理している場合は `danmaku_search_dirs` を設定すると、指定フォルダ内を再帰的に探索して同名XMLを読み込む。この設定がある場合、動画と同じフォルダの探索はスキップされる。

```ini
# MacOS / Linux: コロン区切り
danmaku_search_dirs=/danmaku/danmaku-xmls:/Volumes/NAS/danmaku

# Windows: セミコロン区切り
danmaku_search_dirs=D:\danmaku\danmaku-xmls;E:\NAS\danmaku
```

