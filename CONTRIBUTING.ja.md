# oops へのコントリビュート

[English](CONTRIBUTING.md) | 日本語

手を貸そうと思っていただき、ありがとうございます。oops は小さなツールなので、小さな貢献も歓迎です。誤字の修正、バグ報告、マスクのパターン追加、シェルまわりの調整など、何でも構いません。

## 手伝える方法

- **バグを報告する**: [バグ報告フォーム](https://github.com/ysb3996-blip/oops/issues/new?template=bug_report.md)を使います。`oops doctor` を実行して、その出力を貼ってください。
- **アイデアを提案する**: [機能要望フォーム](https://github.com/ysb3996-blip/oops/issues/new?template=feature_request.md)を使います。変えたい内容より先に、困っている状況を書いてください。
- **issue を引き受ける**: [`good first issue`](https://github.com/ysb3996-blip/oops/labels/good%20first%20issue) のラベルが付いた issue は、最初の貢献にちょうどよい大きさです。2 人が同じ作業をしないよう、始める前にコメントしてください。
- **ドキュメントを良くする**: 日本語訳も含みます。

小さな修正より大きな変更は、コードを書く前に issue を立てて、進め方を合意してください。

## セッションログは絶対に貼らない

oops は、すべてのコマンドの生の出力を、マスクせずに保存します（README の「プライバシーとセキュリティ」を参照）。issue にセッションログを添付しないでください。貼る前に内容を読み返してください。マスクは安全網であって、保証ではありません。

## 環境構築とプルリクエスト

環境構築の全手順（Ruby 3.3 以降、`bundle install`、自分のビルドを新しいタブで試す方法）は、README の「開発」にあります。流れは次のとおりです。

```sh
git clone https://github.com/<あなたのアカウント>/oops.git && cd oops
bundle install
git checkout -b fix/short-description
# ...コードを変更...
bundle exec rake test && bundle exec rubocop && gem build oops-cli.gemspec
```

プルリクエストを出す前に:

- **先にテストを書き**、正しい理由で失敗することを確認してください。バグ修正には、修正なしでは失敗するテストが必要です。
- 上の 3 つのコマンドをすべて実行してください。CI は Ubuntu と macOS で、Ruby 3.3・3.4・4.0 を使って実行します。
- **自分で動作確認をして、その結果をプルリクエストに貼ってください。** これは必須で、プルリクエストのテンプレートにも欄があります。貼るものは次のとおりです。`bundle exec rake test` の最後の行（`N runs, ... 0 failures` の行）、`bundle exec rubocop` の要約、そして動作に影響する変更では、自分のビルドを入れた**新しい端末タブ**で実行した内容とその出力です（例: `oops doctor` と試したコマンド、または変更前後の出力）。個人的な情報は先に隠してください。この確認がないプルリクエストは、レビューの前に差し戻します。
- 1 つのプルリクエストは、1 つの変更にしてください。説明には「なぜ」を書いてください。
- コミットメッセージは短く、`type(scope): summary` の形にします。例: `fix(ansi): keep words apart when a UI places them with cursor column jumps`。よく使う type は `fix`、`feat`、`docs`、`test`、`style`、`refactor` です。
- README や CHANGELOG を変えたときは、日本語版（`README.ja.md`、`CHANGELOG.ja.md`）も更新してください。日本語が書けない場合は、プルリクエストにそう書いてください。メンテナーが手伝います。

## コードの決まり

- **実行時に依存する gem を増やさない**: oops は素の `gem install` で入ります。この形を保ってください。開発用のツールは Gemfile にだけ入れます。
- 最低は Ruby 3.3 です。対応は macOS と Linux、zsh と bash です。どれかのために、別のどれかを壊さないでください。シェルのスニペットは、macOS の bash 3.2 でも動く必要があります。
- 変更箇所の周りの書き方（命名、コメントの量、書き癖）に合わせてください。`bundle exec rubocop` は違反なしにします。
- 作業中の端末で `oops record` を実行しないでください。テストは自前の pty を通して動かします。
- マスクの処理時間は、入力の大きさに比例する（線形）ままにしてください。新しいパターンにはテストが必要です。テキストをまたいで走査するパターンは、範囲に上限を付けます（`test/secrets_test.rb` の守りのテストを参照）。

## 行動の姿勢

親切に、相手に悪意はないものとして接してください。意見が分かれるのはコードについてで、人についてではありません。攻撃的な issue やプルリクエスト、話題から外れたものは、メンテナーが閉じることがあります。

## ライセンス

コントリビュートした内容は、このプロジェクトと同じ MIT ライセンスで提供されるものとします。
