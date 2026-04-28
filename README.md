# github-daily-digest

当日（JST）の GitHub 上での自分の活動を集計し、Slack に日次ダイジェストとして投稿するためのリポジトリです。

集計対象は以下の4カテゴリです。

- ✏️ Created … Issue / Pull Request の起票
- 💬 Commented … Issue / PR / Commit へのコメント（同一 Issue/PR 内の複数コメントは件数に集約）
- ✅ Approved … PR レビューでの approve
- 🔒 Closed / Merged … Issue / PR の close もしくは merge

平日 23:00 JST に GitHub Actions（`.github/workflows/digest.yml`）が実行され、その日の活動が Slack に投稿されます。

## 構成

```
.
├── bin/
│   └── digest.sh                # 集計・Slack 投稿の本体
└── .github/
    └── workflows/
        ├── digest.yml           # 平日 23:00 JST に digest.sh を実行
        └── reminder.yml         # 毎年 4/14 09:00 JST に PAT 更新リマインダを Slack 投稿
```

## 必要なもの

- `bash`
- [`gh`](https://cli.github.com/)（GitHub CLI）
- `jq`
- `curl`

macOS であれば `brew install gh jq` で揃います。

## 初期設定

### 1. GitHub Personal Access Token（fine-grained PAT）の発行

https://github.com/settings/personal-access-tokens から fine-grained PAT を発行します。

- Repository access: **All repositories**
- Repository permissions:
  - Contents: **Read-only**
  - Issues: **Read-only**
  - Pull requests: **Read-only**
  - Metadata: **Read-only**
- Account permissions:
  - Profile: **Read-only**
- 有効期限: 1年（毎年 4/14 にリマインダが Slack に飛びます）

### 2. Slack Incoming Webhook URL の取得

投稿先（自分宛 DM など）に対する Incoming Webhook を作成し、URL を控えておきます。

### 3. 本番（GitHub Actions）に Secrets を登録

https://github.com/azimicat/github-daily-digest/settings/secrets/actions で以下を登録します。

| Secret 名 | 内容 |
| --- | --- |
| `DIGEST_GITHUB_TOKEN` | 上で発行した fine-grained PAT |
| `SLACK_WEBHOOK_URL` | Slack Incoming Webhook URL |

## ローカル実行

リポジトリ直下に `.env` を作成し、必要な環境変数を記述します（`.env` は `.gitignore` 対象です）。

```bash
# fine-grained PAT
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx

# Slack Incoming Webhook URL
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/xxx/yyy/zzz

# 集計対象の GitHub ユーザー名
GITHUB_USERNAME=azimicat

# Slack送信せず標準出力のみにする（既定）
DRY_RUN=true

# 0件のとき通知スキップ（既定 true）
SKIP_IF_EMPTY=true
```

### dry-run（Slack には投稿しない）

```bash
set -a; source .env; set +a
./bin/digest.sh
```

`DRY_RUN=true` の状態では、Slack に投稿される予定のメッセージが標準出力に表示されるだけで、実際の Slack 送信は行われません。動作確認はまずこちらで行います。

### 実際に Slack に投稿する

```bash
set -a; source .env; set +a
DRY_RUN=false ./bin/digest.sh
```

`DRY_RUN=false` のときは `SLACK_WEBHOOK_URL` が必須です。未設定だとスクリプトが起動時に失敗します。

## 本番実行（GitHub Actions）

`.github/workflows/digest.yml` が以下のスケジュールで自動実行されます。

- 平日（月〜金）23:00 JST（cron は `0 14 * * 1-5` の UTC 表記）
- `workflow_dispatch` でも手動実行可能

ワークフロー側では以下が固定されています。

- `GITHUB_USERNAME=azimicat`
- `DRY_RUN=false`（必ず Slack 投稿する）
- `SKIP_IF_EMPTY=false`（活動 0 件でも「本日活動なし」を通知する）
- `TZ=Asia/Tokyo`

手動で動かしたい場合は GitHub の Actions タブから `GitHub Daily Digest` を選び、`Run workflow` で実行できます。

### PAT 更新リマインダ

`.github/workflows/reminder.yml` が毎年 **4/14 09:00 JST** に Slack へ更新手順をリマインドします（PAT の有効期限 1 年に対する 2 週間前通知）。

更新手順は以下の通りです。

1. https://github.com/settings/personal-access-tokens で対象 PAT を更新（または新規発行）
2. https://github.com/azimicat/github-daily-digest/settings/secrets/actions で `DIGEST_GITHUB_TOKEN` を上書き
3. 翌平日 23:00 JST の自動実行が成功するか確認

## 設定リファレンス（環境変数）

`bin/digest.sh` は以下の環境変数を参照します。

| 変数名 | 必須 | 既定値 | 説明 |
| --- | --- | --- | --- |
| `GITHUB_TOKEN` | ✅ | — | fine-grained PAT。`gh api` 認証に使用。 |
| `SLACK_WEBHOOK_URL` | `DRY_RUN=false` のとき ✅ | — | Slack Incoming Webhook URL。 |
| `GITHUB_USERNAME` | — | `azimicat` | 集計対象の GitHub ユーザー名。 |
| `DRY_RUN` | — | `true` | `true` のとき Slack 送信せず標準出力のみ。 |
| `SKIP_IF_EMPTY` | — | `true` | `true` のとき活動 0 件で通知スキップ。`false` だと「本日活動なし」を通知。 |

## 出力例

```
📅 GitHub Daily Digest — 2026-04-28 (火)

✏️ Created (1)
• #123 [azimicat/example] 新機能の追加

💬 Commented (2)
• #120 [azimicat/example] (3 comments)
• #118 [azimicat/other]   (1 comment)

✅ Approved (1)
• #117 [azimicat/example] バグ修正レビュー

🔒 Closed / Merged (1)
• #115 [azimicat/example] リファクタリング (merged)

— total 5 events
```
