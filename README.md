# cloudwatch-log-viewer.sh

TeraTerm から接続した Linux サーバー上で実行し、AWS CloudWatch Logs のログを
**「JST のログ出力時刻 | ログメッセージ」** の見やすい形式で確認する実運用向け
Bash ツールです。期間指定・直近 N 分・フィルタ・`tail -f` 相当の監視・
ロググループ/ストリームの対話選択・AWS 認証/権限確認・権限不足時のスイッチバック
案内/自動実行に対応します。

**複数のロググループをまとめて指定・横断検索**でき、画面にはロググループごとに
区切って表示します。`--excel` を付けると次の 2 つを同じフォルダへ出力します。

- **Excel ブック** … ロググループごとにシートを分割。フォントは **Meiryo UI**。
  JBoss EAP のログは区分（**デプロイ / 起動 / 停止 / エラー / 警告**）ごとに色分けし、
  **「主要イベント」シート**でアプリケーションの配備とサーバー本体の起動・停止を
  ロググループ横断・時刻順に一覧できます。
- **生テキストログ** … **ロググループごと・ログストリームごと**に 1 ファイルへ分割。
  本文はサーバー上のログファイルと同じ形のまま出力するので `grep` / `diff` で使えます。

期間（`--start` / `--end` / `--last-minutes`）の判定は、既定で
**ログ本文に出力されている時刻**を基準に行います（CloudWatch がイベントを受け取った
時刻ではありません）。

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
- `zip`（Info-ZIP。**`--excel` で xlsx を出力する場合のみ**。無い環境では
  `--excel-format xml`（SpreadsheetML 形式）を使えば `zip` なしで出力できます）
- 事前に `aws login --remote` 等で認証済みであること（本ツールは自動ログインしません）

> Excel 出力に Python / openpyxl / COM 等の外部ライブラリは不要です。xlsx（ZIP + XML）を
> スクリプト内で直接組み立てます。

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

`--log-group` を省略すると、参照可能なロググループを一覧表示して番号で選択できます
（**複数選択可**）。`--help` で全オプション・デフォルト・排他条件・環境変数・終了コード・
実行例を表示します。

### 複数ロググループの指定方法

```bash
# 1) オプションを繰り返す
-g /aws/lambda/api -g /aws/lambda/batch -g /aws/ecs/worker

# 2) カンマ区切りでまとめる（ロググループ名にカンマは使えないため安全）
-g "/aws/lambda/api,/aws/lambda/batch,/aws/ecs/worker"

# 3) 1) と 2) の併用も可。重複指定は警告のうえ 1 件にまとめられます
```

指定した順に取得・表示・シート作成を行います。`--log-group` を省略した場合は
一覧から番号で選択でき、複数選択の入力形式は次のとおりです。

| 入力 | 意味 |
|---|---|
| `3` | 3 番を選択 |
| `1,4` または `1 4` | 1 番と 4 番を選択 |
| `2-5` | 2〜5 番を選択 |
| `a` | 表示中の全件を選択 |
| `/正規表現` | 一覧を絞り込む（`//` で解除） |
| `q` | 中止 |

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

# 複数ロググループを直近 30 分ぶん、グループごとに区切って画面表示
./cloudwatch-log-viewer.sh --last-minutes 30 \
  -g /aws/lambda/api -g /aws/lambda/batch -g /aws/ecs/worker

# 一覧から複数選択（番号は 1 3,5 7-9 / a=全件）
./cloudwatch-log-viewer.sh --last-minutes 30

# 複数ロググループをシート別に Excel 出力（画面にも表示する）
# 生テキストログ（ストリームごと）と 00_index.txt も同じフォルダへ出力される
./cloudwatch-log-viewer.sh --start "2026-07-12 09:00" --end "2026-07-12 18:00" \
  -g /aws/lambda/api -g /aws/lambda/batch --excel /tmp/logs.xlsx

# JBoss EAP の 2 系統を横断し、本文時刻で 09:00〜10:00 を切り出して Excel 化
./cloudwatch-log-viewer.sh --start "2026-07-12 09:00:00" --end "2026-07-12 10:00:00" \
  -g "/jboss/eap/server,/jboss/eap/console" --output none --excel ./eap.xlsx

