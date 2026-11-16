import std:assets/content as { Image, Pdf, Icon, ImageSource, ImageSourceKind, image_source }
import std:assets/style as { ImageStyle }
import std:assets/types as { PdfPageBox }

fn/! image(path: String, style: ImageStyle? = none) -> Image
  return Image { source = image_source(path) style = style }
end

fn/! pdf(path: String, style: ImageStyle? = none, pdf_page: Number = 1, pdf_box: PdfPageBox = PdfPageBox.crop) -> Pdf
  return Pdf { path = path style = style pdf_page = pdf_page pdf_box = pdf_box }
end

fn/! icon(source: String, style: ImageStyle? = none) -> Icon
  return Icon { source = source style = style }
end
