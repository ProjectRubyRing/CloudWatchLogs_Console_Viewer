# cloudwatch-log-viewer.sh

TeraTerm から接続した Linux サーバー上で実行し、AWS CloudWatch Logs のログを
**「JST のログ出力時刻 | ログメッセージ」** の見やすい形式で確認する実運用向け
Bash ツールです。期間指定・直近 N 分・フィルタ・`tail -f` 相当の監視・
ロググループ/ストリームの対話選択・AWS 認証/権限確認・権限不足時のスイッチバック
案内/自動実行に対応します。

---

## ファイル構成

```
CloudWatchLogs_Console/
├── cloudwatch-log-viewer.sh   # メインスクリプト
├── common.sh                  # 共通ユーティリティ（任意。無ければ本体が内蔵定義を使う）
├── switchback.sample.sh       # スイッチバック用シェルの雛形（source 前提）
└── README.md                  # 本ドキュメント
```

`common.sh` は **任意** です。次の順で解決します。

1. `--common-sh /path/to/common.sh`
2. 環境変数 `CLOUDWATCH_LOG_COMMON_SH`
3. メインスクリプトと同じディレクトリの `common.sh`

いずれも見つからない場合は本体スクリプトが `log_info` / `die` などのフォールバックを
内蔵定義するため、単体でも動作します。CodeCommit_Git_branch_local_Create / 
CloudWatchLogs_Search プロジェクトの `common.sh` と同じ規約（`log_info` / `log_warn` /
`log_error` / `log_debug` / `die` / `require_command`）に合わせているため、既存の
`common.sh` へそのまま差し替えられます。

---

## 前提条件

- Linux + Bash 4.2 以上
- `aws`（AWS CLI v2）
- `jq`（**必須**。複数行・制御文字・UTF-8 を安全に扱うため JSON 解析に使用）
- GNU `date`（日時解釈に使用）、GNU coreutils（`sort` / `stat` / `mktemp`）
- 事前に `aws login --remote` 等で認証済みであること（本ツールは自動ログインしません）

> 注意: 本スクリプトはフィールド区切りに制御文字 US(0x1F)、一時プレースホルダに
> 0x01 を使用しています（jq 文字列内、コメントで明記）。編集・転送はバイト保持される
> 方法（scp/sftp のバイナリ転送、TeraTerm のファイル送信）で行ってください。

---

## インストール・配置

```bash
# 3 ファイルを同じディレクトリへ配置し、実行権限を付与する
chmod +x cloudwatch-log-viewer.sh common.sh switchback.sample.sh

# 構文確認（推奨）
bash -n cloudwatch-log-viewer.sh
bash -n common.sh
shellcheck -x cloudwatch-log-viewer.sh common.sh   # shellcheck 導入時
```

---

## 使い方

```bash
./cloudwatch-log-viewer.sh [オプション]
```

`--log-group` を省略すると、参照可能なロググループを一覧表示して番号で選択できます。
`--help` で全オプション・デフォルト・排他条件・環境変数・終了コード・実行例を表示します。

### 代表的な実行例

