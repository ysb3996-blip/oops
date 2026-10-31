# 変更履歴

[English](CHANGELOG.md) | 日本語

## 未リリース

- `oops` と `oops err` に `-n N` オプションを追加。`oops -n 3` は `oops 3` と同じで、`oops err -n 2` は直近の失敗した 2 コマンドを（成功したコマンドは飛ばして）古い順にコピーします。[@ricky9408](https://github.com/ricky9408) さんによる貢献（[#22](https://github.com/ysb3996-blip/oops/pull/22)）。

## 0.1.0 - 2026-10-30

最初のバージョン。

- `oops`、`oops N`、`oops err` で、直前のコマンドとその出力を Markdown のコードブロックとしてクリップボードにコピーする。
- `--github`、`--tail`、`--head`、`--show-secrets` オプション。
- 秘密情報（トークン、鍵、メールアドレス、URL 中の認証情報、公開 IPv4 アドレス、コマンドラインオプションで渡されたパスワード）は、出力だけでなくコマンドラインでも、標準でマスクされる。
- 置換テーブル、追加の秘密情報パターン、クリップボードの上書きを持つ設定ファイル。
- `oops init zsh|bash` による zsh と bash への対応。小さな pty 中継（`oops record`）で記録する。
- `oops pause`、`oops resume`、`oops doctor`。