# 画面表示はせず Excel だけ作る（ERROR を含む行のみ・生テキストログは作らない）
./cloudwatch-log-viewer.sh --last-minutes 120 -g "/aws/lambda/api,/aws/lambda/batch" \
  --filter ERROR --output none --excel ./error_logs.xlsx --no-raw-text

# 生テキストログだけをフォルダへ書き出す（Excel は作らない）
./cloudwatch-log-viewer.sh --last-minutes 60 -g /jboss/eap/server \
  --output none --raw-dir ./logs

# イベント時刻で期間を判定する（v1.1 までの動作に戻す）
./cloudwatch-log-viewer.sh --last-minutes 60 -g /aws/lambda/api --time-source event

# zip コマンドが無い環境では SpreadsheetML 形式で出力する
./cloudwatch-log-viewer.sh --last-minutes 60 -g /aws/lambda/api --excel ./logs.xml

# 複数ロググループをまとめて監視（行頭にロググループ名が付く）
./cloudwatch-log-viewer.sh -g /aws/lambda/api -g /aws/lambda/batch --last-minutes 5 --follow
```

---

## 画面表示（複数ロググループ）

ロググループが 2 件以上のときは、ロググループごとに見出しで区切って表示します。

```
==========================================================================
 [1/3] ロググループ: /aws/lambda/api
         期間(JST) : 2026-07-12 09:00:00.000 JST  〜  2026-07-12 18:00:00.999 JST
==========================================================================
2026-07-12 09:00:00.123 JST | INFO  起動しました
2026-07-12 09:01:01.456 JST | ERROR 例外が発生しました
                              Traceback (most recent call last):
                                File "app.py", line 42, in handler
  -- 出力 2 件 / 取得 3 件 / 期間外 1 件 --

==========================================================================
 [2/3] ロググループ: /aws/lambda/batch
