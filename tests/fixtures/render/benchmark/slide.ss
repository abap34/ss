import std:themes/default as *

page overview
let heading = h1!("Rendering benchmark")
let body = text! <<
This fixture exercises the shared PDF and HTML rendering path with several pages，
wrapped text，**Markdown emphasis**，lists，tables，mathematics，and external assets．

- deterministic positioned text
- native vector and raster resources
- embedded PDF pages
>>
~ heading.left == page.left + 88
~ heading.top == page.top - 64
~ body.left == page.left + 104
~ body.right == page.right - 104
~ body.top == heading.bottom - 48
end

page typography
let heading = h1!("Typography and wrapping")
let body = text! <<
Long paragraphs force the compiler to preserve line breaking，glyph clusters，fallback
fonts，and baselines in the rendering intermediate representation．The HTML backend
must replay that placement without asking the browser to choose different line breaks．

日本語の文字列と Latin text を同じ段落に置き，字体代替と基準線も測定する．
>>
~ heading.left == page.left + 88
~ heading.top == page.top - 64
~ body.left == page.left + 104
~ body.right == page.right - 104
~ body.top == heading.bottom - 48
end

page table
let heading = h1!("Markdown table")
let body = text! <<
| Resource | PDF output | HTML output |
| --- | --- | --- |
| Text | Cairo glyphs | positioned spans |
| SVG | librsvg | original SVG image |
| PDF | Form XObject | PDF.js layers |
| Math | shared layout | positioned math boxes |

The table adds borders，fills，alignment，and repeated short text runs．
>>
~ heading.left == page.left + 88
~ heading.top == page.top - 64
~ body.left == page.left + 104
~ body.right == page.right - 104
~ body.top == heading.bottom - 48
end

page latex_math
let heading = h1!("LaTeX mathematics")
let formula = latex!("$x_1^2 + \frac{a+b}{\sqrt{c}} = y^{n+1}$", 1.5)
let body = text! <<
Inline mathematics keeps $x_1^2 + \alpha$ on the surrounding baseline．

$$
\frac{a+b}{\sqrt{c}}
$$
>>
~ heading.left == page.left + 88
~ heading.top == page.top - 64
~ formula.left == page.left + 144
~ formula.top == heading.bottom - 56
~ body.left == page.left + 104
~ body.right == page.right - 104
~ body.top == formula.bottom - 64
end

page dense_inline_math
let heading = h1!("Dense inline LaTeX")
let body = text! <<
This Markdown page contains many small formulas among short prose fragments.

$x_1$, $x_2$, $x_3$, $x_4$, $x_5$, $x_6$, $x_7$, $x_8$, $x_9$, $x_{10}$, $x_{11}$, $x_{12}$.

$a+b$, $a-b$, $ab$, $a/b$, $a^2$, $b^2$, $a_1$, $b_1$, $\alpha$, $\beta$, $\gamma$, $\delta$.

$f(x)$, $g(x)$, $h(x)$, $\sin x$, $\cos x$, $\tan x$, $e^x$, $\log x$, $\sqrt{x}$, $|x|$, $x!$, $n!$.

$u_1$, $u_2$, $v_1$, $v_2$, $p+q$, $p-q$, $pq$, $p/q$, $r^2$, $s^2$, $i+j$, $i-j$.
>>
~ heading.left == page.left + 88
~ heading.top == page.top - 64
~ body.left == page.left + 104
~ body.right == page.right - 104
~ body.top == heading.bottom - 48
end

page vector_asset
let heading = h1!("Explicit SVG resource")
let asset = image!("asset.svg", 0.72)
~ heading.left == page.left + 88
~ heading.top == page.top - 64
~ asset.left == page.left + 184
~ asset.top == heading.bottom - 60
end

page raster_asset
let heading = h1!("Raster resource")
let asset = image!("asset.png", 0.45)
~ heading.left == page.left + 88
~ heading.top == page.top - 64
~ asset.left == page.left + 360
~ asset.top == heading.bottom - 72
end

page pdf_asset
let heading = h1!("Embedded PDF page")
let asset = pdf!("asset.pdf", 0.62, 2)
~ heading.left == page.left + 88
~ heading.top == page.top - 64
~ asset.left == page.left + 356
~ asset.top == heading.bottom - 48
end

page mixed
let heading = h1!("Mixed page")
let body = text! <<
The last page repeats the common workload with **styled text**，$x_i + y_i = z_i$，
and a compact external vector resource．Repeated resources also exercise digest-based
deduplication and cache lookup．
>>
let asset = image!("asset.svg", 0.35)
~ heading.left == page.left + 88
~ heading.top == page.top - 64
~ body.left == page.left + 104
~ body.right == page.right - 104
~ body.top == heading.bottom - 48
~ asset.left == page.left + 392
~ asset.top == body.bottom - 48
end
