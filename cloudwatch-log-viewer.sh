#!/usr/bin/env bash
#
# cloudwatch-log-viewer.sh
# ========================
# AWS CloudWatch Logs のログを「JST のログ出力時刻」と「ログメッセージ」の
# 見やすい形式で TeraTerm 等のコンソールに表示する実運用向けツールです。
#
# 主な機能:
#   - ロググループの直接指定（複数可）/ 一覧からの番号選択（複数選択・プレフィックス絞り込み対応）
#   - 複数ロググループを横断して検索し、ロググループごとに区切って画面表示
#   - ログストリームの直接指定 / プレフィックス / 一覧選択 / 全ストリーム横断
#   - 期間指定（JST の開始・終了日時 / 直近 N 分 / 既定は直近 ${DEFAULT_LAST_MINUTES:-10} 分）
#     ※ 期間の判定は「ログ本文に出力されている時刻」を基準に行う（--time-source）
#   - フィルタ（cloudwatch サーバー側 / literal 固定文字列 / regex 正規表現）
#     除外フィルタ・大文字小文字無視・複数条件の AND/OR
#   - tail -f 相当のリアルタイム監視（ポーリング方式・遅延到着対策・重複排除）
#   - 出力形式 text / tsv / jsonl / none
#   - Excel 出力（--excel）: ロググループごとにシートを分けて 1 ファイルへ書き出す
#     フォントは Meiryo UI。JBoss EAP のログは区分（起動 / 停止 / デプロイ /
#     アンデプロイ / エラー / 警告）ごとに色分けし、「主要イベント」シートに集約する
#   - 生テキストログの出力: ロググループ × ログストリームごとに 1 ファイルへ分けて
#     Excel と同じフォルダへ書き出す（ファイル名は短く分かりやすい形式）
#   - AWS 認証状態の事前確認（未認証は aws login --remote を促して終了）
#   - CloudWatch Logs 操作権限の確認と、権限不足時のスイッチバック案内 / 自動実行
#
# 依存: bash 4.2+, aws (CLI v2), jq, GNU date, GNU coreutils(sort/stat/mktemp)
#       Excel を xlsx 形式で出力する場合のみ zip（Info-ZIP）が追加で必要
#       （zip が無い環境では --excel-format xml で SpreadsheetML 形式を出力できる）
# 共通部品: common.sh（任意。見つかればログ関数等を利用、無ければ本体で定義）
#
# 認証について:
#   本ツールは自動ログインを行いません。事前に `aws login --remote` 等で
#   認証済みであることを前提とし、`aws sts get-caller-identity` の成否で判定します。
#
# 時刻について:
#   入力・表示ともに JST（+09:00）として扱います。実行サーバーの TZ 設定に
#   依存しないよう、スクリプト内で TZ='JST-9'（tzdata 非依存の固定オフセット）を
#   明示設定します。ISO8601 で明示オフセット付きの入力はその値を尊重します。
#
#   期間（--start/--end/--last-minutes）の判定には、既定で「ログ本文の先頭に
#   出力されている時刻」を使います（--time-source message）。アプリケーションが
#   ログを書いた時刻と CloudWatch がイベントを受け取った時刻はずれることがあり、
#   運用上は前者で切り出したいためです。CloudWatch からの取得自体はイベント時刻
#   でしか絞れないため、前後に --time-margin-minutes 分の余裕を持たせて取得し、
#   本文時刻でローカルに絞り込みます。本文に時刻が無い行はイベント時刻を使います。
#
set -Eeuo pipefail

# ===========================================================================
# 0. 基本設定
# ===========================================================================
VERSION="1.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# AWS CLI のページャーを無効化（TeraTerm 上で less が起動しないように）
export AWS_PAGER=""

# 入出力・日時解釈を JST に固定する（サーバー TZ が UTC 等でも正しく動作させる）。
#   POSIX TZ 形式 'JST-9'（= UTC+9）を使う。zoneinfo(tzdata) に 'Asia/Tokyo' が
#   無い最小環境でも確実に +09:00 として解釈・表示でき、JST は DST が無いため
#   固定オフセットで常に正しい。
export TZ='JST-9'
readonly JST_OFFSET_SECONDS=32400   # +09:00 = 9*3600（jq 側の TZ 非依存計算用）

# --- 終了コード定義（実装と一致させること） ---
readonly EX_OK=0            # 正常終了
readonly EX_USAGE=2         # 引数エラー
readonly EX_NODEP=3         # 必須コマンド不足
readonly EX_AUTH=4          # AWS 未認証 / 認証期限切れ
readonly EX_PERM=5          # AWS 権限不足
readonly EX_NOTFOUND=6      # リソース未検出
readonly EX_API=7           # AWS API / 通信エラー
readonly EX_SWITCHBACK=8    # スイッチバック失敗
readonly EX_TIME=9          # 日時指定エラー
readonly EX_OUTPUT=10       # 出力ファイル（Excel）の書き出しエラー
readonly EX_INT=130         # Ctrl+C による終了

# ===========================================================================
# 1. common.sh の解決と読み込み（任意）
#    優先順位: --common-sh > 環境変数 CLOUDWATCH_LOG_COMMON_SH > 同一ディレクトリ
#    見つからない場合は本体でフォールバック関数を定義するため、common.sh は必須ではない。
# ===========================================================================
COMMON_SH="${CLOUDWATCH_LOG_COMMON_SH:-}"   # --common-sh で上書き可能

load_common() {
  local path="$COMMON_SH"
  if [[ -z "$path" && -f "${SCRIPT_DIR}/common.sh" ]]; then
    path="${SCRIPT_DIR}/common.sh"
  fi
  if [[ -n "$path" ]]; then
    if [[ ! -f "$path" ]]; then
      printf '[%s][ERROR] 指定された common.sh が見つかりません: %s\n' "$SCRIPT_NAME" "$path" >&2
      exit "$EX_USAGE"
    fi
    # shellcheck source=/dev/null
    source "$path"
    COMMON_SH="$path"
  fi
  define_fallbacks
}

# common.sh が無い / 一部関数が未定義の場合に備えたフォールバック定義。
# （既存 common.sh を後から差し替えても壊れないよう、未定義のものだけ定義する）
define_fallbacks() {
  if ! declare -F log_info >/dev/null 2>&1; then
    log_info()    { printf '%s[INFO]%s  %s\n'  "${C_BLUE:-}"   "${C_RESET:-}" "$*" >&2; }
  fi
  if ! declare -F log_success >/dev/null 2>&1; then
    log_success() { printf '%s[OK]%s    %s\n'  "${C_GREEN:-}"  "${C_RESET:-}" "$*" >&2; }
  fi
  if ! declare -F log_warn >/dev/null 2>&1; then
    log_warn()    { printf '%s[WARN]%s  %s\n'  "${C_YELLOW:-}" "${C_RESET:-}" "$*" >&2; }
  fi
  if ! declare -F log_error >/dev/null 2>&1; then
    log_error()   { printf '%s[ERROR]%s %s\n'  "${C_RED:-}"    "${C_RESET:-}" "$*" >&2; }
  fi
  if ! declare -F log_debug >/dev/null 2>&1; then
    log_debug()   { [[ "${DEBUG:-false}" == "true" ]] || return 0
                    printf '%s[DEBUG]%s %s\n' "${C_YELLOW:-}" "${C_RESET:-}" "$*" >&2; }
  fi
  if ! declare -F die >/dev/null 2>&1; then
    die() { log_error "$1"; exit "${2:-1}"; }
  fi
  if ! declare -F require_command >/dev/null 2>&1; then
    require_command() { command -v "$1" >/dev/null 2>&1 || die "コマンドが見つかりません: $1" "$EX_NODEP"; }
  fi
  if ! declare -F confirm >/dev/null 2>&1; then
    confirm() {
      local reply
      read -r -p "${1:-続行しますか?} [y/N]: " reply || return 1
      case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
    }
  fi
}

# ===========================================================================
# 2. 既定値（優先順位: コマンドライン > 環境変数 > ここでの既定）
# ===========================================================================
LOG_GROUPS=()                       # --log-group（複数可 / カンマ区切り可）
LOG_GROUP=""                        # 現在処理中のロググループ（ループ内で設定される）
LOG_GROUP_PREFIX=""
LOG_STREAM=""
LOG_STREAM_PREFIX=""
SELECT_LOG_STREAM="false"

START_STR=""
END_STR=""
LAST_MINUTES=""
DEFAULT_LAST_MINUTES="${CLOUDWATCH_LOG_DEFAULT_LAST_MINUTES:-10}"
readonly MAX_LAST_MINUTES=10080     # 直近 N 分の運用上の上限（7 日 = 10080 分）

FILTERS=()                          # --filter（複数可）
EXCLUDES=()                         # --exclude（複数可）
FILTER_MODE="literal"               # cloudwatch|literal|regex
FILTER_LOGIC="and"                  # and|or（複数 --filter 時）
IGNORE_CASE="false"
CW_PATTERN=""                       # cloudwatch モード時のサーバー側パターン

FOLLOW="false"
POLL_INTERVAL="${CLOUDWATCH_LOG_POLL_INTERVAL:-5}"
OVERLAP_SECONDS=5

SHOW_STREAM="false"
SHOW_INGEST="false"
SHOW_EVENT_TIME="false"             # CloudWatch のイベント時刻も表示する（text 形式時）
SHOW_GROUP=""                       # ""(自動)|true|false: 行ごとにロググループ名を出す
SINGLE_LINE="false"
OUTPUT="${CLOUDWATCH_LOG_OUTPUT:-text}"   # text|tsv|jsonl|none

EXCEL_FILE="${CLOUDWATCH_LOG_EXCEL:-}"    # --excel の出力先（空なら Excel 出力しない）
EXCEL_FORMAT=""                     # ""(拡張子から自動)|xlsx|xml
HIGHLIGHT="true"                    # JBoss EAP ログの色分け（--no-highlight で無効）

# 期間判定の基準時刻
#   message: ログ本文に出力されている時刻（既定。無い行はイベント時刻）
#   event  : CloudWatch のイベント時刻（従来動作）
TIME_SOURCE="${CLOUDWATCH_LOG_TIME_SOURCE:-message}"
# message のときに CloudWatch から前後に余分に取得する分数（本文時刻とのずれ対策）
TIME_MARGIN_MINUTES="${CLOUDWATCH_LOG_TIME_MARGIN:-5}"

# 生テキストログの出力（ロググループ × ログストリームごとに 1 ファイル）
RAW_DIR="${CLOUDWATCH_LOG_RAW_DIR:-}"     # 空かつ --excel 指定時は Excel と同じフォルダ
RAW_ENABLED=""                      # ""(自動)|true|false（--no-raw-text で false）
RAW_WITH_TIME="false"               # 各イベントの先頭へ時刻を付ける

MAX_EVENTS=10000
PAGE_LIMIT=1000

AWS_PROFILE_OPT=""
AWS_REGION_OPT=""

SWITCHBACK_MODE="${CLOUDWATCH_LOG_SWITCHBACK_MODE:-exit}"   # exit|auto
SWITCHBACK_SCRIPT="${CLOUDWATCH_LOG_SWITCHBACK_SCRIPT:-}"
SWITCHBACK_ARGS=()

NON_INTERACTIVE="false"
DRY_RUN="false"
NO_COLOR="${NO_COLOR:+true}"        # NO_COLOR 環境変数が空でなければ true
NO_COLOR="${NO_COLOR:-false}"
DEBUG="${DEBUG:-false}"

# --- 実行時に確定する内部変数 ---
START_MS=""            # 対象期間の開始（epoch ミリ秒。本文時刻での絞り込みに使う）
END_MS=""              # 対象期間の終了（epoch ミリ秒, 排他的境界）
FETCH_START_MS=""      # CloudWatch へ要求する取得開始（START_MS - マージン）
FETCH_END_MS=""        # CloudWatch へ要求する取得終了（END_MS + マージン）
ENGINE=""              # get|filter（使用する AWS API）
AWS_GLOBAL=()          # aws のグローバル引数（--profile/--region）
TMP_FILES=()           # trap で削除する一時ファイル
TMP_DIRS=()            # trap で削除する一時ディレクトリ（xlsx 組み立て用）
AWS_OUT=""             # run_aws の標準出力
AWS_ERR=""             # run_aws の標準エラー
FETCHED=0              # 直近フェッチで取得したイベント数
MATCHED=0              # フィルタ後に表示したイベント数
MAXTS=""               # 直近フェッチで観測した最大タイムスタンプ（follow の窓前進用）
SWITCHBACK_DONE="false"
declare -A SEEN=()     # follow モードの重複排除（key -> timestamp）

# --- 出力用の収集バッファ（ロググループ 1 件につき 1 シート / 1 組の生ログ） ---
COLLECT_BUF=""         # emit_events が追記する現在のバッファ（空なら収集しない）
COLLECT_MIN=""         # 現在のグループで出力した最古のログ時刻
COLLECT_MAX=""         # 現在のグループで出力した最新のログ時刻
GRP_NAMES=()           # シート化するロググループ名
GRP_FILES=()           # 対応する行バッファ（US 区切り・ログ時刻昇順）
GRP_FETCHED=()         # 取得件数（CloudWatch から受け取った件数）
GRP_MATCHED=()         # 出力件数（期間・フィルタを通過した件数）
GRP_OUTRANGE=()        # 本文時刻が対象期間外で除外した件数
GRP_MINTS=()           # 最古のログ時刻（該当なしなら空）
GRP_MAXTS=()           # 最新のログ時刻（該当なしなら空）
GRP_RAWFILES=()        # 出力した生テキストログのファイル数
# 区分（CAT_*）ごとの件数。CAT_N 個ずつ連結した 1 次元配列として保持する
#   （bash には多次元配列が無いため、グループ i の区分 c は GRP_CAT[i*CAT_N + c]）
GRP_CAT=()             # 色分けの区分ごと（エラー・警告の件数はこちら）
GRP_KIND=()            # JBoss の観点の区分ごと（デプロイ・起動の件数はこちら。
                       #  デプロイ失敗は色が赤でもデプロイとして数える）

# 現在のグループを処理中に数える区分ごとの件数
CUR_CAT=()
CUR_KIND=()

# ===========================================================================
# 3. 使い方 / ヘルプ
# ===========================================================================
usage() {
  cat >&2 <<USAGE
${SCRIPT_NAME} ${VERSION}

概要:
  AWS CloudWatch Logs のログを「JST の出力時刻 | メッセージ」の形式で表示します。
  期間指定表示・直近 N 分・フィルタ・tail -f 相当の監視に対応します。
  ロググループは複数指定でき、複数を横断して検索・出力できます。
  画面にはロググループごとに区切って表示します。
  --excel を付けると、次のファイルを作成します。
    ・Excel ブック（ロググループごとにシートを分割 / フォントは Meiryo UI /
      JBoss EAP のログは区分ごとに色分け / 「主要イベント」シートを併設）
    ・生テキストログ（ロググループ × ログストリームごとに 1 ファイル。
      Excel と同じフォルダへ出力。--no-raw-text で抑止、--raw-dir で変更可）
  期間の判定は既定で「ログ本文に出力されている時刻」を基準に行います。

使用形式:
  ${SCRIPT_NAME} [オプション]

ロググループ / ストリーム:
  -g, --log-group NAME       ロググループ名を直接指定する
                             複数指定可（-g A -g B）。カンマ区切りでもまとめて指定できる
                             （-g "A,B"）。指定順に画面表示・シート作成を行う。
                             省略時は一覧から複数選択できる（1 3,5 7-9 / a=全件）
      --log-group-prefix P   一覧表示するロググループをプレフィックスで絞り込む
  -s, --log-stream NAME      特定のログストリームを指定する（get-log-events を使用）
                             ※ ロググループを 1 件だけ指定しているときのみ使用可
      --log-stream-prefix P  対象ログストリームをプレフィックスで絞り込む
      --select-log-stream    ログストリームを一覧表示し番号で選択する
                             ※ ロググループを 1 件だけ指定しているときのみ使用可

期間指定（すべて JST として解釈）:
      --start "YYYY-MM-DD HH:MM[:SS]"   取得開始日時（ISO8601 +09:00 形式も可）
      --end   "YYYY-MM-DD HH:MM[:SS]"   取得終了日時（秒単位で inclusive）
  -m, --last-minutes N       現在時刻から直近 N 分を取得（1〜${MAX_LAST_MINUTES}）
                             ※ --start / --end との併用は不可（単独指定）
      （いずれも未指定なら既定で直近 ${DEFAULT_LAST_MINUTES} 分を表示）
      --time-source SRC      期間判定に使う時刻（既定: ${TIME_SOURCE}）
                             message: ログ本文の先頭に出力されている時刻を使う
                                      （本文に時刻が無い行はイベント時刻で判定）
                             event  : CloudWatch のイベント時刻を使う（従来動作）
      --time-margin-minutes N  message のときに CloudWatch から前後 N 分ぶん
                             余分に取得する（既定: ${TIME_MARGIN_MINUTES}）。本文時刻と
                             イベント時刻のずれが大きい場合は増やしてください。

  認識できるログ本文の時刻（先頭 72 文字以内の最初の 1 つ。JST として解釈）:
      2026-07-31 09:15:23,456 / 2026-07-31T09:15:23.456+09:00 / 2026/07/31 09:15:23
      09:15:23,456（日付なし。JBoss EAP 既定形式。日付はイベント時刻から補う）

フィルタ:
  -f, --filter PATTERN       表示するログの条件（複数指定可）
      --exclude PATTERN      除外する条件（複数指定可・いずれかに一致で除外）
      --filter-mode MODE     cloudwatch | literal | regex （既定: ${FILTER_MODE}）
      --filter-logic LOGIC   and | or （複数 --filter 時。既定: ${FILTER_LOGIC}）
  -i, --ignore-case          ローカルフィルタで大文字小文字を区別しない

監視（tail -f 相当・ポーリング方式）:
  -F, --follow               リアルタイム監視を有効にする（--end との併用は不可）
      --poll-interval SEC    ポーリング間隔秒（既定: ${POLL_INTERVAL}）
      --overlap-seconds SEC  遅延到着イベント対策の重複取得期間（既定: ${OVERLAP_SECONDS}）

表示 / 出力:
      --show-log-stream      ログストリーム名も表示する（text 形式時）
      --show-log-group       各行にロググループ名も表示する
                             （既定: ロググループが複数のとき tsv/監視モードで自動的に有効）
      --show-event-time      CloudWatch のイベント時刻も表示する（text 形式時）
                             ※ 行頭の時刻はログ本文に出力されている時刻です
      --show-ingestion-time  取り込み時刻も表示する（text 形式時）
      --single-line          複数行メッセージを 1 行へ変換する（改行を \\n 表示）
      --output FORMAT        text | tsv | jsonl | none （既定: ${OUTPUT}）
                             none は画面へイベントを出力しない（--excel と併用する）
      --max-events N         最大表示イベント数（既定: ${MAX_EVENTS}）
                             ※ ロググループ 1 件あたりの上限として適用されます
      --page-limit N         AWS API 1 回あたりの取得件数（既定: ${PAGE_LIMIT}, 最大 10000）

Excel 出力（ロググループごとにシートを分ける）:
      --excel FILE           Excel ファイルへ出力する（画面表示と併用可）
                             シート構成: サマリ / 主要イベント / ロググループごとに 1 シート
                             フォントは Meiryo UI。行はログの区分ごとに色分けされます
      --excel-format FORMAT  xlsx | xml （既定: FILE の拡張子から自動判定。既定は xlsx）
                             xlsx: 通常の Excel ブック（zip コマンドが必要）
                             xml : SpreadsheetML 2003 形式（zip 不要。Excel で開ける）
      --no-highlight         区分ごとの色分けを行わない（白地のまま出力する）
      ※ --follow との併用はできません（監視は終了しないためファイルを確定できません）

  色分けの区分（JBoss EAP のメッセージコードと出力レベルから判定）:
      デプロイ    緑  WFLYSRV0027/0010/0016, WFLYUT0021, JBAS015876/018559 など
                      （アプリケーションの配備。サーバー起動とは別の観点として区別）
      アンデプロイ橙  WFLYSRV0009/0028, WFLYUT0022, JBAS018558 など
      起動        青  WFLYSRV0049/0025/0026, JBAS015874/015899 など（EAP 本体の起動）
      停止        紫  WFLYSRV0050/0211/0220, JBAS015950 など
      エラー      赤  ERROR / FATAL / SEVERE       警告  黄  WARN
      デバッグ    灰  DEBUG / TRACE                その他  白  INFO 等

生テキストログ出力（--excel 指定時は既定で有効）:
      --raw-dir DIR          生テキストログの出力先（既定: --excel と同じフォルダ）
                             --excel を使わずにこのオプションだけでも出力できます
      --no-raw-text          生テキストログを出力しない
      --raw-with-time        各イベントの先頭に "[時刻(JST)] " を付ける
                             （既定はメッセージ本文をそのまま書き出す）
      ファイル名: NN_ロググループ名_ログストリーム名.log（短縮・NN は通し番号）
                  同じフォルダに 00_index.txt（対応表）も作成します

AWS 接続:
      --profile PROFILE      AWS CLI プロファイル
      --region REGION        AWS リージョン

権限不足時のスイッチバック:
      --switchback-mode M    exit | auto （既定: ${SWITCHBACK_MODE} = 安全側）
      --switchback-script F  auto 時に source する専用シェル
      --switchback-arg V     専用シェルへ渡す引数（複数指定可）

その他:
      --common-sh FILE       参照する common.sh を指定する
      --non-interactive      対話的な番号選択を禁止する
      --dry-run              AWS 参照やスイッチバックを行わず予定内容だけ表示する
      --no-color             色付き表示を無効化する
      --debug                デバッグ情報を標準エラーへ表示（秘密情報は出力しない）
  -h, --help                 このヘルプを表示する
      --version              バージョンを表示する

環境変数（コマンドラインオプションが優先）:
  AWS_PROFILE / AWS_REGION / AWS_DEFAULT_REGION
  CLOUDWATCH_LOG_COMMON_SH             common.sh のパス
  CLOUDWATCH_LOG_SWITCHBACK_MODE       exit|auto
  CLOUDWATCH_LOG_SWITCHBACK_SCRIPT     スイッチバック用シェルのパス
  CLOUDWATCH_LOG_DEFAULT_LAST_MINUTES  既定の直近分数
  CLOUDWATCH_LOG_POLL_INTERVAL         ポーリング間隔秒
  CLOUDWATCH_LOG_OUTPUT                text|tsv|jsonl|none
  CLOUDWATCH_LOG_EXCEL                 Excel 出力先ファイル（--excel 相当）
  CLOUDWATCH_LOG_TIME_SOURCE           message|event（--time-source 相当）
  CLOUDWATCH_LOG_TIME_MARGIN           取得マージン分数（--time-margin-minutes 相当）
  CLOUDWATCH_LOG_RAW_DIR               生テキストログの出力先（--raw-dir 相当）

フィルタの違い（重要）:
  --filter-mode cloudwatch : CloudWatch Logs のフィルタパターンとしてサーバー側で
                             絞り込む（例: '?ERROR ?WARN', '{ \$.level = "ERROR" }'）。
                             大文字小文字は区別され、--ignore-case は無効。--filter は 1 つのみ。
  --filter-mode literal    : 取得後にローカルで「固定文字列」として部分一致検索する。
  --filter-mode regex      : 取得後にローカルで「拡張正規表現(ERE)」として検索する。
  ※ --exclude は常にローカル（いずれかに一致した行を除外）で適用されます。

終了コード:
  0 正常 / 2 引数エラー / 3 コマンド不足 / 4 未認証・期限切れ / 5 権限不足
  6 リソース未検出 / 7 API・通信エラー / 8 スイッチバック失敗 / 9 日時指定エラー
  10 Excel 書き出しエラー / 130 Ctrl+C 中断

認証 / 権限不足時の対応:
  - 実行前に必ず 'aws login --remote' 等で認証しておいてください（自動ログインしません）。
  - CloudWatch Logs 権限が無い場合、--switchback-mode exit なら案内して終了、
    auto なら --switchback-script を source して切り替え、認証・権限を再確認します。

実行例:
  # 一覧から選択し直近 10 分
  ./${SCRIPT_NAME} --last-minutes 10

  # ロググループ直接指定で直近 60 分
  ./${SCRIPT_NAME} --log-group /aws/lambda/example --last-minutes 60

  # JST 期間指定
  ./${SCRIPT_NAME} --log-group /aws/lambda/example \\
    --start "2026-07-12 09:00:00" --end "2026-07-12 10:00:00"

  # ERROR を含む行だけ（固定文字列）
  ./${SCRIPT_NAME} --log-group /aws/lambda/example --last-minutes 30 \\
    --filter ERROR --filter-mode literal

  # 直近 5 分から ERROR のみ監視
  ./${SCRIPT_NAME} --log-group /aws/lambda/example --last-minutes 5 \\
    --follow --filter ERROR --filter-mode literal

  # JSON Lines で出力
  ./${SCRIPT_NAME} --log-group /aws/lambda/example --last-minutes 10 --output jsonl

  # 複数ロググループを直近 30 分ぶん、グループごとに区切って画面表示
  ./${SCRIPT_NAME} --last-minutes 30 \\
    -g /aws/lambda/api -g /aws/lambda/batch -g /aws/ecs/worker

  # カンマ区切りでまとめて指定（上と同じ）
  ./${SCRIPT_NAME} --last-minutes 30 -g "/aws/lambda/api,/aws/lambda/batch,/aws/ecs/worker"

  # 一覧から複数選択（番号は 1 3,5 7-9 / a=全件 の形式で入力）
  ./${SCRIPT_NAME} --last-minutes 30

  # 複数ロググループを、シートを分けて Excel へ出力（画面にも表示）
  # 生テキストログ（ストリームごと）と 00_index.txt も同じフォルダへ出力される
  ./${SCRIPT_NAME} --start "2026-07-12 09:00" --end "2026-07-12 18:00" \\
    -g /aws/lambda/api -g /aws/lambda/batch --excel /tmp/logs.xlsx

  # JBoss EAP の 2 系統を横断し、本文時刻で 09:00〜10:00 を切り出して Excel 化
  ./${SCRIPT_NAME} --start "2026-07-12 09:00:00" --end "2026-07-12 10:00:00" \\
    -g "/jboss/eap/server,/jboss/eap/console" --output none --excel ./eap.xlsx

  # 画面表示は行わず Excel だけ作る（ERROR 行のみ・生テキストログは作らない）
  ./${SCRIPT_NAME} --last-minutes 120 -g "/aws/lambda/api,/aws/lambda/batch" \\
    --filter ERROR --output none --excel ./error_logs.xlsx --no-raw-text

  # 生テキストログだけをフォルダへ書き出す（Excel は作らない）
  ./${SCRIPT_NAME} --last-minutes 60 -g /jboss/eap/server \\
    --output none --raw-dir ./logs

  # イベント時刻で期間を判定する（従来動作に戻す）
  ./${SCRIPT_NAME} --last-minutes 60 -g /aws/lambda/api --time-source event

  # zip コマンドが無い環境では SpreadsheetML 形式で出力する
  ./${SCRIPT_NAME} --last-minutes 60 -g /aws/lambda/api --excel ./logs.xml
USAGE
}

