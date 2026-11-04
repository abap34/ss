import std:math/style as { LatexBlockStyle }
import std:math/types as { LatexConfig }
import std:text as { NEWLINE }
import std:assets/content as { Image, ImageSource, ImageSourceKind }
import std:assets/style as { AssetBlockStyle }
import std:assets/types as { AssetStyle }

type Latex {
  source: String
  style: LatexBlockStyle = LatexBlockStyle {}
  config: LatexConfig = LatexConfig {}
}

type Math {
  source: String
  style: LatexBlockStyle = LatexBlockStyle {}
  config: LatexConfig = LatexConfig {}
}

fn display(self: Placed<Latex>) -> Image
  return Image {
    source = ImageSource {
      kind = ImageSourceKind.latex
      source = self.value.source
      config = self.value.config
      min_height = self.value.style.latex.min_height
    }
    style = AssetBlockStyle {
      layout = self.value.style.layout
      chrome = self.value.style.chrome
      asset = AssetStyle { scale = self.value.style.latex.scale align = self.value.style.latex.align }
    }
  }
end

fn display(self: Placed<Math>) -> Latex
  return Latex {
    ;; A newline protects the closing delimiter from trailing TeX comments.
    source = "$\displaystyle " ++ self.value.source ++ NEWLINE ++ "$"
    style = self.value.style
    config = self.value.config
  }
end