...
```

最後にロググループごとの件数と合計を集計表示します。

- 行頭の時刻は **ログ本文に出力されている時刻**です（本文に時刻が無い行のみ
  CloudWatch のイベント時刻）。並び順もこの時刻の昇順です。
  CloudWatch のイベント時刻も見たい場合は `--show-event-time` を付けてください。
- 「期間外」は、CloudWatch からは取得できたものの**本文の時刻が対象期間の外**だったため
  出力しなかった件数です（`--time-source message` のときのみ発生します）。
- 見出し・件数の行は **`--output text` のときだけ標準出力**へ出します（画面と同じ
  区切りがリダイレクト先のファイルにも残るようにするため）。`tsv` / `jsonl` では
  機械処理を壊さないよう標準エラーへ `[INFO]` として出します。
- ロググループが 1 件のときは見出しを付けません。
- `--max-events` は**ロググループ 1 件あたり**の上限として適用されます。

### 行ごとのロググループ名表示

| 状況 | 行頭 / 列へのロググループ名 |
|---|---|
| ロググループ 1 件 | 付かない（従来どおり） |
| 複数 + `text`（通常取得） | 付かない（見出しで区切られるため） |
| 複数 + `tsv` | **先頭に `logGroup` 列**が追加される |
| 複数 + `--follow` | **行頭にロググループ名**が付く（出力が時系列で混ざるため） |
| `--show-log-group` 指定時 | 常に付く（1 件でも） |
| `jsonl` | 常に `logGroup` フィールドを持つ（従来どおり・変更なし） |

> `tsv` の列構成は v1.2 で変わりました（`logTime_jst` / `logTime(ms)` /
> `eventTime(ms)` / `logStream` / `ingestionTime(ms)` / `message`。複数ロググループ時は
> 先頭に `logGroup` 列）。ログ本文の時刻と CloudWatch のイベント時刻を区別するためです。

---

## 期間の判定（`--time-source`）

アプリケーションがログを書いた時刻と、CloudWatch がイベントを受け取った時刻は
ずれることがあります（バッファリング、エージェントの遅延、サーバー時刻のずれなど）。
運用で「9:00〜10:00 のログ」と言うときに見たいのは **ログ本文に出ている時刻** の
ほうなので、本ツールは既定でそちらを基準に期間を判定します。

| 指定 | 期間判定に使う時刻 |
|---|---|
| `--time-source message`（既定） | **ログ本文の先頭に出力されている時刻**。読み取れない行は CloudWatch のイベント時刻 |
| `--time-source event` | CloudWatch のイベント時刻（v1.1 までの動作） |

認識できる本文の時刻形式（先頭 72 文字以内で最初に見つかったもの。タイムゾーンの
指定が無ければ JST として解釈します）:

| 例 | 備考 |
|---|---|
| `2026-07-31 09:15:23,456` | JBoss EAP / Log4j の標準形式（カンマ・ピリオドどちらも可） |
| `2026-07-31T09:15:23.456+09:00` | ISO8601。オフセットを尊重します |
| `2026-07-31T00:15:23.456Z` | UTC。JST へ変換されます |
| `2026/07/31 09:15:23` | スラッシュ区切り |
| `09:15:23,456` | 日付なし（JBoss EAP 既定の `%d{HH:mm:ss,SSS}`）。日付はイベント時刻から補い、日付境界をまたぐ場合（0 時前後）は前後 12 時間を基準に前日／翌日へ補正します |

**取得マージン**: CloudWatch からはイベント時刻でしか絞り込めないため、
前後 `--time-margin-minutes`（既定 5 分）ぶん広く取得してから、本文時刻で絞り込みます。
本文時刻とイベント時刻のずれが 5 分を超える環境では、この値を大きくしてください。
広げた取得期間は `--dry-run` や実行計画の「取得期間」に表示されます。

出力・画面の並び順、Excel の「時刻(JST)」列も、この本文時刻を基準にします
（CloudWatch のイベント時刻は Excel の別列と `--show-event-time` で確認できます）。

---

## Excel 出力（`--excel`）

ロググループごとにシートを分けた Excel ファイルを作成します。
**フォントは全シート Meiryo UI** です。

```bash
./cloudwatch-log-viewer.sh -g /aws/lambda/api -g /aws/lambda/batch \
  --start "2026-07-12 09:00" --end "2026-07-12 18:00" --excel ./logs.xlsx
