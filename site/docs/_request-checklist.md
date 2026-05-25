# 文書修正チェックリスト

このファイルは，ユーザから再送された修正要望ごとの対応状況を確認するためのメモです．公開ページには出しません．

## 対応状況

- [x] 各論の列挙だけにせず，体系的な説明へ寄せる．
  - 対応箇所: `site/docs/ja/authoring/syntax.mdx`，`site/docs/ja/authoring/values-and-types.mdx`，`site/docs/ja/authoring/functions.mdx`，`site/docs/ja/dev/pipeline.mdx`
  - 確認内容: ファイル構造，値と型，関数，処理系の流れを，定義，構文，静的条件，実行時の扱い，診断，参照の順で説明している．

- [x] 関数のシグネチャと説明をまとめて表示するコンポーネントを作り，使い回す．
  - 対応箇所: `site/components/ApiCard.tsx`，`site/styles/global.css`
  - 利用箇所: `site/docs/ja/components/*.mdx`，`site/docs/ja/authoring/operators-and-builtins.mdx`，`site/docs/ja/authoring/functions.mdx`
  - 確認内容: 日本語の演算子ページでは `ApiCard` が 15 件表示される．

- [x] 各構文に複数の例を付ける．
  - 対応箇所: `site/docs/ja/authoring/syntax.mdx`
  - 確認内容: import，型定義，定数，関数，document，page，let，return，if，プロパティ，制約，式，ラムダ，文字列，実行例をそれぞれ例付きで説明している．

- [x] 基本的な演算子をまとめる．
  - 対応箇所: `site/docs/ja/authoring/operators-and-builtins.mdx`
  - 確認内容: `-`，`+`，`-`，`*`，`/`，`++` と，対応する `neg`，`add`，`sub`，`mul`，`div`，`concat` を表で説明している．

- [x] ページ間のリファレンスを増やす．
  - 対応箇所: `site/docs/ja/authoring/syntax.mdx`，`site/docs/ja/authoring/operators-and-builtins.mdx`，`site/docs/ja/authoring/values-and-types.mdx`，`site/docs/ja/components/*.mdx`，`site/docs/ja/dev/*.mdx`
  - 確認内容: 構文，値と型，演算子，関数，オブジェクト，プロパティ，制約，生成，配置，描画，実装ページへのリンクを追加している．

- [x] 式の節から基本演算子と関数へのリファレンスを貼る．
  - 対応箇所: `site/docs/ja/authoring/syntax.mdx`
  - 確認内容: 式の節で `site/docs/ja/authoring/operators-and-builtins.mdx` に誘導し，`ApiCard` で数値演算と文字列連結を表示している．

- [x] 導出記法をやめ，平易な説明へ寄せる．
  - 対応箇所: `site/docs/ja/authoring/*.mdx`，`site/docs/en/authoring/values-and-types.mdx`
  - 確認内容: `Γ`，`⊢`，`⇓`，導出罫線を文書から削除した．

- [x] 実行例を増やす．
  - 再監査前の問題: 以前の確認は，本文中にコマンド断片があることを対応済みとして扱っていた．実際には，いくつかのページで `slide.ss` のような仮の対象名のままで，そのまま実行できるサンプルファイル，プレビュー，`dump` で見る項目がそろっていなかった．
  - 対応箇所: `site/docs/ja/authoring/*.mdx`，`site/docs/ja/components/*.mdx`，`site/samples/*.ss`，`site/samples/assets/*`
  - 追加した著者向けサンプル: `site/samples/authoring-syntax.ss`，`site/samples/authoring-pages.ss`，`site/samples/authoring-values-and-types.ss`，`site/samples/authoring-functions.ss`，`site/samples/authoring-operators-and-builtins.ss`，`site/samples/authoring-constraints.ss`，`site/samples/authoring-objects.ss`，`site/samples/authoring-properties.ss`，`site/samples/authoring-generation.ss`
  - 追加したコンポーネント用サンプル: `site/samples/components-showcase.ss`，`site/samples/assets/sample-logo.svg`，`site/samples/assets/sample-card.pdf`
  - 確認内容: 著者向け全ページに `SsExample`，`ss check site/samples/...`，`ss dump site/samples/...`，`ss render site/samples/...`，確認する JSON/PDF の項目を入れた．コンポーネント全ページでは `components-showcase` のプレビューと実名コマンドに差し替えた．
  - 実行確認: `npm run render:samples` で，追加したすべての `site/samples/*.ss` から PDF とプレビュー画像を生成できることを確認した．

