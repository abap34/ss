import std:assets/style as { AssetBlockStyle }
import std:assets/types as { AssetStyle }

type Image {
  path: String
  style: AssetBlockStyle = AssetBlockStyle {}
}

type Pdf {
  path: String
  style: AssetBlockStyle = AssetBlockStyle {}
}

type Icon {
  source: String
  style: AssetBlockStyle = AssetBlockStyle { asset = AssetStyle { tint = c"#374151" } }
}
