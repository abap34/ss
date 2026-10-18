import std:layout/types as { LayoutStyle }
import std:assets/types as { AssetStyle }
import std:graphics/paint/types as { ChromeStyle }

type AssetBlockStyle {
  layout: LayoutStyle = LayoutStyle {}
  asset: AssetStyle = AssetStyle {}
  chrome: ChromeStyle = ChromeStyle {}
}

const default_icon_style: AssetBlockStyle = AssetBlockStyle { asset = AssetStyle { tint = c"#374151" } }
