# Notes for agents

## Keep the type checker fast

Release builds (`./make-app.sh`) compile the whole module in one job, so a single
slow expression holds up the entire build. Swift's type checker slows down sharply
on long expressions that mix literals, ternaries and overloaded operators. One
`notes` expression in `SetModel.performSave(to:)`, five `cond ? ["…"] : []` arrays
joined with `+`, once took ~13s, half the build.

- Don't chain `+` across ternaries, array or string literals, or interpolations.
  Build the value up step by step instead (`var x: [String] = []`, then
  `if … { x.append(…) }`).
- Give a long literal or closure an explicit type rather than leaving it to inference.
- Split a large conditional or arithmetic expression into named `let`s.

To find slow spots:

    swift build -c release \
      -Xswiftc -Xfrontend -Xswiftc -debug-time-function-bodies 2>&1 \
      | grep -E '^[0-9.]+ms' | sort -rn | head

Anything over ~100ms deserves a look.
