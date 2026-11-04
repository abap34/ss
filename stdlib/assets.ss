import std:assets/content as { Image, Pdf, Icon, ImageSource, ImageSourceKind, image_source }
import std:assets/style as { AssetBlockStyle, default_icon_style }
import std:assets/types as { PdfPageBox, AssetStyle }

fn/! image(path: String, style: AssetBlockStyle = AssetBlockStyle {}) -> Image
  return Image { source = image_source(path) style = style }
end

fn/! pdf(path: String, style: AssetBlockStyle = AssetBlockStyle {}) -> Pdf
  return Pdf { path = path style = style }
end

fn/! icon(source: String, style: AssetBlockStyle = default_icon_style) -> Icon
  return Icon { source = source style = style }
end
