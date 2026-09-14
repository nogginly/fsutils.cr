require "../../spec_helper"

# Keywords outside the subset Gemini and OpenAI strict mode accept. A schema
# reaching for one of these compiles and registers fine, then fails at the
# vendor, which is an expensive place to find out.
private UNSUPPORTED_KEYWORDS = %w[$ref $defs oneOf anyOf allOf not if then else
  patternProperties additionalProperties format const]

private def walk_keys(value : JSON::Any, &block : String ->) : Nil
  if hash = value.as_h?
    hash.each do |key, nested|
      block.call(key)
      walk_keys(nested, &block)
    end
  elsif array = value.as_a?
    array.each { |nested| walk_keys(nested, &block) }
  end
end

describe FsUtils::Tools::Definition do
  it "publishes one definition per tool, in a stable order" do
    FsUtils::Tools::DEFINITIONS.map(&.name).should eq FsUtils::Tools::Names::ALL
  end

  it "names every tool uniquely and non-empty" do
    names = FsUtils::Tools::DEFINITIONS.map(&.name)
    names.uniq.size.should eq names.size
    names.each { |name| name.empty?.should be_false }
  end

  it "describes every tool" do
    FsUtils::Tools::DEFINITIONS.each do |tool|
      tool.description.size.should be > 100
    end
  end

  describe "the parameter schema" do
    it "is a JSON object with properties and required, and no bundled metadata" do
      FsUtils::Tools::DEFINITIONS.each do |tool|
        schema = JSON.parse(tool.schema)
        schema["type"].as_s.should eq "object"
        schema["properties"].as_h.empty?.should be_false

        # The parts are published separately; a protocol-shaped blob is the
        # host's to assemble.
        schema.as_h.has_key?("name").should be_false
        schema.as_h.has_key?("input_schema").should be_false
      end
    end

    it "stays inside the dialect every vendor accepts" do
      FsUtils::Tools::DEFINITIONS.each do |tool|
        walk_keys(JSON.parse(tool.schema)) do |key|
          UNSUPPORTED_KEYWORDS.includes?(key).should be_false
        end
      end
    end

    it "requires only properties it declares" do
      FsUtils::Tools::DEFINITIONS.each do |tool|
        schema = JSON.parse(tool.schema)
        declared = schema["properties"].as_h.keys
        schema["required"].as_a.each do |name|
          declared.includes?(name.as_s).should be_true
        end
      end
    end
  end

  describe "cross-references" do
    # A description naming a tool the host did not register sends a model at
    # something that is not there. Single-sourcing the names is what keeps
    # these honest; this is the spec that notices when it stops working.
    it "names only tools that exist" do
      known = FsUtils::Tools::Names::ALL

      FsUtils::Tools::DEFINITIONS.each do |tool|
        tool.description.scan(/\b[a-z]+(?:_[a-z]+)+\b/) do |match|
          word = match[0]
          next unless word.ends_with?("_file") || word.ends_with?("_files") ||
                      word.ends_with?("_contents") || word == "text_replace"
          known.includes?(word).should be_true
        end
      end
    end
  end
end