```

### シート構成

| シート | 内容 |
|---|---|
| `サマリ`（1 枚目） | 出力日時 / 対象期間 / **期間の判定基準** / AWS アカウント・プロファイル・リージョン / 抽出条件 / 取得上限 / 生ログの出力先、およびロググループ一覧（No・ロググループ・シート名・取得・期間外・出力・**エラー・警告・デプロイ・アンデプロイ・起動・停止の件数**・最古/最新日時・生ログ数） |
| `主要イベント`（2 枚目） | **アプリケーションのデプロイ**と **JBoss EAP の起動・停止**だけを、ロググループ横断で時刻順に並べた一覧 |
| ロググループごと | 1 行目にロググループ名、2 行目に期間・件数・抽出条件、3 行目が見出し、4 行目以降がログ |

各ログシートの列は次のとおりです。

| 列 | 内容 |
|---|---|
| A | 時刻(JST) — **ログ本文に出力されている時刻**。**Excel の日時型**（書式 `yyyy-mm-dd hh:mm:ss.000`）でそのまま並べ替え・フィルタできます |
| B | 区分（`デプロイ` / `アンデプロイ` / `起動` / `停止` / `エラー` / `警告` / `デバッグ`。通常の INFO 行は空欄） |
| C | レベル（`ERROR` / `WARN` / `INFO` / `DEBUG` など） |
| D | ログストリーム |
| E | メッセージ（セル内で折り返し表示。複数行ログはセル内改行として保持） |
| F | イベント時刻(JST) — CloudWatch がイベントを受け取った時刻。Excel の日時型 |
| G | timestamp(ms) — 数値 |

- 見出し行で**ウィンドウ枠を固定**し、**オートフィルタ**を設定済みです。
  B 列（区分）で絞り込めば、デプロイやエラーだけをすぐ抜き出せます。
- `--single-line` を付けると、メッセージの改行を `\n` 表記の 1 行に変換して入れます。

### JBoss EAP ログの色分け

行は「区分」ごとに色分けされます（`--no-highlight` で無効化）。
**アプリケーションのデプロイは、EAP 本体の起動とは別の観点**として、色も区分も
分けています。デプロイ行を追えばアプリの入れ替えが、起動行を追えばサーバーの
再起動が、それぞれ独立して読み取れます。

| 区分 | 色 | 判定に使う JBoss EAP のメッセージコード等 |
|---|---|---|
| デプロイ | 緑 | `WFLYSRV0027`（Starting deployment of） / `WFLYSRV0010`（Deployed） / `WFLYSRV0016`（Replaced deployment） / `WFLYUT0021`（Registered web context） / `WFLYDS0004` / `WFLYDS0013` / `JBAS015876` / `JBAS018559` / `JBAS017534` |
| アンデプロイ | 橙 | `WFLYSRV0009`（Undeployed） / `WFLYSRV0028`（Stopped deployment） / `WFLYUT0022` / `JBAS018558` / `JBAS015877` / `JBAS017535` |
| 起動 | 青 | `WFLYSRV0049`（starting） / `WFLYSRV0025`（started in Nms） / `WFLYSRV0026` / `WFLYSRV0212` / `JBAS015874` / `JBAS015899` |
| 停止 | 紫 | `WFLYSRV0050`（stopped in Nms） / `WFLYSRV0211`（Suspending） / `WFLYSRV0220`（shutdown） / `WFLYSRV0236` / `JBAS015950` |
| エラー | 赤 | 出力レベル `ERROR` / `FATAL` / `SEVERE` |
| 警告 | 黄 | 出力レベル `WARN` |
| デバッグ | 灰 | 出力レベル `DEBUG` / `TRACE` |

- **色はエラー・警告を最優先**します。デプロイに失敗した行は
  「区分=デプロイ / レベル=ERROR / 色=赤」となり、区分での絞り込みからも漏れません。
- JBoss EAP 以外のログでも、レベル（ERROR / WARN / DEBUG）による色分けは働きます。

### 形式（xlsx / xml）

| 形式 | 指定 | 必要なもの | 備考 |
|---|---|---|---|
| `xlsx` | 拡張子 `.xlsx`、または `--excel-format xlsx` | `zip` コマンド | 通常の Excel ブック（既定） |
| `xml` | 拡張子 `.xml`、または `--excel-format xml` | なし | SpreadsheetML 2003 形式。Excel で開けます |

拡張子から判定できない名前のときは `xlsx` として出力し、警告を表示します。
`zip` が無い環境で xlsx を指定した場合は、終了コード 3 で `--excel-format xml` を案内します。

### シート名の付け方

Excel のシート名には制約（31 文字以内 / `: \ / ? * [ ]` 不可 / 重複不可）があるため、
ロググループ名を次のように変換します。

- 使用できない文字は `_` に置き換える（`/aws/lambda/api` → `_aws_lambda_api`）
- 31 文字を超える場合は**末尾側 31 文字**を残す（`/aws/lambda/...` のように先頭が
  共通しがちで、末尾のほうが識別に役立つため）
- それでも重複する場合は `~2` `~3` … を付けて一意にする

**完全なロググループ名は各シートの 1 行目と「サマリ」シートに記録**されるため、
シート名が切り詰められても対応関係をたどれます。

### 制約

- `--follow` とは併用できません（監視は終了しないためファイルを確定できないため）。
- 既存ファイルは上書きします。対話端末では確認プロンプトを出し、
  `--non-interactive` やパイプ実行では警告のうえ上書きします。
- 1 シートあたり Excel の上限 1,048,576 行、1 セルあたり 32,767 文字を超える分は
  切り捨て、警告を表示します（既定の `--max-events 10000` では通常到達しません）。
- 「主要イベント」シートは 5,000 行を上限とし、超える場合は打ち切って注記します。
- `--output none` を併用すると、画面へはログを出さず Excel だけを作成します
  （`--output none` は `--excel` か `--raw-dir` とセットでのみ指定できます）。

---

## 生テキストログ出力

`--excel` を指定すると、Excel と**同じフォルダ**へ生テキストログも出力します
（`--no-raw-text` で抑止、`--raw-dir DIR` で出力先を変更）。
`--excel` を使わず `--raw-dir` だけを指定して、生テキストログのみを作ることもできます。

**ロググループごと・ログストリームごとに 1 ファイル**へ分割します。

```
出力先フォルダ/
├── logs.xlsx                              # Excel（--excel で指定した名前）
├── 00_index.txt                           # 対応表（どのファイルがどのストリームか）
├── 01_jboss-eap-server_app-node1.log      # ロググループ 1 / ストリーム app/node1
├── 01_jboss-eap-server_app-node2.log      # ロググループ 1 / ストリーム app/node2
└── 02_jboss-eap-console_console-node1.log # ロググループ 2 / ストリーム console/node1
```

- ファイル名は `NN_ロググループ名_ログストリーム名.log`。`NN` は「サマリ」シートの
  No と同じ通し番号です。名前は**ファイル名に使えない文字を `-` へ置換し、
  末尾側 24 文字まで**に短縮します（先頭が共通しがちで末尾のほうが識別に役立つため）。
  短縮後に衝突する場合は `~2` `~3` … を付けて一意にします。
- 完全なロググループ名・ストリーム名と件数は `00_index.txt` に記録されるため、
  短縮されても対応関係をたどれます。
- 中身は**メッセージ本文をそのまま**出力します（先頭 3 行だけ `#` で始まる
  ロググループ・ストリーム・期間の注記が入ります）。複数行のスタックトレースも
  サーバー上のログファイルと同じ見た目のまま残るので、`grep` / `diff` に使えます。