- [x] コンポーネント関数の説明を仕様のように断定しない．
  - 対応箇所: `site/docs/ja/authoring/functions.mdx`，`site/docs/ja/authoring/objects.mdx`，`site/docs/ja/dev/elaboration.mdx`，`site/docs/ja/components/*.mdx`
  - 確認内容: 標準ライブラリの多くのコンポーネント関数は現在ページへ object を追加して返す，`border` や `flow` は既存 object を更新する，文書全体の生成関数はページ列や既存 object を読む，という説明にしている．

- [x] プロパティ値の説明を修正する．
  - 対応箇所: `site/docs/ja/authoring/properties.mdx`，`site/docs/ja/authoring/values-and-types.mdx`，`site/docs/ja/dev/elaboration.mdx`，`site/docs/ja/dev/core-ir.mdx`
  - 確認内容: 代入の右辺は `string`，`number`，`bool`，`style` を受け付ける．中核 IR の保存形式では文字列へ変換される，と説明している．

- [x] 「役割」「内容種別」を用語として整える．
  - 対応箇所: `site/docs/ja/authoring/objects.mdx`，`site/docs/ja/dev/core-ir.mdx`，描画関連ページ
  - 確認内容: 利用者向け文書では `ロール` と `ペイロード種別` を使っている．英語側に残っていた日本語の「タイトル役割」も修正した．

- [x] 「テーマ変更後に PDF を確認します．」を自然な指示文へ直す．
  - 対応箇所: `site/docs/ja/themes/*.mdx`
  - 確認内容: PDF で見る対象を具体的に書く文へ変更した．

- [x] 「資産」を「アセット」へ統一する．
  - 対応箇所: `site/docs/ja/**/*.mdx`，`site/docs/ja/**/*.json`
  - 確認内容: 利用者向け日本語文書では `アセット` を使っている．

- [x] 古い段階名の説明をやめ，現行実装をソースとして書く．
  - 対応箇所: `site/docs/ja/dev/pipeline.mdx`，`site/docs/ja/dev/elaboration.mdx`，`site/docs/ja/dev/lowering.mdx`，`site/docs/en/dev/_meta.json`
  - 確認内容: 実装名は `src/elaboration` と `src/lowering` にそろえた．古い段階名のページは削除した．

- [x] Dev Docs に図，データ構造，定義，実行例を追加する．
  - 対応箇所: `site/docs/ja/dev/pipeline.mdx`，`site/docs/ja/dev/elaboration.mdx`，`site/docs/ja/dev/lowering.mdx`，`site/docs/ja/dev/core-ir.mdx`，`site/docs/ja/dev/layout-solver.mdx`
  - 確認内容: Mermaid 図，`Ir`，`Node`，`Document`，`Term`，`Constraint`，`Diagnostic` などの構造，処理手順，確認コマンドを追加した．

- [x] 廃止済みの型コンストラクタを公開向けの型説明から外す．
  - 対応箇所: `site/docs/ja/authoring/values-and-types.mdx`，`site/docs/en/authoring/values-and-types.mdx`，`site/docs/ja/dev/parser.mdx`
  - 確認内容: 公開向けの値と型ページから廃止済みの型コンストラクタの説明を削除した．内部実装の fragment は Dev Docs の中核 IR 側に残している．

## 検索確認

- [x] 古い段階名が公開文書に残っていない．
- [x] 導出記法で使っていた形式的な記号が公開文書に残っていない．
- [x] コンポーネント呼び出しを言語仕様のように断定する文が公開文書に残っていない．
- [x] プロパティ値を文字列だけに限定する文が公開文書に残っていない．
- [x] テーマ変更後の PDF 確認を不自然に述べる文が公開文書に残っていない．
- [x] 利用者向け日本語文書に `資産`，`内容種別` が残っていない．
- [x] 著者向けページとコンポーネントページに，仮の `ss check slide.ss`，`ss render slide.ss .ss-cache/out.pdf`，`ss dump slide.ss .ss-cache/dump.json` が残っていない．
- [x] サンプルに存在しないプロパティ名 `text_fill`，古い描画方式名 `pdf_asset`，実装にないペイロード表の `rule` / `panel` が残っていない．

## ビルド確認

- [x] `npm run build` が成功した．
- [x] Rspress の言語対応検査が成功した．
- [x] 既存の `DefinePlugin` の `import.meta.env.SSR` 警告が残っている．
