<!-- English or 日本語, either is fine. -->

## What and why / 何を、なぜ


## Verification / 動作確認 (required / 必須)

<!-- Paste real output. A pull request without it is sent back before review. -->
<!-- 実際の出力を貼ってください。ないものはレビュー前に差し戻します。 -->

**Tests and style / テストとスタイル**

```
$ bundle exec rake test
(paste the "N runs, ... failures" line / 「N runs, ... failures」の行)

$ bundle exec rubocop
(paste the summary line / 要約の行)
```

**Behavior check in a new terminal tab / 新しい端末タブでの動作確認**

<!-- Install your build (see README "Development"), open a NEW tab, and paste what you ran and what it printed. -->
<!-- For docs-only changes, write "docs only". -->
<!-- 自分のビルドを入れて(README「開発」)新しいタブを開き、実行した内容と出力を貼ってください。ドキュメントのみの変更は「docs only」と書いてください。 -->

```
(commands and output / コマンドと出力)
```

## Checklist / チェックリスト

- [ ] I wrote the test first and saw it fail / 先にテストを書き、失敗を確認した
- [ ] README.ja.md / CHANGELOG.ja.md are updated if I changed the English files / 英語版を変えたら日本語版も更新した
- [ ] I did not paste session logs or private information / セッションログや個人情報を貼っていない