- `--raw-with-time` を付けると、各イベントの先頭へ `[時刻(JST)] ` を付加します。
- 出力対象は Excel と同じ（対象期間・フィルタを通過したログ）です。
- `--follow` とは併用できません。

---

## オプション一覧

| オプション | 説明 |
|---|---|
| `-g, --log-group NAME` | ロググループ名を直接指定。**複数指定可**（繰り返し / カンマ区切り）。省略時は一覧から複数選択 |
| `--log-group-prefix P` | 一覧表示するロググループをプレフィックスで絞り込む |
| `-s, --log-stream NAME` | 特定のログストリームを指定（`get-log-events` を使用）。ロググループ 1 件のときのみ |
| `--log-stream-prefix P` | 対象ログストリームをプレフィックスで絞り込む |
| `--select-log-stream` | ログストリームを一覧表示し番号で選択。ロググループ 1 件のときのみ |
| `--start "YYYY-MM-DD HH:MM[:SS]"` | 取得開始日時（JST。ISO8601 +09:00 も可） |
| `--end "YYYY-MM-DD HH:MM[:SS]"` | 取得終了日時（JST。秒単位で inclusive） |
| `-m, --last-minutes N` | 直近 N 分（1〜10080）。`--start`/`--end` と併用不可 |
| `--time-source message\|event` | 期間判定に使う時刻（既定 message = ログ本文の時刻） |
| `--time-margin-minutes N` | message のとき CloudWatch から前後 N 分ぶん余分に取得（既定 5） |
| `-f, --filter PATTERN` | 表示条件（複数指定可） |
| `--exclude PATTERN` | 除外条件（複数指定可・いずれか一致で除外） |
| `--filter-mode cloudwatch\|literal\|regex` | フィルタ方式（既定 literal） |
| `--filter-logic and\|or` | 複数 `--filter` の論理（既定 and） |
| `-i, --ignore-case` | ローカルフィルタで大文字小文字を無視 |
| `-F, --follow` | tail -f 相当の監視（`--end` と併用不可） |
| `--poll-interval SEC` | ポーリング間隔秒（既定 5） |
| `--overlap-seconds SEC` | 遅延到着対策の重複取得期間（既定 5） |
| `--show-log-stream` | ログストリーム名も表示（text 時） |
| `--show-log-group` | 各行にロググループ名も表示（複数指定時は tsv / 監視で自動有効） |
| `--show-event-time` | CloudWatch のイベント時刻も表示（text 時） |
| `--show-ingestion-time` | 取り込み時刻も表示（text 時） |
| `--single-line` | 複数行を 1 行へ（改行を `\n` 表示） |
| `--output text\|tsv\|jsonl\|none` | 出力形式（既定 text）。`none` は画面へ出さない（`--excel` / `--raw-dir` 併用時のみ） |
| `--excel FILE` | ロググループごとにシートを分けて Excel 出力（`--follow` とは併用不可） |
| `--excel-format xlsx\|xml` | Excel の形式（既定は拡張子から自動判定。既定 xlsx） |
| `--no-highlight` | Excel の区分ごとの色分けを行わない |
| `--raw-dir DIR` | 生テキストログの出力先（既定は `--excel` と同じフォルダ） |
| `--no-raw-text` | 生テキストログを出力しない |
| `--raw-with-time` | 生テキストログの各イベント先頭へ `[時刻(JST)] ` を付ける |
| `--max-events N` | 最大表示イベント数（既定 10000。**ロググループごと**に適用） |
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
CLOUDWATCH_LOG_OUTPUT                text|tsv|jsonl|none
CLOUDWATCH_LOG_EXCEL                 Excel 出力先ファイル（--excel 相当）
CLOUDWATCH_LOG_TIME_SOURCE           message|event（--time-source 相当）
CLOUDWATCH_LOG_TIME_MARGIN           取得マージン分数（--time-margin-minutes 相当）
CLOUDWATCH_LOG_RAW_DIR               生テキストログの出力先（--raw-dir 相当）
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
| 10 | 出力エラー（Excel / 生テキストログの出力先が無い・書き込めない・zip 失敗・上書き中止） |
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

