import std:assets/style as { AssetBlockStyle, default_icon_style }

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
  style: AssetBlockStyle = default_icon_style
}
