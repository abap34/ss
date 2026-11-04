import std:assets/style as { AssetBlockStyle, default_icon_style }
import std:assets/types as { PdfPageBox }
import std:math/types as { LatexConfig }

enum ImageSourceKind { file pdf icon latex }

type ImageSource {
  kind: ImageSourceKind = ImageSourceKind.file
  source: String
  pdf_page: Number = 1
  pdf_box: PdfPageBox = PdfPageBox.crop
  config: LatexConfig = LatexConfig {}
  min_height: Number = 30
}

fn image_source(path: String) -> ImageSource
  return ImageSource { source = path }
end

type Image {
  source: ImageSource
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

fn display(self: Placed<Pdf>) -> Image
  return Image {
    source = ImageSource {
      kind = ImageSourceKind.pdf
      source = self.value.path
      pdf_page = self.value.style.asset.pdf_page
      pdf_box = self.value.style.asset.pdf_box
    }
    style = self.value.style
  }
end

fn display(self: Placed<Icon>) -> Image
  return Image {
    source = ImageSource { kind = ImageSourceKind.icon source = self.value.source }
    style = self.value.style
  }
end
