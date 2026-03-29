# YES Script
`YES` - **Y**our **E**xtensible **S**cript .

YES is a meta [scriptlet standard][SPEC] whose elements and meaning are determined
by **YOU** the programmer. They can be extended further with attributes which
allow **YOUR** end-users to make their additions to **YOUR** elements.

## Getting Started
This Lua library provides a parser which reads an entire file's contents by string.
You do not need to split the contents. The parser will do that for you.

The only function exported from `lib.lua` is `read(filepath) -> {elements: {}, errors: {}}`.

Both `elements` and `errors` are lists.

See [element.lua](./src/element.lua) for the full Yes Element API.

Each `error` table has the form `{line=int, type=string}` to report to users
which problem ocurred and at what line.

## License
This project is licensed under the [Common Development and Distribution License (CDDL)][LEGAL].

[SPEC]: https://github.com/TheMaverickProgrammer/lua_yes_parser/blob/master/spec/README.md
[LEGAL]: https://github.com/TheMaverickProgrammer/lua_yes_parser/blob/master/legal/LICENSE.md