import assert from "node:assert/strict";

export async function checkSelectionReads({ source, texts, json, run }) {
  const definitions = `type Link { target: Ref<Placed<Text>> }
fn display(self: Placed<Link>) -> Text = text("Link")
fn describe(items: Selection<Placed<Link>>) -> String
  if selection_empty(items)
    return "empty"
  end
  return (*first(items).value.target).value.content.source
end
fn append(s: String, link: Placed<Link>) -> String = s ++ (*link.value.target).value.content.source`;
  const sample = body => [definitions, "page main", ...body, "end"].join("\n");
  const items = "select<Link>(pagectx())";
  for (const [placements, expected] of [
    [[], ["Read empty", "Fold Initial"]],
    [["  place!(Link { target = &later })"], ["Read Initial", "Fold InitialInitial"]],
  ]) {
    const input = await source(sample([...placements,
      `  text!("Read " ++ describe(${items}))`,
      `  text!("Fold " ++ fold(${items}, (*&later).value.content.source, append))`,
      '  let later = text!("Initial")']));
    const rendered = await texts(input);
    for (const s of expected) assert(rendered.includes(s));
    const g = await json(["debug", "schedule", input]);
    const id = prefix => g.units.find(u => u.source.startsWith(prefix)).id;
    const edge = (a,b) => g.edges.some(e => e.from === id(a) && e.to === id(b));
    assert(edge("let later", 'text!("Fold'));
    assert.equal(edge("let later", 'text!("Read'), placements.length !== 0);
  }
  run(["dump", "--quiet", await source(sample([
    `  text!((*first(${items}).value.target).value.content.source)`,
  ]))], "EmptySelection");

  // A false filter proves emptiness even if eligible objects were registered.
  assert((await texts(await source(sample([
    '  let target = text!("A")', "  place!(Link { target = &target })",
    `  text!("Filtered " ++ describe(filter(${items}, (x: Placed<Link>) |-> false)))`,
  ])))).includes("Filtered empty"));

  // Computed named queries preserve their selected element and its reference,
  // including after a join with another known reference.
  const uncertain = `fn choice(flag: Bool, a: Ref<Placed<Text>>, b: Ref<Placed<Text>>) -> Ref<Placed<Text>>
  if flag
    return a
  end
  return b
end`;
  for (const merge of [false, true]) {
    const input = await source([definitions, uncertain, "page main",
      '  let title = text!("Title")', '  let link = place!(Link { target = &title })',
      '  let r = first(select(link, "self_" ++ "placement")).value.target',
      merge ? '  let chosen = choice(page_index(pagectx()) == 1, &title, r)' : '  let chosen = r',
      '  text!((*chosen).value.content.source)', "end"].join("\n"));
    assert.deepEqual((await texts(input)).sort(), ["Link", "Title", "Title"]);
  }

  // A definitely empty operand cannot contribute an unknown element to a
  // nonempty union, regardless of the order of its operands.
  for (const operands of ["absent | known", "known | absent"]) {
    const input = await source(sample([
      '  let title = text!("Target")', '  let link = place!(Link { target = &title })',
      '  let queried = select(link, "self_" ++ "placement")',
      '  let absent = filter(queried, (v: Placed<Link>) |-> false)',
      '  let known = selection(link)',
      `  let r = first(${operands}).value.target`,
      '  let actual = (*r).value.content.source',
    ]));
    assert((await texts(input)).includes("Target"));
  }

  // Evaluating the drawing operand just registers the object. Only the
  // deferred predicate reads the later placement.
  const staged = await source(`page main
  show page_index((*&later).page) == 1
    let shown = text!("Shown")
  end
  let later = text!("Later")
end`);
  assert((await texts(staged)).includes("Shown"));
  const graph = await json(["debug", "schedule", staged]);
  const drawing = graph.units.find(u => u.kind === "drawing_condition");
  assert(drawing);
  const later = graph.units.find(u => u.source.startsWith("let later")).id;
  assert(graph.edges.some(e => e.from === later && e.to === drawing.id));
  assert(!graph.edges.some(e => e.from === later && e.to === drawing.producer));

  // One dereference in a shared function must not union two callers' edges.
  const reads = await source(`fn label(r: Ref<Placed<Text>>) -> String = (*r).value.content.source
page main
  let a = text!("A")
  let x = text!(label(&a))
  let b = text!(x.value.content.source)
  let y = text!(label(&b))
end`);
  const g = await json(["debug", "schedule", reads]);
  const id = name => g.units.find(u => u.source.startsWith("let " + name + " =")).id;
  const edge = (a,b) => g.edges.some(e => e.from === id(a) && e.to === id(b));
  assert(edge("a","x") && edge("x","b") && edge("b","y") && !edge("b","x"));
}