```bash
# 一覧から選択し直近 10 分
./cloudwatch-log-viewer.sh --last-minutes 10

# ロググループ直接指定で直近 60 分
./cloudwatch-log-viewer.sh --log-group /aws/lambda/example --last-minutes 60

# JST の開始・終了日時を指定
./cloudwatch-log-viewer.sh --log-group /aws/lambda/example \
  --start "2026-07-12 09:00:00" --end "2026-07-12 10:00:00"

# ERROR を含む行だけ（固定文字列）
./cloudwatch-log-viewer.sh --log-group /aws/lambda/example --last-minutes 30 \
  --filter ERROR --filter-mode literal

# healthcheck を除外
./cloudwatch-log-viewer.sh --log-group /aws/lambda/example --last-minutes 30 \
  --exclude healthcheck

# 直近 5 分から監視を開始（tail -f 相当）
./cloudwatch-log-viewer.sh --log-group /aws/lambda/example --last-minutes 5 --follow

# ERROR のみを監視
./cloudwatch-log-viewer.sh --log-group /aws/lambda/example --last-minutes 5 \
  --follow --filter ERROR --filter-mode literal

# 特定ログストリームを監視
./cloudwatch-log-viewer.sh --log-group /aws/lambda/example \
  --log-stream '2026/07/12/[$LATEST]xxxxxxxx' --last-minutes 5 --follow

# 権限不足時に警告して終了（既定）
./cloudwatch-log-viewer.sh --log-group /aws/lambda/example --last-minutes 10 \
  --switchback-mode exit

# 権限不足時に専用シェルで自動スイッチバック
./cloudwatch-log-viewer.sh --log-group /aws/lambda/example --last-minutes 10 \
  --switchback-mode auto --switchback-script /opt/team/bin/aws-switchback.sh

# プロファイル/リージョン指定
./cloudwatch-log-viewer.sh --profile example-profile --region ap-northeast-1 \
  --log-group /aws/lambda/example --last-minutes 10

# JSON Lines で出力
./cloudwatch-log-viewer.sh --log-group /aws/lambda/example --last-minutes 10 --output jsonl
```

---

## オプション一覧

| オプション | 説明 |
|---|---|
| `-g, --log-group NAME` | ロググループ名を直接指定 |
| `--log-group-prefix P` | 一覧表示するロググループをプレフィックスで絞り込む |
| `-s, --log-stream NAME` | 特定のログストリームを指定（`get-log-events` を使用） |
| `--log-stream-prefix P` | 対象ログストリームをプレフィックスで絞り込む |
| `--select-log-stream` | ログストリームを一覧表示し番号で選択 |
| `--start "YYYY-MM-DD HH:MM[:SS]"` | 取得開始日時（JST。ISO8601 +09:00 も可） |
| `--end "YYYY-MM-DD HH:MM[:SS]"` | 取得終了日時（JST。秒単位で inclusive） |
| `-m, --last-minutes N` | 直近 N 分（1〜10080）。`--start`/`--end` と併用不可 |
| `-f, --filter PATTERN` | 表示条件（複数指定可） |
| `--exclude PATTERN` | 除外条件（複数指定可・いずれか一致で除外） |
| `--filter-mode cloudwatch\|literal\|regex` | フィルタ方式（既定 literal） |
| `--filter-logic and\|or` | 複数 `--filter` の論理（既定 and） |
| `-i, --ignore-case` | ローカルフィルタで大文字小文字を無視 |
| `-F, --follow` | tail -f 相当の監視（`--end` と併用不可） |
| `--poll-interval SEC` | ポーリング間隔秒（既定 5） |
| `--overlap-seconds SEC` | 遅延到着対策の重複取得期間（既定 5） |
| `--show-log-stream` | ログストリーム名も表示（text 時） |
| `--show-ingestion-time` | 取り込み時刻も表示（text 時） |
| `--single-line` | 複数行を 1 行へ（改行を `\n` 表示） |
| `--output text\|tsv\|jsonl` | 出力形式（既定 text） |
| `--max-events N` | 最大表示イベント数（既定 10000） |
| `--page-limit N` | API 1 回あたり取得件数（既定 1000, 最大 10000） |
| `--profile PROFILE` | AWS CLI プロファイル |
| `--region REGION` | AWS リージョン |
| `--switchback-mode exit\|auto` | 権限不足時の動作（既定 exit = 安全側） |
| `--switchback-script FILE` | auto 時に source する専用シェル |
| `--switchback-arg VALUE` | 専用シェルへ渡す引数（複数指定可） |
| `--common-sh FILE` | 参照する common.sh |
| `--non-interactive` | 対話的な番号選択を禁止 |
| `--dry-run` | AWS 参照/スイッチバックを行わず予定内容のみ表示 |
| `--no-color` | 色付き表示を無効化 |
| `--debug` | デバッグ情報を標準エラーへ（秘密情報は出さない） |
| `-h, --help` | ヘルプ表示 |
| `--version` | バージョン表示 |

### 環境変数（コマンドラインオプションが優先）

