import std:assets/style as { ImageStyle }
import std:math/types as { LatexConfig }
import std:text as { NEWLINE }
import std:assets/content as { Image, ImageSource, ImageSourceKind }

type Latex {
  source: String
  style: ImageStyle? = none
  min_height: Number = 30
  config: LatexConfig = LatexConfig {}
}

type Math {
  source: String
  style: ImageStyle? = none
  min_height: Number = 30
  config: LatexConfig = LatexConfig {}
}

fn display(self: Placed<Latex>) -> Image
  return Image {
    source = ImageSource {
      kind = ImageSourceKind.latex
      source = self.value.source
      config = self.value.config
      min_height = self.value.min_height
    }
    style = self.value.style
  }
end

fn display(self: Placed<Math>) -> Latex
  return Latex {
    ;; A newline protects the closing delimiter from trailing TeX comments.
    source = "$\displaystyle " ++ self.value.source ++ NEWLINE ++ "$"
    style = self.value.style
    min_height = self.value.min_height
    config = self.value.config
  }
end
