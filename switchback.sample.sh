#!/usr/bin/env bash
#
# switchback.sample.sh （サンプル / 雛形）
# =======================================
# CodeCommit 等の作業用ロールへ「スイッチロール」した状態から元のロールへ戻す
# （スイッチバックする）ための雛形です。cloudwatch-log-viewer.sh から
# **source** されることを前提とし、環境変数の unset を呼び出し元シェル
# （本体スクリプトのプロセス）へ反映させます。
#
#   本体側での使い方:
#     ./cloudwatch-log-viewer.sh --switchback-mode auto \
#       --switchback-script /path/to/switchback.sample.sh
#
#   ※ これは雛形です。実運用では別チーム提供の正式なスイッチバック用シェルを
#      --switchback-script / 環境変数 CLOUDWATCH_LOG_SWITCHBACK_SCRIPT で指定して
#      差し替えてください（その内容は信頼済みである必要があります）。
#
# 重要:
#   - source される前提のため exit を使わず return で抜けます。
#   - 引数が必要な場合は本体側の --switchback-arg VALUE で渡され、$1, $2 ... で
#     参照できます（この雛形では引数は使用しません）。

# source ではなく直接実行された場合は意味がないため警告する。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "[switchback.sample.sh][ERROR] このスクリプトは source して使ってください。" >&2
  exit 1
fi

# スイッチロールで設定され得る一時クレデンシャル系環境変数を破棄する。
# これらが無くなると AWS CLI/SDK はベースの認証情報チェーン
# （EC2 インスタンスプロファイル等＝元のロール）へ自動的に戻る。
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN
unset AWS_SECURITY_TOKEN          # 古い SDK 互換
unset AWS_CREDENTIAL_EXPIRATION
unset AWS_PROFILE                 # プロファイル指定が残っていれば解除

echo "[switchback.sample.sh][OK] スイッチバックしました（一時クレデンシャル環境変数を破棄）。"
return 0 2>/dev/null || true