```
AWS_PROFILE / AWS_REGION / AWS_DEFAULT_REGION
CLOUDWATCH_LOG_COMMON_SH             common.sh のパス
CLOUDWATCH_LOG_SWITCHBACK_MODE       exit|auto
CLOUDWATCH_LOG_SWITCHBACK_SCRIPT     スイッチバック用シェルのパス
CLOUDWATCH_LOG_DEFAULT_LAST_MINUTES  既定の直近分数（既定 10）
CLOUDWATCH_LOG_POLL_INTERVAL         ポーリング間隔秒（既定 5）
CLOUDWATCH_LOG_OUTPUT                text|tsv|jsonl
```

### フィルタの違い（重要）

- `cloudwatch` : CloudWatch Logs のフィルタパターンとしてサーバー側で絞り込む。
  大文字小文字は区別され `--ignore-case` は無効。`--filter` は 1 つのみ。
- `literal`    : 取得後にローカルで「固定文字列」として部分一致検索。
- `regex`      : 取得後にローカルで「拡張正規表現(ERE)」として検索。
- `--exclude` は常にローカル（いずれか一致で除外）で適用。

---

## IAM ポリシー例

### 読み取りに必要な最小権限（AWS CLI 方式のみ、Insights 不使用）

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudWatchLogsRead",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:GetLogEvents",
        "logs:FilterLogEvents"
      ],
      "Resource": "*"
    },
    { "Sid": "Sts", "Effect": "Allow", "Action": "sts:GetCallerIdentity", "Resource": "*" }
  ]
}
```

### 対象ロググループを限定する例

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["logs:DescribeLogStreams", "logs:GetLogEvents", "logs:FilterLogEvents"],
      "Resource": "arn:aws:logs:ap-northeast-1:123456789012:log-group:/aws/lambda/example:*"
    },
    {
      "Effect": "Allow",
      "Action": "logs:DescribeLogGroups",
      "Resource": "*"
    },
    { "Effect": "Allow", "Action": "sts:GetCallerIdentity", "Resource": "*" }
  ]
}
```

- `logs:DescribeLogGroups` はリソースレベルの制限が実質的に効かないため、一覧取得は
  `Resource: "*"` になります（ロググループ単位の制限は困難）。
- 本ツールは **CloudWatch Logs Insights を使用しません**（`logs:StartQuery` /
  `GetQueryResults` / `StopQuery` は不要）。Insights を使う運用へ拡張する場合のみ
  これらを追加してください。
- 実際の IAM 設計は必ず自組織の IAM 設計担当者の確認を受けてください。

---

## エラー・終了コード一覧

| コード | 意味 |
|---|---|
| 0 | 正常終了 |
| 2 | 引数エラー（不明オプション・値不足・矛盾） |
| 3 | 必須コマンド不足（aws / jq / GNU date 等） |
| 4 | AWS 未認証または認証期限切れ（`aws login --remote` を促す） |
| 5 | AWS 権限不足（switchback-mode exit 時） |
| 6 | リソース未検出（ロググループ/ストリームなし） |
| 7 | AWS API / 通信エラー |
| 8 | スイッチバック失敗（未指定・不存在・危険権限・実行失敗・再確認不可） |
| 9 | 日時指定エラー |
| 130 | Ctrl+C / SIGTERM による中断 |

エラーは日本語で「原因」と「次に行う操作」を表示します。AWS CLI の生エラーは
通常時は要点のみ、`--debug` 時は秘密情報を除いた詳細を表示します。

---

## 動作確認方法

### 構文・静的解析

```bash
bash -n cloudwatch-log-viewer.sh
bash -n common.sh
shellcheck -x cloudwatch-log-viewer.sh common.sh switchback.sample.sh
```

### 日時変換の単体確認（GNU date 前提）

```bash
export TZ='JST-9'
# JST 入力 -> epoch(ms) -> JST 表示 のラウンドトリップ
in="2026-07-12 14:23:45"; s=$(date -d "$in" +%s)
printf '%(%Y-%m-%d %H:%M:%S)T.123 JST\n' "$s"   # => 2026-07-12 14:23:45.123 JST
# ISO8601 +09:00 と +00:00 で 9 時間差になること
a=$(date -d '2026-07-12T09:00:00+09:00' +%s); b=$(date -d '2026-07-12T09:00:00+00:00' +%s)
echo $((b - a))    # => 32400
```

