enum PdfPageBox { media crop bleed trim art }

type AssetStyle {
  scale: Number = 1
  tint: Color? = none
  width: Number? = none
  pdf_page: Number = 1
  pdf_box: PdfPageBox = PdfPageBox.crop
}
