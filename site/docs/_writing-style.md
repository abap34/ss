# 文書の書き方

このメモは，`site/docs` を直すときの基準です．参照した方針は次のリポジトリです．

- <https://github.com/blader/humanizer>
- <https://github.com/blader/humanizer/blob/main/SKILL.md>
- <https://github.com/conorbronsdon/avoid-ai-writing>
- <https://github.com/199-biotechnologies/humanise-text-skill>
- <https://github.com/adenaufal/anti-slop-writing>
- <https://github.com/dannwaneri/voice-humanizer>

## 基本

- 事実，構文，コマンド，返り値，診断を直接書く．
- 読者の作業に関係しない実装都合を書かない．
- 「このページでは」「このページは」「この章」「ここでは」「まず」「見ていきます」のような予告文を置かない．必要なら見出しに内容を書く．
- 「単なる X ではなく Y」「X だけではなく Y」「Not only」型の対比を避ける．肯定文で書く．
- 「重要」「強力」「柔軟」「シームレス」「モダン」「いい感じ」のような評価語を使わない．必要なら具体的な機能を書く．
- 用語を言い換えない．`object`，`page`，`document`，`selection`，`metadata` などは同じ語で通す．
- 句読点は `，` と `．` を使う．

## 日本語

- 「できます」を連発しない．機能説明では「使います」「書きます」「指定します」「返します」を使う．
- 「確認してください」を連発しない．検査手順では「見る値は」「出力には」「PDF では」のように対象を先に書く．
- 「概要」「全体像」だけの節を増やさない．表や定義があるなら節名に対象を入れる．
- 名詞だけの箇条書きを避ける．一覧が必要な箇所では，表にして列名を具体的にする．
- 英語の直訳を避ける．「資産」は使わず「アセット」と書く．「役割」「内容種別」のような一般語訳は避け，必要なら `role`，`payload` と書く．

## 英語

- `serves as`，`boasts`，`showcases`，`seamless`，`robust`，`comprehensive`，`key` を避ける．
- `not just X but Y`，`from X to Y`，三つ組の箇条書きを避ける．
- em dash と en dash を本文の区切りに使わない．
- 章末の一般論を書かない．最後の文は，その節で使った具体的な対象で終える．

## 検査

本文を書いた後に，次の観点で読む．

- その文は読者の操作，仕様理解，診断理解に直接関係するか．
- 同じことを短く言えるか．
- 抽象語を，実際の構文名，関数名，ファイル名，コマンド名に置き換えられるか．
- 節の冒頭が見出しの言い換えになっていないか．
- 例の後に，実行結果や見るべき値を書いているか．