### 実 AWS での確認

```bash
aws login --remote                      # 事前認証
./cloudwatch-log-viewer.sh --last-minutes 10          # 一覧選択→表示
./cloudwatch-log-viewer.sh -g /aws/lambda/xxx -m 5 -F # 監視
```

---

## テスト観点

- AWS CLI / jq 未導入（→ 3）、AWS 未認証・期限切れ（→ 4）、権限不足（→ 5）
- ロググループ: 一覧成功 / 0 件 / 番号選択 / 不正番号・空・範囲外 / 直接指定不存在
- ログストリーム: 指定あり / なし / `--select-log-stream` / プレフィックス
- 期間: JST start/end / 不正日時 / start>end / 直近 5,10,30,60 分 / 既定 10 分
- フィルタ: 一致あり/なし / 除外 / ignore-case / regex / cloudwatch / AND/OR
- 表示: 複数行 / 同一ミリ秒複数 / 日本語・UTF-8 / 長大メッセージ / ページネーション / 最大件数到達
- 監視: 新規ログ表示 / 新規ストリーム / 遅延到着 / 重複排除 / 一時 API エラー / Ctrl+C
- スイッチバック: 警告終了 / 自動成功 / 自動失敗 / 再確認後も権限不足 / 未指定 / 不存在 / パスに空白
- 出力: text / tsv / jsonl / パイプ・リダイレクト / `--non-interactive`

---

## 既知の制約

- **監視はポーリング方式**です（CloudWatch Logs にネイティブなストリーミング API が
  無いため）。`--poll-interval` 間隔で `filter-log-events` / `get-log-events` を再取得します。
- **遅延到着**は `--overlap-seconds`（既定 5 秒）を超えて過去にさかのぼって到着した
  イベントは取りこぼす可能性があります（サーバー側の `--start-time` で除外されるため）。
  必要に応じて値を増やしてください。
- **重複排除**は eventId が取得できる場合（`filter-log-events`）は eventId、取得できない
  場合（`get-log-events`）は「時刻＋ストリーム＋メッセージ」の組で判定します。後者では
  同一ミリ秒・同一ストリーム・同一本文の異なるイベントは区別できません。
- `cloudwatch` フィルタは CloudWatch のパターン構文で、ローカル正規表現とは意味が
  異なります。`--ignore-case` はローカル（literal/regex）のみ有効です。
- 期間無制限の全件取得は行いません。既定は直近 10 分、上限は `--max-events`。
- メッセージ中に生の制御文字 US(0x1F) が含まれる場合は空白へ置換します（極めて稀）。
- タイムゾーンは固定オフセット `JST-9`（UTC+9）で扱います。JST は DST が無いため常に
  正確ですが、他タイムゾーンの表示には対応しません。
- CloudWatch のログ自体に機密情報が含まれる可能性があります。出力の取り扱いに注意
  してください。スイッチバック用シェルの内容は信頼済みである必要があります。

---

## 実装上の主な判断事項

- **jq を必須**とした（複数行・タブ・制御文字・UTF-8 を安全に扱うため）。未導入時は
  終了コード 3 で明確に案内する。
- 単一ストリーム指定時は `get-log-events`、全/複数ストリーム横断・cloudwatch フィルタ時は
  `filter-log-events` を使用する。
- フィールド区切りに **US(0x1F)** を使用（タブだと bash `read` が空フィールドを畳み込むため）。
- 認証エラーと権限不足を AWS エラー文字列で分類し、終了コードと案内を分ける。
- 自動スイッチバックは 1 回のみ。source 前にファイルの実在・通常ファイル・読み取り可・
  他者書き込み不可を検証し、`eval` は使わず引数は配列で渡す。
- `--last-minutes` は実行時点を終了時刻とする単独指定（`--start`/`--end` と併用不可）。
  `--end` 単独はエラー。`--follow` と `--end` は併用不可。`--dry-run` は AWS 参照も行わず
  予定のみ表示。
