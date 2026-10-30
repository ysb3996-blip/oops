# 変更履歴

[English](CHANGELOG.md) | 日本語

## 0.1.0 - 2026-10-30

最初のバージョン。

- `oops`、`oops N`、`oops err` で、直前のコマンドとその出力を Markdown のコードブロックとしてクリップボードにコピーする。
- `--github`、`--tail`、`--head`、`--show-secrets` オプション。
- 秘密情報（トークン、鍵、メールアドレス、URL 中の認証情報、公開 IPv4 アドレス、コマンドラインオプションで渡されたパスワード）は、出力だけでなくコマンドラインでも、標準でマスクされる。
- 置換テーブル、追加の秘密情報パターン、クリップボードの上書きを持つ設定ファイル。
- `oops init zsh|bash` による zsh と bash への対応。小さな pty 中継（`oops record`）で記録する。
- `oops pause`、`oops resume`、`oops doctor`。
