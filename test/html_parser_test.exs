defmodule HTMLParserTest do
  use ExUnit.Case

  import HTMLParser

  test "empty node" do
    assert parse("") == {:ok, []}
  end

  test "only text" do
    assert parse("Some text") == {:ok, ["Some text"]}
  end

  test "keep spaces before node" do
    assert parse("\n<div></div>") ==
             {:ok,
              [
                "\n",
                {"div", [], [], %{line: 2}}
              ]}
  end

  test "keep spaces after node" do
    assert parse("<div></div>\n") ==
             {:ok,
              [
                {"div", [], [], %{line: 1}},
                "\n"
              ]}
  end

  test "multiple nodes" do
    code = """
    <div>
      Div 1
    </div>
    <div>
      Div 2
    </div>
    """

    assert parse(code) ==
             {:ok,
              [
                {"div", [], ["\n  Div 1\n"], %{line: 1}},
                "\n",
                {"div", [], ["\n  Div 2\n"], %{line: 4}},
                "\n"
              ]}
  end

  test "text before and after" do
    assert parse("hello<foo>bar</foo>world") ==
             {:ok, ["hello", {"foo", [], ["bar"], %{line: 1}}, "world"]}
  end

  test "ignore comments" do
    code = """
    <div>
      <!-- This will be ignored -->
      <span/>
    </div>
    """

    assert parse(code) == {:ok, [
      {
        "div",
        '',
        [
          "\n  ",
          "\n  ",
          {"span", [], [], %{line: 3, space: ""}},
          "\n"
        ],
        %{line: 1}
      },
      "\n"
    ]}
  end

  describe "add warning on void element without self closing tag" do
    test "without attributes" do
      code = """
      <div>
        <hr>
      </div>
      """

      {:ok, [{"div", [], ["\n  ", node, "\n"], _}, "\n"]} = parse(code)
      {"hr", [], [], %{line: line, space: "", warn: warn}} = node

      assert warn ==
        "void element \"hr\" not following XHTML standard. Please replace <hr> with <hr/>"
      assert line == 2
    end

    test "with attributes" do
      code = """
      <div>
        <img
          src="file.gif"
          alt="My image"
        >
      </div>
      """

      {:ok, [{"div", [], ["\n  ", node, "\n"], _}, "\n"]} = parse(code)
      {"img", attributes, [], %{line: line, space: "\n  ", warn: warn}} = node

      assert attributes == [
        {"src", 'file.gif', %{line: 3, spaces: ["\n    ", "", ""]}},
        {"alt", 'My image', %{line: 4, spaces: ["\n    ", "", ""]}}
      ]

      assert warn ==
        "void element \"img\" not following XHTML standard. Please replace <img> with <img/>"
      assert line == 2
    end
  end

  describe "HTML only" do
    test "single node" do
      assert parse("<foo>bar</foo>") ==
               {:ok, [{"foo", [], ["bar"], %{line: 1}}]}
    end

    test "Elixir node" do
      assert parse("<Foo.Bar>bar</Foo.Bar>") ==
               {:ok, [{"Foo.Bar", [], ["bar"], %{line: 1}}]}
    end

    test "mixed nodes" do
      assert parse("<foo>one<bar>two</bar>three</foo>") ==
               {:ok,
                [{"foo", [], ["one", {"bar", [], ["two"], %{line: 1}}, "three"], %{line: 1}}]}
    end

    test "self-closing nodes" do
      assert parse("<foo>one<bar><bat/></bar>three</foo>") ==
               {:ok,
                [
                  {"foo", [],
                   ["one", {"bar", [], [{"bat", [], [], %{line: 1, space: ""}}], %{line: 1}}, "three"],
                   %{line: 1}}
                ]}
    end
  end

  describe "interpolation" do
    test "single curly bracket" do
      assert parse("<foo>{bar}</foo>") ==
               {:ok, [{"foo", [], ["{", "bar}"], %{line: 1}}]}
    end

    test "double curly bracket" do
      assert parse("<foo>{{baz}}</foo>") ==
               {:ok, [{"foo", '', [{:interpolation, "baz"}], %{line: 1}}]}
    end

    test "mixed curly bracket" do
      assert parse("<foo>bar{{baz}}bat</foo>") ==
               {:ok, [{"foo", '', ["bar", {:interpolation, "baz"}, "bat"], %{line: 1}}]}
    end

    test "single-closing curly bracket" do
      assert parse("<foo>bar{{ 'a}b' }}bat</foo>") ==
               {:ok, [{"foo", [], ["bar", {:interpolation, " 'a}b' "}, "bat"], %{line: 1}}]}
    end
  end

  describe "with macros" do
    test "single node" do
      assert parse("<#foo>bar</#foo>") ==
               {:ok, [{"#foo", [], ["bar"], %{line: 1}}]}
    end

    test "mixed nodes" do
      assert parse("<#foo>one<bar>two</baz>three</#foo>") ==
               {:ok, [{"#foo", [], ["one<bar>two</baz>three"], %{line: 1}}]}

      assert parse("<#foo>one<#bar>two</#baz>three</#foo>") ==
               {:ok, [{"#foo", [], ["one<#bar>two</#baz>three"], %{line: 1}}]}

      assert parse("<#foo>one<bar>two<baz>three</#foo>") ==
               {:ok, [{"#foo", [], ["one<bar>two<baz>three"], %{line: 1}}]}

      assert parse("<#foo>one</bar>two</baz>three</#foo>") ==
               {:ok, [{"#foo", [], ["one</bar>two</baz>three"], %{line: 1}}]}
    end
  end

  describe "errors on" do
    test "invalid opening tag" do
      assert parse("<>bar</>") ==
               {:error, "expected opening HTML tag", 1}
    end

    test "invalid closing tag" do
      assert parse("<foo>bar</></foo>") ==
               {:error, "expected closing tag for \"foo\"", 1}
    end

    test "tag mismatch" do
      assert parse("<foo>bar</baz>") ==
               {:error, "closing tag \"baz\" did not match opening tag \"foo\"", 1}
    end

    test "incomplete tag content" do
      assert parse("<foo>bar") ==
               {:error, "expected closing tag for \"foo\"", 1}
    end

    test "incomplete macro content" do
      assert parse("<#foo>bar</#bar>") ==
               {:error, "expected closing tag for \"#foo\"", 1}
    end

    test "non-closing interpolation" do
      assert parse("<foo>{{bar</foo>") ==
               {:error, "expected closing for interpolation", 1}
    end
  end

  describe "attributes" do
    test "regular nodes" do
      code = """
      <foo
        prop1="value1"
        prop2="value2"
      >
        bar
        <div>{{ var }}</div>
      </foo>
      """

      attributes = [
        {"prop1", 'value1', %{line: 2, spaces: ["\n  ", "", ""]}},
        {"prop2", 'value2', %{line: 3, spaces: ["\n  ", "", ""]}}
      ]

      children = [
        "\n  bar\n  ",
        {"div", [], [{:interpolation, " var "}], %{line: 6}},
        "\n"
      ]

      assert parse(code) == {:ok, [{"foo", attributes, children, %{line: 1}}, "\n"]}
    end

    test "self-closing nodes" do
      code = """
      <foo
        prop1="value1"
        prop2="value2"
      />
      """

      attributes = [
        {"prop1", 'value1', %{line: 2, spaces: ["\n  ", "", ""]}},
        {"prop2", 'value2',  %{line: 3, spaces: ["\n  ", "", ""]}}
      ]

      assert parse(code) == {:ok, [{"foo", attributes, [], %{line: 1, space: "\n"}}, "\n"]}
    end

    test "regular nodes with whitespaces" do
      code = """
      <foo
        prop1
        prop2 = "value 2"
        prop3 =
          {{ var3 }}
        prop4
      ></foo>
      """

      attributes = [
        {"prop1", true, %{line: 2, spaces: ["\n  ", "\n  "]}},
        {"prop2", 'value 2', %{line: 3, spaces: ["", " ", " "]}},
        {"prop3", {:attribute_expr, [" var3 "]},
          %{line: 4, spaces: ["\n  ", " ", "\n    "]}
        },
        {"prop4", true, %{line: 6, spaces: ["\n  ", "\n"]}}
      ]

      assert parse(code) == {:ok, [{"foo", attributes, [], %{line: 1}}, "\n"]}
    end

    test "self-closing nodes with whitespaces" do
      code = """
      <foo
        prop1
        prop2 = "2"
        prop3 =
          {{ var3 }}
        prop4
      />
      """

      attributes = [
        {"prop1", true, %{line: 2, spaces: ["\n  ", "\n  "]}},
        {"prop2", '2', %{line: 3, spaces: ["", " ", " "]}},
        {"prop3", {:attribute_expr, [" var3 "]}, %{line: 4, spaces: ["\n  ", " ", "\n    "]}},
        {"prop4", true, %{line: 6, spaces: ["\n  ", "\n"]}}
      ]

      assert parse(code) == {:ok, [{"foo", attributes, [], %{line: 1, space: ""}}, "\n"]}
    end

    test "value as expression" do
      code = """
      <foo
        prop1={{ var1 }}
        prop2={{ var2 }}
      />
      """

      attributes = [
        {"prop1", {:attribute_expr, [" var1 "]},
          %{line: 2, spaces: ["\n  ", "", ""]}
        },
        {"prop2", {:attribute_expr, [" var2 "]},
          %{line: 3, spaces: ["\n  ", "", ""]}
        }
      ]

      assert parse(code) == {:ok, [{"foo", attributes, [], %{line: 1, space: "\n"}}, "\n"]}
    end

    test "integer values" do
      code = """
      <foo
        prop1=1
        prop2=2
      />
      """

      attributes = [
        {"prop1", 1, %{line: 2, spaces: ["\n  ", "", ""]}},
        {"prop2", 2, %{line: 3, spaces: ["\n  ", "", ""]}}
      ]

      assert parse(code) == {:ok, [{"foo", attributes, [], %{line: 1, space: "\n"}}, "\n"]}
    end

    test "boolean values" do
      code = """
      <foo
        prop1
        prop2=true
        prop3=false
        prop4
      />
      """

      attributes = [
        {"prop1", true, %{line: 2, spaces: ["\n  ", "\n  "]}},
        {"prop2", true, %{line: 3, spaces: ["", "", ""]}},
        {"prop3", false, %{line: 4, spaces: ["\n  ", "", ""]}},
        {"prop4", true, %{line: 5, spaces: ["\n  ", "\n"]}}
      ]

      assert parse(code) == {:ok, [{"foo", attributes, [], %{line: 1, space: ""}}, "\n"]}
    end
  end
end
