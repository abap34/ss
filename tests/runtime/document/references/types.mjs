import assert from "node:assert/strict";

export async function checkReferenceTypes({ source, texts, run }) {
  const declarations = `type Link<T> { target: Ref<Placed<T>> }
fn page_of<T>(r: Ref<Placed<T>>) -> Number = page_index((*r).page)
fn optional<T>(r: Ref<Placed<T>>?, fallback: Ref<Placed<T>>) -> Number = page_of(r ?? fallback)
fn pick<T>(a: Ref<T>, b: Ref<T>) -> Ref<T> = a`;
  const sample = body => [declarations, "page sample",
    '  let title = text!("Title")', '  let other = text!("Other")',
    ...body, "end"].join("\n");
  const good = await source(sample([
    "  let link = Link { target = &title }",
    "  let maybe: Ref<Placed<Text>>? = &title",
    '  text!("Pages " ++ str(page_of(link.target)) ++ str(optional(maybe, &other)) ++ str(page_of(pick(&title, &other))))',
  ]));
  assert((await texts(good)).includes("Pages 111"));

  // Group tuple erasure applies to values, not to invariant binding references.
  for (const args of ["&title, &pair", "&pair, &title"]) {
    run(["dump", "--quiet", await source(sample([
      "  let pair = group!(other)", `  let r = pick(${args})`,
    ]))], "ConflictingTypeArguments");
  }
  for (const declaration of [
    "let r: Ref<Placed<Group>> = &pair",
    "let r: Ref<Placed<Group>>? = &pair",
    "let r = Link<Group> { target = &pair }",
    "let r = pick<Placed<Group>>(&pair, &pair)",
  ]) {
    run(["dump", "--quiet", await source(sample([
      "  let pair = group!(other)", `  ${declaration}`,
    ]))], "TypeMismatch");
  }
  assert((await texts(await source(sample([
    "  let pair: Placed<Group> = group!(other)",
    "  let r: Ref<Placed<Group>> = &pair",
    '  text!("Group page " ++ str(page_of(r)))',
  ])))).includes("Group page 1"));

  for (const invalid of ["Placement", "Ref<Placement>", "Selection<Placement>"]) {
    run(["dump", "--quiet", await source(`fn invalid(value: ${invalid}) -> Void\nend`)], "UnknownType");
  }
  run(["dump", "--quiet", await source("fn invalid(value: Placed) -> Void\nend")], "InvalidTypeArity");

  const selections = `type Label<T> { value: T }
fn display<T>(self: Placed<Label<T>>) -> Text = text("Label")
page sample
  let a = place!(Label { value = 1 })
  let b = place!(Label { value = "Word" })
  let numbers = select<Label<Number>>(pagectx())
  let words = select<Label<String>>(pagectx())
`;
  for (const op of ["|", "&", "-"]) {
    for (const [left, right] of [["numbers", "words"], ["words", "numbers"], ["numbers", "pages(docctx())"]]) {
      run(["dump", "--quiet", await source(`${selections}  let invalid = ${left} ${op} ${right}\nend`)], "InvalidSelectionAlgebra");
    }
  }
  const algebra = await texts(await source(`${selections}
  let values = numbers | selection(a)
  let common = values & numbers
  let empty = values - common
  text!("Counts " ++ str(selection_count(values)) ++ str(selection_count(common)) ++ str(selection_count(empty)))
  text!("Value " ++ str(first(values).value.value))
end`));
  assert(algebra.includes("Counts 110"));
  assert(algebra.includes("Value 1"));

  for (const expr of ['anchor(text("Value"), "left")', 'selection<Text>(text("Value"))', 'select(pagectx(), "self_placement")']) {
    run(["dump", "--quiet", await source(`page sample\n  let invalid = ${expr}\nend`)], "TypeMismatch");
  }
}