# ===========================================================================
# 4. 引数解析（Bash のみで堅牢に解析。GNU getopt には依存しない）
# ===========================================================================
# 引数を必要とするオプションで値が無い場合のエラー
need_val() {
  [[ $# -ge 2 && -n "${2:-}" ]] || die "オプション ${1} には値が必要です。" "$EX_USAGE"
}

# --log-group の値を LOG_GROUPS へ追加する。
#   カンマ区切りで複数まとめて指定できる。CloudWatch Logs のロググループ名に
#   使える文字は [.\-_/#A-Za-z0-9] でカンマを含まないため、区切り文字として安全。
#   read -a を使うのは、単語分割時にグロブ展開（* 等）を起こさないため。
add_log_groups() {
  local spec="$1" g parts=()
  IFS=',' read -r -a parts <<< "$spec"
  for g in ${parts[@]+"${parts[@]}"}; do
    g="${g#"${g%%[![:space:]]*}"}"      # 前方の空白を除去
    g="${g%"${g##*[![:space:]]}"}"      # 後方の空白を除去
    [[ -n "$g" ]] && LOG_GROUPS+=("$g")
  done
  return 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -g|--log-group)        need_val "$1" "${2:-}"; add_log_groups "$2"; shift 2 ;;
      --log-group-prefix)    need_val "$1" "${2:-}"; LOG_GROUP_PREFIX="$2"; shift 2 ;;
      -s|--log-stream)       need_val "$1" "${2:-}"; LOG_STREAM="$2"; shift 2 ;;
      --log-stream-prefix)   need_val "$1" "${2:-}"; LOG_STREAM_PREFIX="$2"; shift 2 ;;
      --select-log-stream)   SELECT_LOG_STREAM="true"; shift ;;
      --start)               need_val "$1" "${2:-}"; START_STR="$2"; shift 2 ;;
      --end)                 need_val "$1" "${2:-}"; END_STR="$2"; shift 2 ;;
      -m|--last-minutes)     need_val "$1" "${2:-}"; LAST_MINUTES="$2"; shift 2 ;;
      --time-source)         need_val "$1" "${2:-}"; TIME_SOURCE="$2"; shift 2 ;;
      --time-margin-minutes) need_val "$1" "${2:-}"; TIME_MARGIN_MINUTES="$2"; shift 2 ;;
      -f|--filter)           need_val "$1" "${2:-}"; FILTERS+=("$2"); shift 2 ;;
      --exclude)             need_val "$1" "${2:-}"; EXCLUDES+=("$2"); shift 2 ;;
      --filter-mode)         need_val "$1" "${2:-}"; FILTER_MODE="$2"; shift 2 ;;
      --filter-logic)        need_val "$1" "${2:-}"; FILTER_LOGIC="$2"; shift 2 ;;
      -i|--ignore-case)      IGNORE_CASE="true"; shift ;;
      -F|--follow)           FOLLOW="true"; shift ;;
      --poll-interval)       need_val "$1" "${2:-}"; POLL_INTERVAL="$2"; shift 2 ;;
      --overlap-seconds)     need_val "$1" "${2:-}"; OVERLAP_SECONDS="$2"; shift 2 ;;
      --show-log-stream)     SHOW_STREAM="true"; shift ;;
      --show-log-group)      SHOW_GROUP="true"; shift ;;
      --show-ingestion-time) SHOW_INGEST="true"; shift ;;
      --show-event-time)     SHOW_EVENT_TIME="true"; shift ;;
      --single-line)         SINGLE_LINE="true"; shift ;;
      --output)              need_val "$1" "${2:-}"; OUTPUT="$2"; shift 2 ;;
      --excel)               need_val "$1" "${2:-}"; EXCEL_FILE="$2"; shift 2 ;;
      --excel-format)        need_val "$1" "${2:-}"; EXCEL_FORMAT="$2"; shift 2 ;;
      --no-highlight)        HIGHLIGHT="false"; shift ;;
      --raw-dir)             need_val "$1" "${2:-}"; RAW_DIR="$2"; shift 2 ;;
      --no-raw-text)         RAW_ENABLED="false"; shift ;;
      --raw-with-time)       RAW_WITH_TIME="true"; shift ;;
      --max-events)          need_val "$1" "${2:-}"; MAX_EVENTS="$2"; shift 2 ;;
      --page-limit)          need_val "$1" "${2:-}"; PAGE_LIMIT="$2"; shift 2 ;;
      --profile)             need_val "$1" "${2:-}"; AWS_PROFILE_OPT="$2"; shift 2 ;;
      --region)              need_val "$1" "${2:-}"; AWS_REGION_OPT="$2"; shift 2 ;;
      --switchback-mode)     need_val "$1" "${2:-}"; SWITCHBACK_MODE="$2"; shift 2 ;;
      --switchback-script)   need_val "$1" "${2:-}"; SWITCHBACK_SCRIPT="$2"; shift 2 ;;
      --switchback-arg)      need_val "$1" "${2:-}"; SWITCHBACK_ARGS+=("$2"); shift 2 ;;
      --common-sh)           need_val "$1" "${2:-}"; COMMON_SH="$2"; shift 2 ;;
      --non-interactive)     NON_INTERACTIVE="true"; shift ;;
      --dry-run)             DRY_RUN="true"; shift ;;
      --no-color)            NO_COLOR="true"; shift ;;
      --debug)               DEBUG="true"; shift ;;
      -h|--help)             usage; exit "$EX_OK" ;;
      --version)             printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit "$EX_OK" ;;
      --)                    shift; break ;;
      -*)                    usage; die "不明なオプションです: $1" "$EX_USAGE" ;;
      *)                     usage; die "余分な引数です: $1" "$EX_USAGE" ;;
    esac
  done
  export DEBUG
}

# ===========================================================================
# 5. 色設定（TTY かつ --no-color/NO_COLOR でない場合のみ有効）
# ===========================================================================
setup_colors() {
  if [[ -t 2 && "$NO_COLOR" != "true" ]]; then
    C_RESET="$(printf '\033[0m')"; C_RED="$(printf '\033[31m')"
    C_GREEN="$(printf '\033[32m')"; C_YELLOW="$(printf '\033[33m')"
    C_BLUE="$(printf '\033[34m')"
  else
    C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
  fi
  # ロググループの見出しは標準出力へ出すため、標準出力側の端末判定で色を決める
  #   （ファイルへリダイレクトしたときにエスケープシーケンスを混ぜないため）
  if [[ -t 1 && "$NO_COLOR" != "true" ]]; then
    HDR_C="$(printf '\033[36m')"; HDR_R="$(printf '\033[0m')"
  else
    HDR_C="" HDR_R=""
  fi
}

# ===========================================================================
# 6. 入力値の検証と正規化
# ===========================================================================
is_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }   # 正の整数
is_uint0(){ [[ "$1" =~ ^[0-9]+$ ]]; }        # 0 以上の整数

# ERE として妥当か（grep は不一致=1, 不正な正規表現=2 を返す）
regex_valid() { printf '' | grep -qE -- "$1" 2>/dev/null; [[ $? -le 1 ]]; }

# LOG_GROUPS から重複を取り除く（指定順は保持する）。
#   同じロググループを 2 回表示したり、同名シートを 2 枚作ったりしないため。
dedupe_log_groups() {
  (( ${#LOG_GROUPS[@]} )) || return 0
  local -A seen=()
  local g out=()
  for g in "${LOG_GROUPS[@]}"; do
    if [[ -n "${seen[$g]:-}" ]]; then
      log_warn "ロググループの指定が重複しています（2 回目以降は無視します）: ${g}"
      continue
    fi
    seen[$g]=1
    out+=("$g")
  done
  LOG_GROUPS=("${out[@]}")
  return 0
}

# --excel / --excel-format / --raw-dir の検証と正規化（AWS へアクセスする前に済ませる）
validate_output_options() {
  validate_excel_options
  validate_raw_options
  # 画面にもファイルにも出さない指定は、実行しても結果が残らないため誤りとみなす
  if [[ "$OUTPUT" == "none" && -z "$EXCEL_FILE" && "$RAW_ENABLED" != "true" ]]; then
    die "--output none は --excel または --raw-dir と併せて指定してください（出力先がありません）。" "$EX_USAGE"
  fi
  return 0
}

validate_excel_options() {
  if [[ -z "$EXCEL_FILE" ]]; then
    [[ -n "$EXCEL_FORMAT" ]] && die "--excel-format は --excel と併せて指定してください。" "$EX_USAGE"
    return 0
  fi

  # 監視モードは終了しないためファイルを確定できない
  [[ "$FOLLOW" == "true" ]] && die "--excel と --follow は同時に指定できません（監視は終了しないためファイルを確定できません）。" "$EX_USAGE"

  # 形式の決定: 明示指定 > 拡張子からの推定 > xlsx
  if [[ -z "$EXCEL_FORMAT" ]]; then
    case "${EXCEL_FILE,,}" in
      *.xml)  EXCEL_FORMAT="xml" ;;
      *.xlsx) EXCEL_FORMAT="xlsx" ;;
      *)      EXCEL_FORMAT="xlsx"
              log_warn "--excel の拡張子から形式を判定できないため xlsx として出力します: ${EXCEL_FILE}" ;;
    esac
  fi
  case "$EXCEL_FORMAT" in
    xlsx|xml) ;;
    *) die "--excel-format は xlsx|xml のいずれかです: $EXCEL_FORMAT" "$EX_USAGE" ;;
  esac

  # 出力先の妥当性を先に確認する（長いログ取得のあとで失敗させないため）
  [[ -d "$EXCEL_FILE" ]] && die "--excel の指定がディレクトリです。ファイル名を指定してください: ${EXCEL_FILE}" "$EX_OUTPUT"
  local dir; dir="$(dirname -- "$EXCEL_FILE")"
  [[ -d "$dir" ]] || die "--excel の出力先ディレクトリがありません: ${dir}" "$EX_OUTPUT"
  [[ -w "$dir" ]] || die "--excel の出力先ディレクトリに書き込めません: ${dir}" "$EX_OUTPUT"
  if [[ -e "$EXCEL_FILE" ]]; then
    [[ -f "$EXCEL_FILE" ]] || die "--excel の指定が通常ファイルではありません: ${EXCEL_FILE}" "$EX_OUTPUT"
    [[ -w "$EXCEL_FILE" ]] || die "--excel の出力先ファイルに書き込めません: ${EXCEL_FILE}" "$EX_OUTPUT"
    if [[ "$NON_INTERACTIVE" != "true" && "$DRY_RUN" != "true" && -t 0 ]]; then
      confirm "既存のファイル '${EXCEL_FILE}' を上書きします。よろしいですか?" \
        || die "中止しました（--excel の出力先を変更して再実行してください）。" "$EX_OUTPUT"
    else
      log_warn "既存のファイルを上書きします: ${EXCEL_FILE}"
    fi
  fi
  return 0
}