### 本文時刻の解析の確認

```bash
# 実行計画に「対象期間」と、マージンを足した「取得期間」の両方が出ることを確認する
./cloudwatch-log-viewer.sh -g /jboss/eap/server \
  --start "2026-07-31 09:00:00" --end "2026-07-31 09:30:00" --dry-run

# 本文時刻とイベント時刻を並べて確認する（ずれの大きさを把握できる）
./cloudwatch-log-viewer.sh -g /jboss/eap/server -m 30 --show-event-time
```

`--show-event-time` を付けた行で、先頭の時刻（本文）と `event=`（CloudWatch）が
どの程度ずれるかを見て、`--time-margin-minutes` を決めてください。

### 実 AWS での確認

```bash
aws login --remote                      # 事前認証
./cloudwatch-log-viewer.sh --last-minutes 10          # 一覧から複数選択→表示
./cloudwatch-log-viewer.sh -g /aws/lambda/xxx -m 5 -F # 監視

# 複数ロググループ + Excel + 生テキストログ
./cloudwatch-log-viewer.sh -g /aws/lambda/a -g /aws/lambda/b -m 60 --excel /tmp/logs.xlsx
```

### Excel / 生テキストログ出力の確認（AWS なしでも可能な範囲）

```bash
# xlsx は ZIP コンテナ。中身の XML が整形式であることを確認できる
unzip -l logs.xlsx
unzip -p logs.xlsx xl/workbook.xml | head -c 400
for f in $(unzip -Z1 logs.xlsx); do unzip -p logs.xlsx "$f" | xmllint --noout - || echo "NG $f"; done

# フォントが Meiryo UI で統一されていること
unzip -p logs.xlsx xl/styles.xml | grep -o 'name val="[^"]*"' | sort -u

# SpreadsheetML は単一 XML なのでそのまま確認できる
./cloudwatch-log-viewer.sh -g /aws/lambda/a -m 10 --excel /tmp/logs.xml
xmllint --noout /tmp/logs.xml && echo "XML OK"   # xmllint 導入時

# 生テキストログ: 対応表とファイル数が一致すること
cat 00_index.txt
ls *.log | wc -l
```

