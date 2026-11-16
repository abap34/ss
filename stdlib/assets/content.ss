import std:theme as { theme_for }
import std:assets/style as { ImageStyle }
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
  style: ImageStyle? = none
}

type Pdf {
  path: String
  pdf_page: Number = 1
  pdf_box: PdfPageBox = PdfPageBox.crop
  style: ImageStyle? = none
}

type Icon {
  source: String
  style: ImageStyle? = none
}

fn display(self: Placed<Image>) -> Image
  return self.value with { style = self.value.style ?? theme_for(self.page).image }
end

fn display(self: Placed<Pdf>) -> Image
  return Image {
    source = ImageSource {
      kind = ImageSourceKind.pdf
      source = self.value.path
      pdf_page = self.value.pdf_page
      pdf_box = self.value.pdf_box
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
