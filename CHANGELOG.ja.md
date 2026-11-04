# 変更履歴

[English](CHANGELOG.md) | 日本語

## 0.4.1 - 2026-11-04

- 修正: 閉じたタブのプロセス番号が別のプロセスに使い回されると、そのログがいつまでも消えなかった問題を直しました。ログに最後に書き込まれた後に起動したプロセスは、そのログを書いたタブではないと判断します（[#58](https://github.com/ysb3996-blip/oops/issues/58)）。
- 変更: 開いたままのタブも、`retention_days` より古いコマンドを自分のログから落とすようにしました。確かめるのはコマンドが終わったとき（1 時間に 1 回まで）です（[#59](https://github.com/ysb3996-blip/oops/issues/59)）。
- Ghostty 上の bash: Ghostty が外側のシェルにシェル統合を入れていた場合、記録される側のシェルでもう一度読み込むようにしました。zsh と fish はすでにそうしていました。README で bash の人に頼んでいた 1 行は、この場合は要りません（[#50](https://github.com/ysb3996-blip/oops/issues/50)）。
- 変更: 全画面アプリの出力の代わりに入る 1 行に、コマンド名を入れるようにしました。1 行に 1 コマンドのときだけで、たとえばページャーを通した `git log` なら `[git: full-screen output omitted]` です（[#45](https://github.com/ysb3996-blip/oops/issues/45)）。

## 0.4.0 - 2026-11-03

- `--print` / `-p` を追加。クリップボードの代わりに整形したテキストを標準出力へ書き出し、SSH 先・コンテナ・スクリプトからパイプできるようにします（[#40](https://github.com/ysb3996-blip/oops/issues/40)）。[@ShahadatTest](https://github.com/ShahadatTest) さんによる貢献（[#52](https://github.com/ysb3996-blip/oops/pull/52)）。

## 0.3.0 - 2026-11-02

- `oops clear` で閉じたタブのログを削除できます。`oops clear --all` は今のタブのログも空にします（[#42](https://github.com/ysb3996-blip/oops/issues/42)）。
- 変更: 閉じたタブのログは、最後のコマンドから 7 日たつと、タブが記録を始めるときに削除されるようになりました。日数は設定の `retention_days` で変えられます。`retention_days: false` にすると、50 MB の上限までは残ります（[#42](https://github.com/ysb3996-blip/oops/issues/42)）。
- fish に対応しました。`~/.config/fish/config.fish` に `oops init fish | source` を足します（[#9](https://github.com/ysb3996-blip/oops/issues/9)）。
- zsh のプラグインマネージャー（antidote・zinit・Oh My Zsh など）向けに `oops.plugin.zsh` を追加。clone したリポジトリの oops を動かすので、gem のインストールはいりません。
- Homebrew tap を用意しました: `brew install ysb3996-blip/oops/oops`。Homebrew の Ruby で oops を動かします。

## 0.2.0 - 2026-11-01

- `oops status` を追加。`recording`・`paused`・`off` のどれかを 1 行で出力し、記録中のときだけ終了コード 0 を返します。プロンプトやスクリプトから、このシェルが記録されているか確認できます。
- `--time` オプションを追加。各 `$ コマンド` の前に開始時刻（ローカル時刻）を `# 2026-10-31 19:30:09 +09:00` の行として入れ、`--github` の要約にも足します。
- `--output-only` オプションを追加。`$ コマンド` の行を省き、出力と `(exit N)` だけをコピーします。
- `oops` と `oops err` に `-n N` オプションを追加。`oops -n 3` は `oops 3` と同じで、`oops err -n 2` は直近の失敗した 2 コマンドを（成功したコマンドは飛ばして）古い順にコピーします。[@ricky9408](https://github.com/ricky9408) さんによる貢献（[#22](https://github.com/ysb3996-blip/oops/pull/22)）。
- メールアドレスのマスクが、`/opt/homebrew/opt/mysql@8.4` や `go@1.27` のような版付きの名前を伏せないように修正。ドメインの最後の部分が、実際のトップレベルドメインのように英字のときだけ伏せます（[#24](https://github.com/ysb3996-blip/oops/issues/24)）。

## 0.1.0 - 2026-10-30

最初のバージョン。

- `oops`、`oops N`、`oops err` で、直前のコマンドとその出力を Markdown のコードブロックとしてクリップボードにコピーする。
- `--github`、`--tail`、`--head`、`--show-secrets` オプション。
- 秘密情報（トークン、鍵、メールアドレス、URL 中の認証情報、公開 IPv4 アドレス、コマンドラインオプションで渡されたパスワード）は、出力だけでなくコマンドラインでも、標準でマスクされる。
- 置換テーブル、追加の秘密情報パターン、クリップボードの上書きを持つ設定ファイル。
- `oops init zsh|bash` による zsh と bash への対応。小さな pty 中継（`oops record`）で記録する。
- `oops pause`、`oops resume`、`oops doctor`。
