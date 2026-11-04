import std:layout/types as { Align }

enum PdfPageBox { media crop bleed trim art }

type AssetStyle {
  scale: Number = 1
  tint: Color? = none
  align: Align? = none
  pdf_page: Number = 1
  pdf_box: PdfPageBox = PdfPageBox.crop
}
