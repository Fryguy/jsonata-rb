# frozen_string_literal: true

require "json"
require "pathname"

JSONATA_DIR = Pathname.new(__dir__).join("../jsonata").expand_path
GROUPS_DIR = JSONATA_DIR.join("test/test-suite/groups")
DATASETS_DIR = JSONATA_DIR.join("test/test-suite/datasets")

GROUPS = GROUPS_DIR.children.map { |g| g.basename.to_s }.sort
DATASETS = DATASETS_DIR.glob("*.json").to_h do |f|
  [f.basename(".json").to_s, JSON.load_file(f)]
end

def resolve_dataset(testcase)
  return testcase["data"] if testcase.key?("data")
  return nil if testcase["dataset"].nil?
  return DATASETS[testcase["dataset"]] if DATASETS.key?(testcase["dataset"])
  raise "Unable to find dataset #{testcase["dataset"]} among known datasets, are you sure the datasets directory has a file named #{testcase["dataset"]}.json?"
end

RSpec.describe "JSONata Test Suite" do
  GROUPS.each do |group|
    filenames = GROUPS_DIR.join(group).glob("*.json").sort
    cases = filenames.flat_map do |file|
      json =
        begin
          JSON.load_file(file)
        rescue JSON::ParserError => err
          raise unless err.message.include?("incomplete surrogate pair")
          # TODO: Deal with incomplete surrogate pairs. For now just return nil
          nil
        end
      next if json.nil?

      json = [json] unless json.is_a?(Array)
      json.each { |j| j["description"] ||= file.basename }
      json
    end.compact

    describe "Group: #{group}" do
      cases.each do |testcase|
        if testcase["expr-file"]
          testcase["expr"] = GROUPS_DIR.join(group, testcase["expr-file"]).read
        end

        it "#{testcase["description"]}: #{testcase["expr"]}" do
          pending

          begin
            expr = Jsonata.new(testcase["expr"])

            if testcase["timelimit"] && testcase["depth"]
              # TODO: Implement timeout and depth checks
            end
          rescue Jsonata::Error => e
            raise unless testcase["code"]

            expect(e.code).to eq(testcase["code"])
            expect(e.token).to eq(testcase["token"]) if testcase.key?("token")
          end

          if expr
            # Load the input data set.  First, check to see if the test case defines its own input
            # data (testcase["data"]).  If not, then look for a dataset number.  If it is -1, then that
            # means there is no data (so use undefined).  If there is a dataset number, look up the
            # input data in the datasets array.
            dataset = resolve_dataset(testcase)

            # Test cases have three possible outcomes from evaluation...
            if testcase.key?("undefinedResult")
              # First is that we have an undefined result.  So, check
              # to see if the result we get from evaluation is undefined
              result = expr.evaluate(dataset, testcase["bindings"])
              expect(result).to eq(nil)
            elsif testcase.key?("result")
              # Second is that a (defined) result was provided.  In this case,
              # we do a deep equality check against the expected result.
              result = expr.evaluate(dataset, testcase["bindings"])
              expect(result).to eq(testcase["result"]);
            elsif testcase.key?("error")
              # If an error was expected,
              # we do a deep equality check against the expected error structure.
              expect { expr.evaluate(dataset, testcase["bindings"]) }.to raise_error(
                testcase["error"]
              )
            elsif testcase.key?("code")
              # Finally, if a `code` field was specified, we expected the
              # evaluation to fail and include the specified code in the
              # thrown exception.
              expect { expr.evaluate(dataset, testcase["bindings"]) }.to raise_error(
                an_instance_of(Jsonata::Error).and having_attributes(:code => testcase["code"])
              )
            else
              # If we get here, it means there is something wrong with
              # the test case data because there was nothing to check.
              raise "Nothing to test in this test case"
            end
          end
        end
      end
    end
  end
end
