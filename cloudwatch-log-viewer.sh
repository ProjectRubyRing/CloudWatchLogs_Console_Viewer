#!/usr/bin/env bash
#
# cloudwatch-log-viewer.sh
# ========================
# AWS CloudWatch Logs のログを「JST のログ出力時刻」と「ログメッセージ」の
# 見やすい形式で TeraTerm 等のコンソールに表示する実運用向けツールです。
#
# 主な機能:
#   - ロググループの直接指定 / 一覧からの番号選択（プレフィックス絞り込み対応）
#   - ログストリームの直接指定 / プレフィックス / 一覧選択 / 全ストリーム横断
#   - 期間指定（JST の開始・終了日時 / 直近 N 分 / 既定は直近 ${DEFAULT_LAST_MINUTES:-10} 分）
#   - フィルタ（cloudwatch サーバー側 / literal 固定文字列 / regex 正規表現）
#     除外フィルタ・大文字小文字無視・複数条件の AND/OR
#   - tail -f 相当のリアルタイム監視（ポーリング方式・遅延到着対策・重複排除）
#   - 出力形式 text / tsv / jsonl
#   - AWS 認証状態の事前確認（未認証は aws login --remote を促して終了）
#   - CloudWatch Logs 操作権限の確認と、権限不足時のスイッチバック案内 / 自動実行
#
# 依存: bash 4.2+, aws (CLI v2), jq, GNU date, GNU coreutils(sort/stat/mktemp)
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
set -Eeuo pipefail

# ===========================================================================
# 0. 基本設定
# ===========================================================================
VERSION="1.0.0"
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
}

# ===========================================================================
# 2. 既定値（優先順位: コマンドライン > 環境変数 > ここでの既定）
# ===========================================================================
LOG_GROUP=""
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
SINGLE_LINE="false"
OUTPUT="${CLOUDWATCH_LOG_OUTPUT:-text}"   # text|tsv|jsonl

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
START_MS=""            # 取得開始（epoch ミリ秒）
END_MS=""              # 取得終了（epoch ミリ秒, 排他的境界）
ENGINE=""              # get|filter（使用する AWS API）
AWS_GLOBAL=()          # aws のグローバル引数（--profile/--region）
TMP_FILES=()           # trap で削除する一時ファイル
AWS_OUT=""             # run_aws の標準出力
AWS_ERR=""             # run_aws の標準エラー
FETCHED=0              # 直近フェッチで取得したイベント数
MATCHED=0              # フィルタ後に表示したイベント数
MAXTS=""               # 直近フェッチで観測した最大タイムスタンプ（follow の窓前進用）
SWITCHBACK_DONE="false"
declare -A SEEN=()     # follow モードの重複排除（key -> timestamp）

# ===========================================================================
# 3. 使い方 / ヘルプ
# ===========================================================================
usage() {
  cat >&2 <<USAGE
${SCRIPT_NAME} ${VERSION}

概要:
  AWS CloudWatch Logs のログを「JST の出力時刻 | メッセージ」の形式で表示します。
  期間指定表示・直近 N 分・フィルタ・tail -f 相当の監視に対応します。

使用形式:
  ${SCRIPT_NAME} [オプション]

ロググループ / ストリーム:
  -g, --log-group NAME       ロググループ名を直接指定する
      --log-group-prefix P   一覧表示するロググループをプレフィックスで絞り込む
  -s, --log-stream NAME      特定のログストリームを指定する（get-log-events を使用）
      --log-stream-prefix P  対象ログストリームをプレフィックスで絞り込む
      --select-log-stream    ログストリームを一覧表示し番号で選択する

期間指定（すべて JST として解釈）:
      --start "YYYY-MM-DD HH:MM[:SS]"   取得開始日時（ISO8601 +09:00 形式も可）
      --end   "YYYY-MM-DD HH:MM[:SS]"   取得終了日時（秒単位で inclusive）
  -m, --last-minutes N       現在時刻から直近 N 分を取得（1〜${MAX_LAST_MINUTES}）
                             ※ --start / --end との併用は不可（単独指定）
      （いずれも未指定なら既定で直近 ${DEFAULT_LAST_MINUTES} 分を表示）

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
      --show-ingestion-time  取り込み時刻も表示する（text 形式時）
      --single-line          複数行メッセージを 1 行へ変換する（改行を \\n 表示）
      --output FORMAT        text | tsv | jsonl （既定: ${OUTPUT}）
      --max-events N         最大表示イベント数（既定: ${MAX_EVENTS}）
      --page-limit N         AWS API 1 回あたりの取得件数（既定: ${PAGE_LIMIT}, 最大 10000）

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
  CLOUDWATCH_LOG_OUTPUT                text|tsv|jsonl

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
  130 Ctrl+C 中断

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
USAGE
}