最終的な表示崩れ・色分けの見え方は、実際に Excel で開いて確認してください。

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
- 出力: text / tsv / jsonl / none / パイプ・リダイレクト / `--non-interactive`
- 複数ロググループ: 1 件 / 複数 / カンマ区切り / 繰り返し指定 / 重複指定 / 一部が 0 件 /
  一部が存在しない / 一覧からの複数選択（`1,3` / `2-5` / `a` / 絞り込み後の `a` / 不正入力）/
  `--log-stream` や `--select-log-stream` との併用拒否 / 監視モードでの行頭グループ名 /
  `tsv` の列追加 / 1 件のときに従来と同じ出力になること
- Excel: xlsx / xml / シート数 / シート名の変換・31 文字超の切り詰め・重複時の `~2` /
  0 件シート / 複数行メッセージのセル内改行 / `&` `<` `>` `"` を含むメッセージ /
  日本語・UTF-8 / 日時列が Excel で日時として扱えること / オートフィルタ・枠固定 /
  既存ファイルの上書き（対話・非対話）/ 出力先ディレクトリなし / `zip` 不在時の案内 /
  `--follow` との併用拒否 / `--output none` 単独指定の拒否 / 大量件数（数千件）の所要時間 /
  フォントが Meiryo UI であること / 区分ごとの色分け / `--no-highlight` で色が消えること /
  主要イベントシートの内容と時刻順 / サマリの区分別件数
- 本文時刻: `YYYY-MM-DD HH:MM:SS,mmm` / ISO8601 の `+09:00` と `Z` / `YYYY/MM/DD` /
  日付なし `HH:MM:SS,mmm` とその日付境界（0 時前後）の補正 / 本文に時刻が無い行 /
  先頭以外に時刻がある行 / 0 埋めの月日（`08` を 8 進数と誤解しないこと）/
  本文時刻は範囲内・イベント時刻は範囲外の行が出力されること（マージン）/
  その逆の行が「期間外」として除外されること / `--time-source event` で従来動作になること
- 区分判定: WFLY/JBAS の各コード / デプロイとアンデプロイの取り違えがないこと /
  デプロイ失敗（区分=デプロイ・レベル=ERROR・色=赤）/ JBoss 以外のログでのレベル判定
- 生テキストログ: ストリームごとのファイル分割 / ファイル名の短縮と重複時の `~2` /
  `00_index.txt` の対応表 / 本文がそのまま（複数行を含む）出力されること /
  `--raw-with-time` / `--raw-dir` 単独指定 / `--no-raw-text` / `--follow` との併用拒否 /
  出力先ディレクトリの自動作成

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
- 期間無制限の全件取得は行いません。既定は直近 10 分、上限は `--max-events`
  （**ロググループごと**に適用されるため、3 グループ指定なら最大 3×`--max-events` 件）。
- **複数ロググループは並列ではなく順番に取得します**。ロググループ数に比例して
  時間がかかります（API 呼び出し回数も比例します）。
- 複数ロググループ指定時、**各グループの取得タイミングはわずかにずれます**
  （順番に取得するため）。監視モードでは各グループが独立した取得ウィンドウを持ちます。
- メッセージ中の制御文字（C0: 0x01〜0x08 / 0x0B / 0x0C / 0x0E〜0x1F）は**空白へ置換**します。
  Excel（XML）が扱えない文字であることに加え、ESC 等が端末へそのまま渡ると表示が
  乱れるためです。**v1.0 ではこれらはそのまま出力していました**（`text` / `tsv` /
  `jsonl` の出力がこの点だけ v1.0 と異なります）。`\t` `\r` `\n` は従来どおり
  `\t` `\r` `\n` として可視化します。
- タイムゾーンは固定オフセット `JST-9`（UTC+9）で扱います。JST は DST が無いため常に
  正確ですが、他タイムゾーンの表示には対応しません。
- **本文時刻の解析は「先頭 72 文字以内の最初の時刻」**です。対応表にない形式
  （`Jul 31 09:15:23` などの月名表記等）は認識できず、イベント時刻で判定します。
  複数行のイベントは**先頭行の時刻**をそのイベントの時刻とします。
- CloudWatch からの取得はイベント時刻でしか絞れないため、本文時刻とイベント時刻の
  ずれが `--time-margin-minutes`（既定 5 分）を超えるログは、対象期間内であっても
  取得できません。ずれの大きい環境ではこの値を増やしてください。
