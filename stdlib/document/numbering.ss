import std:query as query

type NumberingState {
  count: Number = 0
  result: Number? = none
}

fn step<T>(state: NumberingState, item: Placed<T>, target: Placed<T>) -> NumberingState
  let next = state.count + 1
  if !selection_empty(query::selection(item) & query::selection(target))
    return NumberingState { count = next result = next }
  end
  return state with { count = next }
end

;; One-based position in the supplied construction-ordered selection.
fn number_of<T>(target: Placed<T>, items: Selection<Placed<T>>) -> Number?
  return fold(items, NumberingState {}, (state: NumberingState, item: Placed<T>) |-> step(state, item, target)).result
end