# ===========================================================================
# 4. 引数解析（Bash のみで堅牢に解析。GNU getopt には依存しない）
# ===========================================================================
# 引数を必要とするオプションで値が無い場合のエラー
need_val() {
  [[ $# -ge 2 && -n "${2:-}" ]] || die "オプション ${1} には値が必要です。" "$EX_USAGE"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -g|--log-group)        need_val "$1" "${2:-}"; LOG_GROUP="$2"; shift 2 ;;
      --log-group-prefix)    need_val "$1" "${2:-}"; LOG_GROUP_PREFIX="$2"; shift 2 ;;
      -s|--log-stream)       need_val "$1" "${2:-}"; LOG_STREAM="$2"; shift 2 ;;
      --log-stream-prefix)   need_val "$1" "${2:-}"; LOG_STREAM_PREFIX="$2"; shift 2 ;;
      --select-log-stream)   SELECT_LOG_STREAM="true"; shift ;;
      --start)               need_val "$1" "${2:-}"; START_STR="$2"; shift 2 ;;
      --end)                 need_val "$1" "${2:-}"; END_STR="$2"; shift 2 ;;
      -m|--last-minutes)     need_val "$1" "${2:-}"; LAST_MINUTES="$2"; shift 2 ;;
      -f|--filter)           need_val "$1" "${2:-}"; FILTERS+=("$2"); shift 2 ;;
      --exclude)             need_val "$1" "${2:-}"; EXCLUDES+=("$2"); shift 2 ;;
      --filter-mode)         need_val "$1" "${2:-}"; FILTER_MODE="$2"; shift 2 ;;
      --filter-logic)        need_val "$1" "${2:-}"; FILTER_LOGIC="$2"; shift 2 ;;
      -i|--ignore-case)      IGNORE_CASE="true"; shift ;;
      -F|--follow)           FOLLOW="true"; shift ;;
      --poll-interval)       need_val "$1" "${2:-}"; POLL_INTERVAL="$2"; shift 2 ;;
      --overlap-seconds)     need_val "$1" "${2:-}"; OVERLAP_SECONDS="$2"; shift 2 ;;
      --show-log-stream)     SHOW_STREAM="true"; shift ;;
      --show-ingestion-time) SHOW_INGEST="true"; shift ;;
      --single-line)         SINGLE_LINE="true"; shift ;;
      --output)              need_val "$1" "${2:-}"; OUTPUT="$2"; shift 2 ;;
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
}

# ===========================================================================
# 6. 入力値の検証と正規化
# ===========================================================================
is_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }   # 正の整数
is_uint0(){ [[ "$1" =~ ^[0-9]+$ ]]; }        # 0 以上の整数

# ERE として妥当か（grep は不一致=1, 不正な正規表現=2 を返す）
regex_valid() { printf '' | grep -qE -- "$1" 2>/dev/null; [[ $? -le 1 ]]; }

validate_inputs() {
  # --- 出力形式 ---
  case "$OUTPUT" in text|tsv|jsonl) ;; *) die "--output は text|tsv|jsonl のいずれかです: $OUTPUT" "$EX_USAGE" ;; esac
  # --- フィルタモード / ロジック ---
  case "$FILTER_MODE" in cloudwatch|literal|regex) ;; *) die "--filter-mode は cloudwatch|literal|regex です: $FILTER_MODE" "$EX_USAGE" ;; esac
  case "$FILTER_LOGIC" in and|or) ;; *) die "--filter-logic は and|or です: $FILTER_LOGIC" "$EX_USAGE" ;; esac
  # --- スイッチバックモード ---
  case "$SWITCHBACK_MODE" in exit|auto) ;; *) die "--switchback-mode は exit|auto です: $SWITCHBACK_MODE" "$EX_USAGE" ;; esac

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

  # --- ログストリーム指定の整合性 ---
  if [[ -n "$LOG_STREAM" && -z "$LOG_GROUP" ]]; then
    die "--log-stream を使う場合は --log-group も指定してください。" "$EX_USAGE"
  fi
  if [[ -n "$LOG_STREAM" && -n "$LOG_STREAM_PREFIX" ]]; then
    die "--log-stream と --log-stream-prefix は同時に指定できません。" "$EX_USAGE"
  fi

  # --- 非対話モードでロググループ未指定はエラー ---
  if [[ "$NON_INTERACTIVE" == "true" && -z "$LOG_GROUP" ]]; then
    die "--non-interactive では --log-group の指定が必須です（一覧選択は行いません）。" "$EX_USAGE"
  fi

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