- **区分（デプロイ / 起動 等）の判定は JBoss EAP のメッセージコードと出力レベルに
  基づくヒューリスティック**です。ログ形式を変更している場合や、メッセージ本文に
  たまたま該当コード・`ERROR` 等の語が含まれる場合は、意図と異なる区分になることが
  あります。色分けは判断の補助であり、最終確認は本文で行ってください。
- 生テキストログはメッセージ本文をそのまま出力しますが、CloudWatch がイベントとして
  受け取った単位で改行されるため、元のログファイルとバイト単位で一致するとは限りません。
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
- 複数ロググループでも **`--log-group` の指定順を保つ**（表示順・シート順とも）。重複指定は
  警告のうえ 1 件にまとめる。ログストリームはロググループに属するため、`--log-stream` /
  `--select-log-stream` はロググループ 1 件のときだけ許可する。
- Excel 出力は**外部ライブラリを使わず xlsx（ZIP + XML）を自前で組み立てる**。Python や
  COM に依存しないため、サーバー側の追加インストールは `zip` だけで済む。`zip` すら無い
  環境向けに SpreadsheetML（単一 XML）へのフォールバックを用意した。
- Excel の時刻列は文字列ではなく**日時型（シリアル値 + 表示書式）**で書き込む。Excel 上で
  そのまま並べ替え・フィルタ・書式変更ができるようにするため。
- Excel の出力先の妥当性（ディレクトリの存在・書き込み可否・上書き確認）は、
  **ログ取得を始める前に**検証する。長い取得のあとで書き出しに失敗させないため。
- イベント 1 件ごとに実行される処理ではコマンド置換（`$(...)`）を使わず、`printf -v` で
  グローバル変数へ値を返す。`$(...)` は 1 回ごとに fork するため、数千件規模で処理時間が
  桁違いに悪化する（実測: 3000 件の xlsx 生成が 2 分超 → 約 14 秒）。
- `${var//pat/rep}` の `rep` に書いた `&` は **bash 5.2 以降「マッチした文字列」に展開される**
  （5.1 以前は単なる文字）。XML エスケープ（`<` → `&lt;` 等）が bash の版によって壊れるため、
  バージョン番号ではなく**実際の挙動を起動時に 1 度調べて**書き方を切り替えている。
- **期間の判定は既定でログ本文の時刻**にした。運用で「9:00〜10:00 のログ」と言うときに
  見たいのはアプリが書いた時刻であり、CloudWatch が受け取った時刻ではないため。
  取得はイベント時刻でしか絞れないので、**取得期間だけをマージンぶん広げ、対象期間は
  変えずに本文時刻でローカル絞り込み**する二段構えにした。従来動作は
  `--time-source event` で選べる。
- 本文時刻の epoch 変換は **`date` を呼ばず bash の算術式だけ**で行う（グレゴリオ暦の
  `days_from_civil` を実装）。イベント 1 件ごとに `date` を fork すると数千件で破綻するため。
  同じ日付の変換結果はキャッシュする。`10#` を付けて `08` を 8 進数と解釈させない。
- 区分判定では、**正規表現の前に安価なグロブ一致で語の有無を調べる**。イベント 1 件ごとに
  最大 9 回の正規表現を走らせると重いため、語を含まない行では実行そのものを省く。
- **アンデプロイをデプロイより先に判定**する。`--ignore-case` 指定時は `Undeployed` が
  `Deployed` のパターンにも一致してしまうため。
- 色は**エラー・警告を最優先**しつつ、**区分名は JBoss の観点（デプロイ / 起動）を残す**。
  デプロイ失敗を緑で埋もれさせず、かつ区分での絞り込みからも漏らさないため。
- 生テキストログはストリームごとにファイルを開き直す回数を減らすため、
  **「ストリーム名 → ログ時刻」の順に並べ替えてから 1 度だけ走査**し、
  ストリームが変わったときだけファイル記述子を開き直す。
- 収集バッファへの追記は `>>` ではなく**ファイル記述子を開いたまま**書く。
  `>>` はイベント 1 件ごとに open/close が発生するため。
