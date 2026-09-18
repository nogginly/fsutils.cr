require "../../spec_helper"

private def convert(html : String, base_url : String? = nil) : String
  output = IO::Memory.new
  FsUtils::Web::HtmlToMarkdown.translate(IO::Memory.new(html), output, base_url)
  output.to_s
end

private def translate(html : String, max_bytes : Int64)
  FsUtils::Web::HtmlToMarkdown.translate(IO::Memory.new(html), IO::Memory.new, max_bytes: max_bytes)
end

private def truncate(html : String, max_bytes : Int64) : String
  output = IO::Memory.new
  FsUtils::Web::HtmlToMarkdown.translate(IO::Memory.new(html), output, max_bytes: max_bytes)
  output.to_s
end

describe FsUtils::Web::HtmlToMarkdown do
  it "converts headings" do
    convert("<h1>Title</h1><h2>Sub</h2>").should eq("# Title\n\n## Sub")
  end

  it "preserves whitespace-only inline elements as a single space" do
    html = %(<p>Website<span typeof="mw:Entity">&nbsp;</span>type</p>)
    convert(html).should eq("Website type")
  end

  it "renders inline formatting and code" do
    html = "<p>This is <b>bold</b>, <i>italic</i>, and <code>inline</code>.</p>"
    convert(html).should eq("This is **bold**, _italic_, and `inline`.")
  end

  it "resolves relative link hrefs to a root-relative same-origin URL" do
    html = %(<a href="/docs/x">link</a>)
    convert(html, base_url: "https://example.com/guide/")
      .should eq("[link](/docs/x)")
  end

  it "resolves relative image srcs to a root-relative same-origin URL" do
    html = %(<img src="pic.png" alt="a pic">)
    convert(html, base_url: "https://example.com/guide/page")
      .should eq("![a pic](/guide/pic.png)")
  end

  it "keeps cross-origin links fully absolute" do
    html = %(<a href="https://other.com/y">y</a>)
    convert(html, base_url: "https://example.com/guide/").should eq("[y](https://other.com/y)")
  end

  it "leaves absolute links untouched with no base_url given" do
    convert(%(<a href="https://other.com/x">x</a>)).should eq("[x](https://other.com/x)")
  end

  it "renders nested unordered lists with indentation" do
    html = "<ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>"
    result = convert(html)
    result.should contain("- one")
    result.should contain("- two")
    result.should contain("    - nested")
  end

  it "renders ordered list items with a literal leading number" do
    # CommonMark renumbers automatically, so a literal "1." per item is
    # intentional -- this documents that choice rather than testing a bug.
    html = "<ol><li>first</li><li>second</li></ol>"
    result = convert(html)
    result.should contain("1. first")
    result.should contain("1. second")
  end

  it "renders blockquotes with each line prefixed" do
    html = "<blockquote><p>line one</p><p>line two</p></blockquote>"
    convert(html).should eq("> line one\n> \n> line two")
  end

  it "renders definition lists" do
    convert("<dl><dt>Term</dt><dd>Definition text</dd></dl>")
      .should eq("**Term**\n  : Definition text")
  end

  it "preserves the code fence language from the class attribute" do
    html = %(<pre><code class="language-crystal">puts "hi"</code></pre>)
    convert(html).should eq(%(```crystal\nputs "hi"\n```))
  end

  it "renders a simple table as GFM pipe syntax" do
    html = "<table><tr><th>Name</th><th>Type</th></tr>" +
           "<tr><td>id</td><td>Int32</td></tr></table>"
    convert(html).should eq("| Name | Type |\n| --- | --- |\n| id | Int32 |")
  end

  it "falls back to raw table tags when a cell has block content" do
    html = "<table><tr><th>Name</th><th>Notes</th></tr>" +
           "<tr><td>id</td><td><p>First para.</p><p>Second para.</p></td></tr></table>"
    result = convert(html)
    result.should contain("<table>")
    result.should contain("<td>")
    result.should contain("First para.")
    result.should contain("Second para.")
  end

  it "drops elements with the hidden attribute" do
    html = "<div hidden>Secret</div><p>Visible</p>"
    convert(html).should eq("Visible")
  end

  it "drops elements with inline display:none or visibility:hidden" do
    html = %(<div style="display:none">Secret</div>) +
           %(<div style="visibility: hidden;">Also secret</div>) +
           "<p>Visible</p>"
    convert(html).should eq("Visible")
  end

  it "does not false-positive on unrelated inline styles" do
    html = %(<div style="color:red">Still visible</div>)
    convert(html).should eq("Still visible")
  end

  it "drops nav, header and footer content entirely" do
    html = "<body><nav><a href=\"/\">Home</a></nav>" +
           "<p>Real content.</p>" +
           "<footer>Copyright 2026</footer></body>"
    convert(html).should eq("Real content.")
  end

  it "prefers <main> as the conversion root when present" do
    html = "<body><header>Site header</header>" +
           "<main><p>Just this.</p></main>" +
           "<footer>Site footer</footer></body>"
    convert(html).should eq("Just this.")
  end

  it "prefers <article> as the conversion root when there is no <main>" do
    html = "<body><nav>Menu</nav><article><p>The post.</p></article></body>"
    convert(html).should eq("The post.")
  end

  describe "the output cap" do
    it "reports the bytes written and no truncation when under the cap" do
      result = translate("<h1>Title</h1>", 1_000_i64)

      result.bytes.should eq "# Title".bytesize
      result.truncated?.should be_false
    end

    it "stops the walk once the cap is reached" do
      html = "<p>#{"word " * 2_000}</p>"
      result = translate(html, 200_i64)

      result.truncated?.should be_true
      result.bytes.should be <= 200
    end

    # Cutting mid-fence or mid-table row would hand a model something it
    # cannot read, so a truncated document ends at a block boundary.
    it "cuts a truncated document back to its last blank line" do
      html = "<h1>One</h1><p>#{"a" * 400}</p><h2>Two</h2>"
      markdown = truncate(html, 300_i64)

      markdown.should eq "# One"
      markdown.should_not contain "aaa"
    end

    it "converts the whole document when no cap is given" do
      html = "<p>#{"word " * 2_000}</p>"

      FsUtils::Web::HtmlToMarkdown
        .translate(IO::Memory.new(html), IO::Memory.new)
        .truncated?.should be_false
    end
  end

  # The cell scan is recursive, so block content nested inside an inline
  # wrapper still forces the raw fallback.
  it "falls back to raw tags for block content nested inside a cell" do
    html = "<table><tr><th>Name</th></tr>" +
           "<tr><td><span><ul><li>one</li></ul></span></td></tr></table>"

    convert(html).should contain "<table>"
  end

  it "uses pipe syntax for a cell holding only inline markup" do
    html = "<table><tr><th>Name</th></tr>" +
           "<tr><td><span><b>id</b></span></td></tr></table>"

    convert(html).should eq "| Name |\n| --- |\n| **id** |"
  end
end
