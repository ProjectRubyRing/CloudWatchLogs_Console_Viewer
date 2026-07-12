#!/usr/bin/env bash
#
# common.sh - 複数のスクリプトで共有するユーティリティ関数群
#   （CloudWatchLogs_Search / CodeCommit_Git_branch_local_Create プロジェクトの
#     common.sh と同じ規約に合わせた共通部品。CodeCommit 固有処理は含まない）
#
# 使い方:
#   このファイルを source して各関数を利用する。
#     source "$(dirname "$0")/common.sh"
#
#   DRY_RUN=true を設定すると run() は実コマンドを実行せず表示のみ行う。
#
# 注意: このファイル自体は単体実行を想定していない（source 専用）。
#
# このプロジェクト（cloudwatch-log-viewer.sh）は common.sh を「任意」とし、
# 見つからない場合は本体側でフォールバック定義する。したがって既存の共通
# common.sh へ後から差し替えても動作するよう、依存関数は最小限にしている。

# 既に読み込み済みなら何もしない（多重 source 対策）
#   マーカー変数が環境に漏れていても、関数が未定義の新しいシェルでは必ず
#   定義し直すよう「変数あり かつ 関数定義済み」を読み込み済みの条件とする。
if [[ -n "${COMMON_SH_LOADED:-}" ]] && declare -F require_command >/dev/null 2>&1; then
  return 0 2>/dev/null || exit 0
fi
COMMON_SH_LOADED=1

# ---------------------------------------------------------------------------
# 色定義（端末が対応している場合のみ色を付ける）
#   本体側で NO_COLOR / --no-color に応じて後から setup_colors() で上書きされる。
# ---------------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RESET="$(printf '\033[0m')"
  C_RED="$(printf '\033[31m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_BLUE="$(printf '\033[34m')"
else
  C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
fi

# ---------------------------------------------------------------------------
# ログ関数（通常メッセージ・警告・エラーはすべて標準エラーへ出す。
#   標準出力はログイベント本体の出力専用にして、パイプ/リダイレクトを汚さない）
# ---------------------------------------------------------------------------
log_info()    { printf '%s[INFO]%s  %s\n'  "$C_BLUE"   "$C_RESET" "$*" >&2; }
log_success() { printf '%s[OK]%s    %s\n'  "$C_GREEN"  "$C_RESET" "$*" >&2; }
log_warn()    { printf '%s[WARN]%s  %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error()   { printf '%s[ERROR]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }

# デバッグログ（DEBUG=true のときだけ標準エラーへ出力する。秘密情報は出さない）
log_debug() {
  [[ "${DEBUG:-false}" == "true" ]] || return 0
  printf '%s[DEBUG]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2
}

# エラーメッセージを出して終了する
# usage: die "メッセージ" [終了コード]
die() {
  local msg="$1"
  local code="${2:-1}"
  log_error "$msg"
  exit "$code"
}

# ---------------------------------------------------------------------------
# コマンド実行ヘルパー
#   DRY_RUN=true のときは実行内容を表示するだけで実行しない。
# usage: run aws logs describe-log-groups
# ---------------------------------------------------------------------------
run() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    printf '%s[DRY-RUN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
    return 0
  fi
  printf '%s[RUN]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2
  "$@"
}

# ---------------------------------------------------------------------------
# 確認プロンプト
#   ASSUME_YES=true のときは確認せず yes とみなす。
#   DRY_RUN=true のときも確認をスキップする。
# usage: if confirm "本当に実行しますか?"; then ... ; fi
# ---------------------------------------------------------------------------
confirm() {
  local prompt="${1:-続行しますか?}"
  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    return 0
  fi
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "(dry-run のため確認をスキップ)"
    return 0
  fi
  local reply
  read -r -p "$prompt [y/N]: " reply
  case "$reply" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 必須コマンドの存在確認
# usage: require_command aws
# ---------------------------------------------------------------------------
require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "コマンドが見つかりません: $cmd" 3
}

# ---------------------------------------------------------------------------
# AWS 認証チェック（簡易版）
#   `aws sts get-caller-identity` が成功すれば認証済みとみなす。
#   ※ 本体スクリプトは終了コードを細かく分けるため独自の認証確認を持つ。
#     これは common.sh 単体利用時の互換用。
# ---------------------------------------------------------------------------
require_aws_authenticated() {
  require_command aws
  local ident
  if ident="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"; then
    log_debug "AWS 認証済み: ${ident}"
    return 0
  fi
  log_error "AWS が未認証です（有効な資格情報が見つかりません）。"
  log_error "  スクリプト実行前に、次のコマンドで認証してください:"
  log_error "      aws login --remote"
  exit 4
}