# ===========================================================================
# 7. 一時ファイルとシグナル処理
# ===========================================================================
cleanup() {
  local f
  for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do
    [[ -n "$f" && -f "$f" ]] && rm -f "$f" 2>/dev/null || true
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
epoch_ms_to_jst() {
  local ms="$1" sec frac out
  sec=$(( ms / 1000 )); frac=$(( ms % 1000 ))
  printf -v out '%(%Y-%m-%d %H:%M:%S)T' "$sec"
  printf '%s.%03d JST' "$out" "$frac"
}

# 取得期間（START_MS / END_MS）を確定する
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
  return 0
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
SELECTED_ITEM=""
MENU_ITEMS=()

select_from_list() {
  local title="$1"
  local view=("${MENU_ITEMS[@]}")
  local pat="" input i it

  if (( ${#MENU_ITEMS[@]} == 0 )); then
    log_warn "選択できる項目がありません。"
    return 2
  fi

  while :; do
    printf '\n' >&2
    log_info "${title}（全 ${#MENU_ITEMS[@]} 件 / 表示 ${#view[@]} 件${pat:+, 絞り込み: /${pat}}）"
    for i in "${!view[@]}"; do
      printf '  %4d) %s\n' "$(( i + 1 ))" "${view[i]}" >&2
    done
    (( ${#view[@]} == 0 )) && log_warn "絞り込みに一致する項目がありません（// で解除）。"

    if ! IFS= read -r -p "番号: 選択, /正規表現: 絞り込み, //: 解除, q: 中止 > " input; then
      return 2   # EOF（非対話環境）は中止扱い
    fi
    case "$input" in
      q|Q) return 2 ;;
      //)  pat=""; view=("${MENU_ITEMS[@]}") ;;
      /*)  pat="${input#/}"
           if ! regex_valid "$pat"; then log_warn "正規表現が不正です: $pat"; pat=""; continue; fi
           view=()
           for it in "${MENU_ITEMS[@]}"; do [[ "$it" =~ $pat ]] && view+=("$it"); done ;;
      ''|*[!0-9]*) log_warn "番号か /正規表現 を入力してください: '$input'" ;;
      *)   if (( input >= 1 && input <= ${#view[@]} )); then
             SELECTED_ITEM="${view[input - 1]}"; return 0
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
to_singleline_space() {
  local s="$1"
  s="${s//\\\\/$'\x01'}"
  s="${s//\\t/ }"; s="${s//\\r/ }"; s="${s//\\n/ }"
  s="${s//$'\x01'/\\}"
  printf '%s' "$s"
}

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
format_text() {
  local ts="$1" ing="$2" ls="$3" emsg="$4"
  local prefix; prefix="$(epoch_ms_to_jst "$ts") | "
  [[ "$SHOW_STREAM" == "true" ]] && prefix+="${ls} | "
  [[ "$SHOW_INGEST" == "true" ]] && prefix+="ingest=$(epoch_ms_to_jst "$ing") | "

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

# tsv 形式: timestamp_jst \t timestamp(ms) \t logStream \t ingestionTime(ms) \t message(1行)
format_tsv() {
  local ts="$1" ing="$2" ls="$3" emsg="$4"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(epoch_ms_to_jst "$ts")" "$ts" "$ls" "$ing" "$emsg"
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
    | ($f[0]|tonumber) as $ts
    | { timestamp: $ts,
        timestamp_jst: ( ((($ts/1000|floor)+$off)|gmtime|strftime("%Y-%m-%d %H:%M:%S"))
                         + "." + ((($ts%1000)+1000)|tostring|.[1:]) + " JST" ),
        message: ($f[4]|unesc),
        logGroup: $lg,
        logStream: ($f[3]|if .=="" then null else . end),
        ingestionTime: ($f[1]|tonumber|if .==0 then null else . end),
        eventId: ($f[2]|if .=="" then null else . end) }' "$f"
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
    [[ -n "$START_MS" ]] && args+=(--start-time "$START_MS")
    [[ -n "$END_MS" ]]   && args+=(--end-time "$END_MS")
    [[ -n "$token" ]]    && args+=(--next-token "$token")
    if ! run_aws "${args[@]}"; then handle_fetch_error "ログイベント取得(get-log-events)"; fi
    resp="$AWS_OUT"

    printf '%s' "$resp" | jq -r --arg ls "$LOG_STREAM" "$JQ_ESC_DEF"'
      .events[] | [(.timestamp|tostring), ((.ingestionTime//0)|tostring), "", $ls, (.message|esc)]
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
    [[ -n "$START_MS" ]]          && args+=(--start-time "$START_MS")
    [[ -n "$END_MS" ]]            && args+=(--end-time "$END_MS")
    [[ -n "$CW_PATTERN" ]]        && args+=(--filter-pattern "$CW_PATTERN")
    [[ -n "$LOG_STREAM" ]]        && args+=(--log-stream-names "$LOG_STREAM")
    [[ -n "$LOG_STREAM_PREFIX" ]] && args+=(--log-stream-name-prefix "$LOG_STREAM_PREFIX")
    [[ -n "$token" ]]             && args+=(--next-token "$token")
    if ! run_aws "${args[@]}"; then handle_fetch_error "ログイベント取得(filter-log-events)"; fi
    resp="$AWS_OUT"

    printf '%s' "$resp" | jq -r "$JQ_ESC_DEF"'
      .events[] | [(.timestamp|tostring), ((.ingestionTime//0)|tostring),
                   (.eventId//""), (.logStreamName//""), (.message|esc)]
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
# 17. 表示（フィルタ適用 + 整形）。DEDUP=true のとき重複排除する。
# ===========================================================================
DEDUP="false"

emit_events() {
  local infile="$1"
  local ts ing eid ls emsg hay key
  local jbuf=""
  [[ "$OUTPUT" == "jsonl" ]] && jbuf="$(mktemp_tracked)"
  MATCHED=0

  while IFS="$US" read -r ts ing eid ls emsg; do
    emsg="${emsg%$'\r'}"          # 末尾 CR を除去（CRLF 環境や CR 混入への保険）
    [[ "$ts" =~ ^[0-9]+$ ]] || continue
    # 窓前進用に最大 ts を更新（フィルタ/重複に関わらず）
    if [[ -z "$MAXTS" ]] || (( ts > MAXTS )); then MAXTS="$ts"; fi

    # 重複排除（eventId 優先。無ければ ts|stream|message）
    if [[ "$DEDUP" == "true" ]]; then
      if [[ -n "$eid" ]]; then key="$eid"; else key="${ts}|${ls}|${emsg}"; fi
      [[ -n "${SEEN[$key]:-}" ]] && continue
      SEEN[$key]="$ts"
    fi

    # フィルタ判定
    hay="$(to_singleline_space "$emsg")"
    passes_filters "$hay" || continue

    MATCHED=$(( MATCHED + 1 ))
    case "$OUTPUT" in
      text) format_text "$ts" "$ing" "$ls" "$emsg" ;;
      tsv)  format_tsv  "$ts" "$ing" "$ls" "$emsg" ;;
      jsonl) printf '%s\037%s\037%s\037%s\037%s\n' "$ts" "$ing" "$eid" "$ls" "$emsg" >> "$jbuf" ;;
    esac
  done < "$infile"

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
# 18. 通常取得モード
# ===========================================================================
run_once() {
  local raw sorted
  raw="$(mktemp_tracked)"; sorted="$(mktemp_tracked)"
  log_info "ログイベントを取得しています（最大 ${MAX_EVENTS} 件, エンジン: ${ENGINE}）..."
  MAXTS=""
  fetch_events "$raw"

  if [[ ! -s "$raw" ]]; then
    log_warn "指定期間・条件に一致するログイベントはありませんでした。"
    return 0
  fi
  # タイムスタンプ昇順に安定ソート（filter-log-events はストリーム跨ぎで順序保証がないため）
  LC_ALL=C sort -s -t"$US" -k1,1n "$raw" > "$sorted" || die "ログの並べ替えに失敗しました。" "$EX_API"

  emit_events "$sorted"
  log_success "表示 ${MATCHED} 件（取得 ${FETCHED} 件）"
}

# ===========================================================================
# 19. 監視モード（tail -f 相当・ポーリング）
# ===========================================================================
run_follow() {
  DEDUP="true"
  local since_ms poll="$POLL_INTERVAL" overlap_ms=$(( OVERLAP_SECONDS * 1000 ))
  since_ms="$START_MS"     # 初回窓の開始（--last-minutes / --start / 既定から算出済み）

  log_info "監視を開始します（ポーリング間隔 ${poll}s, オーバーラップ ${OVERLAP_SECONDS}s）。Ctrl+C で終了します。"
  log_info "  エンジン: ${ENGINE} / ロググループ: ${LOG_GROUP}${LOG_STREAM:+ / ストリーム: ${LOG_STREAM}}"

  while :; do
    local now_ms=$(( ($(date +%s) + 1) * 1000 ))
    START_MS="$since_ms"; END_MS="$now_ms"
    local batch sorted
    batch="$(mktemp_tracked)"; sorted="$(mktemp_tracked)"
    MAXTS=""
    fetch_events "$batch"

    if [[ -s "$batch" ]]; then
      LC_ALL=C sort -s -t"$US" -k1,1n "$batch" > "$sorted" || true
      emit_events "$sorted"
    fi
    rm -f "$batch" "$sorted" 2>/dev/null || true

    # 窓を前進させる。最大 ts からオーバーラップ分だけ戻して遅延到着に備える。
    local nxt
    if [[ -n "$MAXTS" && "$MAXTS" =~ ^[0-9]+$ ]]; then
      nxt=$(( MAXTS - overlap_ms + 1 ))
    else
      nxt=$(( now_ms - overlap_ms ))
    fi
    (( nxt > since_ms )) && since_ms=$nxt
    prune_seen "$since_ms"

    sleep "$poll"
  done
}

# ===========================================================================
# 20. 実行計画の表示（確認・dry-run 用）
# ===========================================================================
print_plan() {
  log_info "=== 実行計画 ==="
  log_info "  ロググループ    : ${LOG_GROUP:-(一覧から選択)}"
  if [[ -n "$LOG_STREAM" ]]; then
    log_info "  ログストリーム  : ${LOG_STREAM}"
  elif [[ -n "$LOG_STREAM_PREFIX" ]]; then
    log_info "  ストリーム接頭辞: ${LOG_STREAM_PREFIX}"
  else
    log_info "  ログストリーム  : (全ストリーム横断)"
  fi
  log_info "  取得期間(JST)   : $(epoch_ms_to_jst "$START_MS")  〜  $(epoch_ms_to_jst "$(( END_MS - 1 ))")"
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
  log_info "  出力形式        : ${OUTPUT}"
  log_info "  監視(follow)    : ${FOLLOW}"
  [[ "$FOLLOW" == "true" ]] && log_info "  ポーリング/重複 : ${POLL_INTERVAL}s / オーバーラップ ${OVERLAP_SECONDS}s"
  log_info "  最大件数        : ${MAX_EVENTS}（1 回 ${PAGE_LIMIT} 件）"
  log_info "  スイッチバック  : ${SWITCHBACK_MODE}${SWITCHBACK_SCRIPT:+ / ${SWITCHBACK_SCRIPT}}"
}

# ===========================================================================
# 21. メイン
# ===========================================================================
main() {
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
    if [[ -z "$LOG_GROUP" ]]; then
      log_info "  （ロググループ未指定のため、実行時は一覧から対話選択します）"
    fi
    exit "$EX_OK"
  fi

  # 依存コマンド・認証・権限（スイッチバック）
  preflight_commands
  build_aws_global
  require_authenticated
  ensure_logs_permission_or_switchback

  # ロググループの解決（未指定なら一覧選択）
  if [[ -z "$LOG_GROUP" ]]; then
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      die "--non-interactive では --log-group が必須です。" "$EX_USAGE"
    fi
    fetch_log_groups
    if ! select_from_list "ロググループ一覧"; then
      die "中止しました。" "$EX_INT"
    fi
    LOG_GROUP="$SELECTED_ITEM"
    log_success "選択したロググループ: ${LOG_GROUP}"
  fi

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