# 生テキストログ出力の有効・無効と出力先を確定する。
#   --no-raw-text    -> 常に無効
#   --raw-dir 指定   -> そのディレクトリへ出力（--excel が無くても出力する）
#   --excel のみ指定 -> Excel と同じフォルダへ出力（既定）
validate_raw_options() {
  if [[ "$RAW_ENABLED" == "false" ]]; then
    [[ -n "$RAW_DIR" ]] && die "--raw-dir と --no-raw-text は同時に指定できません。" "$EX_USAGE"
    [[ "$RAW_WITH_TIME" == "true" ]] && log_warn "--no-raw-text が指定されているため --raw-with-time は無視されます。"
    RAW_DIR=""
    return 0
  fi

  if [[ -z "$RAW_DIR" ]]; then
    if [[ -z "$EXCEL_FILE" ]]; then
      # 出力先が決まらないため生テキストログは作らない（従来どおりの動作）
      RAW_ENABLED="false"
      [[ "$RAW_WITH_TIME" == "true" ]] && log_warn "--raw-with-time は --excel か --raw-dir と併せて指定してください（無視します）。"
      return 0
    fi
    RAW_DIR="$(dirname -- "$EXCEL_FILE")"   # Excel と同じフォルダ
  fi
  RAW_ENABLED="true"

  [[ "$FOLLOW" == "true" ]] && die "生テキストログの出力と --follow は同時に指定できません（監視は終了しないためファイルを確定できません）。" "$EX_USAGE"

  if [[ ! -e "$RAW_DIR" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      return 0   # dry-run では作らない（副作用を起こさない）
    fi
    mkdir -p -- "$RAW_DIR" || die "生テキストログの出力先ディレクトリを作成できません: ${RAW_DIR}" "$EX_OUTPUT"
    log_info "生テキストログの出力先ディレクトリを作成しました: ${RAW_DIR}"
  fi
  [[ -d "$RAW_DIR" ]] || die "生テキストログの出力先がディレクトリではありません: ${RAW_DIR}" "$EX_OUTPUT"
  [[ -w "$RAW_DIR" ]] || die "生テキストログの出力先ディレクトリに書き込めません: ${RAW_DIR}" "$EX_OUTPUT"
  return 0
}

validate_inputs() {
  # --- 出力形式 ---
  case "$OUTPUT" in text|tsv|jsonl|none) ;; *) die "--output は text|tsv|jsonl|none のいずれかです: $OUTPUT" "$EX_USAGE" ;; esac
  # --- フィルタモード / ロジック ---
  case "$FILTER_MODE" in cloudwatch|literal|regex) ;; *) die "--filter-mode は cloudwatch|literal|regex です: $FILTER_MODE" "$EX_USAGE" ;; esac
  case "$FILTER_LOGIC" in and|or) ;; *) die "--filter-logic は and|or です: $FILTER_LOGIC" "$EX_USAGE" ;; esac
  # --- スイッチバックモード ---
  case "$SWITCHBACK_MODE" in exit|auto) ;; *) die "--switchback-mode は exit|auto です: $SWITCHBACK_MODE" "$EX_USAGE" ;; esac
  # --- 期間判定の基準時刻 ---
  case "$TIME_SOURCE" in message|event) ;; *) die "--time-source は message|event です: $TIME_SOURCE" "$EX_USAGE" ;; esac
  is_uint0 "$TIME_MARGIN_MINUTES" || die "--time-margin-minutes は 0 以上の整数で指定してください: $TIME_MARGIN_MINUTES" "$EX_USAGE"
  (( TIME_MARGIN_MINUTES > 1440 )) && die "--time-margin-minutes が大きすぎます（最大 1440 分）: $TIME_MARGIN_MINUTES" "$EX_USAGE"

  # --- 数値系 ---
  is_uint "$MAX_EVENTS"  || die "--max-events は正の整数で指定してください: $MAX_EVENTS" "$EX_USAGE"
  is_uint "$PAGE_LIMIT"  || die "--page-limit は正の整数で指定してください: $PAGE_LIMIT" "$EX_USAGE"
  (( PAGE_LIMIT > 10000 )) && { log_warn "--page-limit は最大 10000 です。10000 に丸めます。"; PAGE_LIMIT=10000; }
  is_uint "$POLL_INTERVAL"    || die "--poll-interval は正の整数で指定してください: $POLL_INTERVAL" "$EX_USAGE"
  is_uint0 "$OVERLAP_SECONDS" || die "--overlap-seconds は 0 以上の整数で指定してください: $OVERLAP_SECONDS" "$EX_USAGE"

  # --- 期間指定の整合性 ---
  if [[ -n "$LAST_MINUTES" ]]; then
    is_uint "$LAST_MINUTES" || die "--last-minutes は正の整数で指定してください: $LAST_MINUTES" "$EX_TIME"
    (( LAST_MINUTES > MAX_LAST_MINUTES )) && die "--last-minutes が上限（${MAX_LAST_MINUTES} 分）を超えています: $LAST_MINUTES" "$EX_TIME"
    [[ -n "$START_STR" || -n "$END_STR" ]] && die "--last-minutes は --start / --end と同時に指定できません（単独で指定してください）。" "$EX_TIME"
  fi
  # --- follow の制約（--end との併用禁止。end-alone 判定より先に評価する）---
  if [[ "$FOLLOW" == "true" && -n "$END_STR" ]]; then
    die "--follow と --end は同時に指定できません（監視は終了時刻を持ちません）。" "$EX_USAGE"
  fi

  # --end のみ指定は範囲が曖昧なためエラー（--start か --last-minutes を併用する）
  if [[ -z "$LAST_MINUTES" && -z "$START_STR" && -n "$END_STR" ]]; then
    die "--end だけの指定はできません。--start と併用するか --last-minutes を使ってください。" "$EX_TIME"
  fi

  # --- ロググループ指定の整合性（重複は指定順を保って除去する）---
  dedupe_log_groups

  # --- ログストリーム指定の整合性 ---
  #     ログストリームはロググループに属するため、複数グループとは併用できない。
  if [[ -n "$LOG_STREAM" && ${#LOG_GROUPS[@]} -eq 0 ]]; then
    die "--log-stream を使う場合は --log-group も指定してください。" "$EX_USAGE"
  fi
  if [[ -n "$LOG_STREAM" && ${#LOG_GROUPS[@]} -gt 1 ]]; then
    die "--log-stream は --log-group を 1 件だけ指定したときにのみ使用できます（現在 ${#LOG_GROUPS[@]} 件）。" "$EX_USAGE"
  fi
  if [[ -n "$LOG_STREAM" && -n "$LOG_STREAM_PREFIX" ]]; then
    die "--log-stream と --log-stream-prefix は同時に指定できません。" "$EX_USAGE"
  fi
  if [[ "$SELECT_LOG_STREAM" == "true" && ${#LOG_GROUPS[@]} -gt 1 ]]; then
    die "--select-log-stream は --log-group を 1 件だけ指定したときにのみ使用できます（現在 ${#LOG_GROUPS[@]} 件）。" "$EX_USAGE"
  fi

  # --- 非対話モードでロググループ未指定はエラー ---
  if [[ "$NON_INTERACTIVE" == "true" && ${#LOG_GROUPS[@]} -eq 0 ]]; then
    die "--non-interactive では --log-group の指定が必須です（一覧選択は行いません）。" "$EX_USAGE"
  fi

  # --- Excel / 生テキストログ出力の検証 ---
  validate_output_options

  # --- フィルタの検証 ---
  if [[ "$FILTER_MODE" == "regex" ]]; then
    local p
    for p in ${FILTERS[@]+"${FILTERS[@]}"} ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
      regex_valid "$p" || die "正規表現が不正です: $p" "$EX_USAGE"
    done
  fi
  if [[ "$FILTER_MODE" == "cloudwatch" ]]; then
    (( ${#FILTERS[@]} > 1 )) && die "--filter-mode cloudwatch では --filter は 1 つだけ指定できます。" "$EX_USAGE"
    (( ${#FILTERS[@]} == 1 )) && CW_PATTERN="${FILTERS[0]}"
    [[ "$IGNORE_CASE" == "true" ]] && log_warn "cloudwatch モードでは --ignore-case は無効です（サーバー側パターンは大文字小文字を区別します）。"
  fi
  return 0   # 直前の条件式が偽でも set -e で落ちないよう明示的に成功を返す
}

# 使用する AWS API（エンジン）を決定する。
#   cloudwatch フィルタが必要 -> filter-log-events（サーバー側フィルタ可能）
#   単一ストリーム指定        -> get-log-events
#   それ以外（全/複数横断）    -> filter-log-events
resolve_engine() {
  if [[ -n "$CW_PATTERN" ]]; then
    ENGINE="filter"
  elif [[ -n "$LOG_STREAM" ]]; then
    ENGINE="get"
  else
    ENGINE="filter"
  fi
  log_debug "使用エンジン: ${ENGINE}（cloudwatch=${CW_PATTERN:+yes}）"
}

# 各行にロググループ名を出すかどうかを決める（LOG_GROUPS 確定後に呼ぶ）。
#   --show-log-group を明示した場合は常に有効。
#   自動判定では、ロググループが複数あり、かつ行だけを見て区別が付かない
#   ケース（tsv の列 / 監視モードは複数グループの出力が時系列で混ざる）で有効にする。
#   text の通常取得はロググループごとの見出しで区切るため行頭には出さない。
resolve_show_group() {
  [[ "$SHOW_GROUP" == "true" ]] && return 0
  SHOW_GROUP="false"
  (( ${#LOG_GROUPS[@]} > 1 )) || return 0
  if [[ "$OUTPUT" == "tsv" || "$FOLLOW" == "true" ]]; then
    SHOW_GROUP="true"
  fi
  return 0
}

# ===========================================================================
# 7. 一時ファイルとシグナル処理
# ===========================================================================
cleanup() {
  local f d
  for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do
    [[ -n "$f" && -f "$f" ]] && rm -f "$f" 2>/dev/null || true
  done
  for d in ${TMP_DIRS[@]+"${TMP_DIRS[@]}"}; do
    # mktemp -d で作った自分専用のディレクトリのみを対象にする（誤削除防止）
    [[ -n "$d" && -d "$d" && "$d" == */cwlv.* ]] && rm -rf -- "$d" 2>/dev/null || true
  done
}
trap cleanup EXIT

on_signal() {
  # Ctrl+C / SIGTERM: スタックトレースを出さず分かりやすく終了する
  printf '\n' >&2
  log_info "中断しました。終了します。"
  exit "$EX_INT"
}
trap on_signal INT TERM

mktemp_tracked() {
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/cwlv.XXXXXX")" || die "一時ファイルの作成に失敗しました。" "$EX_API"
  TMP_FILES+=("$f")
  printf '%s' "$f"
}

mktempdir_tracked() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/cwlv.dir.XXXXXX")" || die "一時ディレクトリの作成に失敗しました。" "$EX_OUTPUT"
  TMP_DIRS+=("$d")
  printf '%s' "$d"
}

# ===========================================================================
# 8. 日時変換（すべて JST。GNU date と bash 組み込み printf を使用）
# ===========================================================================
# JST 日時文字列 -> epoch ミリ秒（TZ=Asia/Tokyo 固定のため naive 入力は JST 解釈）
jst_input_to_epoch_ms() {
  local in="$1" sec
  sec="$(date -d "$in" +%s 2>/dev/null)" || return 1
  [[ "$sec" =~ ^-?[0-9]+$ ]] || return 1
  printf '%s' "$(( sec * 1000 ))"
}

# epoch ミリ秒 -> "YYYY-MM-DD HH:MM:SS.mmm JST"
#   TZ=Asia/Tokyo を export 済みのため bash printf %()T で JST 表示になる。
#   イベント 1 件ごとに呼ばれる箇所では set_jst_str を直接使い、結果を JST_STR から
#   受け取ること（コマンド置換にするとイベント数ぶんの fork が発生して極端に遅くなる）。
JST_STR=""
set_jst_str() {
  local ms="$1" sec frac out
  sec=$(( ms / 1000 )); frac=$(( ms % 1000 ))
  printf -v out '%(%Y-%m-%d %H:%M:%S)T' "$sec"
  printf -v JST_STR '%s.%03d JST' "$out" "$frac"
}
epoch_ms_to_jst() { set_jst_str "$1"; printf '%s' "$JST_STR"; }

# 対象期間（START_MS / END_MS）と、CloudWatch へ要求する取得期間
# （FETCH_START_MS / FETCH_END_MS）を確定する。
#   --time-source message のときは、本文時刻とイベント時刻のずれを吸収するため
#   取得期間だけを前後へ TIME_MARGIN_MINUTES 分広げる。対象期間そのものは変えない
#   （画面表示・Excel の見出し・本文時刻での絞り込みはすべて対象期間を使う）。
resolve_time_range() {
  local now_s; now_s="$(date +%s)"
  if [[ -n "$LAST_MINUTES" ]]; then
    START_MS=$(( (now_s - LAST_MINUTES * 60) * 1000 ))
    END_MS=$(( (now_s + 1) * 1000 ))
  elif [[ -n "$START_STR" ]]; then
    START_MS="$(jst_input_to_epoch_ms "$START_STR")" \
      || die "開始日時の形式が不正です: $START_STR" "$EX_TIME"
    if [[ -n "$END_STR" ]]; then
      local e; e="$(date -d "$END_STR" +%s 2>/dev/null)" \
        || die "終了日時の形式が不正です: $END_STR" "$EX_TIME"
      END_MS=$(( (e + 1) * 1000 ))    # 指定秒を inclusive にするため +1 秒を排他境界にする
      if (( START_MS >= END_MS )); then
        die "開始日時が終了日時より後です。範囲を見直してください。" "$EX_TIME"
      fi
    else
      END_MS=$(( (now_s + 1) * 1000 ))
    fi
  else
    START_MS=$(( (now_s - DEFAULT_LAST_MINUTES * 60) * 1000 ))
    END_MS=$(( (now_s + 1) * 1000 ))
  fi

  local margin_ms=0
  [[ "$TIME_SOURCE" == "message" ]] && margin_ms=$(( TIME_MARGIN_MINUTES * 60000 ))
  FETCH_START_MS=$(( START_MS - margin_ms ))
  (( FETCH_START_MS < 0 )) && FETCH_START_MS=0
  FETCH_END_MS=$(( END_MS + margin_ms ))
  return 0
}

# ===========================================================================
# 8.5 ログ本文に出力されている時刻の解析
#   CloudWatch のイベント時刻は「AWS が受け取った時刻」であり、アプリケーションが
#   ログを書いた時刻とは数秒〜数分ずれることがある。期間で切り出す運用では本文の
#   時刻で判断したいため、本文の先頭にある時刻を取り出して使う。
#   注意: これらの関数はイベント 1 件ごとに呼ばれる。サブシェル（$(...)）や外部
#   コマンド（date）を使うと件数ぶんの fork が発生して極端に遅くなるため、
#   すべて bash の組み込み機能だけで計算し、結果はグローバル変数へ返す。
# ===========================================================================
# 1970-01-01 からの日数（Howard Hinnant の days_from_civil。グレゴリオ暦で厳密）
#   結果は _DAYS。うるう年・世紀の例外を含めて正しく、date への fork を避けられる。
_DAYS=0
days_from_civil() {
  # 10# を付けるのは "08" 等を 8 進数と解釈させないため（bash の算術式の仕様）
  local y=$(( 10#$1 )) m=$(( 10#$2 )) d=$(( 10#$3 )) yy era yoe doy doe
  yy=$(( m <= 2 ? y - 1 : y ))
  era=$(( (yy >= 0 ? yy : yy - 399) / 400 ))
  yoe=$(( yy - era * 400 ))
  doy=$(( (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1 ))
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  _DAYS=$(( era * 146097 + doe - 719468 ))
}

# 同じ日付の変換を繰り返さないためのキャッシュ（ログは同じ日付が連続するため効く）
declare -A _DAYS_CACHE=()
_days_cached() {
  local key="$1$2$3"
  _DAYS="${_DAYS_CACHE[$key]:-}"
  if [[ -z "$_DAYS" ]]; then
    days_from_civil "$1" "$2" "$3"
    _DAYS_CACHE[$key]="$_DAYS"
  fi
}

# 日時の各要素 + オフセット秒 -> epoch ミリ秒（結果は _EPOCH_MS）
_EPOCH_MS=0
parts_to_epoch_ms() {
  local y="$1" mo="$2" d="$3" hh="$4" mi="$5" ss="$6" ms="$7" off="$8"
  _days_cached "$y" "$mo" "$d"
  _EPOCH_MS=$(( (_DAYS * 86400 + 10#$hh * 3600 + 10#$mi * 60 + 10#$ss - off) * 1000 + ms ))
}

# "+09:00" / "+0900" / "Z" -> オフセット秒（結果は _TZ_OFF）。空文字なら JST とみなす。
_TZ_OFF=0
parse_tz_offset() {
  local z="$1"
  if [[ -z "$z" ]]; then _TZ_OFF=$JST_OFFSET_SECONDS; return 0; fi
  if [[ "$z" == [Zz] ]]; then _TZ_OFF=0; return 0; fi
  local sign="${z:0:1}" rest="${z:1}"
  rest="${rest/:/}"
  _TZ_OFF=$(( 10#${rest:0:2} * 3600 + 10#${rest:2:2} * 60 ))
  [[ "$sign" == "-" ]] && _TZ_OFF=$(( -_TZ_OFF ))
  return 0
}

# 小数部（"456" / "4" / "123456"）-> ミリ秒（結果は _FRAC_MS）
_FRAC_MS=0
frac_to_ms() {
  local f="${1}000"
  _FRAC_MS=$(( 10#${f:0:3} ))
}

# ログ本文から出力時刻を取り出す。
#   $1 = エスケープ済みメッセージ / $2 = CloudWatch のイベント時刻(ms)
#   結果: MSG_TS（epoch ミリ秒） / MSG_TS_FROM（log = 本文, event = イベント時刻）
#   本文に時刻が見つからない行（スタックトレースの続き等）はイベント時刻を使う。
MSG_TS=0
MSG_TS_FROM="event"
parse_msg_time() {
  local emsg="$1" ev="$2"
  local head="${emsg:0:72}"      # 時刻は行頭付近にあるため先頭だけを見る（高速化）
  local y mo d hh mi ss frac zone cand diff evparts

  if [[ "$head" =~ ([0-9]{4})[-/]([0-9]{1,2})[-/]([0-9]{1,2})[T\ ]([0-9]{1,2}):([0-9]{2}):([0-9]{2})([.,]([0-9]{1,9}))?(Z|z|[+-][0-9]{2}:?[0-9]{2})? ]]; then
    y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
    hh="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; ss="${BASH_REMATCH[6]}"
    frac="${BASH_REMATCH[8]}"; zone="${BASH_REMATCH[9]}"
    frac_to_ms "$frac"
    parse_tz_offset "$zone"
    parts_to_epoch_ms "$y" "$mo" "$d" "$hh" "$mi" "$ss" "$_FRAC_MS" "$_TZ_OFF"
    MSG_TS="$_EPOCH_MS"; MSG_TS_FROM="log"
    return 0
  fi

  # 日付なしの時刻（JBoss EAP 既定の %d{HH:mm:ss,SSS}）。
  #   行頭付近にあるものだけを対象にする（本文中の "12:34:56" を拾わないため）。
  if [[ "$head" =~ ^[^0-9]{0,4}([0-9]{2}):([0-9]{2}):([0-9]{2})([.,]([0-9]{1,9}))? ]]; then
    hh="${BASH_REMATCH[1]}"; mi="${BASH_REMATCH[2]}"; ss="${BASH_REMATCH[3]}"
    frac="${BASH_REMATCH[5]}"
    frac_to_ms "$frac"
    # 日付はイベント時刻（JST）から補う。TZ='JST-9' 固定のため %()T は JST になる。
    printf -v evparts '%(%Y %m %d)T' "$(( ev / 1000 ))"
    read -r y mo d <<< "$evparts"
    parts_to_epoch_ms "$y" "$mo" "$d" "$hh" "$mi" "$ss" "$_FRAC_MS" "$JST_OFFSET_SECONDS"
    cand="$_EPOCH_MS"
    # 日付の境界をまたぐ場合の補正（例: イベント 00:00:02 に対し本文 23:59:59）。
    #   ずれが 12 時間を超えるなら前日 / 翌日とみなす。
    diff=$(( cand - ev ))
    if (( diff > 43200000 )); then
      cand=$(( cand - 86400000 ))
    elif (( diff < -43200000 )); then
      cand=$(( cand + 86400000 ))
    fi
    MSG_TS="$cand"; MSG_TS_FROM="log"
    return 0
  fi

  MSG_TS="$ev"; MSG_TS_FROM="event"
  return 0
}

# ===========================================================================
# 8.6 ログの区分判定（JBoss EAP のメッセージコード + 出力レベル）
#   JBoss EAP のログは、サーバー本体の起動・停止と、アプリケーションのデプロイ
#   （配備）とで運用上の意味が異なる。両者を別の区分として扱い、Excel では
#   色と「区分」列で区別できるようにする。
# ===========================================================================
readonly CAT_INFO=0 CAT_ERROR=1 CAT_WARN=2 CAT_DEPLOY=3
readonly CAT_UNDEPLOY=4 CAT_START=5 CAT_STOP=6 CAT_DEBUG=7
readonly CAT_N=8

# 区分の表示名（CAT_INFO は列を空にして、色分けした行だけが目立つようにする）
CAT_LABEL=("" "エラー" "警告" "デプロイ" "アンデプロイ" "起動" "停止" "デバッグ")

# --- JBoss EAP のメッセージコード ---
#   WFLY*: EAP 7 以降（WildFly 系） / JBAS*: EAP 6 系
#   アンデプロイはデプロイより先に判定する（--ignore-case 指定時に
#   "Undeployed" が "Deployed" のパターンに一致してしまうため）。
readonly RE_UNDEPLOY='WFLYSRV0009|WFLYSRV0028|WFLYUT0022|JBAS015877|JBAS018558|JBAS017535|Undeployed "|Stopped deployment'
readonly RE_DEPLOY='WFLYSRV0027|WFLYSRV0010|WFLYSRV0016|WFLYSRV0013|WFLYUT0021|WFLYDS0004|WFLYDS0013|JBAS015876|JBAS018559|JBAS017534|Starting deployment of|Deployed "|Replaced deployment'
readonly RE_STOP='WFLYSRV0050|WFLYSRV0211|WFLYSRV0220|WFLYSRV0236|WFLYSRV0241|JBAS015950|stopped in [0-9]'
readonly RE_START='WFLYSRV0049|WFLYSRV0025|WFLYSRV0026|WFLYSRV0212|JBAS015874|JBAS015899|started in [0-9]'

# メッセージから区分とレベルを判定する。
#   結果: EV_CAT  色分けに使う区分 ID
#         EV_KCAT JBoss の観点での区分 ID（デプロイ / 起動 等。無ければ空）
#         EV_LEVEL 出力レベル（ERROR 等。読み取れなければ空）
#   色は「エラー・警告」を最優先にする（デプロイ失敗を緑で埋もれさせないため）。
#   区分名は JBoss の観点を優先して残すので、デプロイ失敗は
#   「区分=デプロイ / レベル=ERROR / 色=赤」となり、区分での絞り込みからも漏れない。
EV_CAT=0
EV_KCAT=""
EV_LEVEL=""
classify_message() {
  local m="${1:0:400}"     # 判定は先頭部分だけ見る（長大なスタックトレース対策）
  local kindcat=-1
  EV_LEVEL=""; EV_KCAT=""; EV_CAT=$CAT_INFO

  # --- 出力レベル ---
  #   重いレベルから順に判定する（1 行に複数のレベル語がある場合は重いほうを採る）。
  #   正規表現の前に安価なグロブ一致で語の有無を調べるのは、イベント 1 件ごとに
  #   呼ばれるためで、語を含まない行では正規表現の実行そのものを省ける。
  if   [[ "$m" == *FATAL* || "$m" == *SEVERE* ]] \
       && [[ "$m" =~ (^|[^A-Za-z])(FATAL|SEVERE)([^A-Za-z]|$) ]];  then EV_LEVEL="FATAL"
  elif [[ "$m" == *ERROR* ]] \
       && [[ "$m" =~ (^|[^A-Za-z])ERROR([^A-Za-z]|$) ]];           then EV_LEVEL="ERROR"
  elif [[ "$m" == *WARN* ]] \
       && [[ "$m" =~ (^|[^A-Za-z])WARN(ING)?([^A-Za-z]|$) ]];      then EV_LEVEL="WARN"
  elif [[ "$m" == *INFO* ]] \
       && [[ "$m" =~ (^|[^A-Za-z])INFO([^A-Za-z]|$) ]];            then EV_LEVEL="INFO"
  elif [[ "$m" == *DEBUG* || "$m" == *TRACE* || "$m" == *FINE* ]] \
       && [[ "$m" =~ (^|[^A-Za-z])(DEBUG|TRACE|FINE)([^A-Za-z]|$) ]]; then EV_LEVEL="DEBUG"
  fi

  # --- JBoss EAP の観点（デプロイ / 起動 など） ---
  #   JBoss のメッセージコードや語を含む行だけを正規表現にかける（上と同じ理由）。
  if [[ "$m" == *WFLY* || "$m" == *JBAS* || "$m" == *eploy* \
     || "$m" == *"tarted in "* || "$m" == *"topped in "* ]]; then
    if   [[ "$m" =~ $RE_UNDEPLOY ]]; then kindcat=$CAT_UNDEPLOY
    elif [[ "$m" =~ $RE_DEPLOY ]];   then kindcat=$CAT_DEPLOY
    elif [[ "$m" =~ $RE_STOP ]];     then kindcat=$CAT_STOP
    elif [[ "$m" =~ $RE_START ]];    then kindcat=$CAT_START
    fi
  fi

  if (( kindcat >= 0 )); then
    EV_KCAT=$kindcat
    case "$EV_LEVEL" in
      FATAL|ERROR) EV_CAT=$CAT_ERROR ;;
      WARN)        EV_CAT=$CAT_WARN ;;
      *)           EV_CAT=$kindcat ;;
    esac
    return 0
  fi

  case "$EV_LEVEL" in
    FATAL|ERROR) EV_CAT=$CAT_ERROR ;;
    WARN)        EV_CAT=$CAT_WARN ;;
    DEBUG)       EV_CAT=$CAT_DEBUG ;;
    *)           EV_CAT=$CAT_INFO ;;
  esac
  return 0
}

# 区分の表示名を返す（結果は EV_KIND_LABEL）。JBoss の観点があればそれを優先する。
EV_KIND_LABEL=""
kind_label() {
  local cat="$1" kcat="$2"
  if [[ -n "$kcat" ]]; then EV_KIND_LABEL="${CAT_LABEL[kcat]}"; else EV_KIND_LABEL="${CAT_LABEL[cat]}"; fi
}

# ===========================================================================
# 9. AWS CLI 実行ラッパー（リトライ + 指数バックオフ + エラー分類）
# ===========================================================================
build_aws_global() {
  AWS_GLOBAL=()
  [[ -n "$AWS_PROFILE_OPT" ]] && AWS_GLOBAL+=(--profile "$AWS_PROFILE_OPT")
  if [[ -n "$AWS_REGION_OPT" ]]; then
    AWS_GLOBAL+=(--region "$AWS_REGION_OPT")
  elif [[ -n "${AWS_REGION:-}" ]]; then
    AWS_GLOBAL+=(--region "$AWS_REGION")
  elif [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    AWS_GLOBAL+=(--region "$AWS_DEFAULT_REGION")
  fi
}

# 一時的（リトライ可能）なエラーか
is_transient_error() {
  printf '%s' "$1" | grep -qiE \
    'Throttling|ThrottlingException|Rate exceeded|RequestLimitExceeded|TooManyRequestsException|ServiceUnavailable|InternalFailure|InternalServerError|\b5[0-9][0-9]\b|timed out|timeout|Could not connect|connection reset|temporarily'
}
is_auth_error() {
  printf '%s' "$1" | grep -qiE \
    'ExpiredToken|ExpiredTokenException|InvalidClientTokenId|UnrecognizedClientException|Unable to locate credentials|security token.*expired|InvalidAccessKeyId|SignatureDoesNotMatch|token.*not.*valid|NoCredentialProviders'
}
is_access_denied() {
  printf '%s' "$1" | grep -qiE \
    'AccessDenied|AccessDeniedException|UnauthorizedOperation|not authorized to perform|is not authorized'
}
is_not_found() {
  printf '%s' "$1" | grep -qiE \
    'ResourceNotFoundException|does not exist|specified log group|specified log stream'
}

# aws を実行し、成功時は AWS_OUT に stdout を格納して 0 を返す。
# 失敗時は AWS_ERR に stderr を格納し、非 0 を返す（呼び出し側で分類）。
# 一時エラーは指数バックオフで最大 AWS_MAX_RETRY 回まで自動再試行する。
AWS_MAX_RETRY=5
run_aws() {
  local attempt=1 delay=1 errf rc
  while :; do
    errf="$(mktemp "${TMPDIR:-/tmp}/cwlv.err.XXXXXX")" || die "一時ファイルの作成に失敗しました。" "$EX_API"
    # rc は必ず then/else の中で捕捉する。
    # 「if COND; then ...; fi」の直後で $? を読むと、COND が偽・else 無しの if は
    # 0 を返す仕様のため、失敗を 0（成功）と誤判定してしまう。明示的な else で捕捉する。
    if AWS_OUT="$(aws ${AWS_GLOBAL[@]+"${AWS_GLOBAL[@]}"} "$@" 2>"$errf")"; then
      rc=0
    else
      rc=$?
    fi
    AWS_ERR="$(cat "$errf")"; rm -f "$errf"
    if (( rc == 0 )); then
      return 0
    fi
    if is_transient_error "$AWS_ERR" && (( attempt < AWS_MAX_RETRY )); then
      log_warn "AWS API 一時エラー（${attempt}/${AWS_MAX_RETRY} 回目）。${delay} 秒後に再試行します..."
      log_debug "詳細: ${AWS_ERR}"
      sleep "$delay"
      delay=$(( delay * 2 )); (( delay > 30 )) && delay=30
      attempt=$(( attempt + 1 ))
      continue
    fi
    return "$rc"
  done
}

# フェッチ中のエラーを分類して適切に終了する
handle_fetch_error() {
  local ctx="$1"
  if is_auth_error "$AWS_ERR"; then
    log_error "AWS の認証が無効または期限切れです（${ctx}）。"
    log_error "  再度 'aws login --remote' で認証してから実行してください。"
    exit "$EX_AUTH"
  elif is_access_denied "$AWS_ERR"; then
    log_error "権限が不足しています（${ctx}）。必要な logs 権限を確認するか、スイッチバックしてください。"
    log_debug "詳細: ${AWS_ERR}"
    exit "$EX_PERM"
  elif is_not_found "$AWS_ERR"; then
    log_error "対象リソースが見つかりません（${ctx}）: ${AWS_ERR}"
    exit "$EX_NOTFOUND"
  else
    log_error "AWS API 呼び出しに失敗しました（${ctx}）: ${AWS_ERR}"
    exit "$EX_API"
  fi
}

# ===========================================================================
# 10. 前提確認・認証・権限
# ===========================================================================
preflight_commands() {
  require_command aws
  require_command jq
  require_command date
  require_command sort
  # GNU date が必要（-d の相対/絶対日時解釈のため）
  if ! date --version 2>/dev/null | grep -qi 'GNU coreutils'; then
    die "GNU date が必要です（本スクリプトは日時解釈に GNU date を使用します）。" "$EX_NODEP"
  fi
  # xlsx は ZIP コンテナのため zip コマンドが必要（xml 形式なら不要）
  if [[ -n "$EXCEL_FILE" && "$EXCEL_FORMAT" == "xlsx" ]] && ! command -v zip >/dev/null 2>&1; then
    log_error "xlsx 形式の出力には zip コマンドが必要ですが見つかりません。"
    log_error "  対処: zip を導入するか、--excel-format xml（SpreadsheetML 形式）を指定してください。"
    log_error "  例:  ${SCRIPT_NAME} ... --excel '${EXCEL_FILE%.xlsx}.xml'"
    exit "$EX_NODEP"
  fi
  # AWS CLI で必要なサブコマンドが使えるか軽く確認
  aws logs help >/dev/null 2>&1 || die "この AWS CLI では 'aws logs' が利用できません。CLI のバージョンを確認してください。" "$EX_NODEP"
}

# AWS 認証状態の事前確認（実 API 呼び出しで判定）。未認証は EX_AUTH で終了。
require_authenticated() {
  local arn account
  if ! run_aws sts get-caller-identity --query Arn --output text; then
    if is_auth_error "$AWS_ERR"; then
      log_error "AWS の認証を確認できませんでした（未認証または資格情報未設定）。"
    else
      log_error "AWS 認証確認に失敗しました: ${AWS_ERR}"
    fi
    log_error "  事前に次のコマンドで認証してから、再度このスクリプトを実行してください:"
    log_error "      aws login --remote"
    exit "$EX_AUTH"
  fi
  arn="$AWS_OUT"
  run_aws sts get-caller-identity --query Account --output text >/dev/null 2>&1 || true
  account="$AWS_OUT"
  CALLER_ARN="$arn"
  CALLER_ACCOUNT="$account"
  log_success "AWS 認証を確認しました。"
  log_info "  アカウント : ${CALLER_ACCOUNT}"
  log_info "  Caller ARN : ${CALLER_ARN}"
  log_info "  プロファイル: ${AWS_PROFILE_OPT:-${AWS_PROFILE:-(既定)}}"
  local rgn="(既定)"
  [[ -n "$AWS_REGION_OPT" ]] && rgn="$AWS_REGION_OPT"
  [[ -z "$AWS_REGION_OPT" && -n "${AWS_REGION:-}" ]] && rgn="$AWS_REGION"
  [[ -z "$AWS_REGION_OPT" && -z "${AWS_REGION:-}" && -n "${AWS_DEFAULT_REGION:-}" ]] && rgn="$AWS_DEFAULT_REGION"
  log_info "  リージョン : ${rgn}"
}

# CloudWatch Logs 読み取り権限の確認（describe-log-groups を代表として使用）。
#   0 = 権限あり / 非0 = 権限なし（AWS_ERR に理由）
probe_logs_permission() {
  run_aws logs describe-log-groups --no-paginate --limit 1 >/dev/null 2>&1
}

# 権限確認 + 必要ならスイッチバック（案内終了 or 自動 source）。
ensure_logs_permission_or_switchback() {
  if probe_logs_permission; then
    log_success "CloudWatch Logs への読み取り権限を確認しました。"
    return 0
  fi

  # 権限なしの原因を分類（認証期限切れはスイッチバック対象外）
  if is_auth_error "$AWS_ERR"; then
    log_error "AWS の認証が無効または期限切れです。'aws login --remote' で再認証してください。"
    exit "$EX_AUTH"
  fi
  if ! is_access_denied "$AWS_ERR"; then
    log_error "CloudWatch Logs の権限確認中に通信エラー等が発生しました: ${AWS_ERR}"
    exit "$EX_API"
  fi

  log_warn "現在の IAM 権限では CloudWatch Logs を参照できません（権限不足）。"

  # --- モードA: 警告して終了 ---
  if [[ "$SWITCHBACK_MODE" != "auto" ]]; then
    log_error "CloudWatch Logs を参照するにはスイッチバックしてから再実行してください。"
    if [[ -n "$SWITCHBACK_SCRIPT" ]]; then
      log_error "  例:  source \"${SWITCHBACK_SCRIPT}\""
    else
      log_error "  （CodeCommit 用ロール等から元のロールへ戻すスイッチバック用シェルを source してください）"
    fi
    log_error "  スイッチバック後、このスクリプトを再度実行してください。"
    exit "$EX_PERM"
  fi

  # --- モードB: 自動スイッチバック（最大 1 回） ---
  do_auto_switchback
}

# スイッチバック用シェルの安全確認と source 実行、実行後の再確認
do_auto_switchback() {
  if [[ "$SWITCHBACK_DONE" == "true" ]]; then
    die "スイッチバック後も CloudWatch Logs の権限を獲得できませんでした（再試行は行いません）。" "$EX_SWITCHBACK"
  fi
  SWITCHBACK_DONE="true"

  [[ -n "$SWITCHBACK_SCRIPT" ]] \
    || die "自動スイッチバックには --switchback-script（または環境変数）でシェルの指定が必要です。" "$EX_SWITCHBACK"

  # 安全確認: 実在する通常ファイルか / 読み取り可能か / 危険なパーミッションでないか
  [[ -e "$SWITCHBACK_SCRIPT" ]] || die "スイッチバック用シェルが存在しません: ${SWITCHBACK_SCRIPT}" "$EX_SWITCHBACK"
  [[ -f "$SWITCHBACK_SCRIPT" ]] || die "スイッチバック用シェルが通常ファイルではありません: ${SWITCHBACK_SCRIPT}" "$EX_SWITCHBACK"
  [[ -r "$SWITCHBACK_SCRIPT" ]] || die "スイッチバック用シェルを読み取れません（権限を確認してください）: ${SWITCHBACK_SCRIPT}" "$EX_SWITCHBACK"
  # 他者書き込み可能（world-writable）なら安全のため拒否する
  local perms other
  if perms="$(stat -c '%a' "$SWITCHBACK_SCRIPT" 2>/dev/null)"; then
    other="${perms: -1}"
    if [[ "$other" =~ ^[0-9]$ ]] && (( (other & 2) != 0 )); then
      die "スイッチバック用シェルが他者書き込み可能（危険なパーミッション ${perms}）です: ${SWITCHBACK_SCRIPT}" "$EX_SWITCHBACK"
    fi
  fi

  # これから実行する内容を表示（対象ファイルと引数）
  log_info "=== 自動スイッチバックを実行します ==="
  log_info "  source \"${SWITCHBACK_SCRIPT}\" ${SWITCHBACK_ARGS[*]:-}"
  log_warn "  注意: 指定したスイッチバック用シェルの内容は信頼済みである必要があります。"

  # dry-run 時は実行せず予定のみ表示して正常終了
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] スイッチバックは実行しません（予定内容のみ表示しました）。"
    exit "$EX_OK"
  fi

  # source で現在のシェルに反映（eval は使わない。パス・引数は配列で安全に渡す）
  local sb_rc=0
  # shellcheck source=/dev/null
  source "$SWITCHBACK_SCRIPT" ${SWITCHBACK_ARGS[@]+"${SWITCHBACK_ARGS[@]}"} || sb_rc=$?
  if (( sb_rc != 0 )); then
    die "スイッチバック用シェルの実行に失敗しました（終了コード ${sb_rc}）: ${SWITCHBACK_SCRIPT}" "$EX_SWITCHBACK"
  fi
  log_success "スイッチバック用シェルを実行しました。"

  # スイッチバック後に認証と権限を再確認する
  if ! run_aws sts get-caller-identity --query Arn --output text; then
    log_error "スイッチバック後、AWS 認証を確認できません。'aws login --remote' で認証してください。"
    exit "$EX_AUTH"
  fi
  log_success "スイッチバック後の認証を確認しました: ${AWS_OUT}"
  if probe_logs_permission; then
    log_success "スイッチバック後、CloudWatch Logs への権限を確認しました。処理を継続します。"
    return 0
  fi
  die "スイッチバックを実行しましたが、CloudWatch Logs の権限を獲得できませんでした。" "$EX_SWITCHBACK"
}

# ===========================================================================
# 11. 対話メニュー（番号選択）
# ===========================================================================
SELECTED_ITEM=""       # 単一選択の結果
SELECTED_ITEMS=()      # 複数選択の結果（単一選択時も 1 要素で設定される）
MENU_ITEMS=()

# 複数選択の入力（例: "1 3,5 7-9" / "a"）を解析して SELECTED_ITEMS を組み立てる。
#   view: 現在表示中の項目配列（名前で参照）。重複指定は 1 件にまとめ、表示順を保つ。
#   戻り値 0=成功 / 1=入力エラー（呼び出し側でプロンプトをやり直す）
parse_multi_selection() {
  local input="$1"; shift
  local view=("$@")
  local -A picked=()
  local tok lo hi i tokens=()

  # カンマも区切りとして扱う（"1,3" と "1 3" を同じに解釈する）
  IFS=', ' read -r -a tokens <<< "$input"
  (( ${#tokens[@]} )) || { log_warn "選択が空です。"; return 1; }

  for tok in "${tokens[@]}"; do
    [[ -z "$tok" ]] && continue
    if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
    elif [[ "$tok" =~ ^[0-9]+$ ]]; then
      lo="$tok"; hi="$tok"
    else
      log_warn "番号または範囲（例: 3 / 5-8）で指定してください: '${tok}'"
      return 1
    fi
    if (( lo < 1 || hi < 1 || lo > ${#view[@]} || hi > ${#view[@]} )); then
      log_warn "1〜${#view[@]} の範囲で入力してください: '${tok}'"
      return 1
    fi
    (( lo > hi )) && { log_warn "範囲の指定が逆転しています: '${tok}'"; return 1; }
    for (( i = lo; i <= hi; i++ )); do picked[$i]=1; done
  done

  (( ${#picked[@]} )) || { log_warn "選択が空です。"; return 1; }

  # 表示順を保って結果を組み立てる（連想配列のキー順は不定のため添字で走査する）
  SELECTED_ITEMS=()
  for (( i = 1; i <= ${#view[@]}; i++ )); do
    [[ -n "${picked[$i]:-}" ]] && SELECTED_ITEMS+=("${view[i - 1]}")
  done
  return 0
}

# 一覧から選択する。$2 に "multi" を渡すと複数選択できる。
#   結果: SELECTED_ITEMS（配列）/ SELECTED_ITEM（先頭の 1 件）
select_from_list() {
  local title="$1" mode="${2:-single}"
  local view=("${MENU_ITEMS[@]}")
  local pat="" input i it prompt

  SELECTED_ITEM=""
  SELECTED_ITEMS=()

  if (( ${#MENU_ITEMS[@]} == 0 )); then
    log_warn "選択できる項目がありません。"
    return 2
  fi

  if [[ "$mode" == "multi" ]]; then
    prompt="番号(例: 3 / 1,4 / 2-5 / a=全件): 選択, /正規表現: 絞り込み, //: 解除, q: 中止 > "
  else
    prompt="番号: 選択, /正規表現: 絞り込み, //: 解除, q: 中止 > "
  fi

  while :; do
    printf '\n' >&2
    log_info "${title}（全 ${#MENU_ITEMS[@]} 件 / 表示 ${#view[@]} 件${pat:+, 絞り込み: /${pat}}）"
    for i in "${!view[@]}"; do
      printf '  %4d) %s\n' "$(( i + 1 ))" "${view[i]}" >&2
    done
    (( ${#view[@]} == 0 )) && log_warn "絞り込みに一致する項目がありません（// で解除）。"

    if ! IFS= read -r -p "$prompt" input; then
      return 2   # EOF（非対話環境）は中止扱い
    fi
    case "$input" in
      q|Q) return 2 ;;
      //)  pat=""; view=("${MENU_ITEMS[@]}"); continue ;;
      /*)  pat="${input#/}"
           if ! regex_valid "$pat"; then log_warn "正規表現が不正です: $pat"; pat=""; continue; fi
           view=()
           for it in "${MENU_ITEMS[@]}"; do [[ "$it" =~ $pat ]] && view+=("$it"); done
           continue ;;
    esac

    (( ${#view[@]} == 0 )) && continue

    if [[ "$mode" == "multi" ]]; then
      # 全件選択（現在の絞り込み結果すべて）
      if [[ "$input" == "a" || "$input" == "A" || "$input" == "*" ]]; then
        SELECTED_ITEMS=("${view[@]}")
        SELECTED_ITEM="${SELECTED_ITEMS[0]}"
        return 0
      fi
      if parse_multi_selection "$input" "${view[@]}"; then
        SELECTED_ITEM="${SELECTED_ITEMS[0]}"
        return 0
      fi
      continue
    fi

    # 単一選択
    case "$input" in
      ''|*[!0-9]*) log_warn "番号か /正規表現 を入力してください: '$input'" ;;
      *)   if (( input >= 1 && input <= ${#view[@]} )); then
             SELECTED_ITEM="${view[input - 1]}"
             SELECTED_ITEMS=("$SELECTED_ITEM")
             return 0
           fi
           log_warn "1〜${#view[@]} の範囲で入力してください: $input" ;;
    esac
  done
}

# ===========================================================================
# 12. ロググループ / ログストリームの一覧取得（ページネーション対応）
# ===========================================================================
fetch_log_groups() {
  log_info "ロググループ一覧を取得しています..."
  local token="" names=() raw
  while :; do
    local args=(logs describe-log-groups --no-paginate
                --query 'logGroups[].logGroupName' --output text)
    [[ -n "$LOG_GROUP_PREFIX" ]] && args+=(--log-group-name-prefix "$LOG_GROUP_PREFIX")
    [[ -n "$token" ]] && args+=(--next-token "$token")
    if ! run_aws "${args[@]}"; then handle_fetch_error "ロググループ一覧取得"; fi
    raw="$AWS_OUT"
    # ページトークンを別途取得
    local targs=(logs describe-log-groups --no-paginate --query 'nextToken' --output text)
    [[ -n "$LOG_GROUP_PREFIX" ]] && targs+=(--log-group-name-prefix "$LOG_GROUP_PREFIX")
    [[ -n "$token" ]] && targs+=(--next-token "$token")
    run_aws "${targs[@]}" || handle_fetch_error "ロググループ一覧取得(トークン)"
    local next="$AWS_OUT"
    if [[ -n "$raw" && "$raw" != "None" ]]; then
      local n
      while IFS= read -r n; do [[ -n "$n" ]] && names+=("$n"); done < <(printf '%s\n' "$raw" | tr '\t' '\n')
    fi
    [[ -z "$next" || "$next" == "None" ]] && break
    token="$next"
  done

  MENU_ITEMS=()
  if (( ${#names[@]} )); then
    mapfile -t MENU_ITEMS < <(printf '%s\n' "${names[@]}" | sort -u)
  fi
  if (( ${#MENU_ITEMS[@]} == 0 )); then
    die "ロググループが 1 件もありません（リージョンやプレフィックスを確認してください）。" "$EX_NOTFOUND"
  fi
}

fetch_log_streams() {
  local group="$1"
  log_info "ログストリーム一覧を取得しています: ${group}"
  # 最終イベント時刻の新しい順。判断材料として最終イベント時刻(JST)も併記する。
  local args=(logs describe-log-streams --no-paginate
              --log-group-name "$group"
              --order-by LastEventTime --descending
              --max-items 50
              --query 'logStreams[].[logStreamName,lastEventTimestamp,lastIngestionTime]'
              --output text)
  [[ -n "$LOG_STREAM_PREFIX" ]] && {
    # prefix 指定時は LogStreamNamePrefix を使う（order-by は LogStreamName になる制約に注意）
    args=(logs describe-log-streams --no-paginate
          --log-group-name "$group"
          --log-stream-name-prefix "$LOG_STREAM_PREFIX"
          --max-items 50
          --query 'logStreams[].[logStreamName,lastEventTimestamp,lastIngestionTime]'
          --output text)
  }
  if ! run_aws "${args[@]}"; then handle_fetch_error "ログストリーム一覧取得"; fi

  MENU_ITEMS=()
  local line name lastev lasting label
  while IFS=$'\t' read -r name lastev lasting; do
    [[ -z "$name" || "$name" == "None" ]] && continue
    if [[ "$lastev" =~ ^[0-9]+$ ]]; then
      label="$(epoch_ms_to_jst "$lastev")"
    else
      label="(最終イベント時刻なし)"
    fi
    MENU_ITEMS+=("${name}    最終: ${label}")
  done < <(printf '%s\n' "$AWS_OUT")

  (( ${#MENU_ITEMS[@]} > 0 )) || die "ロググループ '${group}' にログストリームがありません。" "$EX_NOTFOUND"
}

# メニュー項目（"名前    最終: ...")から実ストリーム名だけを取り出す
strip_stream_label() { printf '%s' "${1%%    最終: *}"; }

# ===========================================================================
# 13. メッセージのエスケープ解除・整形補助
# ===========================================================================
# jq の @tsv は message 中の \t \n \r \\ をエスケープする。以下でその逆変換を行う。

# エスケープ済み1行メッセージ -> 実際の改行等を含む文字列（DECODED に格納）
DECODED=""
decode_msg() {
  local s="$1"
  s="${s//\\\\/$'\x01'}"     # \\ を一時プレースホルダへ退避
  s="${s//\\t/$'\t'}"
  s="${s//\\r/$'\r'}"
  s="${s//\\n/$'\n'}"
  s="${s//$'\x01'/\\}"       # プレースホルダを実際の \ へ戻す
  DECODED="$s"
}

# エスケープ済みメッセージ -> フィルタ判定用の 1 行文字列（\t\n\r を空白に）
#   epoch_ms_to_jst と同様、イベントごとの呼び出しでは set_singleline_space を使って
#   SINGLELINE_STR から受け取る（コマンド置換の fork を避けるため）。
SINGLELINE_STR=""
set_singleline_space() {
  local s="$1"
  s="${s//\\\\/$'\x01'}"
  s="${s//\\t/ }"; s="${s//\\r/ }"; s="${s//\\n/ }"
  SINGLELINE_STR="${s//$'\x01'/\\}"
}
to_singleline_space() { set_singleline_space "$1"; printf '%s' "$SINGLELINE_STR"; }

# ===========================================================================
# 14. フィルタ判定（ローカル）。cloudwatch モードの include はサーバー側で実施済み。
# ===========================================================================
# $1=判定対象(1行), $2=パターン。FILTER_MODE / IGNORE_CASE に従う。
match_one() {
  local hay="$1" pat="$2"
  if [[ "$FILTER_MODE" == "regex" ]]; then
    [[ "$hay" =~ $pat ]]                 # nocasematch が大文字小文字を制御
  else
    [[ "$hay" == *"$pat"* ]]             # 固定文字列（pat はクォートで literal 扱い）
  fi
}

# 表示すべきなら 0、除外なら 1 を返す
passes_filters() {
  local hay="$1" pat
  # 除外（いずれかに一致したら除外）
  if (( ${#EXCLUDES[@]} )); then
    for pat in "${EXCLUDES[@]}"; do
      match_one "$hay" "$pat" && return 1
    done
  fi
  # 包含（cloudwatch モードはサーバー側で処理済みのためローカルでは判定しない）
  if [[ "$FILTER_MODE" != "cloudwatch" ]] && (( ${#FILTERS[@]} )); then
    local hit
    for pat in "${FILTERS[@]}"; do
      if match_one "$hay" "$pat"; then hit=1; else hit=0; fi
      if [[ "$FILTER_LOGIC" == "or" ]]; then
        (( hit == 1 )) && return 0
      else
        (( hit == 0 )) && return 1
      fi
    done
    if [[ "$FILTER_LOGIC" == "or" ]]; then return 1; else return 0; fi
  fi
  return 0
}

# ===========================================================================
# 15. 出力整形
# ===========================================================================
# text 形式（複数行は先頭行に時刻、後続行をインデント）
#   先頭に出す時刻は「ログ本文に出力されている時刻」（mts）。
#   本文に時刻が無い行はイベント時刻が入っているため、見た目は変わらない。
format_text() {
  local mts="$1" ts="$2" ing="$3" ls="$4" emsg="$5"
  local prefix
  set_jst_str "$mts"; prefix="${JST_STR} | "
  [[ "$SHOW_GROUP"  == "true" ]] && prefix+="${LOG_GROUP} | "
  [[ "$SHOW_STREAM" == "true" ]] && prefix+="${ls} | "
  if [[ "$SHOW_EVENT_TIME" == "true" ]]; then set_jst_str "$ts"; prefix+="event=${JST_STR} | "; fi
  if [[ "$SHOW_INGEST" == "true" ]]; then set_jst_str "$ing"; prefix+="ingest=${JST_STR} | "; fi

  if [[ "$SINGLE_LINE" == "true" ]]; then
    # emsg は既に \n \t \r をエスケープした 1 行表現
    printf '%s%s\n' "$prefix" "$emsg"
    return
  fi

  decode_msg "$emsg"
  local dec="$DECODED"
  if [[ "$dec" != *$'\n'* ]]; then
    printf '%s%s\n' "$prefix" "$dec"
    return
  fi
  local indent; indent="$(printf '%*s' "${#prefix}" '')"
  local first=1 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( first )); then printf '%s%s\n' "$prefix" "$line"; first=0
    else printf '%s%s\n' "$indent" "$line"; fi
  done <<< "$dec"
}

# tsv 形式:
#   logTime_jst \t logTime(ms) \t eventTime(ms) \t logStream \t ingestionTime(ms) \t message(1行)
#   logTime はログ本文に出力されている時刻、eventTime は CloudWatch のイベント時刻。
#   SHOW_GROUP が true のときのみ先頭に logGroup 列が付く。
format_tsv() {
  local mts="$1" ts="$2" ing="$3" ls="$4" emsg="$5"
  set_jst_str "$mts"
  if [[ "$SHOW_GROUP" == "true" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$LOG_GROUP" "$JST_STR" "$mts" "$ts" "$ls" "$ing" "$emsg"
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$JST_STR" "$mts" "$ts" "$ls" "$ing" "$emsg"
  fi
}

# jsonl 形式（エスケープ済み TSV を単一 jq パスで JSON 化。改行等は正しく復元）
#   注意点（移植性）:
#     - @tsv のエスケープ解除は、名前付きキャプチャ (?<c>.) を使う jq では一部の
#       古い Oniguruma ビルドで動作しないため、単純な gsub の逐次適用で行う。
#       "\\" を一旦プレースホルダ(U+0001)へ退避してから \t \n \r を戻し、最後に
#       プレースホルダを "\" へ戻す（bash 側 decode_msg と同じロジック）。
#     - jq のオブジェクト値で二項演算子(+)を使う場合は全体を括弧で囲む必要がある。
#     - 時刻は TZ 非依存にするため epoch 秒へ +9h して gmtime|strftime で JST 化する。
emit_jsonl() {
  local f="$1"
  [[ -s "$f" ]] || return 0
  jq -R -c --arg lg "$LOG_GROUP" --argjson off "$JST_OFFSET_SECONDS" '
    def unesc:
        gsub("\\\\\\\\"; "")
      | gsub("\\\\t"; "\t")
      | gsub("\\\\n"; "\n")
      | gsub("\\\\r"; "\r")
      | gsub(""; "\\");
    split("") as $f
    | ($f[1]|tonumber) as $ts
    | ($f[0]|tonumber) as $lts
    | { timestamp: $ts,
        timestamp_jst: ( ((($ts/1000|floor)+$off)|gmtime|strftime("%Y-%m-%d %H:%M:%S"))
                         + "." + ((($ts%1000)+1000)|tostring|.[1:]) + " JST" ),
        logTime: $lts,
        logTime_jst: ( ((($lts/1000|floor)+$off)|gmtime|strftime("%Y-%m-%d %H:%M:%S"))
                       + "." + ((($lts%1000)+1000)|tostring|.[1:]) + " JST" ),
        level: ($f[7]|if .=="" then null else . end),
        category: ($f[8]|if .=="" then null else . end),
        message: ($f[9]|unesc),
        logGroup: $lg,
        logStream: ($f[4]|if .=="" then null else . end),
        ingestionTime: ($f[2]|tonumber|if .==0 then null else . end),
        eventId: ($f[3]|if .=="" then null else . end) }' "$f"
}

# ===========================================================================
# 16. フェッチ（get-log-events / filter-log-events）
#     取得結果は「ts, ingestion, eventId, logStream, message(escaped)」を
#     区切り文字 US(0x1F) で連結して out ファイルへ 1 行ずつ追記する。
#     ※ タブではなく 0x1F を使う理由: bash の read は IFS が空白類（タブ含む）
#       だと連続区切りを 1 個に畳み込み、空フィールド（get の eventId 等）が
#       消えてしまうため。0x1F は非空白なので空フィールドが保持される。
#     ※ message 内の \\ \t \r \n は jq 側で可視エスケープし、混入し得る 0x1F は
#       空白へ置換して 1 行 1 レコードを保証する（bash 側 decode_msg で復元）。
# ---------------------------------------------------------------------------
# jq でメッセージをエスケープする共通定義（@tsv 相当。バックスラッシュを最初に処理）
readonly JQ_ESC_DEF='def esc: gsub("\\\\";"\\\\") | gsub("";" ") | gsub("\t";"\\t") | gsub("\r";"\\r") | gsub("\n";"\\n");'
# XML（Excel）で表現できない C0 制御文字を空白へ落とすための jq 定義。
#   対象は 0x01-0x08 / 0x0B / 0x0C / 0x0E-0x1E。
#   \t(09) \r(0D) \n(0A) は esc が可視化するので除外し、0x1F は esc 側で処理する。
#   文字クラスは printf の 8 進エスケープで組み立て、このソース自体は ASCII のみに保つ
#   （生の制御文字をソースへ書くと、テキスト転送やエディタで失われやすいため）。
readonly JQ_CTRL_DEF="def ctrlsafe: gsub(\"$(printf '[\001-\010\013\014\016-\036]')\";\" \");"
readonly US=$'\037'   # Unit Separator (0x1F) をフィールド区切りに使う
fetch_get_events() {
  local out="$1"
  local token="" resp n next count=0 limit
  while :; do
    limit=$(( MAX_EVENTS - count ))
    (( limit <= 0 )) && break
    (( limit > PAGE_LIMIT )) && limit=$PAGE_LIMIT
    (( limit > 10000 )) && limit=10000
    local args=(logs get-log-events --no-paginate
                --log-group-name "$LOG_GROUP" --log-stream-name "$LOG_STREAM"
                --start-from-head --limit "$limit" --output json)
    [[ -n "$FETCH_START_MS" ]] && args+=(--start-time "$FETCH_START_MS")
    [[ -n "$FETCH_END_MS" ]]   && args+=(--end-time "$FETCH_END_MS")
    [[ -n "$token" ]]          && args+=(--next-token "$token")
    if ! run_aws "${args[@]}"; then handle_fetch_error "ログイベント取得(get-log-events)"; fi
    resp="$AWS_OUT"

    printf '%s' "$resp" | jq -r --arg ls "$LOG_STREAM" "$JQ_ESC_DEF$JQ_CTRL_DEF"'
      .events[] | [(.timestamp|tostring), ((.ingestionTime//0)|tostring), "", $ls, (.message|ctrlsafe|esc)]
      | join("")' >> "$out"
    n="$(printf '%s' "$resp" | jq '.events | length')"
    n="${n%$'\r'}"
    next="$(printf '%s' "$resp" | jq -r '.nextForwardToken // ""')"
    next="${next%$'\r'}"
    count=$(( count + n ))
    _accumulate_maxts_from_resp "$resp" "get"

    # get-log-events は末尾で nextForwardToken が変化しなくなる（AWS 仕様）
    (( n == 0 )) && break
    [[ "$next" == "$token" ]] && break
    if (( count >= MAX_EVENTS )); then
      log_warn "最大取得件数（${MAX_EVENTS} 件）に達しました。--max-events で増やせます。"
      break
    fi
    token="$next"
  done
  FETCHED=$count
}

fetch_filter_events() {
  local out="$1"
  local token="" resp n next count=0 lim
  while :; do
    local rem=$(( MAX_EVENTS - count ))
    (( rem <= 0 )) && break
    lim=$PAGE_LIMIT; (( lim > 10000 )) && lim=10000; (( lim > rem )) && lim=$rem
    local args=(logs filter-log-events --no-paginate
                --log-group-name "$LOG_GROUP" --limit "$lim" --output json)
    [[ -n "$FETCH_START_MS" ]]    && args+=(--start-time "$FETCH_START_MS")
    [[ -n "$FETCH_END_MS" ]]      && args+=(--end-time "$FETCH_END_MS")
    [[ -n "$CW_PATTERN" ]]        && args+=(--filter-pattern "$CW_PATTERN")
    [[ -n "$LOG_STREAM" ]]        && args+=(--log-stream-names "$LOG_STREAM")
    [[ -n "$LOG_STREAM_PREFIX" ]] && args+=(--log-stream-name-prefix "$LOG_STREAM_PREFIX")
    [[ -n "$token" ]]             && args+=(--next-token "$token")
    if ! run_aws "${args[@]}"; then handle_fetch_error "ログイベント取得(filter-log-events)"; fi
    resp="$AWS_OUT"

    printf '%s' "$resp" | jq -r "$JQ_ESC_DEF$JQ_CTRL_DEF"'
      .events[] | [(.timestamp|tostring), ((.ingestionTime//0)|tostring),
                   (.eventId//""), (.logStreamName//""), (.message|ctrlsafe|esc)]
      | join("")' >> "$out"
    n="$(printf '%s' "$resp" | jq '.events | length')"
    n="${n%$'\r'}"
    next="$(printf '%s' "$resp" | jq -r '.nextToken // ""')"
    next="${next%$'\r'}"
    count=$(( count + n ))
    _accumulate_maxts_from_resp "$resp" "filter"

    [[ -z "$next" ]] && break
    if (( count >= MAX_EVENTS )); then
      log_warn "最大取得件数（${MAX_EVENTS} 件）に達しました。--max-events で増やせます。"
      break
    fi
    token="$next"
  done
  FETCHED=$count
}

# レスポンスから最大タイムスタンプを取得し MAXTS を更新（follow の窓前進に使用）
_accumulate_maxts_from_resp() {
  local resp="$1" mx
  mx="$(printf '%s' "$resp" | jq -r '[.events[].timestamp] | max // empty')"
  mx="${mx%$'\r'}"
  [[ -n "$mx" && "$mx" =~ ^[0-9]+$ ]] || return 0
  if [[ -z "$MAXTS" ]] || (( mx > MAXTS )); then MAXTS="$mx"; fi
}

fetch_events() {
  local out="$1"
  if [[ "$ENGINE" == "get" ]]; then fetch_get_events "$out"; else fetch_filter_events "$out"; fi
}

# ===========================================================================
# 16.5 注釈付け（本文時刻の解析 + 区分判定）
#   取得直後の 5 列レコードへ、本文時刻・区分・レベルを足して 10 列にする。
#   本文時刻を先頭列に置くのは、この後 sort でログ出力時刻の昇順に並べるため。
#   列: 1 本文時刻(ms) / 2 イベント時刻(ms) / 3 取り込み時刻(ms) / 4 eventId
#       5 ログストリーム / 6 区分ID(色) / 7 区分ID(JBoss観点) / 8 レベル
#       9 区分名 / 10 メッセージ(エスケープ済み)
# ===========================================================================
ANNOTATED=0        # 注釈を付けたイベント数（グループごと）
NO_MSG_TIME=0      # うち本文から時刻を読み取れずイベント時刻で代用した数
annotate_events() {
  local in="$1" out="$2"
  local ts ing eid ls emsg
  ANNOTATED=0; NO_MSG_TIME=0
  : > "$out"
  [[ -s "$in" ]] || return 0
  {
    while IFS="$US" read -r ts ing eid ls emsg; do
      emsg="${emsg%$'\r'}"        # 末尾 CR を除去（CRLF 環境や CR 混入への保険）
      [[ "$ts" =~ ^[0-9]+$ ]] || continue
      ANNOTATED=$(( ANNOTATED + 1 ))
      if [[ "$TIME_SOURCE" == "message" ]]; then
        parse_msg_time "$emsg" "$ts"
        [[ "$MSG_TS_FROM" == "event" ]] && NO_MSG_TIME=$(( NO_MSG_TIME + 1 ))
      else
        MSG_TS="$ts"
      fi
      classify_message "$emsg"
      kind_label "$EV_CAT" "$EV_KCAT"
      printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' \
        "$MSG_TS" "$ts" "$ing" "$eid" "$ls" "$EV_CAT" "$EV_KCAT" "$EV_LEVEL" "$EV_KIND_LABEL" "$emsg"
    done < "$in"
  } > "$out"
  return 0
}

# ===========================================================================
# 17. 表示（期間・フィルタ適用 + 整形）。DEDUP=true のとき重複排除する。
#   対象期間の判定はここで行う。--time-source message のときは CloudWatch から
#   マージンぶん広く取得しているため、本文時刻で範囲外の行を落とすのはこの段階。
# ===========================================================================
DEDUP="false"
OUT_OF_RANGE=0         # 本文時刻が対象期間外で除外した件数（グループごとに初期化）
KEY_BUF=""             # 主要イベント（起動・停止・デプロイ）の収集先
KEY_COUNT=0
KEY_TRUNCATED=""       # 上限に達したときの注記（主要イベントシートに載せる）
readonly KEY_EVENT_MAX=5000   # 主要イベントシートの上限行数

emit_events() {
  local infile="$1"
  local mts ts ing eid ls cat kcat lvl kind emsg hay key
  local jbuf=""
  [[ "$OUTPUT" == "jsonl" ]] && jbuf="$(mktemp_tracked)"
  MATCHED=0

  # 追記先はファイル記述子として開いておく（イベント 1 件ごとに >> で開き直すと
  # 件数ぶんの open/close が発生するため）。使い終わったら必ず閉じる。
  [[ -n "$COLLECT_BUF" ]] && { exec 4>>"$COLLECT_BUF" || die "収集バッファを開けません。" "$EX_OUTPUT"; }
  [[ -n "$KEY_BUF" ]]     && { exec 5>>"$KEY_BUF"     || die "収集バッファを開けません。" "$EX_OUTPUT"; }
  [[ -n "$jbuf" ]]        && { exec 6>>"$jbuf"        || die "収集バッファを開けません。" "$EX_OUTPUT"; }

  while IFS="$US" read -r mts ts ing eid ls cat kcat lvl kind emsg; do
    emsg="${emsg%$'\r'}"
    [[ "$ts" =~ ^[0-9]+$ ]] || continue
    # 窓前進用に最大 ts を更新（フィルタ/重複に関わらず。窓は必ずイベント時刻で進める）
    if [[ -z "$MAXTS" ]] || (( ts > MAXTS )); then MAXTS="$ts"; fi

    # 重複排除（eventId 優先。無ければ ts|stream|message）
    #   複数ロググループを監視する場合に取り違えないよう、キーはグループ名で修飾する。
    if [[ "$DEDUP" == "true" ]]; then
      if [[ -n "$eid" ]]; then key="${LOG_GROUP}|${eid}"; else key="${LOG_GROUP}|${ts}|${ls}|${emsg}"; fi
      [[ -n "${SEEN[$key]:-}" ]] && continue
      SEEN[$key]="$ts"
    fi

    # 対象期間の判定（ログ本文に出力されている時刻を基準にする）
    #   監視モードには終了時刻が無いため、上限は判定しない。
    if [[ "$TIME_SOURCE" == "message" ]]; then
      if (( mts < START_MS )); then OUT_OF_RANGE=$(( OUT_OF_RANGE + 1 )); continue; fi
      if [[ "$FOLLOW" != "true" ]] && (( mts >= END_MS )); then
        OUT_OF_RANGE=$(( OUT_OF_RANGE + 1 )); continue
      fi
    fi

    # フィルタ判定
    set_singleline_space "$emsg"; hay="$SINGLELINE_STR"
    passes_filters "$hay" || continue

    MATCHED=$(( MATCHED + 1 ))
    CUR_CAT[cat]=$(( ${CUR_CAT[cat]:-0} + 1 ))
    [[ -n "$kcat" ]] && CUR_KIND[kcat]=$(( ${CUR_KIND[kcat]:-0} + 1 ))

    # Excel / 生テキストログ用のバッファへ退避する（画面出力の形式とは無関係に収集する）
    if [[ -n "$COLLECT_BUF" ]]; then
      printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' \
        "$mts" "$ts" "$ing" "$eid" "$ls" "$cat" "$kcat" "$lvl" "$kind" "$emsg" >&4
      [[ -z "$COLLECT_MIN" ]] && COLLECT_MIN="$mts"
      COLLECT_MAX="$mts"       # 入力はログ時刻の昇順のため、最後に見た値が最新になる
    fi

    # 主要イベント（デプロイ / アンデプロイ / 起動 / 停止）はブック全体で 1 枚に集約する
    if [[ -n "$KEY_BUF" && -n "$kcat" ]] && (( KEY_COUNT < KEY_EVENT_MAX )); then
      printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' \
        "$mts" "$LOG_GROUP" "$cat" "$kcat" "$kind" "$lvl" "$ls" "$emsg" >&5
      KEY_COUNT=$(( KEY_COUNT + 1 ))
    fi

    case "$OUTPUT" in
      text) format_text "$mts" "$ts" "$ing" "$ls" "$emsg" ;;
      tsv)  format_tsv  "$mts" "$ts" "$ing" "$ls" "$emsg" ;;
      jsonl) printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' \
               "$mts" "$ts" "$ing" "$eid" "$ls" "$cat" "$kcat" "$lvl" "$kind" "$emsg" >&6 ;;
      none) ;;   # 画面へは出力しない（--excel / --raw-dir 専用モード）
    esac
  done < "$infile"

  [[ -n "$COLLECT_BUF" ]] && exec 4>&-
  [[ -n "$KEY_BUF" ]]     && exec 5>&-
  [[ -n "$jbuf" ]]        && exec 6>&-

  if [[ "$OUTPUT" == "jsonl" ]]; then emit_jsonl "$jbuf"; fi
  return 0
}

# 監視中に古くなった重複排除キーを削除してメモリを抑える
prune_seen() {
  local floor="$1" k
  (( ${#SEEN[@]} )) || return 0
  for k in "${!SEEN[@]}"; do
    if (( ${SEEN[$k]} < floor )); then unset 'SEEN[$k]'; fi
  done
  return 0
}

# ===========================================================================
# 17.5 Excel 出力（ロググループごとに 1 シート）
#   xlsx: Office Open XML（ZIP + XML）を自前で組み立てる。追加ライブラリは不要で、
#         zip コマンドだけあればよい。文字列は inlineStr で書くため sharedStrings は
#         使わない（実装が単純で、ログ用途では文字列の重複も少ないため）。
#   xml : SpreadsheetML 2003（単一 XML ファイル）。zip が無い環境向けの代替。
#   共通: 時刻は Excel が日時として認識できる形で書き込むため、シート上で
#         そのままソート・オートフィルタ・書式変更ができる。
#   注意: 本節の関数はイベント 1 件ごとに呼ばれるため、サブシェル（コマンド置換）を
#         使わず printf -v で結果をグローバル変数へ返す（fork を避けて高速化する）。
# ===========================================================================
readonly XLSX_MAX_CELL=32767      # 1 セルに入る最大文字数（Excel の仕様）
readonly XLSX_MAX_ROWS=1048576    # 1 シートの最大行数（Excel の仕様）
readonly XLSX_DATA_ROW=4          # 1:ロググループ名 2:条件 3:見出し 4以降:データ
readonly XLSX_SUM_DATA_ROW=10     # サマリシートのデータ開始行

# Excel のフォント（全シート共通）。日本語のログを等幅に近い形で読みやすく、
# Windows の Excel に標準搭載されている Meiryo UI を使う。
readonly EXCEL_FONT_NAME='Meiryo UI'

# 区分ごとの配色（CAT_INFO=0 は白地・黒文字のまま）。
#   ARGB 表記（先頭 FF は不透明）。デプロイ（緑）と起動（青）を別系統の色にして、
#   アプリケーションの配備と EAP 本体の起動をひと目で区別できるようにする。
CAT_COLOR=(FF000000 FF9C0006 FF9C6500 FF006100 FF974706 FF1F4E79 FF7030A0 FF7F7F7F)
CAT_BOLD=(0        1        1        1        1        1        1        0)
CAT_FILL=(""       FFFFC7CE FFFFEB9C FFC6EFCE FFFCE4D6 FFDDEBF7 FFE4DFEC FFF2F2F2)

# cellXfs（スタイル）の番号。xlsx_write_styles の並びと必ず一致させること。
readonly STY_TITLE=1              # タイトル行
readonly STY_HEAD=2               # 見出し行
readonly STY_LABEL=3              # 項目名（太字）
readonly STY_BASE=4               # 区分ごとのスタイルの開始位置
# 区分 c のスタイル: 日時 = STY_BASE + c*4 / 文字列 +1 / 折り返し +2 / 数値 +3
readonly STY_DATE=4 STY_TEXT=5 STY_WRAP=6 STY_NUM=7   # 区分 0（通常）の各スタイル

# bash 5.2 以降、${var//pat/rep} の rep に書いた & は「マッチした文字列」へ展開される
# （5.1 以前は単なる文字）。そのため < -> &lt; のような置換は、bash の版によって
# 結果が変わってしまう（5.2 以降では "<lt;" になる）。変数に入れても回避できない。
# バージョン番号ではなく実際の挙動を 1 度だけ調べて、リテラルの & の書き方を決める。
#   ・& -> &amp; はパターンが & 自身なので、どちらの挙動でも結果は &amp; になる
#   ・それ以外は 5.2 以降だけエスケープ（\&）が必要
_probe_amp="x"
if [[ "${_probe_amp//x/&y}" == "&y" ]]; then
  readonly XML_AMP='&'      # bash 5.1 以前
else
  readonly XML_AMP='\&'     # bash 5.2 以降
fi
unset _probe_amp

# XML のテキストとして安全な文字列にする（結果は XML_ESC）。
#   メッセージ本文の C0 制御文字は取得時に jq の ctrlsafe で除去済みのため、
#   ここでは XML の特殊文字だけを処理すればよい。& を最初に処理すること。
XML_ESC=""
xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</${XML_AMP}lt;}"
  s="${s//>/${XML_AMP}gt;}"
  s="${s//\"/${XML_AMP}quot;}"
  XML_ESC="$s"
}

# epoch ミリ秒 -> Excel のシリアル値（1899-12-30 起点。JST の壁時計時刻として格納）
#   25569 = 1970-01-01 のシリアル値。小数部は 1 日を 1 とした経過割合。
#   rem * 10^9 の最大は 86399999*10^9 ≈ 8.6e16 で 64bit 整数に収まる。
EXCEL_SERIAL=""
epoch_ms_to_excel_serial() {
  local ms="$1" total days rem
  total=$(( ms + JST_OFFSET_SECONDS * 1000 ))
  days=$(( total / 86400000 )); rem=$(( total % 86400000 ))
  if (( rem < 0 )); then days=$(( days - 1 )); rem=$(( rem + 86400000 )); fi
  printf -v EXCEL_SERIAL '%d.%09d' "$(( days + 25569 ))" "$(( rem * 1000000000 / 86400000 ))"
}

# epoch ミリ秒 -> SpreadsheetML の DateTime 表記（JST の壁時計時刻）
EXCEL_ISO=""
epoch_ms_to_excel_iso() {
  local ms="$1" sec out
  sec=$(( ms / 1000 ))
  printf -v out '%(%Y-%m-%dT%H:%M:%S)T' "$sec"
  printf -v EXCEL_ISO '%s.%03d' "$out" "$(( ms % 1000 ))"
}

# 収集済み（エスケープ済み）メッセージを Excel のセル値へ変換する（結果は EXCEL_CELL）
#   --single-line 指定時は \n 等を可視文字のまま 1 行で入れる。
#   通常は実際の改行へ戻し、セル内改行（折り返し表示）として見えるようにする。
EXCEL_CELL=""
excel_cell_message() {
  local emsg="$1" s
  if [[ "$SINGLE_LINE" == "true" ]]; then
    s="$emsg"
  else
    decode_msg "$emsg"
    s="${DECODED//$'\r'/}"    # セル内改行は LF のみ。CR は取り除く
  fi
  if (( ${#s} > XLSX_MAX_CELL )); then
    s="${s:0:XLSX_MAX_CELL-16}…(以下省略)"
  fi
  EXCEL_CELL="$s"
}

# シート名を作る。Excel の制約: 31 文字以内 / : \ / ? * [ ] 不可 / 重複不可。
#   ロググループ名は先頭が共通しがち（/aws/lambda/... 等）なので、31 文字を超える
#   場合は識別に有用な末尾側を残す。完全なロググループ名は各シートの 1 行目と
#   サマリシートに記録するため、切り詰めても対応関係は追える。
#   結果は XLSX_SHEET_NAME に返す。コマンド置換で呼ぶとサブシェルになり、
#   使用済みシート名の記録（XLSX_SHEET_USED）が呼び出し元へ残らず、
#   同名シートを持つ壊れたブックを作ってしまうため、必ず直接呼ぶこと。
declare -A XLSX_SHEET_USED=()
XLSX_SHEET_NAME=""
xlsx_sheet_name() {
  local n="$1" base suffix i
  n="${n//:/_}"; n="${n//\\/_}"; n="${n//\//_}"
  n="${n//\?/_}"; n="${n//\*/_}"; n="${n//\[/_}"; n="${n//\]/_}"
  n="${n//$'\t'/_}"; n="${n//$'\n'/_}"
  [[ -z "$n" ]] && n="sheet"
  (( ${#n} > 31 )) && n="${n: -31}"
  [[ "${n:0:1}" == "'" ]] && n="_${n:1}"
  [[ "${n: -1}" == "'" ]] && n="${n:0:${#n}-1}_"
  [[ "${n,,}" == "history" ]] && n="History_"     # Excel の予約シート名
  if [[ -n "${XLSX_SHEET_USED[${n,,}]:-}" ]]; then
    for (( i = 2; i <= 999; i++ )); do
      suffix="~${i}"                              # ~ は変数代入の右辺でもチルダ展開されない
      base="$n"
      (( ${#base} + ${#suffix} > 31 )) && base="${base:0:$(( 31 - ${#suffix} ))}"
      if [[ -z "${XLSX_SHEET_USED[${base,,}${suffix,,}]:-}" ]]; then n="${base}${suffix}"; break; fi
    done
  fi
  XLSX_SHEET_USED["${n,,}"]=1
  XLSX_SHEET_NAME="$n"
}

# サマリ・各シートの見出しに載せる抽出条件の説明
excel_condition_text() {
  local t
  if [[ -n "$CW_PATTERN" ]]; then
    t="フィルタ(cloudwatch): ${CW_PATTERN}"
  elif (( ${#FILTERS[@]} )); then
    t="フィルタ(${FILTER_MODE}/${FILTER_LOGIC}): ${FILTERS[*]}"
  else
    t="フィルタ: なし"
  fi
  (( ${#EXCLUDES[@]} )) && t+=" / 除外: ${EXCLUDES[*]}"
  [[ "$IGNORE_CASE" == "true" ]] && t+=" / 大文字小文字を区別しない"
  [[ -n "$LOG_STREAM" ]] && t+=" / ログストリーム: ${LOG_STREAM}"
  [[ -n "$LOG_STREAM_PREFIX" ]] && t+=" / ログストリーム接頭辞: ${LOG_STREAM_PREFIX}"
  printf '%s' "$t"
}

# 生テキストログの出力先の説明（Excel の見出しに載せる）
excel_rawdir_text() {
  if [[ "$RAW_ENABLED" == "true" ]]; then
    printf 'ロググループ × ログストリームごとに出力: %s （対応表: %s）' "$RAW_DIR" "$RAW_INDEX_NAME"
  else
    printf '出力していません'
  fi
}

# 期間の判定に何を使ったかの説明（Excel の見出しに載せる）
excel_timesource_text() {
  if [[ "$TIME_SOURCE" == "message" ]]; then
    printf 'ログ本文に出力されている時刻（本文に時刻が無い行は CloudWatch のイベント時刻）/ 取得マージン %s 分' \
      "$TIME_MARGIN_MINUTES"
  else
    printf 'CloudWatch のイベント時刻'
  fi
}

# 収集結果を Excel ファイルへ書き出す（形式は EXCEL_FORMAT に従う）
XLSX_SHEET_NAMES=()
KEY_SORTED=""          # 主要イベントを時刻順に並べ替えたファイル
excel_write() {
  local i n=${#GRP_NAMES[@]}
  if (( n == 0 )); then
    log_warn "Excel へ書き出す対象のロググループがありません。ファイルは作成しません。"
    return 0
  fi

  # XLSX_SHEET_USED は宣言時に空。excel_write は 1 回しか呼ばれないため再初期化しない
  # （連想配列への arr=() 代入は bash の版によって属性が落ちることがあるため避ける）
  XLSX_SHEET_NAMES=()
  for (( i = 0; i < n; i++ )); do
    xlsx_sheet_name "${GRP_NAMES[i]}"     # コマンド置換にしないこと（上の注記参照）
    XLSX_SHEET_NAMES+=("$XLSX_SHEET_NAME")
  done

  # 主要イベントはロググループを横断して時刻順に並べる（複数系統の前後関係を追うため）
  KEY_SORTED="$(mktemp_tracked)"
  if [[ -n "$KEY_BUF" && -s "$KEY_BUF" ]]; then
    LC_ALL=C sort -s -t"$US" -k1,1n "$KEY_BUF" > "$KEY_SORTED" \
      || die "主要イベントの並べ替えに失敗しました。" "$EX_OUTPUT"
  else
    : > "$KEY_SORTED"
  fi

  log_info "Excel ファイルを作成しています（サマリ + 主要イベント + ${n} シート, 形式 ${EXCEL_FORMAT}）: ${EXCEL_FILE}"
  if [[ "$EXCEL_FORMAT" == "xml" ]]; then
    excel_write_spreadsheetml
  else
    excel_write_xlsx
  fi

  local total=0
  for (( i = 0; i < n; i++ )); do total=$(( total + GRP_MATCHED[i] )); done
  log_success "Excel ファイルを作成しました: ${EXCEL_FILE}（${n} ロググループ / 合計 ${total} 行）"
  for (( i = 0; i < n; i++ )); do
    log_info "$(printf '    [%s] %s  %d 行' "${XLSX_SHEET_NAMES[i]}" "${GRP_NAMES[i]}" "${GRP_MATCHED[i]}")"
  done
  (( KEY_COUNT > 0 )) && log_info "    [主要イベント] 起動・停止・デプロイ等  ${KEY_COUNT} 行"
  return 0
}

# ---------------------------------------------------------------------------
# xlsx（Office Open XML）
# ---------------------------------------------------------------------------
# スタイル定義を組み立てて書き出す。
#   固定の文字列を貼り付けるのではなくループで生成するのは、区分（CAT_*）を
#   増減しても fonts / fills / cellXfs の番号がずれないようにするため。
#   cellXfs の並び（この番号を各セルの s= 属性に書く）:
#     0 既定 / 1 タイトル / 2 見出し / 3 ラベル(太字)
#     4 + 区分*4 + 0 日時 / +1 文字列 / +2 折り返し文字列 / +3 数値(右寄せ)
xlsx_write_styles() {
  local out="$1" c fill bold
  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    printf '%s' '<numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy\-mm\-dd\ hh:mm:ss.000"/></numFmts>'

    # フォント: 0 通常 / 1 太字 / 2 タイトル / 3+区分 区分ごとの文字色
    printf '<fonts count="%d">' "$(( 3 + CAT_N ))"
    printf '<font><sz val="11"/><color rgb="FF000000"/><name val="%s"/></font>' "$EXCEL_FONT_NAME"
    printf '<font><b/><sz val="11"/><color rgb="FF000000"/><name val="%s"/></font>' "$EXCEL_FONT_NAME"
    printf '<font><b/><sz val="12"/><color rgb="FF1F3864"/><name val="%s"/></font>' "$EXCEL_FONT_NAME"
    for (( c = 0; c < CAT_N; c++ )); do
      bold=""; (( CAT_BOLD[c] )) && bold='<b/>'
      printf '<font>%s<sz val="11"/><color rgb="%s"/><name val="%s"/></font>' \
        "$bold" "${CAT_COLOR[c]}" "$EXCEL_FONT_NAME"
    done
    printf '%s' '</fonts>'

    # 塗り: 0 なし / 1 gray125（Excel が 2 番目を予約） / 2 見出し / 3.. 区分ごと
    #   区分 0（通常）は塗らないため、区分 c の塗り番号は c==0 ? 0 : c+2
    printf '<fills count="%d">' "$(( 2 + CAT_N ))"
    printf '%s' '<fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
    printf '<fill><patternFill patternType="solid"><fgColor rgb="FFDCE6F1"/><bgColor indexed="64"/></patternFill></fill>'
    for (( c = 1; c < CAT_N; c++ )); do
      printf '<fill><patternFill patternType="solid"><fgColor rgb="%s"/><bgColor indexed="64"/></patternFill></fill>' "${CAT_FILL[c]}"
    done
    printf '%s' '</fills>'

    printf '%s' '<borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style="thin"><color rgb="FFBFBFBF"/></left><right style="thin"><color rgb="FFBFBFBF"/></right><top style="thin"><color rgb="FFBFBFBF"/></top><bottom style="thin"><color rgb="FFBFBFBF"/></bottom><diagonal/></border></borders>'
    printf '%s' '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'

    printf '<cellXfs count="%d">' "$(( 4 + CAT_N * 4 ))"
    printf '%s' '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    printf '%s' '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
    printf '%s' '<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf>'
    printf '%s' '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
    for (( c = 0; c < CAT_N; c++ )); do
      fill=0; (( c > 0 )) && fill=$(( c + 2 ))
      printf '<xf numFmtId="164" fontId="%d" fillId="%d" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top"/></xf>' "$(( 3 + c ))" "$fill"
      printf '<xf numFmtId="0" fontId="%d" fillId="%d" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top"/></xf>' "$(( 3 + c ))" "$fill"
      printf '<xf numFmtId="0" fontId="%d" fillId="%d" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>' "$(( 3 + c ))" "$fill"
      printf '<xf numFmtId="0" fontId="%d" fillId="%d" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="right" vertical="top"/></xf>' "$(( 3 + c ))" "$fill"
    done
    printf '%s' '</cellXfs>'
    printf '%s' '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'
  } > "$out"
}

# インライン文字列セル（s=スタイルID）
xlsx_cell_str() { xml_escape "$3"; printf '<c r="%s" s="%s" t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>' "$1" "$2" "$XML_ESC"; }
xlsx_cell_num() { printf '<c r="%s" s="%s"><v>%s</v></c>' "$1" "$2" "$3"; }

xlsx_write_summary_sheet() {
  local out="$1" n=${#GRP_NAMES[@]} i r b cond now
  local hrow=$(( XLSX_SUM_DATA_ROW - 1 ))
  local last=$(( XLSX_SUM_DATA_ROW + n - 1 ))
  (( last < XLSX_SUM_DATA_ROW )) && last=$XLSX_SUM_DATA_ROW
  # 件数のセルも区分の色で塗り、どのロググループを見るべきかを一目で分かるようにする
  #   （--no-highlight のときは他のシートと同じく色を付けない）
  local sERR=$STY_NUM sWRN=$STY_NUM sDEP=$STY_NUM sUND=$STY_NUM sSTA=$STY_NUM sSTP=$STY_NUM
  if [[ "$HIGHLIGHT" == "true" ]]; then
    sERR=$(( STY_BASE + CAT_ERROR    * 4 + 3 )); sWRN=$(( STY_BASE + CAT_WARN     * 4 + 3 ))
    sDEP=$(( STY_BASE + CAT_DEPLOY   * 4 + 3 )); sUND=$(( STY_BASE + CAT_UNDEPLOY * 4 + 3 ))
    sSTA=$(( STY_BASE + CAT_START    * 4 + 3 )); sSTP=$(( STY_BASE + CAT_STOP     * 4 + 3 ))
  fi
  cond="$(excel_condition_text)"
  printf -v now '%(%Y-%m-%d %H:%M:%S)T' -1
  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    printf '<dimension ref="A1:O%d"/>' "$last"
    printf '<sheetViews><sheetView tabSelected="1" workbookViewId="0"><pane ySplit="%d" topLeftCell="A%d" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A%d" sqref="A%d"/></sheetView></sheetViews>' \
      "$hrow" "$XLSX_SUM_DATA_ROW" "$XLSX_SUM_DATA_ROW" "$XLSX_SUM_DATA_ROW"
    printf '%s' '<sheetFormatPr defaultRowHeight="15"/>'
    printf '%s' '<cols><col min="1" max="1" width="5" customWidth="1"/><col min="2" max="2" width="46" customWidth="1"/><col min="3" max="3" width="24" customWidth="1"/><col min="4" max="6" width="9" customWidth="1"/><col min="7" max="12" width="8" customWidth="1"/><col min="13" max="14" width="23" customWidth="1"/><col min="15" max="15" width="9" customWidth="1"/></cols>'
    printf '%s' '<sheetData>'
    printf '<row r="1">%s</row>' "$(xlsx_cell_str A1 "$STY_TITLE" 'CloudWatch Logs 抽出結果')"
    printf '<row r="2">%s%s</row>' "$(xlsx_cell_str A2 "$STY_LABEL" '出力日時')"   "$(xlsx_cell_str B2 0 "${now} JST")"
    printf '<row r="3">%s%s</row>' "$(xlsx_cell_str A3 "$STY_LABEL" '対象期間')"   "$(xlsx_cell_str B3 0 "$(epoch_ms_to_jst "$START_MS")  〜  $(epoch_ms_to_jst "$(( END_MS - 1 ))")")"
    printf '<row r="4">%s%s</row>' "$(xlsx_cell_str A4 "$STY_LABEL" '期間の判定')" "$(xlsx_cell_str B4 0 "$(excel_timesource_text)")"
    printf '<row r="5">%s%s</row>' "$(xlsx_cell_str A5 "$STY_LABEL" 'AWS')"        "$(xlsx_cell_str B5 0 "アカウント: ${CALLER_ACCOUNT:-(不明)} / プロファイル: ${AWS_PROFILE_OPT:-${AWS_PROFILE:-(既定)}} / リージョン: ${AWS_REGION_OPT:-${AWS_REGION:-${AWS_DEFAULT_REGION:-(既定)}}}")"
    printf '<row r="6">%s%s</row>' "$(xlsx_cell_str A6 "$STY_LABEL" '抽出条件')"   "$(xlsx_cell_str B6 0 "$cond")"
    printf '<row r="7">%s%s</row>' "$(xlsx_cell_str A7 "$STY_LABEL" '取得上限')"   "$(xlsx_cell_str B7 0 "ロググループごとに最大 ${MAX_EVENTS} 件")"
    printf '<row r="8">%s%s</row>' "$(xlsx_cell_str A8 "$STY_LABEL" '生ログ')"     "$(xlsx_cell_str B8 0 "$(excel_rawdir_text)")"
    printf '<row r="%d">%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s</row>' "$hrow" \
      "$(xlsx_cell_str "A${hrow}" "$STY_HEAD" 'No')"          "$(xlsx_cell_str "B${hrow}" "$STY_HEAD" 'ロググループ')" \
      "$(xlsx_cell_str "C${hrow}" "$STY_HEAD" 'シート名')"    "$(xlsx_cell_str "D${hrow}" "$STY_HEAD" '取得')" \
      "$(xlsx_cell_str "E${hrow}" "$STY_HEAD" '期間外')"      "$(xlsx_cell_str "F${hrow}" "$STY_HEAD" '出力')" \
      "$(xlsx_cell_str "G${hrow}" "$STY_HEAD" 'エラー')"      "$(xlsx_cell_str "H${hrow}" "$STY_HEAD" '警告')" \
      "$(xlsx_cell_str "I${hrow}" "$STY_HEAD" 'デプロイ')"    "$(xlsx_cell_str "J${hrow}" "$STY_HEAD" 'アンデプロイ')" \
      "$(xlsx_cell_str "K${hrow}" "$STY_HEAD" '起動')"        "$(xlsx_cell_str "L${hrow}" "$STY_HEAD" '停止')" \
      "$(xlsx_cell_str "M${hrow}" "$STY_HEAD" '最古(JST)')"   "$(xlsx_cell_str "N${hrow}" "$STY_HEAD" '最新(JST)')" \
      "$(xlsx_cell_str "O${hrow}" "$STY_HEAD" '生ログ数')"
    for (( i = 0; i < n; i++ )); do
      r=$(( XLSX_SUM_DATA_ROW + i ))
      b=$(( i * CAT_N ))
      printf '<row r="%d">' "$r"
      xlsx_cell_num "A${r}" "$STY_NUM"  "$(( i + 1 ))"
      xlsx_cell_str "B${r}" "$STY_TEXT" "${GRP_NAMES[i]}"
      xlsx_cell_str "C${r}" "$STY_TEXT" "${XLSX_SHEET_NAMES[i]}"
      xlsx_cell_num "D${r}" "$STY_NUM"  "${GRP_FETCHED[i]}"
      xlsx_cell_num "E${r}" "$STY_NUM"  "${GRP_OUTRANGE[i]}"
      xlsx_cell_num "F${r}" "$STY_NUM"  "${GRP_MATCHED[i]}"
      xlsx_cell_num "G${r}" "$sERR" "${GRP_CAT[b + CAT_ERROR]}"
      xlsx_cell_num "H${r}" "$sWRN" "${GRP_CAT[b + CAT_WARN]}"
      xlsx_cell_num "I${r}" "$sDEP" "${GRP_KIND[b + CAT_DEPLOY]}"
      xlsx_cell_num "J${r}" "$sUND" "${GRP_KIND[b + CAT_UNDEPLOY]}"
      xlsx_cell_num "K${r}" "$sSTA" "${GRP_KIND[b + CAT_START]}"
      xlsx_cell_num "L${r}" "$sSTP" "${GRP_KIND[b + CAT_STOP]}"
      if [[ -n "${GRP_MINTS[i]}" ]]; then
        epoch_ms_to_excel_serial "${GRP_MINTS[i]}"; xlsx_cell_num "M${r}" "$STY_DATE" "$EXCEL_SERIAL"
        epoch_ms_to_excel_serial "${GRP_MAXTS[i]}"; xlsx_cell_num "N${r}" "$STY_DATE" "$EXCEL_SERIAL"
      else
        xlsx_cell_str "M${r}" "$STY_TEXT" '-'; xlsx_cell_str "N${r}" "$STY_TEXT" '-'
      fi
      xlsx_cell_num "O${r}" "$STY_NUM" "${GRP_RAWFILES[i]}"
      printf '%s' '</row>'
    done
    printf '%s' '</sheetData>'
    printf '<autoFilter ref="A%d:O%d"/>' "$hrow" "$last"
    printf '%s' '</worksheet>'
  } > "$out"
}

# 主要イベント（デプロイ / アンデプロイ / 起動 / 停止）をロググループ横断で 1 枚にまとめる。
#   アプリケーションの配備とサーバー本体の起動・停止は運用上の観点が違うため、
#   本文全体を追わなくても「いつ・どの系統で・何が起きたか」だけを追える表を用意する。
xlsx_write_key_sheet() {
  local out="$1" rowsf="$2"
  local mts group cat kcat kind lvl ls emsg row msg stream grp
  local r=$XLSX_DATA_ROW last sd stx sw

  : > "$rowsf"
  if [[ -s "$KEY_SORTED" ]]; then
    {
      while IFS="$US" read -r mts group cat kcat kind lvl ls emsg; do
        emsg="${emsg%$'\r'}"
        [[ "$mts" =~ ^-?[0-9]+$ ]] || continue
        (( r >= XLSX_MAX_ROWS )) && break
        # 色は区分（デプロイ等）を基本にしつつ、エラー・警告があればそちらを優先する
        [[ "$HIGHLIGHT" == "true" ]] || cat=$CAT_INFO
        sd=$(( STY_BASE + cat * 4 )); stx=$(( sd + 1 )); sw=$(( sd + 2 ))
        xml_escape "$group";  grp="$XML_ESC"
        xml_escape "$ls";     stream="$XML_ESC"
        xml_escape "$kind";   kind="$XML_ESC"
        xml_escape "$lvl";    lvl="$XML_ESC"
        excel_cell_message "$emsg"; xml_escape "$EXCEL_CELL"; msg="$XML_ESC"
        epoch_ms_to_excel_serial "$mts"
        row="<row r=\"${r}\"><c r=\"A${r}\" s=\"${sd}\"><v>${EXCEL_SERIAL}</v></c>"
        row+="<c r=\"B${r}\" s=\"${stx}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">${grp}</t></is></c>"
        row+="<c r=\"C${r}\" s=\"${stx}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">${kind}</t></is></c>"
        row+="<c r=\"D${r}\" s=\"${stx}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">${lvl}</t></is></c>"
        row+="<c r=\"E${r}\" s=\"${stx}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">${stream}</t></is></c>"
        row+="<c r=\"F${r}\" s=\"${sw}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">${msg}</t></is></c></row>"
        printf '%s\n' "$row"
        r=$(( r + 1 ))
      done < "$KEY_SORTED"
    } > "$rowsf"
  fi
  last=$(( r - 1 ))

  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    printf '<dimension ref="A1:F%d"/>' "$last"
    printf '%s' '<sheetViews><sheetView workbookViewId="0"><pane ySplit="3" topLeftCell="A4" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A4" sqref="A4"/></sheetView></sheetViews>'
    printf '%s' '<sheetFormatPr defaultRowHeight="15"/>'
    printf '%s' '<cols><col min="1" max="1" width="23" customWidth="1"/><col min="2" max="2" width="40" customWidth="1"/><col min="3" max="3" width="14" customWidth="1"/><col min="4" max="4" width="9" customWidth="1"/><col min="5" max="5" width="28" customWidth="1"/><col min="6" max="6" width="100" customWidth="1"/></cols>'
    printf '%s' '<sheetData>'
    printf '<row r="1">%s</row>' "$(xlsx_cell_str A1 "$STY_TITLE" '主要イベント（アプリケーションのデプロイ / JBoss EAP の起動・停止）')"
    printf '<row r="2">%s</row>' "$(xlsx_cell_str A2 0 "デプロイ（緑）はアプリケーションの配備、起動（青）・停止（紫）は EAP 本体の状態変化です。ロググループを横断して時刻順に並べています。${KEY_TRUNCATED}")"
    printf '<row r="3">%s%s%s%s%s%s</row>' \
      "$(xlsx_cell_str A3 "$STY_HEAD" '時刻(JST)')"      "$(xlsx_cell_str B3 "$STY_HEAD" 'ロググループ')" \
      "$(xlsx_cell_str C3 "$STY_HEAD" '区分')"           "$(xlsx_cell_str D3 "$STY_HEAD" 'レベル')" \
      "$(xlsx_cell_str E3 "$STY_HEAD" 'ログストリーム')" "$(xlsx_cell_str F3 "$STY_HEAD" 'メッセージ')"
    cat "$rowsf"
    printf '%s' '</sheetData>'
    printf '<autoFilter ref="A3:F%d"/>' "$last"
    printf '%s' '</worksheet>'
  } > "$out"
  return 0
}

xlsx_write_data_sheet() {
  local out="$1" idx="$2" rowsf="$3"
  local group="${GRP_NAMES[idx]}" src="${GRP_FILES[idx]}"
  local mts ts ing eid ls cat kcat lvl kind emsg
  local row stream msg r=$XLSX_DATA_ROW truncated="false" info last sd stx sw sn

  # イベント 1 件ごとのループなので、ここではコマンド置換（$(...)）を一切使わずに
  # 文字列連結だけで行を組み立てる。$(...) は 1 回ごとに fork するため、
  # 数千件のログでは処理時間が桁違いに悪化する。
  : > "$rowsf"
  if [[ -s "$src" ]]; then
    {
      while IFS="$US" read -r mts ts ing eid ls cat kcat lvl kind emsg; do
        emsg="${emsg%$'\r'}"
        [[ "$mts" =~ ^-?[0-9]+$ ]] || continue
        if (( r >= XLSX_MAX_ROWS )); then truncated="true"; break; fi
        [[ "$HIGHLIGHT" == "true" ]] || cat=$CAT_INFO
        sd=$(( STY_BASE + cat * 4 )); stx=$(( sd + 1 )); sw=$(( sd + 2 )); sn=$(( sd + 3 ))
        xml_escape "$ls";   stream="$XML_ESC"
        xml_escape "$kind"; kind="$XML_ESC"
        xml_escape "$lvl";  lvl="$XML_ESC"
        excel_cell_message "$emsg"; xml_escape "$EXCEL_CELL"; msg="$XML_ESC"
        epoch_ms_to_excel_serial "$mts"
        row="<row r=\"${r}\"><c r=\"A${r}\" s=\"${sd}\"><v>${EXCEL_SERIAL}</v></c>"
        row+="<c r=\"B${r}\" s=\"${stx}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">${kind}</t></is></c>"
        row+="<c r=\"C${r}\" s=\"${stx}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">${lvl}</t></is></c>"
        row+="<c r=\"D${r}\" s=\"${stx}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">${stream}</t></is></c>"
        row+="<c r=\"E${r}\" s=\"${sw}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">${msg}</t></is></c>"
        epoch_ms_to_excel_serial "$ts"
        row+="<c r=\"F${r}\" s=\"${sd}\"><v>${EXCEL_SERIAL}</v></c>"
        row+="<c r=\"G${r}\" s=\"${sn}\"><v>${ts}</v></c></row>"
        printf '%s\n' "$row"
        r=$(( r + 1 ))
      done < "$src"
    } > "$rowsf"
  fi
  [[ "$truncated" == "true" ]] && log_warn "Excel の最大行数を超えたため、途中で打ち切りました: ${group}"

  # データが 0 件なら見出し行（3 行目）が最終行。参照範囲を実在する行に合わせる
  last=$(( r - 1 ))
  info="期間(JST): $(epoch_ms_to_jst "$START_MS")  〜  $(epoch_ms_to_jst "$(( END_MS - 1 ))")"
  info+="  /  取得 ${GRP_FETCHED[idx]} 件  /  期間外 ${GRP_OUTRANGE[idx]} 件  /  出力 ${GRP_MATCHED[idx]} 件"
  info+="  /  $(excel_condition_text)"

  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    printf '<dimension ref="A1:G%d"/>' "$last"
    printf '%s' '<sheetViews><sheetView workbookViewId="0"><pane ySplit="3" topLeftCell="A4" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A4" sqref="A4"/></sheetView></sheetViews>'
    printf '%s' '<sheetFormatPr defaultRowHeight="15"/>'
    printf '%s' '<cols><col min="1" max="1" width="23" customWidth="1"/><col min="2" max="2" width="14" customWidth="1"/><col min="3" max="3" width="9" customWidth="1"/><col min="4" max="4" width="30" customWidth="1"/><col min="5" max="5" width="110" customWidth="1"/><col min="6" max="6" width="23" customWidth="1"/><col min="7" max="7" width="16" customWidth="1"/></cols>'
    printf '%s' '<sheetData>'
    printf '<row r="1">%s</row>' "$(xlsx_cell_str A1 "$STY_TITLE" "ロググループ: ${group}")"
    printf '<row r="2">%s</row>' "$(xlsx_cell_str A2 0 "$info")"
    printf '<row r="3">%s%s%s%s%s%s%s</row>' \
      "$(xlsx_cell_str A3 "$STY_HEAD" '時刻(JST)')"      "$(xlsx_cell_str B3 "$STY_HEAD" '区分')" \
      "$(xlsx_cell_str C3 "$STY_HEAD" 'レベル')"         "$(xlsx_cell_str D3 "$STY_HEAD" 'ログストリーム')" \
      "$(xlsx_cell_str E3 "$STY_HEAD" 'メッセージ')"     "$(xlsx_cell_str F3 "$STY_HEAD" 'イベント時刻(JST)')" \
      "$(xlsx_cell_str G3 "$STY_HEAD" 'timestamp(ms)')"
    cat "$rowsf"
    printf '%s' '</sheetData>'
    printf '<autoFilter ref="A3:G%d"/>' "$last"
    printf '%s' '</worksheet>'
  } > "$out"
  return 0
}

excel_write_xlsx() {
  # シート構成: 1 サマリ / 2 主要イベント / 3 以降 ロググループごと
  local dir rowsf i n=${#GRP_NAMES[@]} sheets=$(( ${#GRP_NAMES[@]} + 2 )) abs zrc=0

  dir="$(mktempdir_tracked)"
  mkdir -p "$dir/_rels" "$dir/xl/_rels" "$dir/xl/worksheets" \
    || die "Excel 用の一時ディレクトリを作成できませんでした。" "$EX_OUTPUT"

  # [Content_Types].xml
  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    printf '%s' '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    printf '%s' '<Default Extension="xml" ContentType="application/xml"/>'
    printf '%s' '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    printf '%s' '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    for (( i = 1; i <= sheets; i++ )); do
      printf '<Override PartName="/xl/worksheets/sheet%d.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' "$i"
    done
    printf '%s' '</Types>'
  } > "$dir/[Content_Types].xml"

  # パッケージ関係定義
  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    printf '%s' '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
    printf '%s' '</Relationships>'
  } > "$dir/_rels/.rels"

  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    for (( i = 1; i <= sheets; i++ )); do
      printf '<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet%d.xml"/>' "$i" "$i"
    done
    printf '<Relationship Id="rId%d" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' "$(( sheets + 1 ))"
    printf '%s' '</Relationships>'
  } > "$dir/xl/_rels/workbook.xml.rels"

  # ブック定義（シート順: サマリ -> 指定順のロググループ）
  {
    printf '%s' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    printf '%s' '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    printf '%s' '<sheets>'
    xml_escape 'サマリ';       printf '<sheet name="%s" sheetId="1" r:id="rId1"/>' "$XML_ESC"
    xml_escape '主要イベント'; printf '<sheet name="%s" sheetId="2" r:id="rId2"/>' "$XML_ESC"
    for (( i = 0; i < n; i++ )); do
      xml_escape "${XLSX_SHEET_NAMES[i]}"
      printf '<sheet name="%s" sheetId="%d" r:id="rId%d"/>' "$XML_ESC" "$(( i + 3 ))" "$(( i + 3 ))"
    done
    printf '%s' '</sheets></workbook>'
  } > "$dir/xl/workbook.xml"

  xlsx_write_styles "$dir/xl/styles.xml"
  xlsx_write_summary_sheet "$dir/xl/worksheets/sheet1.xml"

  rowsf="$(mktemp_tracked)"
  xlsx_write_key_sheet "$dir/xl/worksheets/sheet2.xml" "$rowsf"
  for (( i = 0; i < n; i++ )); do
    xlsx_write_data_sheet "$dir/xl/worksheets/sheet$(( i + 3 )).xml" "$i" "$rowsf"
  done

  # zip は作業ディレクトリを移動して実行するため、出力先を絶対パスへ直す
  case "$EXCEL_FILE" in
    /*) abs="$EXCEL_FILE" ;;
    *)  abs="${PWD}/${EXCEL_FILE}" ;;
  esac
  # zip は既存アーカイブへ「追加」するため、必ず消してから作り直す
  rm -f -- "$abs"
  # -X: 余分な属性を入れない / -D: ディレクトリエントリを作らない
  # -nw: ワイルドカード展開を無効化（[Content_Types].xml を文字クラスと解釈させない）
  ( cd "$dir" && zip -q -X -D -nw "$abs" '[Content_Types].xml' \
                && zip -q -X -D -nw -r "$abs" _rels xl ) || zrc=$?
  (( zrc == 0 )) || die "zip による xlsx の作成に失敗しました（終了コード ${zrc}）: ${EXCEL_FILE}" "$EX_OUTPUT"
  [[ -s "$abs" ]] || die "xlsx ファイルを作成できませんでした: ${EXCEL_FILE}" "$EX_OUTPUT"
  return 0
}

# ---------------------------------------------------------------------------
# SpreadsheetML 2003（単一 XML。zip コマンドが無い環境向け）
# ---------------------------------------------------------------------------
sml_cell_str()  { xml_escape "$2"; printf '<Cell ss:StyleID="%s"><Data ss:Type="String">%s</Data></Cell>' "$1" "$XML_ESC"; }
sml_cell_num()  { printf '<Cell ss:StyleID="%s"><Data ss:Type="Number">%s</Data></Cell>' "$1" "$2"; }
sml_cell_date() { printf '<Cell ss:StyleID="%s"><Data ss:Type="DateTime">%s</Data></Cell>' "$1" "$2"; }

# 区分ごとのスタイル定義を書き出す（xlsx の cellXfs に相当）。
#   ID は sd<区分> 日時 / st<区分> 文字列 / sw<区分> 折り返し / sn<区分> 数値。
sml_write_cat_styles() {
  local c bold fill
  for (( c = 0; c < CAT_N; c++ )); do
    bold=""; (( CAT_BOLD[c] )) && bold=' ss:Bold="1"'
    fill=""
    # SpreadsheetML の色指定は #RRGGBB。ARGB の先頭 2 桁（不透明度）を落とす
    [[ -n "${CAT_FILL[c]}" ]] && fill="<Interior ss:Color=\"#${CAT_FILL[c]:2}\" ss:Pattern=\"Solid\"/>"
    printf '<Style ss:ID="sd%d"><NumberFormat ss:Format="yyyy\\-mm\\-dd\\ hh:mm:ss.000"/><Alignment ss:Vertical="Top"/><Font ss:FontName="%s" ss:Size="11"%s ss:Color="#%s"/>%s</Style>\n' \
      "$c" "$EXCEL_FONT_NAME" "$bold" "${CAT_COLOR[c]:2}" "$fill"
    printf '<Style ss:ID="st%d"><Alignment ss:Vertical="Top"/><Font ss:FontName="%s" ss:Size="11"%s ss:Color="#%s"/>%s</Style>\n' \
      "$c" "$EXCEL_FONT_NAME" "$bold" "${CAT_COLOR[c]:2}" "$fill"
    printf '<Style ss:ID="sw%d"><Alignment ss:Vertical="Top" ss:WrapText="1"/><Font ss:FontName="%s" ss:Size="11"%s ss:Color="#%s"/>%s</Style>\n' \
      "$c" "$EXCEL_FONT_NAME" "$bold" "${CAT_COLOR[c]:2}" "$fill"
    printf '<Style ss:ID="sn%d"><Alignment ss:Vertical="Top" ss:Horizontal="Right"/><Font ss:FontName="%s" ss:Size="11"%s ss:Color="#%s"/>%s</Style>\n' \
      "$c" "$EXCEL_FONT_NAME" "$bold" "${CAT_COLOR[c]:2}" "$fill"
  done
}

excel_write_spreadsheetml() {
  local n=${#GRP_NAMES[@]} i b r cond now group info
  local mts ts ing eid ls cat kcat lvl kind emsg
  # サマリの件数セルの色（--no-highlight のときは色を付けない）
  local cERR=0 cWRN=0 cDEP=0 cUND=0 cSTA=0 cSTP=0
  if [[ "$HIGHLIGHT" == "true" ]]; then
    cERR=$CAT_ERROR; cWRN=$CAT_WARN; cDEP=$CAT_DEPLOY
    cUND=$CAT_UNDEPLOY; cSTA=$CAT_START; cSTP=$CAT_STOP
  fi

  cond="$(excel_condition_text)"
  printf -v now '%(%Y-%m-%d %H:%M:%S)T' -1

  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<?mso-application progid="Excel.Sheet"?>'
    printf '%s\n' '<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:x="urn:schemas-microsoft-com:office:excel" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">'
    printf '%s\n' '<Styles>'
    printf '<Style ss:ID="Default" ss:Name="Normal"><Alignment ss:Vertical="Top"/><Font ss:FontName="%s" ss:Size="11"/></Style>\n' "$EXCEL_FONT_NAME"
    printf '<Style ss:ID="sTitle"><Font ss:FontName="%s" ss:Size="12" ss:Bold="1" ss:Color="#1F3864"/></Style>\n' "$EXCEL_FONT_NAME"
    printf '<Style ss:ID="sLabel"><Font ss:FontName="%s" ss:Size="11" ss:Bold="1"/></Style>\n' "$EXCEL_FONT_NAME"
    printf '<Style ss:ID="sHead"><Font ss:FontName="%s" ss:Size="11" ss:Bold="1"/><Interior ss:Color="#DCE6F1" ss:Pattern="Solid"/><Alignment ss:Horizontal="Center" ss:Vertical="Center"/><Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#BFBFBF"/><Border ss:Position="Top" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#BFBFBF"/><Border ss:Position="Left" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#BFBFBF"/><Border ss:Position="Right" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#BFBFBF"/></Borders></Style>\n' "$EXCEL_FONT_NAME"
    sml_write_cat_styles
    printf '%s\n' '</Styles>'

    # --- サマリシート ---
    xml_escape 'サマリ'
    printf '<Worksheet ss:Name="%s"><Table>' "$XML_ESC"
    printf '%s' '<Column ss:Width="34"/><Column ss:Width="300"/><Column ss:Width="150"/><Column ss:Width="56"/><Column ss:Width="56"/><Column ss:Width="56"/><Column ss:Width="52"/><Column ss:Width="52"/><Column ss:Width="60"/><Column ss:Width="72"/><Column ss:Width="52"/><Column ss:Width="52"/><Column ss:Width="150"/><Column ss:Width="150"/><Column ss:Width="60"/>'
    printf '<Row>%s</Row>' "$(sml_cell_str sTitle 'CloudWatch Logs 抽出結果')"
    printf '<Row>%s%s</Row>' "$(sml_cell_str sLabel '出力日時')"   "$(sml_cell_str st0 "${now} JST")"
    printf '<Row>%s%s</Row>' "$(sml_cell_str sLabel '対象期間')"   "$(sml_cell_str st0 "$(epoch_ms_to_jst "$START_MS")  〜  $(epoch_ms_to_jst "$(( END_MS - 1 ))")")"
    printf '<Row>%s%s</Row>' "$(sml_cell_str sLabel '期間の判定')" "$(sml_cell_str st0 "$(excel_timesource_text)")"
    printf '<Row>%s%s</Row>' "$(sml_cell_str sLabel 'AWS')"        "$(sml_cell_str st0 "アカウント: ${CALLER_ACCOUNT:-(不明)} / プロファイル: ${AWS_PROFILE_OPT:-${AWS_PROFILE:-(既定)}} / リージョン: ${AWS_REGION_OPT:-${AWS_REGION:-${AWS_DEFAULT_REGION:-(既定)}}}")"
    printf '<Row>%s%s</Row>' "$(sml_cell_str sLabel '抽出条件')"   "$(sml_cell_str st0 "$cond")"
    printf '<Row>%s%s</Row>' "$(sml_cell_str sLabel '取得上限')"   "$(sml_cell_str st0 "ロググループごとに最大 ${MAX_EVENTS} 件")"
    printf '<Row>%s%s</Row>' "$(sml_cell_str sLabel '生ログ')"     "$(sml_cell_str st0 "$(excel_rawdir_text)")"
    printf '<Row>%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s</Row>' \
      "$(sml_cell_str sHead 'No')"           "$(sml_cell_str sHead 'ロググループ')" \
      "$(sml_cell_str sHead 'シート名')"     "$(sml_cell_str sHead '取得')" \
      "$(sml_cell_str sHead '期間外')"       "$(sml_cell_str sHead '出力')" \
      "$(sml_cell_str sHead 'エラー')"       "$(sml_cell_str sHead '警告')" \
      "$(sml_cell_str sHead 'デプロイ')"     "$(sml_cell_str sHead 'アンデプロイ')" \
      "$(sml_cell_str sHead '起動')"         "$(sml_cell_str sHead '停止')" \
      "$(sml_cell_str sHead '最古(JST)')"    "$(sml_cell_str sHead '最新(JST)')" \
      "$(sml_cell_str sHead '生ログ数')"
    for (( i = 0; i < n; i++ )); do
      b=$(( i * CAT_N ))
      printf '%s' '<Row>'
      sml_cell_num sn0 "$(( i + 1 ))"
      sml_cell_str st0 "${GRP_NAMES[i]}"
      sml_cell_str st0 "${XLSX_SHEET_NAMES[i]}"
      sml_cell_num sn0 "${GRP_FETCHED[i]}"
      sml_cell_num sn0 "${GRP_OUTRANGE[i]}"
      sml_cell_num sn0 "${GRP_MATCHED[i]}"
      sml_cell_num "sn${cERR}" "${GRP_CAT[b + CAT_ERROR]}"
      sml_cell_num "sn${cWRN}" "${GRP_CAT[b + CAT_WARN]}"
      sml_cell_num "sn${cDEP}" "${GRP_KIND[b + CAT_DEPLOY]}"
      sml_cell_num "sn${cUND}" "${GRP_KIND[b + CAT_UNDEPLOY]}"
      sml_cell_num "sn${cSTA}" "${GRP_KIND[b + CAT_START]}"
      sml_cell_num "sn${cSTP}" "${GRP_KIND[b + CAT_STOP]}"
      if [[ -n "${GRP_MINTS[i]}" ]]; then
        epoch_ms_to_excel_iso "${GRP_MINTS[i]}"; sml_cell_date sd0 "$EXCEL_ISO"
        epoch_ms_to_excel_iso "${GRP_MAXTS[i]}"; sml_cell_date sd0 "$EXCEL_ISO"
      else
        sml_cell_str st0 '-'; sml_cell_str st0 '-'
      fi
      sml_cell_num sn0 "${GRP_RAWFILES[i]}"
      printf '%s' '</Row>'
    done
    printf '%s\n' '</Table><WorksheetOptions xmlns="urn:schemas-microsoft-com:office:excel"><FreezePanes/><FrozenNoSplit/><SplitHorizontal>9</SplitHorizontal><TopRowBottomPane>9</TopRowBottomPane><ActivePane>2</ActivePane></WorksheetOptions></Worksheet>'

    # --- 主要イベントシート（デプロイ / 起動・停止をロググループ横断で時刻順に） ---
    xml_escape '主要イベント'
    printf '<Worksheet ss:Name="%s"><Table>' "$XML_ESC"
    printf '%s' '<Column ss:Width="150"/><Column ss:Width="260"/><Column ss:Width="90"/><Column ss:Width="60"/><Column ss:Width="180"/><Column ss:Width="640"/>'
    printf '<Row>%s</Row>' "$(sml_cell_str sTitle '主要イベント（アプリケーションのデプロイ / JBoss EAP の起動・停止）')"
    printf '<Row>%s</Row>' "$(sml_cell_str st0 "デプロイ（緑）はアプリケーションの配備、起動（青）・停止（紫）は EAP 本体の状態変化です。ロググループを横断して時刻順に並べています。${KEY_TRUNCATED}")"
    printf '<Row>%s%s%s%s%s%s</Row>' \
      "$(sml_cell_str sHead '時刻(JST)')"      "$(sml_cell_str sHead 'ロググループ')" \
      "$(sml_cell_str sHead '区分')"           "$(sml_cell_str sHead 'レベル')" \
      "$(sml_cell_str sHead 'ログストリーム')" "$(sml_cell_str sHead 'メッセージ')"
    if [[ -s "$KEY_SORTED" ]]; then
      r=0
      while IFS="$US" read -r mts group cat kcat kind lvl ls emsg; do
        emsg="${emsg%$'\r'}"
        [[ "$mts" =~ ^-?[0-9]+$ ]] || continue
        r=$(( r + 1 )); (( r >= XLSX_MAX_ROWS - 3 )) && break
        [[ "$HIGHLIGHT" == "true" ]] || cat=$CAT_INFO
        printf '%s' '<Row>'
        epoch_ms_to_excel_iso "$mts"; sml_cell_date "sd${cat}" "$EXCEL_ISO"
        sml_cell_str "st${cat}" "$group"
        sml_cell_str "st${cat}" "$kind"
        sml_cell_str "st${cat}" "$lvl"
        sml_cell_str "st${cat}" "$ls"
        excel_cell_message "$emsg"; sml_cell_str "sw${cat}" "$EXCEL_CELL"
        printf '%s' '</Row>'
      done < "$KEY_SORTED"
    fi
    printf '%s\n' '</Table><WorksheetOptions xmlns="urn:schemas-microsoft-com:office:excel"><FreezePanes/><FrozenNoSplit/><SplitHorizontal>3</SplitHorizontal><TopRowBottomPane>3</TopRowBottomPane><ActivePane>2</ActivePane></WorksheetOptions></Worksheet>'

    # --- ロググループごとのシート ---
    for (( i = 0; i < n; i++ )); do
      group="${GRP_NAMES[i]}"
      info="期間(JST): $(epoch_ms_to_jst "$START_MS")  〜  $(epoch_ms_to_jst "$(( END_MS - 1 ))")"
      info+="  /  取得 ${GRP_FETCHED[i]} 件  /  期間外 ${GRP_OUTRANGE[i]} 件  /  出力 ${GRP_MATCHED[i]} 件  /  ${cond}"
      xml_escape "${XLSX_SHEET_NAMES[i]}"
      printf '<Worksheet ss:Name="%s"><Table>' "$XML_ESC"
      printf '%s' '<Column ss:Width="150"/><Column ss:Width="90"/><Column ss:Width="60"/><Column ss:Width="200"/><Column ss:Width="700"/><Column ss:Width="150"/><Column ss:Width="100"/>'
      printf '<Row>%s</Row>' "$(sml_cell_str sTitle "ロググループ: ${group}")"
      printf '<Row>%s</Row>' "$(sml_cell_str st0 "$info")"
      printf '<Row>%s%s%s%s%s%s%s</Row>' \
        "$(sml_cell_str sHead '時刻(JST)')"      "$(sml_cell_str sHead '区分')" \
        "$(sml_cell_str sHead 'レベル')"         "$(sml_cell_str sHead 'ログストリーム')" \
        "$(sml_cell_str sHead 'メッセージ')"     "$(sml_cell_str sHead 'イベント時刻(JST)')" \
        "$(sml_cell_str sHead 'timestamp(ms)')"
      if [[ -s "${GRP_FILES[i]}" ]]; then
        r=0
        while IFS="$US" read -r mts ts ing eid ls cat kcat lvl kind emsg; do
          emsg="${emsg%$'\r'}"
          [[ "$mts" =~ ^-?[0-9]+$ ]] || continue
          r=$(( r + 1 ))
          (( r >= XLSX_MAX_ROWS - 3 )) && break
          [[ "$HIGHLIGHT" == "true" ]] || cat=$CAT_INFO
          printf '%s' '<Row>'
          epoch_ms_to_excel_iso "$mts"; sml_cell_date "sd${cat}" "$EXCEL_ISO"
          sml_cell_str "st${cat}" "$kind"
          sml_cell_str "st${cat}" "$lvl"
          sml_cell_str "st${cat}" "$ls"
          excel_cell_message "$emsg"; sml_cell_str "sw${cat}" "$EXCEL_CELL"
          epoch_ms_to_excel_iso "$ts"; sml_cell_date "sd${cat}" "$EXCEL_ISO"
          sml_cell_num "sn${cat}" "$ts"
          printf '%s' '</Row>'
        done < "${GRP_FILES[i]}"
      fi
      printf '%s\n' '</Table><WorksheetOptions xmlns="urn:schemas-microsoft-com:office:excel"><FreezePanes/><FrozenNoSplit/><SplitHorizontal>3</SplitHorizontal><TopRowBottomPane>3</TopRowBottomPane><ActivePane>2</ActivePane></WorksheetOptions></Worksheet>'
    done
    printf '%s\n' '</Workbook>'
  } > "$EXCEL_FILE" || die "SpreadsheetML ファイルの書き出しに失敗しました: ${EXCEL_FILE}" "$EX_OUTPUT"
  return 0
}

# ===========================================================================
# 17.6 生テキストログの出力
#   Excel とは別に、CloudWatch Logs のメッセージ本文をそのままの形で
#   「ロググループ × ログストリーム」ごとに 1 ファイルへ書き出す。
#   サーバー上の元のログファイルに近い形で grep / diff できるようにするため、
#   本文には手を加えない（--raw-with-time 指定時のみ行頭へ時刻を付ける）。
#   ファイル名は「NN_ロググループ名_ストリーム名.log」に短縮し、完全な対応は
#   同じフォルダの 00_index.txt に残す。
# ===========================================================================
readonly RAW_INDEX_NAME="00_index.txt"
readonly RAW_NAME_MAX=24          # 名前 1 要素あたりの最大長（短く分かりやすく保つ）
declare -A RAW_NAME_USED=()       # 出力済みファイル名（重複回避）
RAW_INDEX_BUF=""                  # 00_index.txt に書く内容を貯めるファイル
RAW_TOTAL_FILES=0
RAW_TOTAL_LINES=0
RAW_SORT_TMP=""

# ファイル名に使える短い名前へ変換する（結果は RAW_SHORT）。
#   末尾側を残すのは、ロググループ名・ストリーム名とも先頭が共通しがちで、
#   識別に役立つ情報が末尾にあるため（/aws/ecs/app-prod, .../i-0abc123 など）。
RAW_SHORT=""
short_token() {
  local s="$1" max="${2:-$RAW_NAME_MAX}"
  s="${s//[!A-Za-z0-9._-]/-}"       # 使えない文字はまとめてハイフンへ
  while [[ "$s" == *--* ]]; do s="${s//--/-}"; done
  s="${s#-}"; s="${s%-}"; s="${s#.}"
  (( ${#s} > max )) && s="${s: -max}"
  s="${s#-}"
  [[ -z "$s" ]] && s="log"
  RAW_SHORT="$s"
}

# 重複しないファイル名を作る（結果は RAW_FILE_NAME）
RAW_FILE_NAME=""
raw_unique_name() {
  local base="$1" name="$2" i cand
  cand="${base}_${name}.log"
  if [[ -n "${RAW_NAME_USED[${cand,,}]:-}" ]]; then
    for (( i = 2; i <= 999; i++ )); do
      cand="${base}_${name}~${i}.log"
      [[ -z "${RAW_NAME_USED[${cand,,}]:-}" ]] && break
    done
  fi
  RAW_NAME_USED["${cand,,}"]=1
  RAW_FILE_NAME="$cand"
}

# 1 ロググループぶんの収集結果を、ログストリームごとのファイルへ書き出す。
#   ストリームごとにファイルを開き直す回数を最小にするため、まず
#   「ストリーム名 -> ログ時刻」の順に並べ替えてから 1 度だけ走査する。
write_raw_group() {
  local idx="$1"
  local group="${GRP_NAMES[idx]}" src="${GRP_FILES[idx]}"
  local mts ts ing eid ls cat kcat lvl kind emsg
  local cur="" path="" files=0 lines=0 nlines=0 gshort sshort prefix
  GRP_RAWFILES[idx]=0
  [[ -s "$src" ]] || return 0

  [[ -z "$RAW_SORT_TMP" ]] && RAW_SORT_TMP="$(mktemp_tracked)"
  LC_ALL=C sort -s -t"$US" -k5,5 -k1,1n "$src" > "$RAW_SORT_TMP" \
    || die "生テキストログの並べ替えに失敗しました: ${group}" "$EX_OUTPUT"

  short_token "$group"; gshort="$RAW_SHORT"
  printf -v prefix '%02d_%s' "$(( idx + 1 ))" "$gshort"

  while IFS="$US" read -r mts ts ing eid ls cat kcat lvl kind emsg; do
    emsg="${emsg%$'\r'}"
    [[ "$mts" =~ ^-?[0-9]+$ ]] || continue

    if [[ "$ls" != "$cur" || -z "$path" ]]; then
      if [[ -n "$path" ]]; then
        exec 3>&-
        printf '%s\t%s\t%s\t%d\t%s\n' "$(( idx + 1 ))" "$group" "$cur" "$nlines" "$RAW_FILE_NAME" >> "$RAW_INDEX_BUF"
      fi
      cur="$ls"; nlines=0
      short_token "${ls:-nostream}"; sshort="$RAW_SHORT"
      raw_unique_name "$prefix" "$sshort"
      path="${RAW_DIR}/${RAW_FILE_NAME}"
      exec 3>"$path" || die "生テキストログを書き出せません: ${path}" "$EX_OUTPUT"
      files=$(( files + 1 ))
      printf '# ロググループ  : %s\n' "$group"          >&3
      printf '# ログストリーム: %s\n' "${ls:-(なし)}"   >&3
      printf '# 期間(JST)     : %s 〜 %s\n' \
        "$(epoch_ms_to_jst "$START_MS")" "$(epoch_ms_to_jst "$(( END_MS - 1 ))")" >&3
    fi

    decode_msg "$emsg"
    if [[ "$RAW_WITH_TIME" == "true" ]]; then
      set_jst_str "$mts"
      printf '[%s] %s\n' "$JST_STR" "$DECODED" >&3
    else
      printf '%s\n' "$DECODED" >&3
    fi
    nlines=$(( nlines + 1 )); lines=$(( lines + 1 ))
  done < "$RAW_SORT_TMP"

  if [[ -n "$path" ]]; then
    exec 3>&-
    printf '%s\t%s\t%s\t%d\t%s\n' "$(( idx + 1 ))" "$group" "$cur" "$nlines" "$RAW_FILE_NAME" >> "$RAW_INDEX_BUF"
  fi

  GRP_RAWFILES[idx]=$files
  RAW_TOTAL_FILES=$(( RAW_TOTAL_FILES + files ))
  RAW_TOTAL_LINES=$(( RAW_TOTAL_LINES + lines ))
  return 0
}

# 00_index.txt（ファイルとロググループ／ストリームの対応表）を書き出す
write_raw_index() {
  local path="${RAW_DIR}/${RAW_INDEX_NAME}" now
  printf -v now '%(%Y-%m-%d %H:%M:%S)T' -1
  {
    printf '# CloudWatch Logs 生テキストログ 一覧\n'
    printf '# 出力日時  : %s JST\n' "$now"
    printf '# 対象期間  : %s 〜 %s\n' \
      "$(epoch_ms_to_jst "$START_MS")" "$(epoch_ms_to_jst "$(( END_MS - 1 ))")"
    printf '# 期間の判定: %s\n' "$(excel_timesource_text)"
    printf '# 抽出条件  : %s\n' "$(excel_condition_text)"
    [[ -n "$EXCEL_FILE" ]] && printf '# Excel     : %s\n' "$(basename -- "$EXCEL_FILE")"
    printf '#\n'
    printf 'No\tロググループ\tログストリーム\t件数\tファイル名\n'
    # ここは必ず if で書く。ブロックの最後が偽の「[[ ]] && cmd」だとブロック全体が
    # 非 0 を返し、対象ログが 0 件のときに下の || die が誤って発火するため。
    if [[ -s "$RAW_INDEX_BUF" ]]; then cat "$RAW_INDEX_BUF"; fi
  } > "$path" || die "生テキストログの一覧を書き出せません: ${path}" "$EX_OUTPUT"
  return 0
}

# 生テキストログの出力全体（run_once の最後に呼ぶ）
raw_write_all() {
  local i n=${#GRP_NAMES[@]}
  (( n > 0 )) || return 0
  log_info "生テキストログを書き出しています: ${RAW_DIR}"
  RAW_INDEX_BUF="$(mktemp_tracked)"; : > "$RAW_INDEX_BUF"
  for (( i = 0; i < n; i++ )); do
    write_raw_group "$i"
  done
  write_raw_index
  if (( RAW_TOTAL_FILES == 0 )); then
    log_warn "出力対象のログがないため、生テキストログは ${RAW_INDEX_NAME} のみ作成しました: ${RAW_DIR}"
  else
    log_success "生テキストログを作成しました: ${RAW_DIR}（${RAW_TOTAL_FILES} ファイル / 合計 ${RAW_TOTAL_LINES} 件 / 一覧: ${RAW_INDEX_NAME}）"
  fi
  return 0
}

# ===========================================================================
# 17.7 ロググループごとの区切り表示
#   見出しは text 形式のときだけ標準出力へ出す（画面と同じ区切りがリダイレクト先の
#   ファイルにも残るようにするため）。tsv / jsonl は機械処理される前提なので、
#   標準出力を汚さないよう標準エラーへ [INFO] として出す。
#   ロググループが 1 件だけのときは見出しを出さず、従来どおりの出力を保つ。
# ===========================================================================
HDR_C=""   # 見出しの色（標準出力が端末のときだけ着色する）
HDR_R=""

group_banner() {
  local bar
  printf -v bar '%*s' 74 ''
  printf '%s' "${bar// /=}"
}

print_group_header() {
  local idx="$1" total="$2" group="$3"
  local title="[${idx}/${total}] ロググループ: ${group}"
  # 全角 2 桁幅を前提に、2 行目のコロン位置を 1 行目へそろえる
  local range="         期間(JST) : $(epoch_ms_to_jst "$START_MS")  〜  $(epoch_ms_to_jst "$(( END_MS - 1 ))")"
  local bar; bar="$(group_banner)"

  if [[ "$OUTPUT" == "text" ]]; then
    printf '\n%s%s%s\n'  "$HDR_C" "$bar"   "$HDR_R"
    printf '%s %s%s\n'   "$HDR_C" "$title" "$HDR_R"
    printf '%s%s%s\n'    "$HDR_C" "$range" "$HDR_R"
    printf '%s%s%s\n'    "$HDR_C" "$bar"   "$HDR_R"
  else
    log_info "=== ${title} ==="
  fi
}

print_group_footer() {
  local group="$1" fetched="$2" matched="$3" outrange="${4:-0}"
  local extra=""
  (( outrange > 0 )) && extra=" / 期間外 ${outrange} 件"
  if [[ "$OUTPUT" == "text" ]]; then
    (( matched == 0 )) && printf '%s  (該当するログイベントはありません)%s\n' "$HDR_C" "$HDR_R"
    printf '%s  -- 出力 %d 件 / 取得 %d 件%s --%s\n' "$HDR_C" "$matched" "$fetched" "$extra" "$HDR_R"
  else
    log_info "    出力 ${matched} 件 / 取得 ${fetched} 件${extra}"
  fi
  return 0
}

# 実行後の集計（ロググループが複数のときのみ）。
#   bash 4.2 でも動くよう nameref（declare -n, 4.3 以降）は使わず、
#   run_once が組み立てたグローバル配列を直接参照する。
SUM_GROUPS=()
SUM_FETCHED=()
SUM_MATCHED=()
SUM_OUTRANGE=()
print_group_summary() {
  local i width=0 tf=0 tm=0 to=0
  for i in "${!SUM_GROUPS[@]}"; do
    (( ${#SUM_GROUPS[i]} > width )) && width=${#SUM_GROUPS[i]}
  done
  (( width > 60 )) && width=60
  log_info "=== 集計（${#SUM_GROUPS[@]} ロググループ）==="
  for i in "${!SUM_GROUPS[@]}"; do
    log_info "$(printf '  %-*s  出力 %6d 件 / 取得 %6d 件 / 期間外 %6d 件' \
      "$width" "${SUM_GROUPS[i]}" "${SUM_MATCHED[i]}" "${SUM_FETCHED[i]}" "${SUM_OUTRANGE[i]:-0}")"
    tf=$(( tf + SUM_FETCHED[i] )); tm=$(( tm + SUM_MATCHED[i] )); to=$(( to + ${SUM_OUTRANGE[i]:-0} ))
  done
  # 合計行は日本語ラベルの表示幅が %-*s（バイト/文字数基準）とずれるため、桁合わせをしない
  log_success "$(printf '合計: 出力 %d 件 / 取得 %d 件 / 期間外 %d 件' "$tm" "$tf" "$to")"
  return 0
}

# ===========================================================================
# 18. 通常取得モード（ロググループごとに順番に取得・表示する）
# ===========================================================================
run_once() {
  local total=${#LOG_GROUPS[@]} idx=0 g c collect="false"
  local raw annotated sorted

  # Excel か生テキストログを作るなら、表示形式に関わらず行を貯めておく
  [[ -n "$EXCEL_FILE" || "$RAW_ENABLED" == "true" ]] && collect="true"
  [[ -n "$EXCEL_FILE" ]] && KEY_BUF="$(mktemp_tracked)"

  SUM_GROUPS=(); SUM_FETCHED=(); SUM_MATCHED=(); SUM_OUTRANGE=()
  raw="$(mktemp_tracked)"; annotated="$(mktemp_tracked)"; sorted="$(mktemp_tracked)"

  for g in "${LOG_GROUPS[@]}"; do
    idx=$(( idx + 1 ))
    LOG_GROUP="$g"
    (( total > 1 )) && print_group_header "$idx" "$total" "$g"

    # 収集用のバッファ（ロググループごとに 1 ファイル = 1 シート + 生ログ 1 組）
    COLLECT_BUF=""; COLLECT_MIN=""; COLLECT_MAX=""
    [[ "$collect" == "true" ]] && COLLECT_BUF="$(mktemp_tracked)"
    CUR_CAT=(); CUR_KIND=()
    for (( c = 0; c < CAT_N; c++ )); do CUR_CAT[c]=0; CUR_KIND[c]=0; done

    if (( total == 1 )); then
      log_info "ログイベントを取得しています（最大 ${MAX_EVENTS} 件, エンジン: ${ENGINE}）..."
    else
      # 見出しでロググループ名は既に示しているため、ここでは繰り返さない
      log_info "[${idx}/${total}] ログイベントを取得しています（最大 ${MAX_EVENTS} 件, エンジン: ${ENGINE}）..."
    fi

    : > "$raw"; : > "$annotated"; : > "$sorted"
    MAXTS=""; FETCHED=0; MATCHED=0; OUT_OF_RANGE=0
    fetch_events "$raw"

    if [[ -s "$raw" ]]; then
      # 本文時刻・区分を付けてから、ログ出力時刻の昇順に安定ソートする
      #   （filter-log-events はストリーム跨ぎで順序保証がなく、本文時刻とイベント
      #     時刻の並びも一致しないため、表示・出力の直前に必ず並べ替える）
      annotate_events "$raw" "$annotated"
      # 本文から時刻を読み取れない行が大半なら、期間の判定は実質イベント時刻に
      # なっている。気づかず使い続けないよう、一度だけ知らせる。
      if [[ "$TIME_SOURCE" == "message" ]] && (( ANNOTATED > 0 && NO_MSG_TIME * 2 > ANNOTATED )); then
        log_warn "本文から時刻を読み取れない行が多数あります（${NO_MSG_TIME}/${ANNOTATED} 件）。それらはイベント時刻で期間を判定しています。"
        log_warn "  ログの出力形式が想定と異なる可能性があります（--help の「認識できるログ本文の時刻」を参照）。"
      fi
      LC_ALL=C sort -s -t"$US" -k1,1n "$annotated" > "$sorted" || die "ログの並べ替えに失敗しました。" "$EX_API"
      emit_events "$sorted"
    elif (( total == 1 )); then
      log_warn "指定期間・条件に一致するログイベントはありませんでした。"
    fi

    if [[ "$collect" == "true" ]]; then
      GRP_NAMES+=("$g")
      GRP_FILES+=("$COLLECT_BUF")
      GRP_FETCHED+=("$FETCHED")
      GRP_MATCHED+=("$MATCHED")
      GRP_OUTRANGE+=("$OUT_OF_RANGE")
      GRP_MINTS+=("$COLLECT_MIN")
      GRP_MAXTS+=("$COLLECT_MAX")
      GRP_RAWFILES+=(0)
      for (( c = 0; c < CAT_N; c++ )); do
        GRP_CAT+=("${CUR_CAT[c]}")
        GRP_KIND+=("${CUR_KIND[c]}")
      done
    fi
    SUM_GROUPS+=("$g"); SUM_FETCHED+=("$FETCHED"); SUM_MATCHED+=("$MATCHED")
    SUM_OUTRANGE+=("$OUT_OF_RANGE")

    (( total > 1 )) && print_group_footer "$g" "$FETCHED" "$MATCHED" "$OUT_OF_RANGE"
  done
  COLLECT_BUF=""

  if (( total > 1 )); then
    print_group_summary
  else
    log_success "出力 ${MATCHED} 件（取得 ${FETCHED} 件$( (( OUT_OF_RANGE > 0 )) && printf ' / 期間外 %d 件' "$OUT_OF_RANGE" )）"
  fi

  # 生テキストログ -> Excel の順に書き出す（Excel のサマリへ生ログの件数を載せるため）
  [[ "$RAW_ENABLED" == "true" ]] && raw_write_all
  if [[ -n "$EXCEL_FILE" ]]; then
    KEY_TRUNCATED=""
    (( KEY_COUNT >= KEY_EVENT_MAX )) && KEY_TRUNCATED=" ※ 上限 ${KEY_EVENT_MAX} 件で打ち切っています。"
    excel_write
  fi
  return 0
}

# ===========================================================================
# 19. 監視モード（tail -f 相当・ポーリング）
# ===========================================================================
run_follow() {
  DEDUP="true"
  local poll="$POLL_INTERVAL" overlap_ms=$(( OVERLAP_SECONDS * 1000 ))
  local total=${#LOG_GROUPS[@]} g i now_ms nxt floor batch annotated sorted
  # 監視の窓はロググループごとに独立して前進させる
  #   （更新頻度が違うグループを同じ窓で扱うと、静かなグループの取りこぼしが増えるため）
  local -A since=()
  for g in "${LOG_GROUPS[@]}"; do since["$g"]="$FETCH_START_MS"; done

  # 一時ファイルはループの外で 1 度だけ確保して毎回切り詰める
  #   （毎周 mktemp すると TMP_FILES が際限なく増え、長時間監視で問題になるため）
  batch="$(mktemp_tracked)"; annotated="$(mktemp_tracked)"; sorted="$(mktemp_tracked)"

  log_info "監視を開始します（ポーリング間隔 ${poll}s, オーバーラップ ${OVERLAP_SECONDS}s）。Ctrl+C で終了します。"
  log_info "  エンジン: ${ENGINE}${LOG_STREAM:+ / ストリーム: ${LOG_STREAM}}"
  if (( total == 1 )); then
    log_info "  ロググループ: ${LOG_GROUPS[0]}"
  else
    log_info "  ロググループ（${total} 件・行頭にグループ名を表示します）:"
    i=0
    for g in "${LOG_GROUPS[@]}"; do i=$(( i + 1 )); log_info "    ${i}) ${g}"; done
  fi

  while :; do
    now_ms=$(( ($(date +%s) + 1) * 1000 ))
    floor=""
    for g in "${LOG_GROUPS[@]}"; do
      LOG_GROUP="$g"
      # 取得の窓だけを前進させる。対象期間の下限（START_MS）は最初の指定のまま
      #   使い、本文時刻がそれより古い遅延到着ログは emit_events 側で落とす。
      FETCH_START_MS="${since[$g]}"; FETCH_END_MS="$now_ms"
      : > "$batch"; : > "$annotated"; : > "$sorted"
      MAXTS=""
      fetch_events "$batch"

      if [[ -s "$batch" ]]; then
        annotate_events "$batch" "$annotated"
        LC_ALL=C sort -s -t"$US" -k1,1n "$annotated" > "$sorted" || true
        emit_events "$sorted"
      fi

      # 窓を前進させる。最大 ts からオーバーラップ分だけ戻して遅延到着に備える。
      if [[ -n "$MAXTS" && "$MAXTS" =~ ^[0-9]+$ ]]; then
        nxt=$(( MAXTS - overlap_ms + 1 ))
      else
        nxt=$(( now_ms - overlap_ms ))
      fi
      (( nxt > ${since[$g]} )) && since["$g"]=$nxt
      # 重複排除キーの掃除は、最も遅れているグループの窓を基準にする
      if [[ -z "$floor" ]] || (( ${since[$g]} < floor )); then floor="${since[$g]}"; fi
    done

    [[ -n "$floor" ]] && prune_seen "$floor"
    sleep "$poll"
  done
}

# ===========================================================================
# 20. 実行計画の表示（確認・dry-run 用）
# ===========================================================================
print_plan() {
  local i
  log_info "=== 実行計画 ==="
  if (( ${#LOG_GROUPS[@]} == 0 )); then
    log_info "  ロググループ    : (一覧から選択)"
  elif (( ${#LOG_GROUPS[@]} == 1 )); then
    log_info "  ロググループ    : ${LOG_GROUPS[0]}"
  else
    log_info "  ロググループ    : ${#LOG_GROUPS[@]} 件"
    for i in "${!LOG_GROUPS[@]}"; do
      log_info "$(printf '                    %2d) %s' "$(( i + 1 ))" "${LOG_GROUPS[i]}")"
    done
  fi
  if [[ -n "$LOG_STREAM" ]]; then
    log_info "  ログストリーム  : ${LOG_STREAM}"
  elif [[ -n "$LOG_STREAM_PREFIX" ]]; then
    log_info "  ストリーム接頭辞: ${LOG_STREAM_PREFIX}"
  else
    log_info "  ログストリーム  : (全ストリーム横断)"
  fi
  log_info "  対象期間(JST)   : $(epoch_ms_to_jst "$START_MS")  〜  $(epoch_ms_to_jst "$(( END_MS - 1 ))")"
  log_info "  期間の判定      : $(excel_timesource_text)"
  if [[ "$TIME_SOURCE" == "message" ]]; then
    log_info "  取得期間(JST)   : $(epoch_ms_to_jst "$FETCH_START_MS")  〜  $(epoch_ms_to_jst "$(( FETCH_END_MS - 1 ))")"
  fi
  log_info "  エンジン        : ${ENGINE}"
  if [[ -n "$CW_PATTERN" ]]; then
    log_info "  フィルタ        : cloudwatch パターン: ${CW_PATTERN}"
  elif (( ${#FILTERS[@]} )); then
    log_info "  フィルタ        : ${FILTER_MODE} [${FILTER_LOGIC}] ${FILTERS[*]}"
  else
    log_info "  フィルタ        : (なし)"
  fi
  (( ${#EXCLUDES[@]} )) && log_info "  除外            : ${EXCLUDES[*]}"
  [[ "$IGNORE_CASE" == "true" ]] && log_info "  大文字小文字    : 無視"
  log_info "  出力形式        : ${OUTPUT}$( [[ "$OUTPUT" == "none" ]] && printf '（画面へは出力しません）' )"
  if [[ -n "$EXCEL_FILE" ]]; then
    log_info "  Excel 出力      : ${EXCEL_FILE}（形式: ${EXCEL_FORMAT}, シート: サマリ + 主要イベント + ロググループごと）"
    log_info "  Excel の書式    : フォント ${EXCEL_FONT_NAME} / 区分ごとの色分け: $( [[ "$HIGHLIGHT" == "true" ]] && printf '有効' || printf '無効' )"
  fi
  if [[ "$RAW_ENABLED" == "true" ]]; then
    log_info "  生テキストログ  : ${RAW_DIR}（ロググループ × ログストリームごと / 一覧: ${RAW_INDEX_NAME}）"
  fi
  log_info "  監視(follow)    : ${FOLLOW}"
  [[ "$FOLLOW" == "true" ]] && log_info "  ポーリング/重複 : ${POLL_INTERVAL}s / オーバーラップ ${OVERLAP_SECONDS}s"
  log_info "  最大件数        : ${MAX_EVENTS}（1 回 ${PAGE_LIMIT} 件）$( (( ${#LOG_GROUPS[@]} > 1 )) && printf '※ロググループごと' )"
  log_info "  スイッチバック  : ${SWITCHBACK_MODE}${SWITCHBACK_SCRIPT:+ / ${SWITCHBACK_SCRIPT}}"
  return 0
}

# ===========================================================================
# 21. メイン
# ===========================================================================
main() {
  local i
  define_fallbacks     # parse_args 内のエラーでも die/log_* を使えるよう先に用意する
  parse_args "$@"
  load_common          # --common-sh / 環境変数指定の common.sh を読み込み（関数を上書き）
  setup_colors
  validate_inputs
  resolve_engine

  # ignore-case はここで一括設定（== と =~ の両方に効く）
  [[ "$IGNORE_CASE" == "true" ]] && shopt -s nocasematch

  # dry-run は AWS へアクセスせず、解決した計画のみ表示して終了（読み取りも行わない）
  if [[ "$DRY_RUN" == "true" ]]; then
    # 期間の算出だけは行う（AWS 非依存）
    resolve_time_range
    log_warn "dry-run: AWS への参照・スイッチバックは行いません。予定内容のみ表示します。"
    print_plan
    if (( ${#LOG_GROUPS[@]} == 0 )); then
      log_info "  （ロググループ未指定のため、実行時は一覧から対話選択します）"
    fi
    exit "$EX_OK"
  fi

  # 依存コマンド・認証・権限（スイッチバック）
  preflight_commands
  build_aws_global
  require_authenticated
  ensure_logs_permission_or_switchback

  # ロググループの解決（未指定なら一覧から選択。複数選択できる）
  if (( ${#LOG_GROUPS[@]} == 0 )); then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      die "--non-interactive では --log-group が必須です。" "$EX_USAGE"
    fi
    fetch_log_groups
    if ! select_from_list "ロググループ一覧（複数選択できます）" multi; then
      die "中止しました。" "$EX_INT"
    fi
    LOG_GROUPS=("${SELECTED_ITEMS[@]}")
    if (( ${#LOG_GROUPS[@]} == 1 )); then
      log_success "選択したロググループ: ${LOG_GROUPS[0]}"
    else
      log_success "選択したロググループ: ${#LOG_GROUPS[@]} 件"
      for i in "${!LOG_GROUPS[@]}"; do log_info "  $(( i + 1 ))) ${LOG_GROUPS[i]}"; done
    fi
    # 対話選択の結果とストリーム指定の整合性を取り直す（複数選択できるため）
    if [[ "$SELECT_LOG_STREAM" == "true" && ${#LOG_GROUPS[@]} -gt 1 ]]; then
      die "--select-log-stream はロググループが 1 件のときだけ使用できます（${#LOG_GROUPS[@]} 件選択されました）。" "$EX_USAGE"
    fi
  fi
  LOG_GROUP="${LOG_GROUPS[0]}"
  resolve_show_group

  # ログストリームの解決（--select-log-stream 指定時のみ一覧選択）
  if [[ -z "$LOG_STREAM" && "$SELECT_LOG_STREAM" == "true" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      die "--non-interactive では --select-log-stream は使用できません。" "$EX_USAGE"
    fi
    fetch_log_streams "$LOG_GROUP"
    if ! select_from_list "ログストリーム一覧（最終イベントの新しい順）: ${LOG_GROUP}"; then
      die "中止しました。" "$EX_INT"
    fi
    LOG_STREAM="$(strip_stream_label "$SELECTED_ITEM")"
    log_success "選択したログストリーム: ${LOG_STREAM}"
    # 単一ストリーム確定に伴いエンジンを再判定
    resolve_engine
  fi

  resolve_time_range
  print_plan

  if [[ "$FOLLOW" == "true" ]]; then
    run_follow
  else
    run_once
  fi
}

main "$@"
